import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/domain/behaviour/behaviour_replay.dart';
import 'package:bhorosha/domain/behaviour/enrolment_store.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:bhorosha/features/send_money/logic/risk_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const rina = UserProfile(
  uid: 'rina',
  nameBn: 'রিনা',
  nameEn: 'Rina',
  phoneMasked: '017*****412',
  persona: Persona.rina,
  trustedContactUid: 'rafiq',
  p95SendBdt: 5000,
  acctId: 'acct_rina',
  balanceBdt: 12000,
);

const txn = Txn(type: TxnType.sendMoney, amountBdt: 500, toAccount: 'acct_x');

final live = [for (var i = 0; i < FeatureNames.count; i++) i + 1.0];

void main() {
  late FakeRiskApi api;
  late EnrolmentStore store;
  late bool enrolling;
  late RiskFlow flow;
  final clock = FakeClock(DateTime.utc(2026, 10, 17, 9));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeRiskApi();
    store = EnrolmentStore();
    enrolling = false;
    flow = RiskFlow(
      api: api,
      native: FakeBhoroshaNative(),
      cooldown: Cooldown(clock),
      clock: clock,
      nonce: () => 'n',
      enrolment: store,
      enrolling: () => enrolling,
    );
  });

  Future<Map<String, dynamic>> run(BehaviourMode mode) async {
    await flow.scoreTransfer(
      user: rina,
      sessionId: 'sess_1',
      txn: txn,
      features: live,
      demo: DemoState.initial,
      mode: mode,
    );
    return api.callsTo(RiskRoutes.signals).last.body! as Map<String, dynamic>;
  }

  List<double> sent(Map<String, dynamic> body) => [
    for (final v in (body['behaviour'] as Map)['features'] as List)
      (v as num).toDouble(),
  ];

  test('live posts the measured 55-float vector', () async {
    final body = await run(BehaviourMode.live);
    expect(sent(body), live);
    expect(await store.rows('rina'), isEmpty, reason: 'not enrolling');
  });

  test('off omits the behaviour block entirely', () async {
    final body = await run(BehaviourMode.off);
    expect(body.containsKey('behaviour'), isFalse);
    expect(body['session_id'], 'sess_1');
  });

  test('live while enrolling appends the vector for the persona', () async {
    enrolling = true;
    await run(BehaviourMode.live);
    final rows = await store.rows('rina');
    expect(rows.single.features, live);
    expect(rows.single.persona, 'rina');
    expect(rows.single.sessionId, startsWith('sess_1-'));
  });

  test('off and the replay never enrol, even while enrolling', () async {
    enrolling = true;
    await run(BehaviourMode.off);
    await run(BehaviourMode.replayStranger);
    expect(await store.rows('rina'), isEmpty);
  });

  test('replayStranger perturbs the last enrolled row', () async {
    final enrolled = List<double>.filled(FeatureNames.count, 2);
    await store.append(
      EnrolmentRow(
        sessionId: 'e1',
        ts: clock.now(),
        persona: 'rina',
        features: enrolled,
      ),
    );
    final body = await run(BehaviourMode.replayStranger);
    expect(sent(body), BehaviourReplay.stranger(enrolled));
  });

  test(
    'replayStranger with nothing enrolled perturbs the live vector',
    () async {
      final body = await run(BehaviourMode.replayStranger);
      expect(sent(body), BehaviourReplay.stranger(live));
    },
  );

  test(
    'each replay mode posts its own perturbation of the enrolled row',
    () async {
      final enrolled = [for (var i = 0; i < FeatureNames.count; i++) i + 2.0];
      final expected = {
        BehaviourMode.replayStranger: BehaviourReplay.stranger(enrolled),
        BehaviourMode.replayTapPattern: BehaviourReplay.tapPattern(enrolled),
        BehaviourMode.replayShaking: BehaviourReplay.shaking(enrolled),
        BehaviourMode.replayCoached: BehaviourReplay.coached(enrolled),
      };
      await store.append(
        EnrolmentRow(
          sessionId: 'e1',
          ts: clock.now(),
          persona: 'rina',
          features: enrolled,
        ),
      );
      for (final MapEntry(key: mode, value: vector) in expected.entries) {
        expect(sent(await run(mode)), vector, reason: mode.name);
      }
      expect(
        BehaviourMode.values.where((m) => m.replayed).toSet(),
        expected.keys.toSet(),
      );
    },
  );

  test('every replay mode with nothing enrolled perturbs the live vector and '
      'never enrols', () async {
    enrolling = true;
    expect(
      sent(await run(BehaviourMode.replayTapPattern)),
      BehaviourReplay.tapPattern(live),
    );
    expect(
      sent(await run(BehaviourMode.replayShaking)),
      BehaviourReplay.shaking(live),
    );
    expect(
      sent(await run(BehaviourMode.replayCoached)),
      BehaviourReplay.coached(live),
    );
    expect(await store.rows('rina'), isEmpty);
  });

  test('onFlags reports the merged flags before scoring', () async {
    DemoFlags? flags;
    await flow.scoreTransfer(
      user: rina,
      sessionId: 's',
      txn: txn,
      features: live,
      demo: DemoState.initial.copyWith(callActive: true),
      onFlags: (f) => flags = f,
    );
    expect(flags?.callActive, isTrue);
  });
}
