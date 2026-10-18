/// Android implementations of the FNA voice audio ports: [NativeFnaAudioOut]
/// over the `bhorosha_native` bridge and [RecordFnaAudioIn] over the `record`
/// package.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/features/apa/voice/fna_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// FNA's voice out through the native PCM player and voice audio session.
///
/// The bridge never throws; this class still guards every call so a test
/// double or a future bridge change cannot break the voice session.
class NativeFnaAudioOut implements FnaAudioOut {
  NativeFnaAudioOut(this._native);

  static const _tag = 'fna.audio.out';

  final BhoroshaNative _native;

  @override
  Future<void> enterSession() =>
      _guard('enterSession', _native.enterVoiceSession);

  @override
  Future<void> exitSession() => _guard('exitSession', _native.exitVoiceSession);

  @override
  Future<void> play(Uint8List pcm16, int sampleRate) =>
      _guard('play', () => _native.playPcm(pcm16, sampleRate));

  @override
  Future<void> stop() => _guard('stop', _native.stopPcm);

  @override
  Stream<void> get drained => _native.events
      .where((NativeEvent e) => e is PcmDrainedEvent)
      .map<void>((_) {});

  Future<void> _guard(String what, Future<void> Function() call) async {
    try {
      await call();
    } on Object catch (e) {
      Log.w(_tag, '$what failed', e);
    }
  }
}

/// The customer's voice in: `record` with the platform echo canceller, noise
/// suppressor and auto gain on the voice-communication source.
///
/// The recorder must not own the audio mode ([VoiceAudioSession] on the
/// Kotlin side does): mode "normal" means "do not touch", no speakerphone, no
/// Bluetooth SCO, and interruptions do not pause it.
class RecordFnaAudioIn implements FnaAudioIn {
  RecordFnaAudioIn({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  static const _tag = 'fna.audio.in';

  /// The exact capture configuration ("Recorder" row).
  static const RecordConfig config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    echoCancel: true,
    noiseSuppress: true,
    autoGain: true,
    audioInterruption: AudioInterruptionMode.none,
    androidConfig: AndroidRecordConfig(
      audioSource: AndroidAudioSource.voiceCommunication,
      audioManagerMode: AudioManagerMode.modeNormal,
      speakerphone: false,
      manageBluetooth: false,
    ),
  );

  final AudioRecorder _recorder;
  double _level = 0;

  @override
  double get level => _level;

  @override
  Future<bool> requestPermission() async {
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } on Object catch (e) {
      Log.w(_tag, 'permission request failed', e);
      return false;
    }
  }

  @override
  Future<bool> permanentlyDenied() async {
    try {
      return await Permission.microphone.isPermanentlyDenied;
    } on Object catch (e) {
      Log.w(_tag, 'permission status failed', e);
      return false;
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    try {
      final stream = await _recorder.startStream(config);
      return stream
          .map((Uint8List chunk) {
            _level = rmsLevel(chunk);
            return chunk;
          })
          .handleError((Object e) => Log.w(_tag, 'pcm stream error', e));
    } on Object catch (e) {
      Log.w(_tag, 'startStream failed', e);
      return const Stream<Uint8List>.empty();
    }
  }

  @override
  Future<void> stop() async {
    _level = 0;
    // Unconditional: during startStream isRecording() can still be false,
    // and a stop that waits for it would leave the mic open.
    try {
      await _recorder.stop();
    } on Object catch (e) {
      Log.w(_tag, 'stop failed', e);
    }
  }

  /// Releases the recorder; called when the provider is disposed.
  Future<void> dispose() async {
    _level = 0;
    try {
      await _recorder.dispose();
    } on Object catch (e) {
      Log.w(_tag, 'dispose failed', e);
    }
  }

  /// RMS of a PCM16 little-endian [chunk], normalised to 0..1 (full scale is
  /// 32768). An empty chunk or a trailing odd byte is ignored.
  static double rmsLevel(Uint8List chunk) {
    final samples = chunk.lengthInBytes ~/ 2;
    if (samples == 0) return 0;
    final data = ByteData.sublistView(chunk);
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final s = data.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    final rms = math.sqrt(sum / samples) / 32768.0;
    return rms > 1 ? 1 : rms;
  }
}

/// Overridden with `FakeFnaAudioOut` in tests.
final fnaAudioOutProvider = Provider<FnaAudioOut>(
  (ref) => NativeFnaAudioOut(ref.watch(nativeProvider)),
);

/// Overridden with `FakeFnaAudioIn` in tests.
final fnaAudioInProvider = Provider<FnaAudioIn>((ref) {
  final mic = RecordFnaAudioIn();
  ref.onDispose(mic.dispose);
  return mic;
});
