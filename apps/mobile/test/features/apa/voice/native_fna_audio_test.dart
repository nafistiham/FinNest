import 'dart:typed_data';

import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/features/apa/voice/fna_audio.dart';
import 'package:bhorosha/features/apa/voice/native_fna_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import 'fna_audio_fakes.dart';

Uint8List pcm(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('RecordFnaAudioIn.rmsLevel', () {
    test('silence and empty chunks are 0', () {
      expect(RecordFnaAudioIn.rmsLevel(Uint8List(0)), 0);
      expect(RecordFnaAudioIn.rmsLevel(Uint8List(1)), 0);
      expect(RecordFnaAudioIn.rmsLevel(pcm([0, 0, 0, 0])), 0);
    });

    test('a constant half-scale signal is 0.5', () {
      expect(
        RecordFnaAudioIn.rmsLevel(pcm([16384, -16384, 16384, -16384])),
        closeTo(0.5, 1e-9),
      );
    });

    test('full scale clamps to 1 and samples are little-endian', () {
      expect(RecordFnaAudioIn.rmsLevel(pcm([-32768, -32768])), 1);
      // 0x0100 LE = 256, not 1.
      expect(
        RecordFnaAudioIn.rmsLevel(Uint8List.fromList([0x00, 0x01])),
        closeTo(256 / 32768, 1e-12),
      );
    });

    test('RMS of a mixed chunk', () {
      // sqrt((3000^2 + 4000^2) / 2) / 32768
      expect(
        RecordFnaAudioIn.rmsLevel(pcm([3000, -4000])),
        closeTo(3535.533905932738 / 32768, 1e-9),
      );
    });

    test('a trailing odd byte is ignored', () {
      final odd = Uint8List.fromList([
        ...pcm([16384, -16384]),
        0x7f,
      ]);
      expect(RecordFnaAudioIn.rmsLevel(odd), closeTo(0.5, 1e-9));
    });
  });

  group('RecordFnaAudioIn.stop', () {
    test('stops even while isRecording() is still false', () async {
      final rec = _Recorder();
      final mic = RecordFnaAudioIn(recorder: rec);
      await mic.stop();
      expect(rec.stops, 1);
    });

    test('a failing stop is swallowed', () async {
      final rec = _Recorder()..throwOnStop = true;
      await RecordFnaAudioIn(recorder: rec).stop();
      expect(rec.stops, 1);
    });
  });

  group('RecordFnaAudioIn.config', () {
    test('is 16 kHz mono PCM16', () {
      const c = RecordFnaAudioIn.config;
      expect(c.encoder, AudioEncoder.pcm16bits);
      expect(c.sampleRate, 16000);
      expect(c.numChannels, 1);
      expect(c.echoCancel, isTrue);
      expect(c.noiseSuppress, isTrue);
      expect(c.autoGain, isTrue);
      expect(c.audioInterruption, AudioInterruptionMode.none);
      final a = c.androidConfig;
      expect(a.audioSource, AndroidAudioSource.voiceCommunication);
      expect(a.audioManagerMode, AudioManagerMode.modeNormal);
      expect(a.speakerphone, isFalse);
      expect(a.manageBluetooth, isFalse);
    });
  });

  group('NativeFnaAudioOut', () {
    late FakeBhoroshaNative native;
    late NativeFnaAudioOut out;

    setUp(() {
      native = FakeBhoroshaNative();
      out = NativeFnaAudioOut(native);
    });

    tearDown(() => native.dispose());

    test('delegates enter, exit, play and stop to the bridge', () async {
      await out.enterSession();
      await out.play(Uint8List.fromList([1, 2]), 24000);
      await out.stop();
      await out.exitSession();
      await out.exitSession();

      expect(native.enterVoiceSessionCalls, 1);
      expect(native.exitVoiceSessionCalls, 2);
      expect(native.pcmChunks, [
        Uint8List.fromList([1, 2]),
      ]);
      expect(native.pcmSampleRates, [24000]);
      expect(native.stopPcmCalls, 1);
    });

    test('drained carries only pcm_drained events', () async {
      var drained = 0;
      final sub = out.drained.listen((_) => drained++);

      native.emit(const ObscuredTouchEvent());
      native.emit(const PcmDrainedEvent());
      native.emit(const ScreenCaptureEvent(true));
      native.emit(const PcmDrainedEvent());
      await pumpEventQueue();

      expect(drained, 2);
      await sub.cancel();
    });
  });

  group('PcmDrainedEvent wire format', () {
    test('decodes {type: pcm_drained}; unknown types stay dropped', () {
      expect(
        NativeEvent.fromMap({'type': 'pcm_drained'}),
        const PcmDrainedEvent(),
      );
      expect(NativeEvent.fromMap({'type': 'pcm_drain'}), isNull);
    });
  });

  group('providers', () {
    test('fnaAudioOutProvider wraps nativeProvider', () async {
      final native = FakeBhoroshaNative();
      final container = ProviderContainer(
        overrides: [nativeProvider.overrideWithValue(native)],
      );
      addTearDown(container.dispose);
      addTearDown(native.dispose);

      final FnaAudioOut out = container.read(fnaAudioOutProvider);
      expect(out, isA<NativeFnaAudioOut>());
      await out.enterSession();
      expect(native.enterVoiceSessionCalls, 1);
    });
  });

  group('fakes', () {
    test('FakeFnaAudioOut records calls and emits drained', () async {
      final out = FakeFnaAudioOut();
      addTearDown(out.dispose);
      final drained = out.drained.first;
      await out.enterSession();
      await out.play(Uint8List(4), 24000);
      out.emitDrained();
      await drained;
      await out.stop();
      await out.exitSession();
      expect(out.enters, 1);
      expect(out.exits, 1);
      expect(out.stops, 1);
      expect(out.played.single.length, 4);
      expect(out.inSession, isFalse);
    });

    test('FakeFnaAudioIn scripts permission and streams pushed PCM', () async {
      final mic = FakeFnaAudioIn(granted: false, deniedForGood: true);
      expect(await mic.requestPermission(), isFalse);
      expect(await mic.permanentlyDenied(), isTrue);
      final stream = await mic.start();
      final first = stream.first;
      mic.push(pcm([1, 2]));
      expect((await first).length, 4);
      mic.level = 0.3;
      expect(mic.level, 0.3);
      await mic.stop();
      expect(mic.running, isFalse);
    });
  });
}

/// A recorder that is "not recording yet" (startStream still in flight).
class _Recorder implements AudioRecorder {
  int stops = 0;
  bool throwOnStop = false;

  @override
  Future<bool> isRecording() async => false;

  @override
  Future<String?> stop() async {
    stops++;
    if (throwOnStop) throw StateError('stop');
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
