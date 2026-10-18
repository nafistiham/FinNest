import 'package:audioplayers/audioplayers.dart' hide AudioEvent;
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/features/intervention/logic/asset_catalog.dart';
import 'package:bhorosha/features/intervention/logic/audioplayers_apa_audio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intervention_fakes.dart';

void main() {
  late List<FakeAudioPlayer> players;
  late FakeFlutterTts tts;
  late List<AudioEvent> events;
  late AudioplayersApaAudio audio;

  /// Players are created in `AssetCatalog.byId` order during preload.
  FakeAudioPlayer playerFor(String id) => audio.players[id]! as FakeAudioPlayer;

  Future<void> settle() async {
    await pumpEventQueue();
    await pumpEventQueue();
  }

  AudioplayersApaAudio build({
    bool failTts = false,
    int speakResult = 1,
    Map<String, int>? durations,
    bool failResume = false,
  }) {
    players = [];
    tts = FakeFlutterTts(failSetLanguage: failTts, speakResult: speakResult);
    events = [];
    var t = 1000;
    final a = AudioplayersApaAudio(
      createPlayer: () {
        final p = FakeAudioPlayer(failResume: failResume);
        players.add(p);
        return p;
      },
      createTts: () => tts,
      durationsMs: durations ?? AssetCatalog.durationMs,
      nowMs: () => t += 10,
    );
    a.events.listen(events.add);
    return a;
  }

  setUp(() {
    audio = build();
  });

  group('preload', () {
    test('creates one low-latency player per bundled clip, sourced', () async {
      await audio.preload();
      expect(players.length, 4);
      expect(audio.players.keys, unorderedEquals(AssetCatalog.byId.keys));
      for (final e in AssetCatalog.byId.entries) {
        final p = playerFor(e.key);
        expect(p.modeSet, PlayerMode.lowLatency);
        expect(p.releaseModeSet, ReleaseMode.stop);
        // AudioCache prefixes `assets/` itself.
        expect(p.assetPath, 'audio/${e.key}.ogg');
        expect(p.resumes, 0);
      }
    });

    test('is idempotent', () async {
      await audio.preload();
      await audio.preload();
      expect(players.length, 4);
    });
  });

  group('queue', () {
    test('a second clip waits for the first to complete', () async {
      await audio.preload();
      await audio.playAsset('apa_hold_call_active');
      await audio.playAsset('apa_generic_caution');
      await settle();

      final first = playerFor('apa_hold_call_active');
      final second = playerFor('apa_generic_caution');
      expect(first.resumes, 1);
      expect(second.resumes, 0, reason: 'never cut mid-sentence');
      expect(audio.isPlaying, isTrue);
      expect(audio.queued, ['apa_generic_caution']);
      expect(events.whereType<AudioStarted>().map((e) => e.assetId), [
        'apa_hold_call_active',
      ]);

      first.complete();
      await settle();

      expect(second.resumes, 1);
      expect(audio.queued, isEmpty);
      expect(events.map((e) => '${e.runtimeType}:${e.assetId}'), [
        'AudioStarted:apa_hold_call_active',
        'AudioFinished:apa_hold_call_active',
        'AudioStarted:apa_generic_caution',
      ]);

      second.complete();
      await settle();
      expect(audio.isPlaying, isFalse);
      expect(events.last, isA<AudioFinished>());
      expect(events.last.assetId, 'apa_generic_caution');
    });

    test('a clip without a completion event ends on its timer', () async {
      audio = build(
        durations: {'apa_hold_screen_share': 0, 'apa_generic_caution': 0},
      );
      await audio.preload();
      await audio.playAsset('apa_hold_screen_share');
      await audio.playAsset('apa_generic_caution');
      // The timer is duration + grace (400 ms); real time here, so wait it out.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await settle();
      expect(playerFor('apa_generic_caution').resumes, 1);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await settle();
      expect(audio.isPlaying, isFalse);
    });

    test('stop clears the queue and stops the current clip and TTS', () async {
      await audio.preload();
      await audio.playAsset('apa_hold_call_active');
      await audio.playAsset('apa_generic_caution');
      await audio.speak('কিছু কথা');
      await settle();
      expect(audio.queued, ['apa_generic_caution', 'tts']);

      await audio.stop();
      await settle();

      expect(audio.queued, isEmpty);
      expect(audio.isPlaying, isFalse);
      expect(playerFor('apa_hold_call_active').stops, greaterThanOrEqualTo(2));
      expect(playerFor('apa_generic_caution').resumes, 0);
      expect(tts.spoken, isEmpty);
      expect(events.whereType<AudioFinished>().length, 1);
    });

    test('plays a clip again after it has been played once', () async {
      await audio.preload();
      await audio.playAsset('apa_generic_caution');
      await settle();
      playerFor('apa_generic_caution').complete();
      await settle();
      await audio.playAsset('apa_generic_caution');
      await settle();
      expect(playerFor('apa_generic_caution').resumes, 2);
      expect(players.length, 4, reason: 'no new player per play');
    });

    test('a platform error on resume is swallowed and logged', () async {
      audio = build(failResume: true);
      await audio.preload();
      await audio.playAsset('apa_generic_caution');
      await settle();
      expect(audio.isPlaying, isFalse);
      expect(events, isEmpty, reason: 'failure = missing AudioStarted');
    });
  });

  group('fallback chain', () {
    test('playAsset with an unknown id plays nothing', () async {
      await audio.preload();
      await audio.playAsset('apa_future_clip');
      await settle();
      expect(players.every((p) => p.resumes == 0), isTrue);
      expect(tts.spoken, isEmpty);
      expect(events, isEmpty);
    });

    test('unknown id with text falls back to TTS in bn-BD', () async {
      await audio.preload();
      await audio.playForScript(
        assetId: 'apa_future_clip',
        scriptBn: 'নতুন একটি লাইন',
      );
      await settle();
      expect(players.every((p) => p.resumes == 0), isTrue);
      expect(tts.language, 'bn-BD');
      expect(tts.awaitCompletion, isTrue);
      expect(tts.spoken, ['নতুন একটি লাইন']);
      expect(events.length, 2);
      expect(events.first, isA<AudioStarted>());
      expect(events.first.assetId, startsWith('tts:'));
      expect(events.last, isA<AudioFinished>());
    });

    test('unknown id whose text matches a script plays that clip', () async {
      await audio.preload();
      await audio.playForScript(
        assetId: 'apa_future_clip',
        scriptBn: AssetCatalog.scripts['apa_delay_new_payee']!,
      );
      await settle();
      expect(playerFor('apa_delay_new_payee').resumes, 1);
      expect(tts.spoken, isEmpty);
      expect(events.first.assetId, 'apa_delay_new_payee');
    });

    test('null id with a matching script plays that clip', () async {
      await audio.preload();
      await audio.playForScript(
        assetId: null,
        scriptBn: AssetCatalog.scripts['apa_generic_caution']!,
      );
      await settle();
      expect(playerFor('apa_generic_caution').resumes, 1);
    });

    test('the apa_turn stub text has no clip and goes to TTS', () async {
      await audio.preload();
      final stub = AssetCatalog.scripts[AssetCatalog.apaTextDefault]!;
      await audio.playForScript(assetId: null, scriptBn: stub);
      await settle();
      expect(tts.spoken, [stub]);
    });

    test('no id and no text plays nothing', () async {
      await audio.preload();
      await audio.playForScript(assetId: null, scriptBn: '');
      await settle();
      expect(tts.spoken, isEmpty);
      expect(events, isEmpty);
    });

    test('a clip is created lazily when preload was never called', () async {
      await audio.playForScript(assetId: 'apa_generic_caution', scriptBn: '');
      await settle();
      expect(players.length, 1);
      expect(players.single.resumes, 1);
    });

    test('a known id plays the clip even when the text is unknown', () async {
      await audio.preload();
      await audio.playForScript(
        assetId: 'apa_hold_screen_share',
        scriptBn: 'অন্য কথা',
      );
      await settle();
      expect(playerFor('apa_hold_screen_share').resumes, 1);
      expect(tts.spoken, isEmpty);
    });
  });

  group('tts', () {
    test('a missing engine is swallowed: text only, no events', () async {
      audio = build(failTts: true);
      await audio.speak('কিছু কথা');
      await settle();
      expect(tts.spoken, isEmpty);
      expect(events, isEmpty);
      expect(audio.isPlaying, isFalse);
    });

    test('an engine that refuses (result 0) emits no AudioStarted', () async {
      audio = build(speakResult: 0);
      await audio.speak('কিছু কথা');
      await settle();
      expect(tts.spoken, ['কিছু কথা']);
      expect(events, isEmpty);
    });

    test('speech queues behind a playing clip', () async {
      await audio.preload();
      await audio.playAsset('apa_generic_caution');
      await audio.speak('তারপর এটা');
      await settle();
      expect(tts.spoken, isEmpty);
      playerFor('apa_generic_caution').complete();
      await settle();
      expect(tts.spoken, ['তারপর এটা']);
    });

    test('empty text is ignored', () async {
      await audio.speak('   ');
      await settle();
      expect(tts.spoken, isEmpty);
    });
  });

  test('dispose releases players and closes the stream', () async {
    await audio.preload();
    await audio.dispose();
    expect(players.every((p) => p.disposed), isTrue);
    await audio.playAsset('apa_generic_caution');
    await settle();
    expect(audio.isPlaying, isFalse);
  });
}
