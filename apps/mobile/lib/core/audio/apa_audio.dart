import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What happened on the audio path; the overlay uses `started` to measure
/// hold-to-audio latency and the sheet uses `finished` to re-enable the mic.
sealed class AudioEvent {
  const AudioEvent(this.assetId, this.atMs);

  /// Bundled asset id, or `tts:<sha256 prefix>` for a spoken line.
  final String assetId;

  /// `DateTime.now().millisecondsSinceEpoch` when the event happened.
  final int atMs;
}

final class AudioStarted extends AudioEvent {
  const AudioStarted(super.assetId, super.atMs);
}

final class AudioFinished extends AudioEvent {
  const AudioFinished(super.assetId, super.atMs);
}

/// Apa's voice: bundled OGG clips for the fixed lines (played within 300 ms,
/// no network on the path), text-to-speech for everything else, text only when
/// both fail. Implementations never throw to callers; failures are logged and
/// reported as a missing `AudioStarted`.
///
/// Implemented by `AudioplayersApaAudio` (lib/features/intervention/logic/,
/// Task 8). Consumed by the intervention overlay (Task 8), the Apa sheet
/// (Task 9) and the demo panel (Task 12).
abstract class ApaAudio {
  /// Pre-creates one low-latency player per bundled clip. Idempotent.
  Future<void> preload();

  /// Plays a bundled clip by id. If a clip is already playing, this one is
  /// queued after it (never cut mid-sentence). Unknown ids are logged and
  /// ignored; use [playForScript] when a text fallback exists.
  Future<void> playAsset(String assetId);

  /// Plays the clip for [assetId] when bundled; otherwise the clip indexed by
  /// `sha256(scriptBn)`; otherwise speaks [scriptBn] with TTS; otherwise does
  /// nothing. Each fallback step is logged.
  Future<void> playForScript({
    required String? assetId,
    required String scriptBn,
  });

  /// Speaks Bangla text with the device TTS engine (`bn-BD`).
  Future<void> speak(String textBn);

  /// Stops playback and clears the queue.
  Future<void> stop();

  /// Whether a clip or utterance is playing right now.
  bool get isPlaying;

  /// Resolves when nothing plays and nothing is queued: at once when idle,
  /// otherwise when the last queued line has finished (or [stop] ran). A
  /// caller that just queued a line waits for that line's real end, not for
  /// the end of the clip before it.
  Future<void> whenIdle();

  Stream<AudioEvent> get events;
}

/// Test double: records what would have been played or spoken.
class FakeApaAudio implements ApaAudio {
  final List<String> played = [];
  final List<String> spoken = [];
  final List<({String? assetId, String scriptBn})> scripted = [];
  final Set<String> knownAssets = {
    'apa_hold_call_active',
    'apa_hold_screen_share',
    'apa_delay_new_payee',
    'apa_generic_caution',
  };
  final StreamController<AudioEvent> _events = StreamController.broadcast();
  bool preloaded = false;
  bool _playing = false;
  int stopCalls = 0;
  final List<Completer<void>> _idle = [];

  void _becameIdle() {
    _playing = false;
    final waiting = List.of(_idle);
    _idle.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.complete();
    }
  }

  @override
  Future<void> preload() async => preloaded = true;

  @override
  Future<void> playAsset(String assetId) async {
    played.add(assetId);
    _playing = true;
    _events.add(AudioStarted(assetId, DateTime.now().millisecondsSinceEpoch));
  }

  @override
  Future<void> playForScript({
    required String? assetId,
    required String scriptBn,
  }) async {
    scripted.add((assetId: assetId, scriptBn: scriptBn));
    if (assetId != null && knownAssets.contains(assetId)) {
      await playAsset(assetId);
    } else if (scriptBn.isNotEmpty) {
      await speak(scriptBn);
    }
  }

  @override
  Future<void> speak(String textBn) async {
    spoken.add(textBn);
    _playing = true;
    _events.add(AudioStarted('tts', DateTime.now().millisecondsSinceEpoch));
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _becameIdle();
  }

  /// Simulates the end of the current clip.
  void finish([String assetId = 'fake']) {
    _becameIdle();
    _events.add(AudioFinished(assetId, DateTime.now().millisecondsSinceEpoch));
  }

  @override
  Future<void> whenIdle() {
    if (!_playing) return Future<void>.value();
    final c = Completer<void>();
    _idle.add(c);
    return c.future;
  }

  @override
  bool get isPlaying => _playing;

  @override
  Stream<AudioEvent> get events => _events.stream;
}

/// Overridden in main with the real implementation (Task 8). Defaults to the
/// silent fake so widget tests and previews never touch the platform.
final apaAudioProvider = Provider<ApaAudio>((ref) => FakeApaAudio());
