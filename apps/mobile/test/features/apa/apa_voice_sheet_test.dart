import 'dart:typed_data';

import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/providers.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_live_service.dart';
import 'package:bhorosha/features/apa/logic/apa_mic.dart';
import 'package:bhorosha/features/intervention/logic/apa_voice.dart';
import 'package:bhorosha/features/intervention/logic/audioplayers_apa_audio.dart';
import 'package:bhorosha/features/intervention/logic/gemini_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

/// [FakeApaAudio] that can also play bytes, like the real player.
class BytesFakeApaAudio extends FakeApaAudio implements ApaBytesAudio {
  final List<String> bytesLabels = [];

  @override
  Future<void> playBytes(
    String label,
    Uint8List bytes, {
    String mimeType = 'audio/wav',
  }) async => bytesLabels.add(label);
}

/// The FNA sheet's spoken answers go through [ApaVoice]: Gemini
/// TTS for dynamic text, the phone's voice only when it fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BytesFakeApaAudio audio;
  late List<String> asked;
  late bool fail;

  ProviderContainer container() {
    audio = BytesFakeApaAudio();
    asked = [];
    final c = ProviderContainer(
      overrides: [
        riskApiProvider.overrideWithValue(FakeRiskApi()),
        apaAudioProvider.overrideWithValue(audio),
        nativeProvider.overrideWithValue(FakeBhoroshaNative()),
        apaLiveServiceProvider.overrideWithValue(
          const DisabledApaLiveService(),
        ),
        apaMicProvider.overrideWithValue(FakeApaMic()),
        geminiTtsProvider.overrideWithValue(
          GeminiTts(
            engine: (text) async {
              asked.add(text);
              if (fail) throw StateError('vertex down');
              return GeminiTtsAudio(Uint8List(48), 'audio/L16;rate=24000');
            },
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => fail = false);

  test('a dynamic answer is spoken by Gemini TTS, not the phone', () async {
    final c = container();
    await c
        .read(apaControllerProvider.notifier)
        .openFor(held: heldScore, screen: 'result');
    expect(asked, [heldFirstLineBn]);
    expect(audio.bytesLabels, ['gemini']);
    expect(audio.spoken, isEmpty);
    expect(c.read(apaVoiceProvider).lastSource.value, ApaVoiceSource.gemini);
  });

  test('Gemini failing: the phone speaks it, once', () async {
    fail = true;
    final c = container();
    await c
        .read(apaControllerProvider.notifier)
        .openFor(held: heldScore, screen: 'result');
    expect(asked, [heldFirstLineBn]);
    expect(audio.bytesLabels, isEmpty);
    expect(audio.spoken, [heldFirstLineBn]);
  });
}
