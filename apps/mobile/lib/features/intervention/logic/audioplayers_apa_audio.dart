import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' hide AudioEvent;
import 'package:flutter_tts/flutter_tts.dart';

import '../../../core/audio/apa_audio.dart';
import '../../../core/ids.dart';
import '../../../core/log.dart';
import 'asset_catalog.dart';
import 'wav.dart';

typedef PlayerFactory = AudioPlayer Function();

/// Plays audio bytes (a server clip, server live audio, a Gemini TTS WAV)
/// through the same FIFO queue as the bundled clips, so FNA's dynamic "why"
/// always follows the clip already playing (`ApaVoice`).
abstract interface class ApaBytesAudio {
  /// Queues [bytes]; [label] names it in the [AudioEvent]s (`voice:<label>`).
  Future<void> playBytes(
    String label,
    Uint8List bytes, {
    String mimeType = 'audio/wav',
  });
}

typedef TtsFactory = FlutterTts Function();

const _tag = 'audio';

/// Apa's voice on a real device (audio paragraph).
///
/// * One `AudioPlayer` per bundled clip, created and sourced by [preload] in
///   `PlayerMode.lowLatency` (SoundPool), so the first audible frame follows the
///   `ScoreResponse` within 300 ms.
/// * A FIFO queue: a new clip or utterance starts only after the current one
///   has finished; nothing is ever cut mid-sentence. Low-latency players fire no
///   completion event, so each clip also has a timer at its known length.
/// * Fallback chain in [playForScript]: asset id -> `sha256(script)` index ->
///   `flutter_tts` (`bn-BD`) -> nothing, each step logged.
/// * Every platform call is guarded; failures are logged and surface only as a
///   missing [AudioStarted].
///
/// Register in `main` with
/// `apaAudioProvider.overrideWithValue(AudioplayersApaAudio()..preload())`.
class AudioplayersApaAudio implements ApaAudio, ApaBytesAudio {
  AudioplayersApaAudio({
    PlayerFactory? createPlayer,
    TtsFactory? createTts,
    Map<String, String> assets = AssetCatalog.byId,
    Map<String, int> durationsMs = AssetCatalog.durationMs,
    int Function()? nowMs,
    this.completionGrace = const Duration(milliseconds: 400),
    this.unknownClipBudget = const Duration(seconds: 15),
  }) : _newPlayer = createPlayer ?? AudioPlayer.new,
       _newTts = createTts ?? FlutterTts.new,
       _assets = Map.unmodifiable(assets),
       _durations = Map.unmodifiable(durationsMs),
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PlayerFactory _newPlayer;
  final TtsFactory _newTts;
  final Map<String, String> _assets;
  final Map<String, int> _durations;
  final int Function() _now;

  /// Added to a clip's known length before the queue moves on without a
  /// completion event.
  final Duration completionGrace;

  /// Queue budget for a clip whose length is not in the catalog.
  final Duration unknownClipBudget;

  final Map<String, AudioPlayer> _players = {};

  /// The player of the bytes job now playing (one per job, disposed after).
  AudioPlayer? _bytesPlayer;
  FlutterTts? _tts;
  void Function()? _ttsStarted;
  void Function()? _ttsFinished;

  final Queue<_Job> _queue = Queue();
  _Job? _current;
  bool _pumping = false;
  bool _disposed = false;
  final StreamController<AudioEvent> _events = StreamController.broadcast();

  /// Players created so far, by asset id (for tests and diagnostics).
  Map<String, AudioPlayer> get players => Map.unmodifiable(_players);

  /// Asset ids waiting behind the current clip (for tests and diagnostics).
  List<String> get queued => [for (final j in _queue) j.label];

  @override
  Stream<AudioEvent> get events => _events.stream;

  @override
  bool get isPlaying => _current != null;

  final List<Completer<void>> _idle = [];

  @override
  Future<void> whenIdle() {
    if (_current == null && _queue.isEmpty && !_pumping) {
      return Future<void>.value();
    }
    final c = Completer<void>();
    _idle.add(c);
    return c.future;
  }

  void _notifyIdle() {
    final waiting = List.of(_idle);
    _idle.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.complete();
    }
  }

  @override
  Future<void> preload() async {
    for (final e in _assets.entries) {
      if (_players.containsKey(e.key)) continue;
      final p = await _createPlayer(e.key, e.value);
      if (p != null) _players[e.key] = p;
    }
    Log.d(_tag, 'preloaded ${_players.length}/${_assets.length} clips');
  }

  @override
  Future<void> playAsset(String assetId) async {
    if (!_assets.containsKey(assetId)) {
      Log.w(_tag, 'playAsset: unknown asset "$assetId", nothing played');
      return;
    }
    _enqueue(_ClipJob(assetId));
  }

  @override
  Future<void> playForScript({
    required String? assetId,
    required String scriptBn,
  }) async {
    if (assetId != null && _assets.containsKey(assetId)) {
      Log.d(_tag, 'playForScript: asset "$assetId"');
      _enqueue(_ClipJob(assetId));
      return;
    }
    if (assetId != null && assetId.isNotEmpty) {
      Log.w(_tag, 'playForScript: unknown asset "$assetId", trying the script');
    }
    final hashed = AssetCatalog.idForScript(scriptBn);
    if (hashed != null && _assets.containsKey(hashed)) {
      Log.d(_tag, 'playForScript: sha256 index -> "$hashed"');
      _enqueue(_ClipJob(hashed));
      return;
    }
    if (scriptBn.trim().isNotEmpty) {
      Log.d(
        _tag,
        'playForScript: no clip, TTS fallback (${scriptBn.length} chars)',
      );
      _enqueue(_TtsJob(scriptBn));
      return;
    }
    Log.w(_tag, 'playForScript: no clip and no text, nothing played');
  }

  /// The language of the next on-device utterance (`bn-BD`, or `en-US`
  /// for the English UI); set by the voice stack before [speak].
  String speechLanguage = 'bn-BD';
  String _ttsLanguage = 'bn-BD';

  @override
  Future<void> speak(String textBn) async {
    if (textBn.trim().isEmpty) return;
    _enqueue(_TtsJob(textBn, speechLanguage));
  }

  @override
  Future<void> playBytes(
    String label,
    Uint8List bytes, {
    String mimeType = 'audio/wav',
  }) async {
    if (bytes.isEmpty) {
      Log.w(_tag, 'playBytes "$label": no bytes, nothing played');
      return;
    }
    _enqueue(_BytesJob(label, bytes, mimeType));
  }

  @override
  Future<void> stop() async {
    _queue.clear();
    final cur = _current;
    if (cur is _ClipJob) {
      try {
        await _players[cur.assetId]?.stop();
      } catch (e) {
        Log.w(_tag, 'stop clip failed', e);
      }
    }
    if (cur is _BytesJob) {
      try {
        await _bytesPlayer?.stop();
      } catch (e) {
        Log.w(_tag, 'stop bytes failed', e);
      }
    }
    final tts = _tts;
    if (tts != null) {
      try {
        await tts.stop();
      } catch (e) {
        Log.w(_tag, 'stop tts failed', e);
      }
    }
    cur?.finish();
  }

  /// Releases every player and closes the event stream. Not part of
  /// [ApaAudio]; call from the owning provider's `onDispose`.
  Future<void> dispose() async {
    _disposed = true;
    await stop();
    _notifyIdle();
    for (final p in _players.values) {
      try {
        await p.dispose();
      } catch (e) {
        Log.w(_tag, 'dispose player failed', e);
      }
    }
    _players.clear();
    await _events.close();
  }

  // ---------------------------------------------------------------- queue --

  void _enqueue(_Job job) {
    if (_disposed) return;
    _queue.add(job);
    if (!_pumping) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final job = _queue.removeFirst();
        _current = job;
        try {
          switch (job) {
            case _ClipJob():
              await _runClip(job);
            case _TtsJob():
              await _runTts(job);
            case _BytesJob():
              await _runBytes(job);
          }
        } catch (e) {
          Log.w(_tag, 'job ${job.label} failed', e);
        } finally {
          _current = null;
        }
      }
    } finally {
      _pumping = false;
      _notifyIdle();
    }
  }

  void _emit(AudioEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ---------------------------------------------------------------- clips --

  Future<AudioPlayer?> _createPlayer(String id, String file) async {
    try {
      final p = _newPlayer();
      await p.setPlayerMode(PlayerMode.lowLatency);
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setSource(AssetSource(_assetSourcePath(file)));
      return p;
    } catch (e) {
      Log.w(_tag, 'preload "$id" failed', e);
      return null;
    }
  }

  /// `AssetSource` already prefixes `assets/` (AudioCache default).
  static String _assetSourcePath(String file) =>
      file.startsWith('assets/') ? file.substring('assets/'.length) : file;

  Future<void> _runClip(_ClipJob job) async {
    final id = job.assetId;
    var player = _players[id];
    if (player == null) {
      final file = _assets[id];
      if (file == null) return;
      player = await _createPlayer(id, file);
      if (player == null) {
        Log.w(_tag, 'clip "$id" unavailable, skipped');
        return;
      }
      _players[id] = player;
    }

    var started = false;
    void markStarted() {
      if (started) return;
      started = true;
      _emit(AudioStarted(id, _now()));
    }

    StreamSubscription<PlayerState>? stateSub;
    StreamSubscription<void>? completeSub;
    Timer? timer;
    try {
      // Rewind a clip that was played before; must precede the subscriptions
      // because stop() reports `stopped` on the state stream.
      await player.stop();
      stateSub = player.onPlayerStateChanged.listen((s) {
        switch (s) {
          case PlayerState.playing:
            markStarted();
          case PlayerState.completed ||
              PlayerState.stopped ||
              PlayerState.disposed:
            job.finish();
          case PlayerState.paused:
            break;
        }
      });
      completeSub = player.onPlayerComplete.listen((_) => job.finish());
      await player.resume();
      markStarted();
      final budget = _durations[id];
      timer = Timer(
        budget == null
            ? unknownClipBudget
            : Duration(milliseconds: budget) + completionGrace,
        () {
          Log.d(_tag, 'clip "$id": no completion event, timer ended it');
          job.finish();
        },
      );
      await job.done.future;
    } catch (e) {
      Log.w(_tag, 'play "$id" failed', e);
    } finally {
      timer?.cancel();
      await stateSub?.cancel();
      await completeSub?.cancel();
      if (started) _emit(AudioFinished(id, _now()));
    }
  }

  // ---------------------------------------------------------------- bytes --

  Future<void> _runBytes(_BytesJob job) async {
    final id = 'voice:${job.label}';
    AudioPlayer? player;
    var started = false;
    void markStarted() {
      if (started) return;
      started = true;
      _emit(AudioStarted(id, _now()));
    }

    StreamSubscription<PlayerState>? stateSub;
    StreamSubscription<void>? completeSub;
    Timer? timer;
    try {
      player = _newPlayer();
      _bytesPlayer = player;
      await player.setReleaseMode(ReleaseMode.release);
      await player.setSource(BytesSource(job.bytes, mimeType: job.mimeType));
      stateSub = player.onPlayerStateChanged.listen((s) {
        switch (s) {
          case PlayerState.playing:
            markStarted();
          case PlayerState.completed ||
              PlayerState.stopped ||
              PlayerState.disposed:
            if (started) job.finish();
          case PlayerState.paused:
            break;
        }
      });
      completeSub = player.onPlayerComplete.listen((_) => job.finish());
      await player.resume();
      markStarted();
      final length = Wav.duration(job.bytes);
      timer = Timer(
        length == null ? unknownClipBudget : length + completionGrace,
        () {
          Log.d(_tag, '$id: no completion event, timer ended it');
          job.finish();
        },
      );
      await job.done.future;
    } catch (e) {
      Log.w(_tag, 'play "$id" failed', e);
    } finally {
      timer?.cancel();
      await stateSub?.cancel();
      await completeSub?.cancel();
      if (identical(_bytesPlayer, player)) _bytesPlayer = null;
      try {
        await player?.dispose();
      } catch (e) {
        Log.w(_tag, 'dispose bytes player failed', e);
      }
      if (started) _emit(AudioFinished(id, _now()));
    }
  }

  // ------------------------------------------------------------------ tts --

  Future<FlutterTts?> _ensureTts() async {
    final existing = _tts;
    if (existing != null) return existing;
    try {
      final t = _newTts();
      t.setStartHandler(() => _ttsStarted?.call());
      t.setCompletionHandler(() => _ttsFinished?.call());
      t.setCancelHandler(() => _ttsFinished?.call());
      t.setErrorHandler((Object? message) {
        Log.w(_tag, 'tts error: $message');
        _ttsFinished?.call();
      });
      await t.setLanguage('bn-BD');
      _ttsLanguage = 'bn-BD';
      await t.awaitSpeakCompletion(true);
      _tts = t;
      return t;
    } catch (e) {
      Log.w(_tag, 'tts unavailable', e);
      return null;
    }
  }

  Future<void> _runTts(_TtsJob job) async {
    final tts = await _ensureTts();
    if (tts == null) {
      Log.w(_tag, 'tts: engine missing, text only');
      return;
    }
    final text = job.text;
    final id = 'tts:${sha256Hex(text).substring(0, 12)}';

    var started = false;
    void markStarted() {
      if (started) return;
      started = true;
      _emit(AudioStarted(id, _now()));
    }

    _ttsStarted = markStarted;
    _ttsFinished = job.finish;
    // Rough Bangla speaking rate plus slack; only a backstop for a silent engine.
    final timer = Timer(Duration(milliseconds: 2000 + 90 * text.length), () {
      Log.d(_tag, 'tts: no completion callback, timer ended it');
      job.finish();
    });
    try {
      if (job.language != _ttsLanguage) {
        await tts.setLanguage(job.language);
        _ttsLanguage = job.language;
      }
      final result = await tts.speak(text);
      if (result == 0) {
        Log.w(_tag, 'tts: speak returned 0 (engine refused), text only');
        job.finish();
      } else {
        // awaitSpeakCompletion(true) resolves at the end of the utterance; the
        // engine spoke even if its start callback never reached us.
        markStarted();
        job.finish();
      }
      await job.done.future;
    } catch (e) {
      Log.w(_tag, 'tts: speak failed', e);
      job.finish();
    } finally {
      timer.cancel();
      _ttsStarted = null;
      _ttsFinished = null;
      if (started) _emit(AudioFinished(id, _now()));
    }
  }
}

sealed class _Job {
  final Completer<void> done = Completer<void>();

  String get label;

  void finish() {
    if (!done.isCompleted) done.complete();
  }
}

final class _ClipJob extends _Job {
  _ClipJob(this.assetId);
  final String assetId;
  @override
  String get label => assetId;
}

final class _TtsJob extends _Job {
  _TtsJob(this.text, [this.language = 'bn-BD']);
  final String text;
  final String language;
  @override
  String get label => 'tts';
}

final class _BytesJob extends _Job {
  _BytesJob(this.label, this.bytes, this.mimeType);
  @override
  final String label;
  final Uint8List bytes;
  final String mimeType;
}
