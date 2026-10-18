/// FNA's voice: one entry point for everything the assistant says aloud.
///
/// [ApaVoice.speak] picks the first source that works, in this order, and
/// records which one played in the [MetricsLog] (`apa_voice_<source>_ms`,
/// the time from the call to the line being queued):
///
/// 1. **Bundled clip**: the utterance's asset id, or `sha256(textBn)` in the
///    [AssetCatalog] (no network, as before).
/// 2. **Server pre-rendered clip**: `GET /v1/apa/clips/{clipId}`, cached by
///    id for the session; 404 or 5xx goes on.
/// 3. **Server live audio**: `POST /v1/apa/why-audio` with the line's token,
///    buffered whole (a file written while `audioplayers` reads it is not
///    reliable on Android), header sizes fixed; 204, 429 or 5xx goes on, and a
///    429 silences the route for its `Retry-After` (never a retry loop).
/// 4. **Gemini TTS on Vertex** through Firebase AI Logic ([GeminiTts]) for
///    any other dynamic text: one call per text per session.
/// 5. **On-device TTS** (`flutter_tts`, `bn-BD`) only when 1-4 all fail or
///    the phone is offline, and the log says so.
///
/// A bundled or server clip is never re-synthesised. Utterances are resolved
/// one at a time, in call order, then queued on [ApaAudio]'s FIFO, so a line
/// never jumps ahead of the clip already playing.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../core/audio/apa_audio.dart';
import '../../../core/log.dart';
import '../../../data/api/api_failure.dart';
import '../../../data/api/risk_api.dart';
import '../../../data/contracts/intervene.dart';
import '../../../data/firebase/firebase_bootstrap.dart';
import '../../../data/local/local_auth_repo.dart';
import '../../../data/providers.dart';
import 'asset_catalog.dart';
import 'audioplayers_apa_audio.dart';
import 'gemini_tts.dart';
import 'metrics_log.dart';
import 'wav.dart';

const _tag = 'voice';

/// One thing FNA says. [textBn] is what is spoken (the voice is Bangla);
/// [textEn] is carried for logs and the screen, never spoken.
/// What happens when no audio can be had for a line: a chat answer may be
/// read by the phone's own engine (its only voice offline); a warning on a
/// hold or delay never is, because the hold's clip already played in the
/// assistant's voice and a second voice would be a second speaker.
enum ApaFallback { onDevice, none }

@immutable
class ApaUtterance {
  const ApaUtterance({
    required this.textBn,
    this.textEn = '',
    this.assetId,
    this.clipId,
    this.token,
    this.speakOnDevice = false,
    this.fallback = ApaFallback.onDevice,
    this.english = false,
  });

  /// A line of the server's generated warning (`InterveneResponse.lines`,
  /// `ApaWhyResponse.lines`).
  factory ApaUtterance.fromLine(
    ApaLine line, {
    ApaFallback fallback = ApaFallback.onDevice,
    bool english = false,
  }) => ApaUtterance(
    textBn: line.textBn,
    textEn: line.textEn,
    clipId: line.clipId,
    token: line.token,
    speakOnDevice: line.speakOnDevice,
    fallback: fallback,
    english: english,
  );

  final String textBn;
  final String textEn;

  /// A bundled clip id (`audio_asset_id`).
  final String? assetId;

  /// A server pre-rendered clip (`ApaLine.clip_id`).
  final String? clipId;

  /// The `/v1/apa/why-audio` token issued with exactly [textBn].
  final String? token;

  /// The server has no audio for this line. Informational: the app still
  /// tries Gemini TTS before the phone's own voice.
  final bool speakOnDevice;

  /// See [ApaFallback].
  final ApaFallback fallback;

  /// The app is in English: [textEn] is spoken (Gemini TTS in English, or
  /// the phone's English voice for a chat answer); the Bangla clips and the
  /// server's Bangla audio are skipped. The spoken line follows the app
  /// language.
  final bool english;

  @override
  String toString() =>
      'ApaUtterance(${textBn.length} chars, asset: $assetId, clip: $clipId, '
      'token: ${token != null})';
}

/// Where a line's audio came from.
enum ApaVoiceSource {
  bundled('bundled'),
  serverClip('server_clip'),
  serverLive('server_live'),
  gemini('gemini_tts'),
  onDevice('on_device_tts'),

  /// Nothing to say (empty text) or the line was cancelled by [ApaVoice.stop].
  none('none');

  const ApaVoiceSource(this.id);

  /// Log and metric id.
  final String id;

  /// The [MetricsLog] name this source records under.
  String get metric => 'apa_voice_${id}_ms';

  /// The demo-panel label (ARB `voiceSource*`).
  String label(AppLocalizations l10n) => switch (this) {
    bundled => l10n.voiceSourceBundled,
    serverClip => l10n.voiceSourceServerClip,
    serverLive => l10n.voiceSourceServerLive,
    gemini => l10n.voiceSourceGemini,
    onDevice => l10n.voiceSourceOnDevice,
    none => l10n.voiceSourceNone,
  };
}

/// What [ApaVoice] plays through: the bundled clips, audio bytes and the
/// phone's TTS. [ApaAudioOutput] adapts [ApaAudio]; tests fake it.
abstract interface class ApaVoiceOutput {
  bool hasBundled(String assetId);
  Future<void> playBundled(String assetId);

  /// Queues [bytes]; `false` when this output cannot play bytes.
  Future<bool> playBytes(String label, Uint8List bytes, String mimeType);
  Future<void> speakOnDevice(String textBn, {String language = 'bn-BD'});
  Future<void> stop();
}

/// [ApaVoiceOutput] over the app's [ApaAudio] (one queue for everything).
class ApaAudioOutput implements ApaVoiceOutput {
  ApaAudioOutput(this.audio, {this._bundled = AssetCatalog.byId});

  final ApaAudio audio;
  final Map<String, String> _bundled;

  @override
  bool hasBundled(String assetId) => _bundled.containsKey(assetId);

  @override
  Future<void> playBundled(String assetId) => audio.playAsset(assetId);

  @override
  Future<bool> playBytes(String label, Uint8List bytes, String mimeType) async {
    if (audio case final ApaBytesAudio bytesAudio) {
      await bytesAudio.playBytes(label, bytes, mimeType: mimeType);
      return true;
    }
    return false;
  }

  @override
  Future<void> speakOnDevice(String textBn, {String language = 'bn-BD'}) {
    if (audio case final AudioplayersApaAudio a) a.speechLanguage = language;
    return audio.speak(textBn);
  }

  @override
  Future<void> stop() => audio.stop();
}

class ApaVoice {
  ApaVoice({
    required this._output,
    RiskApi? Function()? api,
    String Function()? userId,
    this._gemini,
    this._metrics,
    bool Function()? isOffline,
    int Function()? nowMs,
    this.offlineWindow = const Duration(seconds: 30),
    this.defaultQuiet = const Duration(seconds: 20),
    this.maxCachedAudio = 16,
    this.ownDelivery = AppEnv.voiceOwnDelivery,
  }) : _api = api ?? (() => null),
       _userId = userId ?? (() => LocalAuthRepo.signedOutUid),
       _isOffline = isOffline ?? (() => false),
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ApaVoiceOutput _output;
  final RiskApi? Function() _api;
  final String Function() _userId;
  final GeminiTts? _gemini;
  final MetricsLog? _metrics;
  final bool Function() _isOffline;
  final int Function() _now;

  /// A network failure on a server audio route counts as offline this long.
  /// Gemini TTS in the app's own delivery before the server's clip and live
  /// audio (see [AppEnv.voiceOwnDelivery]); the server rungs stay as the
  /// fallback when Gemini is off, offline or fails.
  final bool ownDelivery;

  final Duration offlineWindow;

  /// How long a 429 without `Retry-After` keeps `/v1/apa/why-audio` quiet
  /// (risk-mw `tts.RATE_LIMIT_QUIET_S`).
  final Duration defaultQuiet;

  /// Server audio (clips by id, live audio by text) kept for the session.
  final int maxCachedAudio;

  final LinkedHashMap<String, ApaAudioBytes> _audioCache = LinkedHashMap();
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  int _offlineUntilMs = 0;
  int _liveQuietUntilMs = 0;

  /// The source of the most recent line (the demo panel's audio preview).
  final ValueNotifier<ApaVoiceSource?> lastSource = ValueNotifier(null);

  /// Every source played this session, oldest first (tests, diagnostics).
  final List<ApaVoiceSource> history = [];

  /// Says [u] from the first source that works; resolves once it is queued
  /// (not when it finishes), with the source used. Never throws.
  Future<ApaVoiceSource> speak(ApaUtterance u) {
    final generation = _generation;
    final run = _tail.then((_) => _speak(u, generation));
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run.catchError((Object e) {
      Log.w(_tag, 'speak failed', e);
      return ApaVoiceSource.none;
    });
  }

  /// Drops lines still being resolved and stops playback.
  Future<void> stop() async {
    _generation++;
    await _output.stop();
  }

  void dispose() => lastSource.dispose();

  bool get _offline => _isOffline() || _now() < _offlineUntilMs;

  Future<ApaVoiceSource> _speak(ApaUtterance u, int generation) async {
    final started = _now();
    if (u.english) return _speakEnglish(u, generation, started);
    final text = u.textBn;

    // 1. Bundled clip: the asset id, else the script's sha256.
    final asset = _bundledFor(u);
    if (asset != null) {
      if (generation != _generation) return ApaVoiceSource.none;
      await _output.playBundled(asset);
      return _played(ApaVoiceSource.bundled, started, 'asset "$asset"');
    }
    if (text.trim().isEmpty) {
      Log.w(_tag, 'no clip and no text, nothing said');
      return ApaVoiceSource.none;
    }

    String why;
    if (_offline) {
      why = 'offline';
    } else {
      final gemini = _gemini;
      final geminiOn = gemini != null && gemini.enabled;
      // The app's own delivery first (the server's is "urgent"); its
      // failure falls through to the server's audio.
      if (ownDelivery && geminiOn) {
        final wav = await gemini.wav(text);
        final audio = wav == null ? null : ApaAudioBytes(wav);
        if (audio != null && await _play(generation, 'gemini', audio)) {
          return _played(ApaVoiceSource.gemini, started, 'gemini tts');
        }
      }
      final clipId = u.clipId;
      if (clipId != null && clipId.isNotEmpty && !_offline) {
        final clip = await _serverClip(clipId);
        if (clip != null && await _play(generation, 'clip:$clipId', clip)) {
          return _played(ApaVoiceSource.serverClip, started, 'clip $clipId');
        }
      }
      final token = u.token;
      if (token != null && token.isNotEmpty && !_offline) {
        final live = await _serverLive(text, token);
        if (live != null && await _play(generation, 'live', live)) {
          return _played(ApaVoiceSource.serverLive, started, 'why-audio');
        }
      }
      if (!geminiOn) {
        why = 'no server audio, Gemini TTS off';
      } else if (_offline) {
        why = 'offline';
      } else if (ownDelivery) {
        why = 'no server audio, Gemini TTS failed';
      } else {
        final wav = await gemini.wav(text);
        final audio = wav == null ? null : ApaAudioBytes(wav);
        if (audio != null && await _play(generation, 'gemini', audio)) {
          return _played(ApaVoiceSource.gemini, started, 'gemini tts');
        }
        why = _offline ? 'offline' : 'no server audio, Gemini TTS failed';
      }
    }

    if (generation != _generation) return ApaVoiceSource.none;
    if (u.fallback == ApaFallback.none) {
      // A warning is never spoken in the phone's own voice (a product
      // rule): the hold's bundled clip already played, and the text is on screen.
      Log.w(_tag, 'not spoken ($why): warning lines never use on-device TTS');
      return ApaVoiceSource.none;
    }
    await _output.speakOnDevice(text);
    return _played(ApaVoiceSource.onDevice, started, 'fallback: $why');
  }

  /// The English UI: the English text through Gemini TTS in English, then
  /// the phone's English voice for a chat answer; a warning line with no
  /// audio stays on screen. No Bangla clip or server audio is played.
  Future<ApaVoiceSource> _speakEnglish(
    ApaUtterance u,
    int generation,
    int started,
  ) async {
    final text = u.textEn.trim();
    if (text.isEmpty) {
      Log.w(_tag, 'english: no English text, nothing said');
      return ApaVoiceSource.none;
    }
    String why;
    final gemini = _gemini;
    if (gemini == null || !gemini.enabled) {
      why = 'Gemini TTS off';
    } else if (_offline) {
      why = 'offline';
    } else {
      final wav = await gemini.wav(
        text,
        languageCode: FnaVoiceStyle.englishLanguageCode,
      );
      final audio = wav == null ? null : ApaAudioBytes(wav);
      if (audio != null && await _play(generation, 'gemini', audio)) {
        return _played(ApaVoiceSource.gemini, started, 'gemini tts, en');
      }
      why = _offline ? 'offline' : 'Gemini TTS failed';
    }
    if (generation != _generation) return ApaVoiceSource.none;
    if (u.fallback == ApaFallback.none) {
      Log.w(_tag, 'not spoken ($why): warning lines never use on-device TTS');
      return ApaVoiceSource.none;
    }
    await _output.speakOnDevice(
      text,
      language: FnaVoiceStyle.englishLanguageCode,
    );
    return _played(ApaVoiceSource.onDevice, started, 'fallback, en: $why');
  }

  String? _bundledFor(ApaUtterance u) {
    final id = u.assetId;
    if (id != null && _output.hasBundled(id)) return id;
    if (id != null && id.isNotEmpty) {
      Log.d(_tag, 'asset "$id" is not bundled; trying the text');
    }
    final hashed = AssetCatalog.idForScript(u.textBn);
    return hashed != null && _output.hasBundled(hashed) ? hashed : null;
  }

  Future<bool> _play(int generation, String label, ApaAudioBytes a) async {
    if (generation != _generation) return false;
    final bytes = Wav.fixStreamedSizes(a.bytes);
    final ok = await _output.playBytes(label, bytes, a.mimeType);
    if (!ok) Log.w(_tag, '$label: this output cannot play bytes');
    return ok;
  }

  ApaVoiceSource _played(ApaVoiceSource s, int startedMs, String detail) {
    final ms = _now() - startedMs;
    _metrics?.record(s.metric, ms);
    if (s == ApaVoiceSource.onDevice) {
      Log.w(_tag, 'played ${s.id} ($detail) after $ms ms');
    } else {
      Log.i(_tag, 'played ${s.id} ($detail) after $ms ms');
    }
    history.add(s);
    lastSource.value = s;
    return s;
  }

  ApaAudioBytes? _cached(String key) {
    final hit = _audioCache.remove(key);
    if (hit != null) _audioCache[key] = hit;
    return hit;
  }

  void _cache(String key, ApaAudioBytes a) {
    _audioCache[key] = a;
    while (_audioCache.length > maxCachedAudio) {
      _audioCache.remove(_audioCache.keys.first);
    }
  }

  Future<ApaAudioBytes?> _serverClip(String clipId) async {
    final key = 'clip:$clipId';
    final hit = _cached(key);
    if (hit != null) return hit;
    final api = _api();
    if (api == null) return null;
    try {
      final clip = await api.getApaClip(clipId);
      _cache(key, clip);
      return clip;
    } on ApiFailure catch (e) {
      _noteFailure(e);
      Log.w(_tag, 'clip $clipId unavailable: $e');
      return null;
    } on Object catch (e) {
      Log.w(_tag, 'clip $clipId failed', e);
      return null;
    }
  }

  Future<ApaAudioBytes?> _serverLive(String textBn, String token) async {
    final key = 'live:$textBn';
    final hit = _cached(key);
    if (hit != null) return hit;
    if (_now() < _liveQuietUntilMs) {
      Log.d(_tag, 'why-audio rate-limited; skipped');
      return null;
    }
    final api = _api();
    if (api == null) return null;
    try {
      final audio = await api.postApaWhyAudio(
        ApaWhyAudioRequest(userId: _userId(), textBn: textBn, token: token),
      );
      if (audio == null) {
        Log.d(_tag, 'why-audio 204: the server has no live audio');
        return null;
      }
      _cache(key, audio);
      return audio;
    } on RateLimited catch (e) {
      final quiet = e.retryAfterSeconds == null
          ? defaultQuiet
          : Duration(seconds: e.retryAfterSeconds!);
      _liveQuietUntilMs = _now() + quiet.inMilliseconds;
      Log.w(_tag, 'why-audio 429: quiet for ${quiet.inSeconds} s');
      return null;
    } on ApiFailure catch (e) {
      _noteFailure(e);
      Log.w(_tag, 'why-audio unavailable: $e');
      return null;
    } on Object catch (e) {
      Log.w(_tag, 'why-audio failed', e);
      return null;
    }
  }

  void _noteFailure(ApiFailure e) {
    if (e is NetworkFailure) {
      _offlineUntilMs = _now() + offlineWindow.inMilliseconds;
    }
  }
}

/// The session's Gemini TTS: on only with Firebase configured (App Check,
/// Vertex) and `AppEnv.geminiTts`.
final geminiTtsProvider = Provider<GeminiTts>((ref) {
  final on =
      AppEnv.geminiTts &&
      ref.watch(firebaseStatusProvider) == FirebaseStatus.configured;
  final engine = FirebaseGeminiTtsEngine();
  return GeminiTts(
    engine: engine.call,
    engineIn: engine.callIn,
    enabled: () => on,
  );
});

/// FNA's voice for the overlay and the FNA sheet. The API and the uid are
/// read only when a line has a clip or a token, so screens and tests without
/// a `riskApiProvider` override keep working.
final apaVoiceProvider = Provider<ApaVoice>((ref) {
  final voice = ApaVoice(
    output: ApaAudioOutput(ref.watch(apaAudioProvider)),
    api: () {
      try {
        return ref.read(riskApiProvider);
      } on Object catch (e) {
        Log.w(_tag, 'no risk api', e);
        return null;
      }
    },
    userId: () {
      try {
        return ref.read(currentUserProvider).value?.uid ??
            LocalAuthRepo.signedOutUid;
      } on Object {
        return LocalAuthRepo.signedOutUid;
      }
    },
    gemini: ref.watch(geminiTtsProvider),
    metrics: ref.watch(metricsLogProvider),
  );
  ref.onDispose(voice.dispose);
  return voice;
});
