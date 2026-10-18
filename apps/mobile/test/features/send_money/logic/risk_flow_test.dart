import 'dart:async';

import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/core/ids.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:bhorosha/domain/risk/decision_routing.dart';
import 'package:bhorosha/features/send_money/logic/risk_flow.dart';
import 'package:bhorosha/features/send_money/logic/risk_outcome.dart';
import 'package:flutter_test/flutter_test.dart';

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

const txn = Txn(
  type: TxnType.sendMoney,
  amountBdt: 7900,
  toAccount: '017XXXXX412',
  isNewPayee: true,
);

Reason reason(String code, double weight) =>
    Reason(code: code, weight: weight, textBn: 'বাংলা', textEn: 'en');

ScoreResponse score(
  Decision decision, {
  List<Reason> reasons = const [],
  List<ActionItem> actions = const [],
}) => ScoreResponse(
  decision: decision,
  riskScore: 0.85,
  band: Band.high,
  reasons: reasons,
  actions: actions,
  modelVersion: 'test',
);

final holdScore = score(
  Decision.hold,
  reasons: [reason('SCAM_CONVERSATION', 0.85)],
  actions: const [
    ActionItem(type: 'hold_transaction', params: {'minutes': 60}),
    ActionItem(
      type: 'trusted_contact_check',
      params: {'expires_in_minutes': 30},
    ),
  ],
);

final delayScore = score(
  Decision.delay,
  reasons: [reason('NEW_PAYEE_ABOVE_P95', 0.6)],
  actions: const [
    ActionItem(type: 'delay_new_payee', params: {'minutes': 60}),
    ActionItem(
      type: 'trusted_contact_check',
      params: {'expires_in_minutes': 30},
    ),
  ],
);

const callActiveIntervene = InterveneResponse(
  intervene: true,
  scriptBn: 'আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন।',
  scriptEn: 'This is your FinNest Assistant. You are on a call right now.',
  audioAssetId: 'apa_hold_call_active',
  ui: UiMode.fullscreen,
  actions: [
    ActionItem(type: 'delay_new_payee', params: {'minutes': 60}),
    ActionItem(
      type: 'trusted_contact_check',
      params: {'expires_in_minutes': 15},
    ),
  ],
  cooldownS: 120,
);

final features = List<double>.filled(55, 0.0);

class Harness {
  Harness({
    ScoreResponse? scoreResponse,
    InterveneResponse? interveneResponse,
    NativeSignals? signals,
    String? integrityToken,
    Duration nativeDelay = Duration.zero,
    Duration signalsTimeout = const Duration(milliseconds: 1500),
    bool sendAppSafety = false,
    bool sendSessionFields = false,
    this.evidenceQuote,
  }) : api = FakeRiskApi(
         scoreResponse: scoreResponse,
         interveneResponse: interveneResponse,
       ),
       native = FakeBhoroshaNative(
         signals: signals,
         integrityToken: integrityToken,
         delay: nativeDelay,
       ),
       clock = FakeClock(DateTime.utc(2026, 10, 16, 12)) {
    cooldown = Cooldown(clock);
    flow = RiskFlow(
      api: api,
      native: native,
      cooldown: cooldown,
      clock: clock,
      nonce: () => 'nonce-${++nonces}',
      lastEvidenceQuote: () => evidenceQuote,
      signalsTimeout: signalsTimeout,
      integrityTimeout: signalsTimeout,
      sendAppSafety: sendAppSafety,
      sendSessionFields: sendSessionFields,
    );
  }

  final FakeRiskApi api;
  final FakeBhoroshaNative native;
  final FakeClock clock;
  late final Cooldown cooldown;
  late final RiskFlow flow;
  String? evidenceQuote;
  int nonces = 0;

  Future<RiskOutcome> run({
    DemoState demo = DemoState.initial,
    SafetyVerdict? lastVerdict,
    AppSafetyContext? appSafety,
    void Function(String, String, ScoreResponse)? onHoldPredicted,
  }) => flow.scoreTransfer(
    user: rina,
    sessionId: 'sess_1',
    txn: txn,
    features: features,
    demo: demo,
    lastVerdict: lastVerdict,
    appSafety: appSafety,
    onHoldPredicted: onHoldPredicted,
  );

  Map<String, dynamic> body(String route) =>
      api.callsTo(route).single.body! as Map<String, dynamic>;
}

// An App Safety block, with the hold's id on its action.
final appSafetyBlock = score(
  Decision.block,
  reasons: [reason('APP_SAFETY_BLOCK', 0.95)],
  actions: const [
    ActionItem(
      type: 'block_transaction',
      params: {'reason': 'app_safety', 'intervention_id': 'iv-1'},
    ),
  ],
);

void main() {
  group('a block, explained', () {
    test('an App Safety block asks /v1/intervene with the app_safety '
        'trigger', () async {
      final h = Harness(scoreResponse: appSafetyBlock);
      expect(await h.run(), isA<Blocked>());
      final served = await h.flow.explainBlock(
        user: rina,
        sessionId: 'sess_1',
        txn: txn,
        score: appSafetyBlock,
      );
      expect(served, FakeRiskApi.genericCaution);
      final body = h.body(RiskRoutes.intervene);
      expect(body['trigger'], 'app_safety');
      expect(body['user_id'], rina.uid);
      expect(body.containsKey('intervention_id'), isFalse);
    });

    test(
      'with the session fields it names the block\'s hold and call',
      () async {
        final h = Harness(scoreResponse: appSafetyBlock, sendSessionFields: true);
        await h.flow.explainBlock(
          user: rina,
          sessionId: 'sess_1',
          txn: txn,
          score: appSafetyBlock,
        );
        final body = h.body(RiskRoutes.intervene);
        expect(body['intervention_id'], 'iv-1');
        expect(body['session_id'], 'sess_1');
      },
    );

    test('a block that is not App Safety is not explained', () async {
      final h = Harness();
      final served = await h.flow.explainBlock(
        user: rina,
        sessionId: 'sess_1',
        txn: txn,
        score: score(
          Decision.block,
          reasons: [reason('SCAM_CONVERSATION', 0.95)],
        ),
      );
      expect(served, isNull);
      expect(h.api.callsTo(RiskRoutes.intervene), isEmpty);
    });

    test('a failed explanation is null and still arms the cooldown', () async {
      final h = Harness();
      h.api.failures[RiskRoutes.intervene] = const TimeoutFailure();
      expect(h.cooldown.shouldSpeak('app_safety'), isTrue);
      final served = await h.flow.explainBlock(
        user: rina,
        sessionId: 'sess_1',
        txn: txn,
        score: appSafetyBlock,
      );
      expect(served, isNull);
      expect(h.cooldown.shouldSpeak('app_safety'), isFalse);
    });
  });

  group('decision → outcome', () {
    test('allow → Allowed', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      final out = await h.run();
      expect(out, isA<Allowed>());
      expect((out as Allowed).score.decision, Decision.allow);
      expect(h.api.callsTo(RiskRoutes.intervene), isEmpty);
    });

    test('block → Blocked, no intervene call', () async {
      final h = Harness(
        scoreResponse: score(
          Decision.block,
          reasons: [reason('APP_SAFETY_BLOCK', 0.95)],
        ),
      );
      final out = await h.run();
      expect(out, isA<Blocked>());
      expect(h.api.callsTo(RiskRoutes.intervene), isEmpty);
    });

    test('step_up → StepUpRequired, no intervene call', () async {
      final h = Harness(
        scoreResponse: score(
          Decision.stepUp,
          reasons: [reason('SCREEN_SHARE_ACTIVE', 0.5)],
        ),
      );
      final out = await h.run(demo: const DemoState(screenShare: true));
      expect(out, isA<StepUpRequired>());
      expect(h.api.callsTo(RiskRoutes.intervene), isEmpty);
    });

    test(
      'hold → Held with trigger, asset, intervene and merged actions',
      () async {
        final h = Harness(
          scoreResponse: holdScore,
          interveneResponse: callActiveIntervene,
        );
        final out = await h.run(
          demo: const DemoState(callActive: true, scamScore: 0.85),
        );
        expect(out, isA<Held>());
        final held = out as Held;
        expect(held.trigger, 'call_active');
        expect(held.predictedAsset, 'apa_hold_call_active');
        expect(held.intervene, callActiveIntervene);
        expect(held.speak, isTrue);
        expect(held.container, Container.fullscreen);
        expect(held.actions.map((a) => a.type), [
          'hold_transaction',
          'trusted_contact_check',
          // The intervene's delay is the same outcome as the hold: collapsed.
        ]);
        // Score wins on the shared type.
        expect(
          held.actions
              .singleWhere((a) => a.type == 'trusted_contact_check')
              .params['expires_in_minutes'],
          30,
        );
      },
    );

    test('delay → Delayed, banner, new_payee trigger', () async {
      final h = Harness(scoreResponse: delayScore);
      final out = await h.run();
      expect(out, isA<Delayed>());
      final delayed = out as Delayed;
      expect(delayed.trigger, 'new_payee_high_amount');
      expect(delayed.predictedAsset, 'apa_delay_new_payee');
      expect(delayed.container, Container.banner);
      expect(delayed.intervene, FakeRiskApi.genericCaution);
    });

    test(
      'delay with a fullscreen ui from the server tightens the container',
      () async {
        final h = Harness(
          scoreResponse: delayScore,
          interveneResponse: callActiveIntervene, // ui: fullscreen
        );
        final out = await h.run() as Delayed;
        expect(out.container, Container.fullscreen);
      },
    );
  });

  group('score failures', () {
    for (final failure in <ApiFailure>[
      const TimeoutFailure('slow', Duration(seconds: 2)),
      const ServerFailure(503),
      const NetworkFailure(),
      const ContractFailure('bad body'),
    ]) {
      test('${failure.runtimeType} on score → Unavailable', () async {
        final h = Harness(scoreResponse: holdScore);
        h.api.failures[RiskRoutes.score] = failure;
        final out = await h.run();
        expect(out, isA<Unavailable>());
        expect((out as Unavailable).failure, same(failure));
        expect(h.api.callsTo(RiskRoutes.intervene), isEmpty);
      });
    }
  });

  group('signals', () {
    test('signals failure is tolerated and score still runs', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      h.api.failures[RiskRoutes.signals] = const NetworkFailure();
      final out = await h.run();
      expect(out, isA<Allowed>());
      expect(h.api.calls.map((c) => c.route), [
        RiskRoutes.signals,
        RiskRoutes.score,
      ]);
    });

    test(
      'signals body carries session, merged signals, features and token',
      () async {
        final h = Harness(
          scoreResponse: score(Decision.allow),
          signals: const NativeSignals(
            signals: DeviceSignals(subscriptionChangedHours: 3),
            device: DeviceInfo(model: 'Pixel 6', os: 'Android 14'),
          ),
          integrityToken: 'tok_123',
        );
        await h.run(demo: const DemoState(callActive: true));

        final body = h.body(RiskRoutes.signals);
        expect(body['session_id'], 'sess_1');
        expect(body['integrity_token'], 'tok_123');
        expect((body['device'] as Map)['model'], 'Pixel 6');
        final signals = body['signals'] as Map;
        expect(signals['call_state'], 'OFFHOOK'); // demo wins
        expect(signals['subscription_changed_hours'], 3); // real passes
        expect((body['behaviour'] as Map)['features'], hasLength(55));
        expect(body['simulated'], ['call_state']); // the panel forced it
      },
    );

    test('signals name every panel-forced field in simulated; none when '
        'nothing is forced', () async {
      final forced = Harness(scoreResponse: score(Decision.allow));
      await forced.run(demo: const DemoState(simSwap: true, screenShare: true));
      // sim_swap is never named (the server expands it to its SIM fields):
      // only the field the merge changed.
      expect(forced.body(RiskRoutes.signals)['simulated'], ['screen_capture']);

      final onCall = Harness(
        scoreResponse: score(Decision.allow),
        signals: NativeSignals(
          signals: const DeviceSignals(callState: CallState.offhook),
          device: NativeSignals.defaults().device,
        ),
      );
      await onCall.run(demo: const DemoState(callActive: true));
      expect(
        onCall.body(RiskRoutes.signals).containsKey('simulated'),
        isFalse,
        reason: 'a real call stays measured with the demo toggle on',
      );

      final clean = Harness(scoreResponse: score(Decision.allow));
      await clean.run();
      expect(clean.body(RiskRoutes.signals).containsKey('simulated'), isFalse);
    });

    test('integrity request hash is sha256(acct|to|amount|nonce)', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      await h.run();
      expect(h.native.integrityRequests, [
        sha256Hex('acct_rina|017XXXXX412|7900.0|nonce-1'),
      ]);
    });

    test('no payee account hashes as an empty segment', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      await h.flow.scoreTransfer(
        user: rina,
        sessionId: 'sess_1',
        txn: const Txn(type: TxnType.pinReset),
        features: features,
        demo: DemoState.initial,
      );
      expect(h.native.integrityRequests, [sha256Hex('acct_rina||0.0|nonce-1')]);
    });

    test('a missing integrity token is sent as null', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      await h.run();
      expect(h.body(RiskRoutes.signals)['integrity_token'], isNull);
    });
  });

  group('score request', () {
    test('carries user, session, txn and the merged DemoFlags only', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      await h.run(
        demo: const DemoState(
          simSwap: true,
          persona: Persona.rina,
          forcedSafetyVerdict: SafetyVerdict.caution,
          scamScore: 0.85,
        ),
        lastVerdict: SafetyVerdict.block,
      );
      final body = h.body(RiskRoutes.score);
      expect(body['user_id'], 'rina');
      expect(body['session_id'], 'sess_1');
      expect(body['txn'], txn.toJson());
      final flags = body['demo_flags'] as Map;
      expect(flags['sim_swap'], isTrue);
      expect(flags['scam_score'], 0.85);
      expect(flags['app_safety_verdict'], 'CAUTION'); // forced beats last
      expect(flags.keys, isNot(contains('persona')));
      expect(flags.keys, isNot(contains('forced_safety_verdict')));
    });

    test('last verdict is used when nothing is forced', () async {
      final h = Harness(scoreResponse: score(Decision.allow));
      await h.run(lastVerdict: SafetyVerdict.block);
      expect(
        (h.body(RiskRoutes.score)['demo_flags'] as Map)['app_safety_verdict'],
        'BLOCK',
      );
    });

    const appSafety = AppSafetyContext(
      verdict: SafetyVerdict.caution,
      riskScore: 0.55,
      findings: [
        AppSafetyFinding(
          package: 'com.takanow.app',
          signal: 'accessibility_control',
          severity: 'high',
        ),
      ],
      appsToUninstall: ['com.takanow.app'],
      recommendedAction: 'uninstall',
      attestation: 'strong',
      checkId: 'chk_1',
    );

    test(
      'the app-safety block is left out without RISK_MW_APP_SAFETY_IN_SCORE: '
      'the deployed service forbids unknown keys',
      () async {
        final h = Harness(scoreResponse: score(Decision.allow));
        await h.run(appSafety: appSafety, lastVerdict: SafetyVerdict.caution);
        final body = h.body(RiskRoutes.score);
        expect(body.containsKey('app_safety'), isFalse);
        expect((body['demo_flags'] as Map)['app_safety_verdict'], 'CAUTION');
      },
    );

    test('with the flag on, the score carries the App Safety Check result the '
        'phone holds', () async {
      final h = Harness(
        scoreResponse: score(Decision.allow),
        sendAppSafety: true,
      );
      await h.run(appSafety: appSafety, lastVerdict: SafetyVerdict.caution);
      final sent = h.body(RiskRoutes.score)['app_safety'] as Map;
      expect(sent['verdict'], 'CAUTION');
      expect(sent['risk_score'], 0.55);
      expect(sent['source'], 'check');
      expect((sent['findings'] as List).single, {
        'package': 'com.takanow.app',
        'signal': 'accessibility_control',
        'severity': 'high',
        'scope': 'app',
      });
      expect(sent['apps_to_uninstall'], ['com.takanow.app']);
      // Never the user-facing copy or the raw answer: only the data points.
      expect(sent.keys, isNot(contains('user_message_bn')));
      expect(sent.keys, isNot(contains('findings_raw')));
    });

    test('with the flag on but no check yet, nothing is sent', () async {
      final h = Harness(
        scoreResponse: score(Decision.allow),
        sendAppSafety: true,
      );
      await h.run();
      expect(h.body(RiskRoutes.score).containsKey('app_safety'), isFalse);
    });
  });

  group('intervene', () {
    test('onHoldPredicted fires before the intervene call completes', () async {
      final h = Harness(
        scoreResponse: holdScore,
        interveneResponse: callActiveIntervene,
      );
      final release = h.api.holdIntervene();
      final predicted = Completer<(String, String, ScoreResponse)>();

      final pending = h.run(
        demo: const DemoState(callActive: true),
        onHoldPredicted: (trigger, asset, s) =>
            predicted.complete((trigger, asset, s)),
      );

      final (trigger, asset, s) = await predicted.future;
      expect(trigger, 'call_active');
      expect(asset, 'apa_hold_call_active');
      expect(s, holdScore);
      // The intervene call is in flight (recorded) but not answered.
      expect(h.api.callsTo(RiskRoutes.intervene), hasLength(1));
      var done = false;
      unawaited(pending.then((_) => done = true));
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      release();
      final out = await pending as Held;
      expect(out.intervene, callActiveIntervene);
    });

    test(
      'request body carries user_id, trigger, txn and transcript_snippet',
      () async {
        final h = Harness(
          scoreResponse: holdScore,
          evidenceQuote: 'আপনার ওটিপি বলুন',
        );
        await h.run(demo: const DemoState(callActive: true));
        final body = h.body(RiskRoutes.intervene);
        expect(body['user_id'], 'rina');
        expect(body['trigger'], 'call_active');
        expect(body['txn'], txn.toJson());
        expect(body['transcript_snippet'], 'আপনার ওটিপি বলুন');
        // Not without RISK_MW_SESSION_FIELDS: the deployed service forbids
        // unknown keys.
        expect(body.containsKey('session_id'), isFalse);
        expect(body.containsKey('intervention_id'), isFalse);
      },
    );

    test(
      'with the session request fields on, intervene names the session, '
      "the hold's server id and txn_id; the score never carries txn_id",
      () async {
        final api = FakeRiskApi(
          scoreResponse: score(
            Decision.hold,
            reasons: [reason('SCAM_CONVERSATION', 0.85)],
            actions: const [
              ActionItem(
                type: 'hold_transaction',
                params: {'minutes': 60, 'intervention_id': 'iv-hold'},
              ),
            ],
          ),
        );
        final clock = FakeClock(DateTime.utc(2026, 10, 16, 12));
        final flow = RiskFlow(
          api: api,
          native: FakeBhoroshaNative(),
          cooldown: Cooldown(clock),
          clock: clock,
          nonce: () => 'n',
          sendSessionFields: true,
        );
        await flow.scoreTransfer(
          user: rina,
          sessionId: 'sess_1',
          txn: txn.copyWith(txnId: 'txn_42'),
          features: features,
          demo: DemoState.initial,
        );
        final scoreBody =
            api.callsTo(RiskRoutes.score).single.body! as Map<String, dynamic>;
        expect((scoreBody['txn'] as Map).containsKey('txn_id'), isFalse);
        final body =
            api.callsTo(RiskRoutes.intervene).single.body!
                as Map<String, dynamic>;
        expect(body['session_id'], 'sess_1');
        expect(body['intervention_id'], 'iv-hold');
        expect((body['txn'] as Map)['txn_id'], 'txn_42');
      },
    );

    test('without the flag a txn_id from the PIN pad is left out of both '
        'calls', () async {
      final h = Harness(scoreResponse: holdScore);
      await h.flow.scoreTransfer(
        user: rina,
        sessionId: 'sess_1',
        txn: txn.copyWith(txnId: 'txn_42'),
        features: features,
        demo: DemoState.initial,
      );
      expect(
        (h.body(RiskRoutes.score)['txn'] as Map).containsKey('txn_id'),
        isFalse,
      );
      expect(
        (h.body(RiskRoutes.intervene)['txn'] as Map).containsKey('txn_id'),
        isFalse,
      );
    });

    test(
      'evidence quote is read at call time, not construction time',
      () async {
        final h = Harness(scoreResponse: holdScore);
        await h.run();
        expect(h.body(RiskRoutes.intervene)['transcript_snippet'], isNull);

        h.api.calls.clear();
        h.evidenceQuote = 'কোড বলুন';
        await h.run();
        expect(h.body(RiskRoutes.intervene)['transcript_snippet'], 'কোড বলুন');
      },
    );

    test(
      'intervene failure → intervene null, still Held, default cooldown',
      () async {
        final h = Harness(scoreResponse: holdScore);
        h.api.failures[RiskRoutes.intervene] = const TimeoutFailure();
        final out = await h.run(demo: const DemoState(callActive: true));
        expect(out, isA<Held>());
        final held = out as Held;
        expect(held.intervene, isNull);
        expect(held.speak, isTrue);
        expect(held.container, Container.fullscreen);
        expect(held.actions, holdScore.actions);
        expect(
          h.cooldown.until('call_active'),
          h.clock.now().add(const Duration(seconds: RiskFlow.defaultCooldownS)),
        );
      },
    );

    test('cooldown is armed with the server cooldown_s', () async {
      final h = Harness(
        scoreResponse: holdScore,
        interveneResponse: callActiveIntervene, // cooldown_s: 120
      );
      await h.run(demo: const DemoState(callActive: true));
      expect(
        h.cooldown.until('call_active'),
        h.clock.now().add(const Duration(seconds: 120)),
      );
    });
  });

  group('cooldown', () {
    test('second identical hold inside the window does not speak', () async {
      final h = Harness(
        scoreResponse: holdScore,
        interveneResponse: callActiveIntervene,
      );
      const demo = DemoState(callActive: true);
      final first = await h.run(demo: demo) as Held;
      final second = await h.run(demo: demo) as Held;
      expect(first.speak, isTrue);
      expect(second.speak, isFalse);
      // The card still has everything it needs.
      expect(second.intervene, callActiveIntervene);
      expect(second.actions, isNotEmpty);
    });

    test('a different trigger inside the window still speaks', () async {
      final h = Harness(scoreResponse: holdScore);
      final first =
          await h.run(demo: const DemoState(callActive: true)) as Held;
      h.api.scoreResponse = score(
        Decision.hold,
        reasons: [reason('SIM_CHANGED_24H', 0.85)],
      );
      final second = await h.run(demo: const DemoState(simSwap: true)) as Held;
      expect(first.trigger, 'call_active');
      expect(second.trigger, 'sim_swap');
      expect(second.speak, isTrue);
    });

    test('speaks again after the window has passed', () async {
      final h = Harness(
        scoreResponse: holdScore,
        interveneResponse: callActiveIntervene,
      );
      const demo = DemoState(callActive: true);
      await h.run(demo: demo);
      h.clock.advance(const Duration(seconds: 120));
      final again = await h.run(demo: demo) as Held;
      expect(again.speak, isTrue);
    });

    test('reset restores speak', () async {
      final h = Harness(scoreResponse: holdScore);
      const demo = DemoState(callActive: true);
      await h.run(demo: demo);
      expect((await h.run(demo: demo) as Held).speak, isFalse);
      h.cooldown.reset();
      expect((await h.run(demo: demo) as Held).speak, isTrue);
    });

    test('the predicted callback sees the same speak decision', () async {
      final h = Harness(scoreResponse: holdScore);
      const demo = DemoState(callActive: true);
      await h.run(demo: demo);
      bool? speakAtCallback;
      final out = await h.run(
        demo: demo,
        onHoldPredicted: (trigger, _, _) =>
            speakAtCallback = h.cooldown.shouldSpeak(trigger),
      ) as Held;
      expect(speakAtCallback, isFalse);
      expect(out.speak, isFalse);
    });
  });

  group('native bridge', () {
    test('a native slower than the budget still yields a decision with '
        'default signals and no token', () async {
      final h = Harness(
        scoreResponse: score(Decision.allow),
        signals: const NativeSignals(
          signals: DeviceSignals(callState: CallState.offhook),
          device: DeviceInfo(model: 'Slow'),
        ),
        integrityToken: 'late_token',
        nativeDelay: const Duration(milliseconds: 200),
        signalsTimeout: const Duration(milliseconds: 20),
      );
      final out = await h.run();
      expect(out, isA<Allowed>());
      final body = h.body(RiskRoutes.signals);
      expect((body['signals'] as Map)['call_state'], 'IDLE');
      expect((body['device'] as Map)['model'], '');
      expect(body['integrity_token'], isNull);
      // Let the fake's delayed futures finish so nothing leaks past the test.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });

    test('a native within the budget is used as-is', () async {
      final h = Harness(
        scoreResponse: score(Decision.allow),
        signals: const NativeSignals(
          signals: DeviceSignals(callState: CallState.offhook),
          device: DeviceInfo(model: 'Fast'),
        ),
        integrityToken: 'tok',
        nativeDelay: const Duration(milliseconds: 5),
        signalsTimeout: const Duration(milliseconds: 500),
      );
      await h.run();
      final body = h.body(RiskRoutes.signals);
      expect((body['signals'] as Map)['call_state'], 'OFFHOOK');
      expect((body['device'] as Map)['model'], 'Fast');
      expect(body['integrity_token'], 'tok');
    });

    test('signals and the integrity token are awaited concurrently', () async {
      final h = Harness(
        scoreResponse: score(Decision.allow),
        signals: const NativeSignals(
          signals: DeviceSignals(callState: CallState.offhook),
          device: DeviceInfo(model: 'Slowish'),
        ),
        integrityToken: 'tok',
        nativeDelay: const Duration(milliseconds: 150),
        signalsTimeout: const Duration(milliseconds: 400),
      );
      final watch = Stopwatch()..start();
      await h.run();
      watch.stop();
      final body = h.body(RiskRoutes.signals);
      expect((body['device'] as Map)['model'], 'Slowish');
      expect(body['integrity_token'], 'tok');
      // Sequential waits would take at least 300 ms.
      expect(watch.elapsedMilliseconds, lessThan(290));
    });

    test(
      'demo merge applies on top of default signals after a timeout',
      () async {
        final h = Harness(
          scoreResponse: holdScore,
          nativeDelay: const Duration(milliseconds: 200),
          signalsTimeout: const Duration(milliseconds: 20),
        );
        final out =
            await h.run(demo: const DemoState(callActive: true)) as Held;
        expect(out.trigger, 'call_active');
        expect(
          (h.body(RiskRoutes.score)['demo_flags'] as Map)['call_active'],
          isTrue,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      },
    );
  });

  test('call order: signals, score, intervene', () async {
    final h = Harness(scoreResponse: holdScore);
    await h.run(demo: const DemoState(callActive: true));
    expect(h.api.calls.map((c) => c.route), [
      RiskRoutes.signals,
      RiskRoutes.score,
      RiskRoutes.intervene,
    ]);
    expect(h.native.signalsCalls, 1);
    expect(h.native.integrityRequests, hasLength(1));
  });

  test('a fresh nonce is drawn on every attempt', () async {
    final h = Harness(scoreResponse: score(Decision.allow));
    await h.run();
    await h.run();
    expect(h.native.integrityRequests.toSet(), hasLength(2));
  });

  group('unexpected throws', () {
    RiskFlow flowWith(RiskApi api, Harness h) => RiskFlow(
      api: api,
      native: h.native,
      cooldown: h.cooldown,
      clock: h.clock,
      nonce: () => 'n',
    );

    Future<RiskOutcome> runWith(
      RiskFlow flow, {
      void Function(String, String, ScoreResponse)? onHoldPredicted,
    }) => flow.scoreTransfer(
      user: rina,
      sessionId: 'sess_1',
      txn: txn,
      features: features,
      demo: DemoState.initial,
      onHoldPredicted: onHoldPredicted,
    );

    test('a StateError from /score is Unavailable, never an allow', () async {
      final h = Harness();
      final out = await runWith(
        flowWith(_ThrowingApi(score: StateError('boom')), h),
      );
      expect(out, isA<Unavailable>());
      expect((out as Unavailable).failure, isA<ContractFailure>());
    });

    test(
      'a TypeError from /signals is tolerated and the transfer is scored',
      () async {
        final h = Harness();
        final out = await runWith(
          flowWith(
            _ThrowingApi(
              signals: TypeError(),
              scoreResponse: score(Decision.allow),
            ),
            h,
          ),
        );
        expect(out, isA<Allowed>());
      },
    );

    test('a throw from /intervene counts as no response', () async {
      final h = Harness();
      final out = await runWith(
        flowWith(
          _ThrowingApi(intervene: StateError('x'), scoreResponse: holdScore),
          h,
        ),
      );
      expect(out, isA<Held>());
      expect((out as Held).intervene, isNull);
    });

    test('a throwing onHoldPredicted callback still yields the hold', () async {
      final h = Harness(scoreResponse: holdScore);
      final out = await h.run(
        demo: const DemoState(callActive: true),
        onHoldPredicted: (_, _, _) => throw StateError('callback'),
      );
      expect(out, isA<Held>());
    });
  });
}

/// A [FakeRiskApi] whose chosen routes throw a non-[ApiFailure] error.
class _ThrowingApi extends FakeRiskApi {
  _ThrowingApi({this.score, this.signals, this.intervene, super.scoreResponse});

  final Object? score;
  final Object? signals;
  final Object? intervene;

  @override
  Future<ScoreResponse> postScore(ScoreRequest r) =>
      score == null ? super.postScore(r) : Future.error(score!);

  @override
  Future<SignalsResponse> postSignals(SignalsRequest r) =>
      signals == null ? super.postSignals(r) : Future.error(signals!);

  @override
  Future<InterveneResponse> postIntervene(InterveneRequest r) =>
      intervene == null ? super.postIntervene(r) : Future.error(intervene!);
}
