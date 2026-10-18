import 'dart:convert';
import 'dart:typed_data';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/features/intervention/logic/gemini_tts.dart';
import 'package:bhorosha/features/intervention/logic/wav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wav.header', () {
    final h = Wav.header(48000); // one second
    final v = ByteData.sublistView(h);
    String ascii(int at) => String.fromCharCodes(h.sublist(at, at + 4));

    test('44 bytes, RIFF/WAVE/fmt /data', () {
      expect(h.length, 44);
      expect(ascii(0), 'RIFF');
      expect(ascii(8), 'WAVE');
      expect(ascii(12), 'fmt ');
      expect(ascii(36), 'data');
    });

    test('24000 Hz, mono, 16-bit PCM', () {
      expect(v.getUint32(16, Endian.little), 16, reason: 'fmt chunk size');
      expect(v.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(v.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(v.getUint32(24, Endian.little), 24000);
      expect(v.getUint32(28, Endian.little), 48000, reason: 'byte rate');
      expect(v.getUint16(32, Endian.little), 2, reason: 'block align');
      expect(v.getUint16(34, Endian.little), 16);
    });

    test('sizes: RIFF = 36 + data, data = PCM bytes', () {
      expect(v.getUint32(4, Endian.little), 36 + 48000);
      expect(v.getUint32(40, Endian.little), 48000);
    });

    test('wrapPcm puts the samples after the header', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      final wav = Wav.wrapPcm(pcm);
      expect(wav.length, 48);
      expect(wav.sublist(44), pcm);
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 4);
      expect(Wav.duration(wav), const Duration(microseconds: 83));
    });

    test('rateOf reads the PCM mime type', () {
      expect(Wav.rateOf('audio/L16;codec=pcm;rate=24000'), 24000);
      expect(Wav.rateOf('audio/L16;rate=16000'), 16000);
      expect(Wav.rateOf('audio/pcm'), 24000);
    });

    test('a non-WAV (OGG) passes fixStreamedSizes untouched', () {
      final ogg = Uint8List.fromList([
        ...'OggS'.codeUnits,
        ...List.filled(60, 0),
      ]);
      expect(identical(Wav.fixStreamedSizes(ogg), ogg), isTrue);
      expect(Wav.duration(ogg), isNull);
    });
  });

  group('GeminiTtsAudio.toWav', () {
    test('raw PCM is wrapped at the mime rate; a WAV is kept', () {
      final pcm = Uint8List(32);
      final wav = GeminiTtsAudio(pcm, 'audio/L16;codec=pcm;rate=24000').toWav();
      expect(wav.length, 76);
      expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 24000);
      final whole = Wav.wrapPcm(pcm);
      expect(
        identical(GeminiTtsAudio(whole, 'audio/wav').toWav(), whole),
        isTrue,
      );
    });
  });

  group('the request matches risk-mw app/tts.py', () {
    test('the model, location and voice are the server\'s', () {
      expect(AppEnv.geminiTts, isTrue);
      // Gemini 3.8 TTS for dynamic lines: Lite is the server's engine;
      // Flash is the fallback.
      expect(AppEnv.geminiTtsModel, 'gemini-3.8-flash-lite-tts');
      expect(AppEnv.geminiTtsFallbackModel, 'gemini-3.8-flash-tts');
      expect(AppEnv.geminiTtsLocation, 'global');
      expect(FnaVoiceStyle.voiceName, 'Sulafat');
      expect(FnaVoiceStyle.languageCode, 'bn-BD');
    });

    test('generation config: audio out, Sulafat, bn-BD', () {
      final json = FirebaseGeminiTtsEngine.generationConfig.toJson();
      expect(json['responseModalities'], ['AUDIO']);
      expect(jsonEncode(json['speechConfig']), contains('"Sulafat"'));
      expect(jsonEncode(json['speechConfig']), contains('"bn-BD"'));
    });

    test('3.8: the style is metadata and the text is exactly the line', () {
      const line = 'কোড কাউকে দেবেন না।';
      final c = FirebaseGeminiTtsEngine.contentFor(
        'gemini-3.8-flash-tts',
        line,
      );
      final json = c.toJson();
      final part = (json['parts']! as List).single as Map<String, Object?>;
      expect(part['text'], line, reason: 'nothing read aloud is prepended');
      expect(part['speechMetadata'], {'style': FnaVoiceStyle.urgentStyle});
    });

    test('2.x takes the style before the text, as the clips were made', () {
      final c = FirebaseGeminiTtsEngine.contentFor('gemini-2.5-flash-tts', 'x');
      final part = (c.toJson()['parts']! as List).single as Map;
      expect(part['text'], '${FnaVoiceStyle.urgentStyle}: x');
    });

    test('style off sends the bare line', () {
      final c = FirebaseGeminiTtsEngine.contentFor(
        'gemini-3.8-flash-lite-tts',
        'x',
        style: false,
      );
      expect((c.toJson()['parts']! as List).single, {'text': 'x'});
    });

    test('the style: Bangladeshi Bengali, a calm professional customer-care '
        'agent, never excited or over-familiar, no trailing ": "', () {
      expect(FnaVoiceStyle.urgentStyle, startsWith('Speak in Bangladeshi '));
      expect(FnaVoiceStyle.urgentStyle, contains('Dhaka accent'));
      expect(FnaVoiceStyle.urgentStyle, contains('customer-care agent'));
      expect(FnaVoiceStyle.urgentStyle, contains('empathetic'));
      expect(FnaVoiceStyle.urgentStyle, contains('never excited'));
      expect(FnaVoiceStyle.urgentStyle, contains('no drama'));
      expect(FnaVoiceStyle.urgentStyle, endsWith('or panicked'));
      expect(FnaVoiceStyle.urgentStyle, isNot(contains('older sister')));
      expect(FnaVoiceStyle.urgentStyle, isNot(endsWith(': ')));
    });
  });
}
