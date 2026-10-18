import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/demo_panel/logic/scam_replay.dart';
import 'package:flutter_test/flutter_test.dart';

/// `n` alternating turns starting with the caller.
List<Turn> script(int n) => [
  for (var i = 0; i < n; i++)
    Turn(
      speaker: i.isEven ? Turn.callerSpeaker : Turn.userSpeaker,
      text: 'turn $i',
      ts: i * 5.0,
    ),
];

List<Map<String, dynamic>> turnsOf(FakeCall c) =>
    ((c.body as Map<String, dynamic>)['turns'] as List)
        .cast<Map<String, dynamic>>();

void main() {
  test(
    'posts the growing prefix per caller turn with send_money + amount',
    () async {
      final api = FakeRiskApi();
      final out = await ScamReplay(api)
          .replay(sessionId: 'sess-1', script: script(6), amountBdt: 5000)
          .toList();

      expect(out, hasLength(3), reason: 'one answer per caller turn');
      final calls = api.callsTo(RiskRoutes.scamTurn).toList();
      expect(calls, hasLength(3));
      expect(calls.map((c) => turnsOf(c).length), [1, 3, 5]);
      for (final c in calls) {
        final body = c.body as Map<String, dynamic>;
        expect(body['session_id'], 'sess-1');
        expect(body['pending_action'], 'send_money');
        expect(body['amount_bdt'], 5000.0);
        // Every prefix ends with the caller line it was posted for.
        expect(turnsOf(c).last['speaker'], Turn.callerSpeaker);
      }
      // The third prefix is the whole conversation so far, in order.
      expect(turnsOf(calls[2]).map((t) => t['text']), [
        'turn 0',
        'turn 1',
        'turn 2',
        'turn 3',
        'turn 4',
      ]);
    },
  );

  test('caps each request at the last 8 turns', () async {
    final api = FakeRiskApi();
    await ScamReplay(api)
        .replay(sessionId: 's', script: script(12), amountBdt: 5000)
        .toList();

    final calls = api.callsTo(RiskRoutes.scamTurn).toList();
    expect(calls, hasLength(6));
    expect(calls.map((c) => turnsOf(c).length), [1, 3, 5, 7, 8, 8]);
    // Caller turn 10 (index 10) -> prefix 0..10 (11 turns) -> window 3..10.
    expect(turnsOf(calls.last).map((t) => t['text']), [
      for (var i = 3; i <= 10; i++) 'turn $i',
    ]);
  });

  test(
    'skips user turns entirely when the script has none from the caller',
    () async {
      final api = FakeRiskApi();
      final only = [const Turn(speaker: Turn.userSpeaker, text: 'hi', ts: 0)];
      final out = await ScamReplay(api)
          .replay(sessionId: 's', script: only, amountBdt: 1)
          .toList();
      expect(out, isEmpty);
      expect(api.calls, isEmpty);
    },
  );

  test('yields the failure and stops on the first ApiFailure', () async {
    final api = FakeRiskApi();
    api.failures[RiskRoutes.scamTurn] = const TimeoutFailure();

    final events = <Object>[];
    await ScamReplay(api)
        .replay(sessionId: 's', script: script(6), amountBdt: 5000)
        .handleError(events.add)
        .forEach(events.add);

    expect(events, hasLength(1));
    expect(events.single, isA<TimeoutFailure>());
    expect(api.callsTo(RiskRoutes.scamTurn), hasLength(1));
  });
}
