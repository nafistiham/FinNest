import 'dart:io';

import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/widgets/animated/rolling_amount.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:bhorosha/features/intervention/ui/intervention_overlay.dart';
import 'package:bhorosha/features/pay/logic/billers.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/ui/amount_step.dart';
import 'package:bhorosha/features/pay/ui/bill_confirm_step.dart';
import 'package:bhorosha/features/pin_pad/logic/pin_attempts.dart';
import 'package:bhorosha/features/pin_pad/ui/pin_pad_screen.dart';
import 'package:bhorosha/features/result/ui/result_screen.dart';
import 'package:bhorosha/features/safety/ui/safety_screen.dart';
import 'package:bhorosha/features/send_money/logic/risk_flow.dart';
import 'package:bhorosha/features/send_money/logic/risk_outcome.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:bhorosha/features/session/logic/session_reset.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../intervention/intervention_fakes.dart';
import '../pay/pay_test_support.dart';

const rinaPin = '1234';
const glyphs = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

/// Signs Rina in, picks রফিক and 500 taka, opens the PIN pad of [kind]
/// (cash out: agent AG-0027; recharge: her own Operator A number; bill:
/// DESCO 12345678).
Future<ProviderContainer> openPin(
  WidgetTester tester,
  ScreenHarness h, {
  int amount = 500,
  bool newPayee = false,
  PayKind kind = PayKind.send,
  List<Override> extraOverrides = const [],
}) async {
  final c = await pumpPay(
    tester,
    harness: h,
    location: PayPaths.start(kind),
    extraOverrides: extraOverrides,
  );
  final ctl = c.read(payControllerProvider.notifier);
  switch (kind) {
    case PayKind.send when newPayee:
      ctl.selectCounterparty(
        const Counterparty(
          acctId: 'acct_01999999999',
          nameBn: '01999-999999',
          subtitle: '01999999999',
          isSaved: false,
        ),
      );
    case PayKind.send:
      ctl.selectPayee(const Payee(acctId: 'acct_rafiq', nameBn: 'রফিক ইসলাম'));
    case PayKind.cashOut:
      ctl.selectCounterparty(
        const Counterparty(
          acctId: 'AG-0027',
          nameBn: 'এজেন্ট',
          subtitle: '017XXXXX027',
        ),
      );
    case PayKind.recharge:
      ctl.selectCounterparty(
        const Counterparty(
          acctId: 'mob_017XXXXX412',
          nameBn: 'রিনা আক্তার',
          subtitle: '017XXXXX412',
        ),
      );
    case PayKind.bill:
      final billers = BillerCatalog.parse(
        File(BillerCatalog.path).readAsStringSync(),
      );
      ctl.setBill(Bill(biller: billers.first, account: '12345678'));
    case PayKind.dps:
      ctl.beginDps(monthlyBdt: amount, tenureMonths: 36);
    case PayKind.cashIn:
      break;
  }
  if (!kind.fixedAmount) ctl.setAmount(amount);
  routerOf(c).go(PayPaths.pin(kind));
  await tester.pumpAndSettle();
  expect(find.byType(PinPadScreen), findsOneWidget);
  return c;
}

/// The result amount (digit slots, so not one Text).
num resultAmount(WidgetTester tester) =>
    tester.widget<RollingAmount>(find.byKey(const Key('result_amount'))).amount;

// Repo reads after `pumpAndSettle` run under `runAsync`: a stream `.first`
// awaited from the fake-async zone with no pump in flight never resolves.
Future<List<LedgerTxn>> rows(WidgetTester tester, ProviderContainer c) async =>
    (await tester.runAsync(
      () => c.read(ledgerRepoProvider).watchRecent('rina', limit: 50).first,
    ))!;

Future<double> balance(WidgetTester tester, ProviderContainer c) async =>
    (await tester.runAsync(
      () => c.read(ledgerRepoProvider).watchBalance('rina').first,
    ))!;

Future<List<InterventionRecord>> interventionRecords(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(
  () => c.read(interventionRepoProvider).watch('rina').first,
))!;

void main() {
  testWidgets('FLAG_SECURE: step 1 and the pad turn it on, going back '
      'keeps it on, leaving /pay turns it off; digits never in a Text', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    // Step 1 (owner of /pay/*) and then the pad: on, on.
    expect(h.native.secureCalls, [true, true]);
    expect(find.text('পিন দিন'), findsOneWidget);
    expect(find.text('রফিক ইসলাম-কে পাঠাচ্ছেন'), findsOneWidget);
    expect(find.text('৳ ৫০০'), findsOneWidget);
    expect(find.byKey(const Key('numpad_lock')), findsOneWidget);
    expect(
      find.byType(FloatingActionButton),
      findsNothing,
      reason: 'no Apa FAB',
    );

    await tapDigits(tester, '123');
    final texts = allTexts(tester);
    // Each key glyph appears exactly once (the key itself); no sequence.
    for (final g in glyphs) {
      expect(texts.where((t) => t == g), hasLength(1));
    }
    for (final t in texts) {
      expect(t, isNot(contains('১২৩')));
      expect(t, isNot(contains('123')));
    }
    expect(find.byKey(const Key('pin_dots')), findsOneWidget);
    expect(h.api.callsTo(RiskRoutes.score), isEmpty);

    // Back to step 1: never off; step 1 re-arms it on didPopNext.
    routerOf(c).go(PayPaths.send);
    await tester.pumpAndSettle();
    expect(h.native.secureCalls, isNot(contains(false)));
    expect(h.native.secureCalls.last, isTrue);
    expect(h.native.secureCalls, hasLength(3), reason: 'didPopNext re-arm');

    // Leaving /pay entirely turns it off.
    routerOf(c).go(Routes.home);
    await tester.pumpAndSettle();
    expect(h.native.secureCalls.last, isFalse);
  });

  testWidgets('back from the pad (system or app bar) returns to the amount '
      'step and keeps the flow secure', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PinPadScreen), findsNothing);
    expect(find.byType(AmountStep), findsOneWidget);
    expect(locationOf(c), PayPaths.sendAmount);
    expect(c.read(payControllerProvider).amountBdt, 500);
    expect(h.native.secureCalls, isNot(contains(false)));
    expect(h.native.secureCalls.last, isTrue);

    routerOf(c).go(PayPaths.sendPin);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.sendAmount);
  });

  testWidgets('system back cannot pop the pad while verifying', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    final release = h.api.hold(RiskRoutes.score);
    await tapDigits(tester, rinaPin);
    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(locationOf(c), PayPaths.sendPin);

    release();
    await tester.pumpAndSettle();
    expect(find.byType(ResultScreen), findsOneWidget);
  });

  testWidgets('backspace is a correction, never a recorded press', (
    tester,
  ) async {
    final h = ScreenHarness();
    await openPin(tester, h);
    await tapDigit(tester, 1);
    await tester.tap(find.bySemanticsLabel('মুছুন'));
    await tester.pump();
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    final signals =
        h.api.callsTo(RiskRoutes.signals).single.body! as Map<String, dynamic>;
    final features =
        (signals['behaviour'] as Map<String, dynamic>)['features']
            as List<Object?>;
    // Five digit presses (1, then 1-2-3-4) and one correction.
    expect(features[FeatureNames.indexOf('tap_count')], 5.0);
    expect(features[FeatureNames.indexOf('pin_backspaces')], 1.0);
  });

  testWidgets('fourth key locks the pad and shows যাচাই হচ্ছে… at once', (
    tester,
  ) async {
    final h = ScreenHarness();
    await openPin(tester, h);
    final release = h.api.hold(RiskRoutes.score);

    await tapDigits(tester, rinaPin);
    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);
    expect(find.byKey(const Key('pin_verifying')), findsOneWidget);
    // Extra taps while locked change nothing.
    await tester.tap(find.text('৫'));
    await tester.pump();
    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);

    release();
    await tester.pumpAndSettle();
    expect(find.byType(ResultScreen), findsOneWidget);
  });

  testWidgets('wrong PIN: no score call, Bangla line, dots cleared', (
    tester,
  ) async {
    final h = ScreenHarness();
    await openPin(tester, h);
    await tapDigits(tester, '0000');
    await tester.pumpAndSettle();

    expect(h.api.callsTo(RiskRoutes.score), isEmpty);
    expect(h.api.callsTo(RiskRoutes.signals), isEmpty);
    expect(find.text('পিন ভুল হয়েছে। আবার দিন।'), findsOneWidget);
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(find.text('যাচাই হচ্ছে…'), findsNothing);
  });

  testWidgets('wrong PIN then the right one: the intent survives and the '
      'transfer is scored', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    await tapDigits(tester, '0000');
    await tester.pumpAndSettle();
    expect(find.text('পিন ভুল হয়েছে। আবার দিন।'), findsOneWidget);
    final intent = c.read(payControllerProvider);
    expect(intent.counterparty, isNotNull, reason: 'wrong PIN kept the payee');
    expect(intent.amountBdt, 500);

    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.score), hasLength(1));
    expect(find.byType(ResultScreen), findsOneWidget);
  });

  testWidgets('third wrong PIN starts a 30 s pause, then the pad returns', (
    tester,
  ) async {
    final h = ScreenHarness();
    await openPin(tester, h);
    for (var i = 0; i < 3; i++) {
      await tapDigits(tester, '0000');
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('৩০ সেকেন্ড'), findsOneWidget);
    // Locked: a digit does nothing.
    await tapDigits(tester, rinaPin);
    expect(h.api.callsTo(RiskRoutes.score), isEmpty);

    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.textContaining('সেকেন্ড'), findsNothing);

    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.score), hasLength(1));
  });

  testWidgets('the 30 s pause survives back and Next: a new pad is still '
      'paused with its countdown', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    for (var i = 0; i < 3; i++) {
      await tapDigits(tester, '0000');
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('৩০ সেকেন্ড'), findsOneWidget);

    // Back to the amount step, then Next builds a fresh pad.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AmountStep), findsOneWidget);
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    expect(find.byType(PinPadScreen), findsOneWidget);

    // Still paused, with the countdown; the right PIN does nothing.
    expect(find.textContaining('সেকেন্ড'), findsOneWidget);
    await tapDigits(tester, rinaPin);
    await tester.pump();
    expect(h.api.callsTo(RiskRoutes.score), isEmpty);

    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.textContaining('সেকেন্ড'), findsNothing);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.score), hasLength(1));
    expect(c.read(pinAttemptsProvider), isEmpty, reason: 'right PIN clears');
  });

  testWidgets('two wrong PINs, back and Next: the third still pauses (the '
      'count is per user, not per pad)', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    for (var i = 0; i < 2; i++) {
      await tapDigits(tester, '0000');
      await tester.pumpAndSettle();
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    await tapDigits(tester, '0000');
    await tester.pumpAndSettle();
    expect(find.textContaining('৩০ সেকেন্ড'), findsOneWidget);
    expect(c.read(pinAttemptsProvider)['rina']?.pauseUntil, isNotNull);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('logout clears the pause (session reset)', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h);
    for (var i = 0; i < 3; i++) {
      await tapDigits(tester, '0000');
      await tester.pumpAndSettle();
    }
    expect(c.read(pinAttemptsProvider), isNotEmpty);
    await tester.runAsync(() => resetSessionState(c.read, previousUid: 'rina'));
    expect(c.read(pinAttemptsProvider), isEmpty);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('obscured touch pauses input for a second with a warning', (
    tester,
  ) async {
    final h = ScreenHarness();
    await openPin(tester, h);
    h.native.emit(const ObscuredTouchEvent());
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('অন্য একটি অ্যাপ'), findsOneWidget);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(h.api.callsTo(RiskRoutes.score), isEmpty);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('অন্য একটি অ্যাপ'), findsNothing);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.score), hasLength(1));
  });

  testWidgets('right PIN: signals carry 55 features, score carries the txn, '
      'Allowed → ledger done and the result route', (tester) async {
    final h = ScreenHarness();
    final c = await openPin(tester, h, newPayee: true, amount: 7900);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    final signals =
        h.api.callsTo(RiskRoutes.signals).single.body! as Map<String, dynamic>;
    final behaviour = signals['behaviour'] as Map<String, dynamic>;
    final features = behaviour['features'] as List<Object?>;
    expect(features, hasLength(55));
    expect(features.every((f) => f is double && f.isFinite), isTrue);
    // Four presses were recorded: the PIN timings are measurable.
    expect((features[14] as double), greaterThanOrEqualTo(0));

    final score =
        h.api.callsTo(RiskRoutes.score).single.body! as Map<String, dynamic>;
    expect(score['user_id'], 'rina');
    final txn = score['txn'] as Map<String, dynamic>;
    expect(txn['type'], 'send_money');
    expect(txn['amount_bdt'], 7900.0);
    expect(txn['to_account'], 'acct_01999999999');
    expect(txn['is_new_payee'], isTrue);
    expect(score['session_id'], c.read(sessionRepoProvider).sessionId);

    expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=done'));
    expect(find.text('টাকা পাঠানো হয়েছে'), findsOneWidget);
    expect(resultAmount(tester), 7900);
    expect(c.read(lastScoreProvider), FakeRiskApi.allowScore);

    final done = (await rows(
      tester,
      c,
    )).where((t) => t.status == LedgerStatus.done);
    expect(done, hasLength(1));
    expect(done.single.toAcct, 'acct_01999999999');
    expect(await balance(tester, c), 1941);
  });

  testWidgets('Held: overlay opens before /intervene answers, predicted clip '
      'plays, then script_bn renders; ledger held, record open', (
    tester,
  ) async {
    final h = ScreenHarness(score: holdScore(), intervene: served());
    final c = await openPin(tester, h);
    final release = h.api.holdIntervene();

    await tapDigits(tester, rinaPin);
    // The overlay's waiting spinner never settles while /intervene is held.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Overlay is up on the score alone, with the reasons and the clip,
    // and says what is held.
    expect(find.byType(InterventionScreen), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('intervention_held_amount')))
          .data,
      '৳ ৫০০',
    );
    expect(find.text('রফিক ইসলাম'), findsOneWidget);
    expect(find.text(reasonScam.textBn), findsOneWidget);
    expect(find.text('এফএনএ বলছে…'), findsOneWidget);
    // No call_active flag: the top reason SCAM_CONVERSATION predicts the
    // generic clip, which starts before /intervene answers.
    expect(h.audio.played, ['apa_generic_caution']);
    expect(find.byKey(const ValueKey('intervention_script')), findsNothing);

    release();
    await tester.pumpAndSettle();
    expect(find.text(served().scriptBn), findsOneWidget);
    // The served asset differs, so the overlay queues it after the predicted
    // one (never cut mid-sentence).
    expect(h.audio.played, ['apa_generic_caution', 'apa_hold_call_active']);

    final held = (await rows(
      tester,
      c,
    )).where((t) => t.status == LedgerStatus.held);
    expect(held, hasLength(1));
    final records = await interventionRecords(tester, c);
    expect(records, hasLength(1));
    expect(records.single.status, InterventionStatus.open);
    expect(records.single.trigger, 'scam_conversation');
    expect(records.single.scriptBn, served().scriptBn);
    expect(records.single.txnId, held.single.txnId);
    expect(held.single.interventionId, records.single.id);
    // Money did not move.
    expect(await balance(tester, c), 9841);

    // Dismiss → result held with the server reasons.
    await tester.tap(find.byKey(const ValueKey('intervention_dismiss')));
    await tester.pumpAndSettle();
    expect(find.byType(InterventionScreen), findsNothing);
    expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=held'));
    expect(find.text('আপনার টাকা নিরাপদে আটকে আছে'), findsOneWidget);
    expect(find.text(reasonScam.textBn), findsOneWidget);
    expect(find.byKey(const Key('apa_button_result')), findsOneWidget);
  });

  testWidgets('Held: the held row and open record exist before /intervene '
      'answers and survive a dismiss that comes first', (tester) async {
    final h = ScreenHarness(score: holdScore(), intervene: served());
    final c = await openPin(tester, h);
    final release = h.api.holdIntervene();

    await tapDigits(tester, rinaPin);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(InterventionScreen), findsOneWidget);

    // Written in onHoldPredicted, with /intervene still pending.
    var held = (await rows(
      tester,
      c,
    )).where((t) => t.status == LedgerStatus.held);
    expect(held, hasLength(1));
    var records = await interventionRecords(tester, c);
    expect(records, hasLength(1));
    expect(records.single.status, InterventionStatus.open);
    expect(records.single.scriptBn, isEmpty);
    expect(records.single.reasons, holdScore().reasons);
    expect(held.single.interventionId, records.single.id);

    // Dismiss before /intervene answers: the pad is gone.
    await tester.tap(find.byKey(const ValueKey('intervention_dismiss')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(PinPadScreen), findsNothing);
    expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=held'));
    expect(find.text(reasonScam.textBn), findsOneWidget, reason: 'last score');

    // /intervene answers after the dismiss: the record is still patched.
    release();
    await tester.pumpAndSettle();
    held = (await rows(tester, c)).where((t) => t.status == LedgerStatus.held);
    expect(held, hasLength(1));
    records = await interventionRecords(tester, c);
    expect(records, hasLength(1));
    expect(records.single.scriptBn, served().scriptBn);
    expect(records.single.txnId, held.single.txnId);
    expect(await balance(tester, c), 9841);
  });

  testWidgets('Held: trusted contact action posts the request and marks '
      'the record pending', (tester) async {
    final h = ScreenHarness(score: holdScore(), intervene: served());
    final c = await openPin(tester, h);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('action_trusted_contact_check')),
    );
    await tester.pumpAndSettle();
    final call =
        h.api.callsTo(RiskRoutes.trustedContact).single.body!
            as Map<String, dynamic>;
    expect(call['contact_uid'], 'rafiq');
    // The button turns into the green "sent" line in place; the request id
    // never reaches the screen (log and demo panel only).
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('trusted_request_sent')), findsOneWidget);
    expect(find.text('আপনজনকে অনুরোধ পাঠানো হয়েছে'), findsOneWidget);
    expect(find.textContaining('fake-req-1'), findsNothing);
    final records = await interventionRecords(tester, c);
    expect(records.single.status, InterventionStatus.pending);
    expect(records.single.requestId, 'fake-req-1');
  });

  testWidgets('Unavailable: score times out → cannot verify, no money moved', (
    tester,
  ) async {
    final h = ScreenHarness();
    h.api.failures[RiskRoutes.score] = const TimeoutFailure();
    final c = await openPin(tester, h);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    expect(
      locationOf(c),
      startsWith('${PayPaths.sendResult}?state=unavailable'),
    );
    expect(find.text('এখন যাচাই করা যাচ্ছে না'), findsOneWidget);
    expect(find.byKey(const Key('result_retry')), findsOneWidget);
    final done = (await rows(
      tester,
      c,
    )).where((t) => t.status == LedgerStatus.done);
    expect(done, isEmpty);
    expect(await balance(tester, c), 9841);
    expect(c.read(lastScoreProvider), isNull);

    // Retry returns to the PIN pad with the same session and payee.
    final session = c.read(payControllerProvider).sessionId;
    await tester.tap(find.byKey(const Key('result_retry')));
    await tester.pumpAndSettle();
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(c.read(payControllerProvider).sessionId, session);
    expect(c.read(payControllerProvider).counterparty?.acctId, 'acct_rafiq');
  });

  group('an unexpected throw while scoring', () {
    for (final (name, overrides)
        in <(String, List<Override> Function(ScreenHarness))>[
          (
            'the API throws a StateError',
            (h) => [
              riskFlowProvider.overrideWith(
                (ref) => RiskFlow(
                  api: _ThrowingScoreApi(),
                  native: h.native,
                  cooldown: Cooldown(const SystemClock()),
                  clock: const SystemClock(),
                  nonce: () => 'n',
                ),
              ),
            ],
          ),
          (
            'the risk flow itself throws',
            (h) => [riskFlowProvider.overrideWith((ref) => _ThrowingFlow(h))],
          ),
        ]) {
      testWidgets('$name: cannot verify, retry, never stuck verifying', (
        tester,
      ) async {
        final h = ScreenHarness();
        final c = await openPin(tester, h, extraOverrides: overrides(h));
        await tapDigits(tester, rinaPin);
        await tester.pumpAndSettle();

        expect(find.text('যাচাই হচ্ছে…'), findsNothing);
        expect(
          locationOf(c),
          startsWith('${PayPaths.sendResult}?state=unavailable'),
        );
        expect(find.byKey(const Key('result_retry')), findsOneWidget);
        final done = (await rows(
          tester,
          c,
        )).where((t) => t.status == LedgerStatus.done);
        expect(done, isEmpty);
      });
    }
  });

  testWidgets('StepUp: stop-screen-share sheet, retry returns to the pad', (
    tester,
  ) async {
    final h = ScreenHarness(
      score: const ScoreResponse(
        decision: Decision.stepUp,
        riskScore: 0.5,
        band: Band.high,
        reasons: [],
        actions: [ActionItem(type: 'step_up_verification')],
        modelVersion: 'fake',
      ),
    );
    final c = await openPin(tester, h);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    expect(find.text('স্ক্রিন শেয়ার বন্ধ করুন'), findsOneWidget);
    await tester.tap(find.byKey(const Key('step_up_retry')));
    await tester.pumpAndSettle();
    expect(find.text('স্ক্রিন শেয়ার বন্ধ করুন'), findsNothing);
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(find.text('যাচাই হচ্ছে…'), findsNothing);
    expect(
      (await rows(tester, c)).where((t) => t.status != LedgerStatus.ok),
      isEmpty,
    );

    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.score), hasLength(2));
  });

  // An App Safety block gets FNA's words, written by the
  // server from what the check found; the block's own actions are unchanged.
  testWidgets('Blocked by App Safety: FNA explains it through /v1/intervene', (
    tester,
  ) async {
    const appSafetyReason = Reason(
      code: 'APP_SAFETY_BLOCK',
      weight: 0.95,
      textBn: 'আপনার ফোনের একটি অ্যাপ আপনার মেসেজ পড়তে পারে।',
      textEn: 'An app on your phone can read your messages.',
    );
    final h = ScreenHarness(
      score: const ScoreResponse(
        decision: Decision.block,
        riskScore: 0.95,
        band: Band.critical,
        reasons: [appSafetyReason],
        actions: [ActionItem(type: 'block_transaction')],
        modelVersion: 'fake',
      ),
    );
    await openPin(tester, h);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    expect(find.byType(InterventionScreen), findsOneWidget);
    final calls = h.api.callsTo(RiskRoutes.intervene);
    expect(calls, hasLength(1));
    expect(
      (calls.single.body! as Map<String, dynamic>)['trigger'],
      'app_safety',
    );
    expect(find.text(appSafetyReason.textBn), findsOneWidget);
    expect(
      find.textContaining(FakeRiskApi.genericCaution.scriptBn),
      findsWidgets,
    );
    // Still a block: one acknowledgement, no hold actions from the answer.
    expect(find.byKey(const ValueKey('action_acknowledge')), findsOneWidget);
    expect(find.byKey(const ValueKey('action_hold_transaction')), findsNothing);
  });

  testWidgets('Blocked: overlay with the score reasons and actions, ledger '
      'blocked; dismiss opens the safety findings with the reasons', (
    tester,
  ) async {
    final h = ScreenHarness(
      score: const ScoreResponse(
        decision: Decision.block,
        riskScore: 0.99,
        band: Band.critical,
        reasons: [reasonScam],
        actions: [ActionItem(type: 'block_transaction')],
        modelVersion: 'fake',
      ),
    );
    final c = await openPin(tester, h);
    await tapDigits(tester, rinaPin);
    await tester.pumpAndSettle();

    expect(find.byType(InterventionScreen), findsOneWidget);
    expect(find.text(reasonScam.textBn), findsOneWidget);
    // One state: "ঠিক আছে", never a cancel.
    expect(
      find.byKey(const ValueKey('action_block_transaction')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('action_acknowledge')), findsOneWidget);
    expect(h.api.callsTo(RiskRoutes.intervene), isEmpty);

    await tester.tap(find.byKey(const ValueKey('intervention_dismiss')));
    await tester.pumpAndSettle();
    expect(find.byType(InterventionScreen), findsNothing);
    expect(locationOf(c), '${Routes.safety}?block=1');
    expect(find.byType(SafetyScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('safety_block_reason_SCAM_CONVERSATION')),
      findsOneWidget,
    );
    final blocked = (await rows(
      tester,
      c,
    )).where((t) => t.status == LedgerStatus.blocked);
    expect(blocked, hasLength(1));
    expect(await balance(tester, c), 9841);
  });

  group('per kind', () {
    testWidgets('cash out is scored as a transfer to the agent till: amount '
        '+ fee, known agent; ledger cash_out', (tester) async {
      final h = ScreenHarness();
      final c = await openPin(tester, h, kind: PayKind.cashOut, amount: 2000);
      expect(find.text('এজেন্ট ০১৭XX-XXX০২৭-কে ক্যাশ আউট'), findsOneWidget);
      expect(find.text('চার্জ সহ মোট ৳ ২,০৩০'), findsOneWidget);
      expect(find.text('দুই হাজার টাকা'), findsOneWidget);
      await tapDigits(tester, rinaPin);
      await tester.pumpAndSettle();

      final signals =
          h.api.callsTo(RiskRoutes.signals).single.body!
              as Map<String, dynamic>;
      expect(
        ((signals['behaviour'] as Map<String, dynamic>)['features'] as List)
            .length,
        55,
      );
      final score =
          h.api.callsTo(RiskRoutes.score).single.body! as Map<String, dynamic>;
      final txn = score['txn'] as Map<String, dynamic>;
      expect(txn['type'], 'send_money');
      expect(txn['amount_bdt'], 2030.0);
      expect(txn['to_account'], 'AG-0027');
      expect(txn['is_new_payee'], isFalse);

      final row = (await rows(tester, c)).first;
      expect(row.type, 'cash_out');
      expect(row.status, LedgerStatus.done);
      expect(row.amountBdt, 2030);
      expect(row.counterpartyNameBn, 'এজেন্ট ক্যাশ আউট');
      expect(await balance(tester, c), 9841 - 2030);
      expect(
        locationOf(c),
        startsWith('${PayPaths.result(PayKind.cashOut, state: 'done')}&'),
      );
      expect(find.text('ক্যাশ আউট হয়েছে'), findsOneWidget);
    });

    testWidgets('a new agent is scored as a new payee', (tester) async {
      final h = ScreenHarness();
      final c = await pumpPay(
        tester,
        harness: h,
        location: PayPaths.start(PayKind.cashOut),
      );
      c.read(payControllerProvider.notifier)
        ..selectCounterparty(
          const Counterparty(
            acctId: 'agent_01812345678',
            nameBn: 'এজেন্ট',
            subtitle: '01812345678',
            isSaved: false,
          ),
        )
        ..setAmount(1000);
      routerOf(c).go(PayPaths.pin(PayKind.cashOut));
      await tester.pumpAndSettle();
      await tapDigits(tester, rinaPin);
      await tester.pumpAndSettle();
      final txn =
          (h.api.callsTo(RiskRoutes.score).single.body!
                  as Map<String, dynamic>)['txn']
              as Map<String, dynamic>;
      expect(txn['to_account'], 'agent_01812345678');
      expect(txn['is_new_payee'], isTrue);
      expect(txn['amount_bdt'], 1015.0);
    });

    for (final (kind, type, amount, title) in [
      (PayKind.recharge, 'recharge', 100, 'রিচার্জ হয়েছে'),
      (PayKind.bill, 'payment', 1240, 'বিল দেওয়া হয়েছে'),
    ]) {
      testWidgets('${kind.slug}: PIN, a local allow with no risk call, a '
          'done $type row; 55 features still built', (tester) async {
        final h = ScreenHarness();
        PinPadScreen.lastFeatures = null;
        final c = await openPin(tester, h, kind: kind, amount: amount);
        if (kind == PayKind.recharge) {
          expect(
            find.text('০১৭XX-XXX৪১২ · অপারেটর ক রিচার্জ'),
            findsOneWidget,
          );
        } else {
          expect(find.text('ডেসকো বিদ্যুৎ বিল'), findsOneWidget);
        }
        await tapDigits(tester, rinaPin);
        expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);
        // The local allow keeps the verifying rhythm for 600 ms.
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(PinPadScreen), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();

        expect(h.api.callsTo(RiskRoutes.score), isEmpty);
        expect(h.api.callsTo(RiskRoutes.signals), isEmpty);
        expect(PinPadScreen.lastFeatures, hasLength(55));
        final row = (await rows(tester, c)).first;
        expect(row.type, type);
        expect(row.status, LedgerStatus.done);
        expect(row.amountBdt, amount);
        expect(await balance(tester, c), 9841 - amount);
        expect(
          locationOf(c),
          startsWith('${PayPaths.result(kind, state: 'done')}&'),
        );
        expect(find.text(title), findsOneWidget);
      });
    }

    testWidgets(
      'bill: a wrong PIN still recovers, back goes to the bill card',
      (tester) async {
        final h = ScreenHarness();
        final c = await openPin(tester, h, kind: PayKind.bill);
        await tapDigits(tester, '0000');
        await tester.pumpAndSettle();
        expect(find.text('পিন ভুল হয়েছে। আবার দিন।'), findsOneWidget);
        expect(
          (await rows(tester, c)).where((t) => t.type == 'payment'),
          isEmpty,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(BillConfirmStep), findsOneWidget);
      },
    );
  });

  group('store writes rejected (Firestore after a failed sign-in)', () {
    List<Override> rejecting(ScreenHarness h) => [
      ledgerRepoProvider.overrideWith((ref) {
        final repo = _RejectingLedger(h.assets);
        ref.onDispose(repo.dispose);
        return repo;
      }),
      interventionRepoProvider.overrideWith((ref) {
        final repo = _RejectingInterventions();
        ref.onDispose(repo.dispose);
        return repo;
      }),
    ];

    testWidgets('Allowed still routes to the result', (tester) async {
      final h = ScreenHarness();
      final c = await openPin(tester, h, extraOverrides: rejecting(h));
      await tapDigits(tester, rinaPin);
      await tester.pumpAndSettle();
      expect(find.text('যাচাই হচ্ছে…'), findsNothing);
      expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=done'));
    });

    testWidgets('Held: overlay opens and dismiss routes to held', (
      tester,
    ) async {
      final h = ScreenHarness(score: holdScore(), intervene: served());
      final c = await openPin(tester, h, extraOverrides: rejecting(h));
      await tapDigits(tester, rinaPin);
      await tester.pumpAndSettle();
      expect(find.byType(InterventionScreen), findsOneWidget);
      expect(find.text(served().scriptBn), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('intervention_dismiss')));
      await tester.pumpAndSettle();
      expect(locationOf(c), startsWith('${PayPaths.sendResult}?state=held'));
    });

    testWidgets('Blocked: overlay still opens', (tester) async {
      final h = ScreenHarness(
        score: const ScoreResponse(
          decision: Decision.block,
          riskScore: 0.99,
          band: Band.critical,
          reasons: [reasonScam],
          actions: [ActionItem(type: 'block_transaction')],
          modelVersion: 'fake',
        ),
      );
      await openPin(tester, h, extraOverrides: rejecting(h));
      await tapDigits(tester, rinaPin);
      await tester.pumpAndSettle();
      expect(find.byType(InterventionScreen), findsOneWidget);
    });
  });
}

class _RejectingLedger extends LocalLedgerRepo {
  _RejectingLedger(super.assets);

  @override
  Future<LedgerTxn> create(String uid, LedgerTxn t) =>
      Future.error(StateError('PERMISSION_DENIED'));
}

class _RejectingInterventions extends LocalInterventionRepo {
  @override
  Future<void> upsert(InterventionRecord r) =>
      Future.error(StateError('PERMISSION_DENIED'));
}

/// `/score` fails with something that is not an `ApiFailure`.
class _ThrowingScoreApi extends FakeRiskApi {
  @override
  Future<ScoreResponse> postScore(ScoreRequest r) =>
      Future.error(StateError('boom'));
}

/// A risk flow that throws straight out of `scoreTransfer` (a bug).
class _ThrowingFlow extends RiskFlow {
  _ThrowingFlow(ScreenHarness h)
    : super(
        api: h.api,
        native: h.native,
        cooldown: Cooldown(const SystemClock()),
        clock: const SystemClock(),
        nonce: () => 'n',
      );

  @override
  Future<RiskOutcome> scoreTransfer({
    required UserProfile user,
    required String sessionId,
    required Txn txn,
    required List<double> features,
    required DemoState demo,
    SafetyVerdict? lastVerdict,
    AppSafetyContext? appSafety,
    HoldPredicted? onHoldPredicted,
    BehaviourMode mode = BehaviourMode.live,
    void Function(DemoFlags flags)? onFlags,
  }) => throw TypeError();
}
