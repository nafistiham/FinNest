import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/intervention/logic/apa_voice.dart';
import 'package:bhorosha/features/intervention/logic/asset_catalog.dart';
import 'package:bhorosha/features/intervention/logic/gemini_tts.dart';
import 'package:bhorosha/features/intervention/logic/metrics_log.dart';
import 'package:bhorosha/features/intervention/logic/wav.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what would have played, in order: `bundled:<id>`,
/// `bytes:<label>`, `device:<text>`.
class FakeVoiceOutput implements ApaVoiceOutput {
  FakeVoiceOutput({this.canPlayBytes = true});

  final bool canPlayBytes;
  final List<String> log = [];
  final List<Uint8List> bytesPlayed = [];
  int stops = 0;

  @override
  bool hasBundled(String assetId) => AssetCatalog.byId.containsKey(assetId);

  @override
  Future<void> playBundled(String assetId) async => log.add('bundled:$assetId');

  @override
  Future<bool> playBytes(String label, Uint8List bytes, String mimeType) async {
    if (!canPlayBytes) return false;
    log.add('bytes:$label');
    bytesPlayed.add(bytes);
    return true;
  }

  @override
  Future<void> speakOnDevice(
    String textBn, {
    String language = 'bn-BD',
  }) async => log.add('device:$textBn');

  @override
  Future<void> stop() async => stops++;
}

/// A scripted Gemini engine: answers [answer] after [delay], or throws.
class FakeEngine {
  FakeEngine({
    this.fail = false,
    this.delay = Duration.zero,
    this.hang = false,
  });

  bool fail;
  Duration delay;
  bool hang;
  final List<String> texts = [];

  static final pcm = Uint8List.fromList(List.filled(480, 1)); // 10 ms

  final languages = <String>[];

  Future<GeminiTtsAudio?> callIn(String text, String languageCode) {
    languages.add(languageCode);
    return call(text);
  }

  Future<GeminiTtsAudio?> call(String textBn) async {
    texts.add(textBn);
    if (hang) return Completer<GeminiTtsAudio?>().future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('vertex said no');
    return GeminiTtsAudio(pcm, 'audio/L16;codec=pcm;rate=24000');
  }
}

const dynamicBn = 'এই লোকটি আপনার কাছে কোড চাইছে, কোড কাউকে দেবেন না।';
const otherBn = 'আগে কল কেটে দিন, তারপর আপনজনকে জিজ্ঞেস করুন।';

void main() {
  late FakeVoiceOutput out;
  late FakeRiskApi api;
  late FakeEngine engine;
  late GeminiTts gemini;
  late MetricsLog metrics;
  late bool offline;
  late bool geminiOn;
  late int now;

  ApaVoice build({
    ApaVoiceOutput? output,
    Duration deadline = const Duration(seconds: 6),
    bool withApi = true,
    bool ownDelivery = false,
  }) => ApaVoice(
    ownDelivery: ownDelivery,
    output: output ?? out,
    api: withApi ? () => api : null,
    userId: () => 'u_test',
    gemini: gemini = GeminiTts(
      engine: engine.call,
      engineIn: engine.callIn,
      enabled: () => geminiOn,
      deadline: deadline,
    ),
    metrics: metrics,
    isOffline: () => offline,
    nowMs: () => now,
  );

  setUp(() {
    out = FakeVoiceOutput();
    api = FakeRiskApi();
    engine = FakeEngine();
    metrics = MetricsLog();
    offline = false;
    geminiOn = true;
    now = 1000000;
  });

  group('the English UI (ApaUtterance.english)', () {
    test('speaks the English text through Gemini in English; no Bangla clip, '
        'no server audio', () async {
      api.clips['c1'] = FakeRiskApi.silentWav;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(
          textBn: dynamicBn,
          textEn: 'Do not share the code with anyone.',
          clipId: 'c1',
          token: 'tok',
          assetId: 'apa_hold_call_active',
          english: true,
        ),
      );
      expect(s, ApaVoiceSource.gemini);
      expect(engine.texts, ['Do not share the code with anyone.']);
      expect(engine.languages, ['en-US']);
      expect(out.log, ['bytes:gemini']);
      expect(api.calls, isEmpty);
    });

    test(
      'a warning line in English with Gemini failing stays unspoken',
      () async {
        engine.fail = true;
        final voice = build();
        final s = await voice.speak(
          const ApaUtterance(
            textBn: dynamicBn,
            textEn: 'Do not share the code.',
            english: true,
            fallback: ApaFallback.none,
          ),
        );
        expect(s, ApaVoiceSource.none);
        expect(out.log, isEmpty);
      },
    );

    test('a chat answer in English with Gemini off goes to the phone in '
        'English', () async {
      geminiOn = false;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, textEn: 'Hello.', english: true),
      );
      expect(s, ApaVoiceSource.onDevice);
      expect(out.log, ['device:Hello.']);
    });

    test('no English text: nothing is said', () async {
      final voice = build();
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn, english: true)),
        ApaVoiceSource.none,
      );
      expect(engine.texts, isEmpty);
    });
  });

  group('own delivery first (the default build: AppEnv.voiceOwnDelivery)', () {
    test('a dynamic line with a server clip and a token still goes to Gemini '
        'first, in the app\'s calm delivery', () async {
      api.clips['c1'] = FakeRiskApi.silentWav;
      api.whyAudio = FakeRiskApi.silentWav;
      final voice = build(ownDelivery: true);
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, clipId: 'c1', token: 'tok'),
      );
      expect(s, ApaVoiceSource.gemini);
      expect(engine.texts, [dynamicBn]);
      expect(api.callsTo(RiskRoutes.apaClipTemplate), isEmpty);
      expect(api.callsTo(RiskRoutes.apaWhyAudio), isEmpty);
    });

    test('Gemini failing falls through to the server clip', () async {
      engine.fail = true;
      api.clips['c1'] = FakeRiskApi.silentWav;
      final voice = build(ownDelivery: true);
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, clipId: 'c1', token: 'tok'),
      );
      expect(s, ApaVoiceSource.serverClip);
    });

    test('a bundled clip is still first', () async {
      final voice = build(ownDelivery: true);
      final s = await voice.speak(
        const ApaUtterance(textBn: '', assetId: 'apa_hold_call_active'),
      );
      expect(s, ApaVoiceSource.bundled);
      expect(engine.texts, isEmpty);
    });
  });

  group('source order', () {
    test('asset only: the bundled clip, no network, no Gemini', () async {
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, assetId: 'apa_generic_caution'),
      );
      expect(s, ApaVoiceSource.bundled);
      expect(out.log, ['bundled:apa_generic_caution']);
      expect(api.calls, isEmpty);
      expect(engine.texts, isEmpty);
      expect(metrics.last(ApaVoiceSource.bundled.metric), isNotNull);
      expect(voice.lastSource.value, ApaVoiceSource.bundled);
    });

    test('a catalog script without an id finds its clip by sha256', () async {
      final voice = build();
      final s = await voice.speak(
        ApaUtterance(
          textBn: AssetCatalog.scripts['apa_hold_screen_share']!,
          token: 'tok',
          clipId: 'c1',
        ),
      );
      expect(s, ApaVoiceSource.bundled);
      expect(out.log, ['bundled:apa_hold_screen_share']);
      expect(api.calls, isEmpty, reason: 'a bundled clip is never re-fetched');
      expect(engine.texts, isEmpty, reason: 'never re-synthesised');
    });

    test('clipId 200: the server clip, cached by id for the session', () async {
      api.clips['c1'] = FakeRiskApi.silentWav;
      final voice = build();
      const u = ApaUtterance(textBn: dynamicBn, clipId: 'c1', token: 'tok');
      expect(await voice.speak(u), ApaVoiceSource.serverClip);
      expect(await voice.speak(u), ApaVoiceSource.serverClip);
      expect(out.log, ['bytes:clip:c1', 'bytes:clip:c1']);
      expect(api.callsTo(RiskRoutes.apaClipTemplate), hasLength(1));
      expect(api.callsTo(RiskRoutes.apaWhyAudio), isEmpty);
      expect(engine.texts, isEmpty);
    });

    test('clipId 404 then token 200: server live audio', () async {
      api.whyAudio = FakeRiskApi.silentWav;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, clipId: 'gone', token: 'tok'),
      );
      expect(s, ApaVoiceSource.serverLive);
      expect(out.log, ['bytes:live']);
      expect(api.calls.map((c) => c.route), [
        RiskRoutes.apaClipTemplate,
        RiskRoutes.apaWhyAudio,
      ]);
      expect(api.callsTo(RiskRoutes.apaWhyAudio).single.body, {
        'user_id': 'u_test',
        'text_bn': dynamicBn,
        'token': 'tok',
      });
      expect(engine.texts, isEmpty);
    });

    test('token 204 then Gemini TTS', () async {
      api.whyAudio = null; // 204
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, token: 'tok'),
      );
      expect(s, ApaVoiceSource.gemini);
      expect(out.log, ['bytes:gemini']);
      expect(engine.texts, [dynamicBn]);
      final wav = out.bytesPlayed.single;
      expect(Wav.isWav(wav), isTrue);
      expect(wav.length, Wav.headerBytes + FakeEngine.pcm.length);
      expect(metrics.last(ApaVoiceSource.gemini.metric), isNotNull);
    });

    test('Gemini failure then on-device TTS, logged as the fallback', () async {
      engine.fail = true;
      final voice = build();
      final s = await voice.speak(const ApaUtterance(textBn: dynamicBn));
      expect(s, ApaVoiceSource.onDevice);
      expect(out.log, ['device:$dynamicBn']);
      expect(engine.texts, [dynamicBn]);
      expect(metrics.last(ApaVoiceSource.onDevice.metric), isNotNull);
    });

    test('a warning line (fallback none) is never spoken by the phone: '
        'Gemini failure ends in silence, the text stays on screen', () async {
      engine.fail = true;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, fallback: ApaFallback.none),
      );
      expect(s, ApaVoiceSource.none);
      expect(out.log, isEmpty);
      expect(engine.texts, [dynamicBn]);
      expect(metrics.last(ApaVoiceSource.onDevice.metric), isNull);
    });

    test('a warning line offline: nothing, not the phone\'s voice', () async {
      offline = true;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(
          textBn: dynamicBn,
          clipId: 'c1',
          token: 'tok',
          fallback: ApaFallback.none,
        ),
      );
      expect(s, ApaVoiceSource.none);
      expect(out.log, isEmpty);
    });

    test('a warning line that has a bundled clip still plays it', () async {
      offline = true;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(
          textBn: '',
          assetId: 'apa_hold_call_active',
          fallback: ApaFallback.none,
        ),
      );
      expect(s, ApaVoiceSource.bundled);
    });

    test('offline: on-device TTS, no network and no Gemini', () async {
      offline = true;
      api.clips['c1'] = FakeRiskApi.silentWav;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, clipId: 'c1', token: 'tok'),
      );
      expect(s, ApaVoiceSource.onDevice);
      expect(out.log, ['device:$dynamicBn']);
      expect(api.calls, isEmpty);
      expect(engine.texts, isEmpty);
    });

    test('offline still plays a bundled clip', () async {
      offline = true;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: '', assetId: 'apa_hold_call_active'),
      );
      expect(s, ApaVoiceSource.bundled);
    });

    test('a network failure on a server route counts as offline', () async {
      api.failures[RiskRoutes.apaClipTemplate] = const NetworkFailure();
      api.whyAudio = FakeRiskApi.silentWav;
      final voice = build();
      final s = await voice.speak(
        const ApaUtterance(textBn: dynamicBn, clipId: 'c1', token: 'tok'),
      );
      expect(s, ApaVoiceSource.onDevice);
      expect(api.callsTo(RiskRoutes.apaWhyAudio), isEmpty);
      expect(engine.texts, isEmpty);
    });

    test('Gemini off (no Firebase or GEMINI_TTS=false): on-device', () async {
      geminiOn = false;
      final voice = build();
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn)),
        ApaVoiceSource.onDevice,
      );
      expect(engine.texts, isEmpty);
    });

    test('no api client: straight to Gemini', () async {
      final voice = build(withApi: false);
      expect(
        await voice.speak(
          const ApaUtterance(textBn: dynamicBn, clipId: 'c1', token: 'tok'),
        ),
        ApaVoiceSource.gemini,
      );
    });

    test('an output that cannot play bytes falls to the phone', () async {
      final fake = FakeApaAudio();
      final voice = build(output: ApaAudioOutput(fake));
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn)),
        ApaVoiceSource.onDevice,
      );
      expect(fake.spoken, [dynamicBn]);
    });

    test('empty text and no clip says nothing', () async {
      final voice = build();
      expect(
        await voice.speak(const ApaUtterance(textBn: '  ')),
        ApaVoiceSource.none,
      );
      expect(out.log, isEmpty);
    });
  });

  group('server live audio', () {
    test('429 silences why-audio for Retry-After, never a loop', () async {
      api.failNext[RiskRoutes.apaWhyAudio] = [
        const RateLimited(retryAfterSeconds: 30),
      ];
      api.whyAudio = FakeRiskApi.silentWav;
      final voice = build();
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn, token: 't1')),
        ApaVoiceSource.gemini,
      );
      now += 10000; // 10 s later: still quiet
      expect(
        await voice.speak(const ApaUtterance(textBn: otherBn, token: 't2')),
        ApaVoiceSource.gemini,
      );
      expect(api.callsTo(RiskRoutes.apaWhyAudio), hasLength(1));
      now += 25000; // past Retry-After
      expect(
        await voice.speak(
          const ApaUtterance(textBn: '$otherBn আবার', token: 't3'),
        ),
        ApaVoiceSource.serverLive,
      );
      expect(api.callsTo(RiskRoutes.apaWhyAudio), hasLength(2));
    });

    test('5xx goes on to Gemini', () async {
      api.failures[RiskRoutes.apaWhyAudio] = const ServerFailure(503);
      final voice = build();
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn, token: 't')),
        ApaVoiceSource.gemini,
      );
    });

    test('a streamed header (sizes 0xFFFFFFFF) is fixed before play', () async {
      final pcm = Uint8List(96);
      final streamed = Uint8List.fromList([...Wav.header(0), ...pcm]);
      ByteData.sublistView(streamed)
        ..setUint32(4, Wav.unknownLength, Endian.little)
        ..setUint32(40, Wav.unknownLength, Endian.little);
      api.whyAudio = ApaAudioBytes(streamed);
      final voice = build();
      await voice.speak(const ApaUtterance(textBn: dynamicBn, token: 't'));
      final played = ByteData.sublistView(out.bytesPlayed.single);
      expect(played.getUint32(40, Endian.little), 96);
      expect(played.getUint32(4, Endian.little), 36 + 96);
    });
  });

  group('Gemini TTS cost guard and cache', () {
    test('a cache hit avoids a second call', () async {
      final voice = build();
      await voice.speak(const ApaUtterance(textBn: dynamicBn));
      await voice.speak(const ApaUtterance(textBn: dynamicBn));
      expect(out.log, ['bytes:gemini', 'bytes:gemini']);
      expect(engine.texts, [dynamicBn]);
      expect(gemini.calls, 1);
    });

    test('a failed text is never sent again this session', () async {
      engine.fail = true;
      final voice = build();
      await voice.speak(const ApaUtterance(textBn: dynamicBn));
      engine.fail = false;
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn)),
        ApaVoiceSource.onDevice,
      );
      expect(engine.texts, [dynamicBn]);
    });

    test('the 6 s deadline: a hung call falls to the phone', () async {
      engine.hang = true;
      final voice = build(deadline: const Duration(milliseconds: 40));
      final clock = Stopwatch()..start();
      expect(
        await voice.speak(const ApaUtterance(textBn: dynamicBn)),
        ApaVoiceSource.onDevice,
      );
      expect(clock.elapsedMilliseconds, lessThan(2000));
      expect(gemini.calls, 1);
    });

    test('the default deadline is 6 s and the cache holds 16', () {
      final g = GeminiTts(engine: engine.call);
      expect(g.deadline, const Duration(seconds: 6));
      expect(g.maxEntries, 16);
    });

    test('LRU of 16: the oldest text is evicted and not re-called', () async {
      final g = GeminiTts(engine: engine.call);
      for (var i = 0; i < 17; i++) {
        expect(await g.wav('লাইন $i'), isNotNull);
      }
      expect(g.cachedTexts, hasLength(16));
      expect(g.cachedTexts.first, 'লাইন 1');
      expect(await g.wav('লাইন 0'), isNull, reason: 'one call per text');
      expect(await g.wav('লাইন 16'), isNotNull);
      expect(g.calls, 17);
    });

    test('concurrent requests for one text share one call', () async {
      engine.delay = const Duration(milliseconds: 20);
      final g = GeminiTts(engine: engine.call);
      final both = await Future.wait([g.wav(dynamicBn), g.wav(dynamicBn)]);
      expect(both, everyElement(isNotNull));
      expect(engine.texts, hasLength(1));
    });

    test('off: no call at all', () async {
      final g = GeminiTts(engine: engine.call, enabled: () => false);
      expect(await g.wav(dynamicBn), isNull);
      expect(g.calls, 0);
    });
  });

  group('ordering and stop', () {
    test('lines are queued in call order, however slow each source', () async {
      engine.delay = const Duration(milliseconds: 30);
      final voice = build();
      final a = voice.speak(const ApaUtterance(textBn: dynamicBn));
      final b = voice.speak(
        const ApaUtterance(textBn: '', assetId: 'apa_generic_caution'),
      );
      await Future.wait([a, b]);
      expect(out.log, ['bytes:gemini', 'bundled:apa_generic_caution']);
    });

    test('stop drops a line still being resolved', () async {
      engine.delay = const Duration(milliseconds: 30);
      final voice = build();
      final pending = voice.speak(const ApaUtterance(textBn: dynamicBn));
      await voice.stop();
      expect(await pending, ApaVoiceSource.none);
      expect(out.log, isEmpty);
      expect(out.stops, 1);
    });
  });

  test('ApaUtterance.fromLine keeps the clip, the token and both texts', () {
    const line = ApaLine(
      role: 'T',
      textBn: dynamicBn,
      textEn: 'He is asking for your code.',
      token: 'tok',
      clipId: 'c9',
    );
    final u = ApaUtterance.fromLine(line);
    expect(u.textBn, dynamicBn);
    expect(u.textEn, line.textEn);
    expect(u.token, 'tok');
    expect(u.clipId, 'c9');
    expect(u.assetId, isNull);
  });
}
