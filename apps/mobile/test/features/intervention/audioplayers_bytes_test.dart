import 'package:audioplayers/audioplayers.dart' hide AudioEvent;
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/features/intervention/logic/audioplayers_apa_audio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intervention_fakes.dart';

/// `AudioplayersApaAudio.playBytes`: server and Gemini audio go
/// through the same FIFO as the bundled clips.
void main() {
  late List<FakeAudioPlayer> players;
  late List<AudioEvent> events;
  late AudioplayersApaAudio audio;

  Future<void> settle() async {
    await pumpEventQueue();
    await pumpEventQueue();
  }

  setUp(() async {
    players = [];
    events = [];
    var t = 1000;
    audio = AudioplayersApaAudio(
      createPlayer: () {
        final p = FakeAudioPlayer();
        players.add(p);
        return p;
      },
      createTts: () => FakeFlutterTts(),
      nowMs: () => t += 10,
    );
    audio.events.listen(events.add);
    await audio.preload();
  });

  test(
    'bytes play from a BytesSource in a fresh player, then dispose',
    () async {
      final wav = FakeRiskApi.silentWav.bytes;
      await audio.playBytes('gemini', wav);
      await settle();
      final p = players.last;
      expect(p.sourceSet, isA<BytesSource>());
      expect((p.sourceSet! as BytesSource).bytes, wav);
      expect((p.sourceSet! as BytesSource).mimeType, 'audio/wav');
      expect(p.resumes, 1);
      expect(events.first, isA<AudioStarted>());
      expect(events.first.assetId, 'voice:gemini');
      p.complete();
      await settle();
      expect(p.disposed, isTrue);
      expect(events.last, isA<AudioFinished>());
      expect(audio.isPlaying, isFalse);
    },
  );

  test('a dynamic line waits for the bundled clip already playing', () async {
    await audio.playAsset('apa_hold_call_active');
    await audio.playBytes('live', FakeRiskApi.silentWav.bytes);
    await settle();
    expect(audio.queued, ['live']);
    final clip = audio.players['apa_hold_call_active']! as FakeAudioPlayer;
    expect(clip.resumes, 1);
    clip.complete();
    await settle();
    expect(audio.queued, isEmpty);
    expect(players.last.sourceSet, isA<BytesSource>());
    expect(players.last.resumes, 1);
  });

  test('empty bytes play nothing', () async {
    await audio.playBytes('gemini', FakeRiskApi.silentWav.bytes.sublist(0, 0));
    await settle();
    expect(events, isEmpty);
  });

  test('stop ends the bytes job', () async {
    await audio.playBytes('gemini', FakeRiskApi.silentWav.bytes);
    await settle();
    await audio.stop();
    await settle();
    expect(players.last.stops, greaterThan(0));
    expect(audio.isPlaying, isFalse);
  });
}
