// The identity step-up at both entry points: the PIN
// pad's step-up sheet by leading reason (A) and the overlay's fingerprint
// release of a behaviour-only hold (B).

import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/intervention/logic/action_labels.dart';
import 'package:bhorosha/features/intervention/logic/step_up_policy.dart';
import 'package:bhorosha/features/intervention/ui/intervention_overlay.dart';
import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pin_pad/ui/pin_pad_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../intervention/intervention_fakes.dart';
import '../login/biometric_fakes.dart';
import '../pay/pay_test_support.dart';
import 'pin_pad_screen_test.dart'
    show balance, interventionRecords, openPin, rinaPin, rows;

const mismatch = Reason(
  code: 'ATO_BEHAVIOUR_MISMATCH',
  weight: 1,
  textBn: 'নিরাপত্তার জন্য একবার আপনার পরিচয় নিশ্চিত করতে চাই।',
  textEn: 'For your safety we want to confirm it is you.',
);

const screenShare = Reason(
  code: 'SCREEN_SHARE_ACTIVE',
  weight: 0.9,
  textBn: 'আপনার স্ক্রিন শেয়ার চালু আছে।',
  textEn: 'Your screen is being shared.',
);

const simSwap = Reason(
  code: 'SIM_CHANGED_24H',
  weight: 0.8,
  textBn: 'আপনার সিম সম্প্রতি বদলেছে।',
  textEn: 'Your SIM changed recently.',
);

const coaching = Reason(
  code: 'COACHING_SUSPECTED',
  weight: 0.6,
  textBn: 'মনে হচ্ছে কেউ আপনাকে বলে দিচ্ছে কী করতে হবে।',
  textEn: 'It looks like someone is telling you what to do.',
);

ScoreResponse stepUpScore(
  List<Reason> reasons, {
  SignalSources? sources = const SignalSources(),
}) => ScoreResponse(
  decision: Decision.stepUp,
  riskScore: 0.7,
  band: Band.high,
  reasons: reasons,
  actions: const [ActionItem(type: 'step_up_verification')],
  modelVersion: 'rules-v1',
  signalSources: sources,
);

/// Rejects the release write of a record (the open record still lands).
class RejectingRelease extends LocalInterventionRepo {
  @override
  Future<void> upsert(InterventionRecord r) =>
      r.status == InterventionStatus.releasedByStepUp
      ? Future.error(StateError('PERMISSION_DENIED'))
      : super.upsert(r);
}

final fingerprintSheet = find.byKey(const Key('step_up_identity'));
final genericSheet = find.byKey(const Key('step_up_generic'));

ScoreResponse behaviourHold({SignalSources? sources = const SignalSources()}) =>
    ScoreResponse(
      decision: Decision.hold,
      riskScore: 1,
      band: Band.critical,
      reasons: const [mismatch],
      actions: const [holdAction, trustedAction],
      modelVersion: 'rules-v1',
      signalSources: sources,
    );

final stepUpKey = find.byKey(
  const ValueKey('action_${ActionLabels.biometricStepUp}'),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

void main() {
  group('Entry A: the step-up sheet by leading reason', () {
    testWidgets('identity: the fingerprint sheet with the server reason; a '
        'pass sends the money with the step-up record', (tester) async {
      final h = ScreenHarness(score: stepUpScore(const [mismatch]));
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);

      expect(find.byKey(const Key('step_up_identity')), findsOneWidget);
      expect(find.text('একবার নিশ্চিত করুন'), findsOneWidget);
      expect(find.text(mismatch.textBn), findsOneWidget);
      expect(find.text('এটা আপনিই?'), findsOneWidget);
      expect(find.text('হ্যাঁ, আঙুলের ছাপ দিয়ে নিশ্চিত করুন'), findsOneWidget);
      expect(tester.widget(stepUpKey), isA<OutlinedButton>());
      expect(find.text('আপনজনের মত নিন'), findsOneWidget);
      expect(find.text('বাতিল'), findsOneWidget);
      expect(find.text('স্ক্রিন শেয়ার বন্ধ করুন'), findsNothing);

      await tester.tap(stepUpKey);
      await settle(tester);
      expect(h.biometric.authenticateCalls, 1);
      expect(h.biometric.lastReason, 'টাকা পাঠাতে আপনার আঙুলের ছাপ দিন।');
      final done = (await rows(
        tester,
        c,
      )).where((t) => t.status == LedgerStatus.done).toList();
      expect(done, hasLength(1));
      expect(done.single.stepUp?.method, 'biometric');
      expect(done.single.stepUp?.serverDecision, 'step_up');
      expect(done.single.stepUp?.reasonCodes, ['ATO_BEHAVIOUR_MISMATCH']);
      expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=done'));
      expect(await balance(tester, c), 9841 - 500);
      expect(c.read(stepUpAttemptsProvider), 1);
      // m1: the step-up's decisionId points at a closed record.
      final record = (await interventionRecords(tester, c)).single;
      expect(record.status, InterventionStatus.stepUpPassed);
      expect(record.stepUp, done.single.stepUp);
      expect(done.single.stepUp?.decisionId, record.id);
    });

    testWidgets('identity: a failed fingerprint is terminal; the secondary '
        'stays; nothing is written', (tester) async {
      final h = ScreenHarness(
        score: stepUpScore(const [mismatch]),
        biometric: FakeBiometricAuth(outcome: const BiometricFailed()),
      );
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      await tester.tap(stepUpKey);
      await settle(tester);

      expect(find.text('যাচাই হয়নি। আপনজনের মত নিন।'), findsOneWidget);
      expect(stepUpKey, findsNothing, reason: 'no retry on a locked sensor');
      expect(find.byKey(const Key('step_up_ask_trusted')), findsOneWidget);
      expect(
        (await rows(tester, c)).where((t) => t.status != LedgerStatus.ok),
        isEmpty,
      );
    });

    testWidgets('identity: a dismissed prompt keeps the button; "বাতিল" '
        'closes the sheet and changes nothing', (tester) async {
      final h = ScreenHarness(
        score: stepUpScore(const [mismatch]),
        biometric: FakeBiometricAuth(outcome: const BiometricCancelled()),
      );
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      await tester.tap(stepUpKey);
      await settle(tester);
      expect(stepUpKey, findsOneWidget);
      expect(find.text('যাচাই হয়নি। আপনজনের মত নিন।'), findsNothing);

      await tester.tap(find.byKey(const Key('step_up_cancel')));
      await settle(tester);
      expect(find.byKey(const Key('step_up_identity')), findsNothing);
      expect(find.byType(PinPadScreen), findsOneWidget);
      expect(find.text('যাচাই হচ্ছে…'), findsNothing);
      expect(
        (await rows(tester, c)).where((t) => t.status != LedgerStatus.ok),
        isEmpty,
      );
      expect(await interventionRecords(tester, c), isEmpty);
    });

    testWidgets('identity: "আপনজনের মত নিন" holds the transfer and asks the '
        'trusted contact', (tester) async {
      final h = ScreenHarness(score: stepUpScore(const [mismatch]));
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      await tester.tap(find.byKey(const Key('step_up_ask_trusted')));
      await settle(tester);

      final held = (await rows(
        tester,
        c,
      )).where((t) => t.status == LedgerStatus.held).toList();
      expect(held, hasLength(1));
      final record = (await interventionRecords(tester, c)).single;
      expect(record.trigger, 'behaviour_mismatch');
      expect(held.single.interventionId, record.id);
      expect(h.api.callsTo(RiskRoutes.trustedContact), hasLength(1));
      expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=held'));
    });

    testWidgets('screen share keeps today\'s sheet', (tester) async {
      final h = ScreenHarness(score: stepUpScore(const [screenShare]));
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.text('স্ক্রিন শেয়ার বন্ধ করুন'), findsOneWidget);
      expect(stepUpKey, findsNothing);
    });

    testWidgets('another reason: the generic sheet with the server text and '
        'a retry', (tester) async {
      final h = ScreenHarness(score: stepUpScore(const [simSwap]));
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.byKey(const Key('step_up_generic')), findsOneWidget);
      expect(find.text('একবার নিশ্চিত করুন'), findsOneWidget);
      expect(find.text(simSwap.textBn), findsOneWidget);
      expect(stepUpKey, findsNothing);
      await tester.tap(find.byKey(const Key('step_up_retry')));
      await settle(tester);
      expect(find.byKey(const Key('step_up_generic')), findsNothing);
      expect(find.byType(PinPadScreen), findsOneWidget);
    });

    // B1: the sheet follows the step-up policy, not the leading reason.
    for (final (name, reasons) in [
      ('identity + coaching', const [mismatch, coaching]),
      ('identity + SIM change', const [mismatch, simSwap]),
    ]) {
      testWidgets('B1 $name: the generic sheet, no fingerprint', (
        tester,
      ) async {
        final h = ScreenHarness(score: stepUpScore(reasons));
        await openPin(tester, h);
        await tapDigits(tester, rinaPin);
        await settle(tester);
        expect(fingerprintSheet, findsNothing);
        expect(genericSheet, findsOneWidget);
        expect(stepUpKey, findsNothing);
        expect(h.biometric.authenticateCalls, 0);
      });
    }

    testWidgets('B1 identity + screen share (identity leading): the screen '
        'share sheet, no fingerprint', (tester) async {
      final h = ScreenHarness(
        score: stepUpScore(const [mismatch, screenShare]),
      );
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.text('স্ক্রিন শেয়ার বন্ধ করুন'), findsOneWidget);
      expect(fingerprintSheet, findsNothing);
      expect(stepUpKey, findsNothing);
    });

    testWidgets('B1 a stranger replay: no fingerprint sheet', (tester) async {
      final h = ScreenHarness(score: stepUpScore(const [mismatch]));
      final c = await openPin(tester, h);
      c.read(behaviourModeProvider.notifier).set(BehaviourMode.replayStranger);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(fingerprintSheet, findsNothing);
      expect(genericSheet, findsOneWidget);
    });

    testWidgets('B1 above the persona p95: no fingerprint sheet', (
      tester,
    ) async {
      final h = ScreenHarness(score: stepUpScore(const [mismatch]));
      await openPin(tester, h, amount: 6000);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(fingerprintSheet, findsNothing);
      expect(genericSheet, findsOneWidget);
    });

    testWidgets('B1 a weak biometric: no fingerprint sheet', (tester) async {
      final h = ScreenHarness(
        score: stepUpScore(const [mismatch]),
        biometric: FakeBiometricAuth(strengthValue: BiometricStrength.weakOnly),
      );
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(fingerprintSheet, findsNothing);
      expect(genericSheet, findsOneWidget);
    });

    testWidgets('B1 no signal_sources (call unknown): no fingerprint sheet', (
      tester,
    ) async {
      final h = ScreenHarness(
        score: stepUpScore(const [mismatch], sources: null),
      );
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(fingerprintSheet, findsNothing);
      expect(genericSheet, findsOneWidget);
    });

    testWidgets('M2 three dismissed prompts use up the step-up: the '
        'exhausted line, no fourth prompt', (tester) async {
      final h = ScreenHarness(
        score: stepUpScore(const [mismatch]),
        biometric: FakeBiometricAuth(outcome: const BiometricCancelled()),
      );
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      for (var i = 0; i < maxStepUpAttempts; i++) {
        expect(stepUpKey, findsOneWidget, reason: 'prompt ${i + 1}');
        await tester.tap(stepUpKey);
        await settle(tester);
      }
      expect(h.biometric.authenticateCalls, maxStepUpAttempts);
      expect(c.read(stepUpAttemptsProvider), maxStepUpAttempts);
      expect(stepUpKey, findsNothing);
      expect(
        find.text('তিনবার যাচাই হয়নি। এখন আপনজনের মত নিন।'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('step_up_ask_trusted')), findsOneWidget);
    });
  });

  group('Entry B: the overlay releases a behaviour-only hold', () {
    testWidgets('offered; a pass releases the row and the record with the '
        'step-up and shows the result with its demo note', (tester) async {
      final h = ScreenHarness(score: behaviourHold(), intervene: served());
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(stepUpKey, findsOneWidget);
      expect(find.text('এটা আপনিই?'), findsOneWidget);

      await tester.tap(stepUpKey);
      await settle(tester);

      expect(find.byType(InterventionScreen), findsNothing);
      final row = (await rows(tester, c)).first;
      expect(row.status, LedgerStatus.releasedByStepUp);
      expect(row.stepUp?.serverDecision, 'hold');
      expect(row.stepUp?.reasonCodes, ['ATO_BEHAVIOUR_MISMATCH']);
      final record = (await interventionRecords(tester, c)).single;
      expect(record.status, InterventionStatus.releasedByStepUp);
      expect(record.stepUp, row.stepUp);
      expect(row.stepUp?.decisionId, record.id);
      // finishHold's script patch survives the release.
      expect(record.scriptBn, served().scriptBn);
      expect(record.signalSources, const SignalSources());

      expect(locationOf(c), contains('state=released_by_step_up'));
      expect(find.text('ফোনে যাচাই করে পাঠানো হয়েছে'), findsOneWidget);
      expect(
        find.text('ডেমো: সার্ভারে লেনদেনটি আটকে রাখা হিসেবে লেখা আছে।'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('result_reference')), findsOneWidget);
      expect(await balance(tester, c), 9841 - 500);
    });

    testWidgets('a failed fingerprint keeps the hold; the fail line replaces '
        'the button', (tester) async {
      final h = ScreenHarness(
        score: behaviourHold(),
        intervene: served(),
        biometric: FakeBiometricAuth(outcome: const BiometricFailed()),
      );
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      await tester.tap(stepUpKey);
      await settle(tester);
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(stepUpKey, findsNothing);
      expect(find.text('যাচাই হয়নি। আপনজনের মত নিন।'), findsOneWidget);
      expect((await rows(tester, c)).first.status, LedgerStatus.held);
      expect(await balance(tester, c), 9841);
    });

    testWidgets('no signal_sources from the server: no step-up', (
      tester,
    ) async {
      final h = ScreenHarness(
        score: behaviourHold(sources: null),
        intervene: served(),
      );
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(stepUpKey, findsNothing);
    });

    testWidgets('a weak biometric: no step-up', (tester) async {
      final h = ScreenHarness(
        score: behaviourHold(),
        intervene: served(),
        biometric: FakeBiometricAuth(strengthValue: BiometricStrength.weakOnly),
      );
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(stepUpKey, findsNothing);
    });

    testWidgets('a stranger replay: no step-up, the simulated tag, and the '
        'row and record stay simulated after /intervene (finishHold keeps '
        'the new fields)', (tester) async {
      final h = ScreenHarness(score: behaviourHold(), intervene: served());
      final c = await openPin(tester, h);
      c.read(behaviourModeProvider.notifier).set(BehaviourMode.replayStranger);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(stepUpKey, findsNothing);
      expect(
        find.byKey(const ValueKey('intervention_simulated')),
        findsOneWidget,
      );
      expect(find.text('সিমুলেটেড: অন্য কারও হাতের ধরন'), findsOneWidget);

      final row = (await rows(tester, c)).first;
      expect(row.status, LedgerStatus.held);
      expect(row.simulated, isTrue);
      final record = (await interventionRecords(tester, c)).single;
      expect(record.scriptBn, served().scriptBn, reason: 'patched');
      expect(record.simulated, isTrue);
      expect(record.signalSources, const SignalSources());
    });

    testWidgets('m6: the held overlay shows the customer review line while '
        'the row is held', (tester) async {
      final h = ScreenHarness(score: behaviourHold(), intervene: served());
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('intervention_held')),
          matching: find.text('টাকা পাঠানো হয়নি, আপনার কাছেই আছে।'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('M1: once the trusted contact is asked the step-up is gone '
        'and the hold stays', (tester) async {
      final h = ScreenHarness(
        score: behaviourHold(),
        intervene: served(),
        biometric: FakeBiometricAuth(outcome: const BiometricFailed()),
      );
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(stepUpKey, findsOneWidget);
      // The trusted contact waits behind the fingerprint; a failed prompt
      // brings it forward.
      expect(
        find.byKey(const ValueKey('action_trusted_contact_check')),
        findsNothing,
      );
      await tester.tap(stepUpKey);
      await settle(tester);
      expect(h.biometric.authenticateCalls, 1);
      await tester.tap(
        find.byKey(const ValueKey('action_trusted_contact_check')),
      );
      await settle(tester);
      expect(h.api.callsTo(RiskRoutes.trustedContact), hasLength(1));
      expect(stepUpKey, findsNothing);
      expect(find.text('এটা আপনিই?'), findsNothing);
      expect((await rows(tester, c)).first.status, LedgerStatus.held);
      final record = (await interventionRecords(tester, c)).single;
      expect(record.status, InterventionStatus.pending);
      expect(record.requestId, isNotNull);
    });

    testWidgets('M2: three dismissed prompts switch to the exhausted line; '
        'the hold stays', (tester) async {
      final h = ScreenHarness(
        score: behaviourHold(),
        intervene: served(),
        biometric: FakeBiometricAuth(outcome: const BiometricCancelled()),
      );
      final c = await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      for (var i = 0; i < maxStepUpAttempts; i++) {
        expect(stepUpKey, findsOneWidget, reason: 'prompt ${i + 1}');
        await tester.tap(stepUpKey);
        await settle(tester);
      }
      expect(h.biometric.authenticateCalls, maxStepUpAttempts);
      expect(stepUpKey, findsNothing);
      expect(
        find.text('তিনবার যাচাই হয়নি। এখন আপনজনের মত নিন।'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('action_trusted_contact_check')),
        findsOneWidget,
      );
      expect((await rows(tester, c)).first.status, LedgerStatus.held);
    });

    testWidgets('M2: a server-sent biometric_step_up is never honoured', (
      tester,
    ) async {
      const serverStepUp = ActionItem(type: ActionLabels.biometricStepUp);
      final h = ScreenHarness(
        score: const ScoreResponse(
          decision: Decision.hold,
          riskScore: 1,
          band: Band.critical,
          reasons: [mismatch, coaching],
          actions: [holdAction, serverStepUp, trustedAction],
          modelVersion: 'rules-v1',
          signalSources: SignalSources(),
        ),
        intervene: served(),
      );
      await openPin(tester, h);
      await tapDigits(tester, rinaPin);
      await settle(tester);
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(stepUpKey, findsNothing);
      expect(h.biometric.authenticateCalls, 0);
    });

    testWidgets('M3: a release that does not land stays on the overlay with '
        'the failed line, never the sent result', (tester) async {
      final h = ScreenHarness(score: behaviourHold(), intervene: served());
      final c = await openPin(
        tester,
        h,
        extraOverrides: [
          interventionRepoProvider.overrideWithValue(RejectingRelease()),
        ],
      );
      await tapDigits(tester, rinaPin);
      await settle(tester);
      await tester.tap(stepUpKey);
      await settle(tester);
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(find.text('যাচাই হয়নি। আপনজনের মত নিন।'), findsOneWidget);
      expect(find.text('ফোনে যাচাই করে পাঠানো হয়েছে'), findsNothing);
      expect(locationOf(c), isNot(contains('released_by_step_up')));
      expect((await rows(tester, c)).first.status, LedgerStatus.held);
      expect(await balance(tester, c), 9841);
    });
  });
}
