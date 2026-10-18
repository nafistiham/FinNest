/// Audio ports of the FNA voice session.
///
/// The session is pure Dart and talks to the platform only through these two
/// interfaces, so tests drive it with fakes.
library;

import 'dart:typed_data';

/// FNA's voice out: 16-bit mono PCM to the phone's loudspeaker.
abstract class FnaAudioOut {
  /// Enters the voice audio session: communication mode (so the platform echo
  /// canceller hears FNA) with the loudspeaker forced. Idempotent.
  Future<void> enterSession();

  /// Restores the audio mode and routing that were active before
  /// [enterSession]. Idempotent; safe without a prior enter.
  Future<void> exitSession();

  /// Queues [pcm16] at [sampleRate] Hz for playback, in order.
  Future<void> play(Uint8List pcm16, int sampleRate);

  /// Stops playback now and drops everything queued (barge-in).
  Future<void> stop();

  /// Fires each time the player has played every byte queued so far (the
  /// buffer ran empty after at least one [play]). Never fires after [stop]
  /// until the next [play].
  Stream<void> get drained;
}

/// The customer's voice in: 16 kHz mono PCM16 chunks.
abstract class FnaAudioIn {
  /// `true` when the microphone permission is granted (asks when needed).
  Future<bool> requestPermission();

  /// `true` when the permission is denied for good ("don't ask again"); the
  /// UI then offers to open the app settings.
  Future<bool> permanentlyDenied();

  /// Starts the microphone with echo cancel, noise suppression and auto gain,
  /// voice-communication source, without touching the audio mode. Returns the
  /// PCM chunk stream (empty stream on failure; never throws).
  Future<Stream<Uint8List>> start();

  /// Stops the microphone; idempotent.
  Future<void> stop();

  /// Input level of the last chunk, 0..1, for the level bars.
  double get level;
}
