import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/domain/behaviour/behaviour_sample.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/ui/amount_step.dart';
import 'package:bhorosha/features/send_money/ui/send_recipient_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../pay/pay_test_support.dart';

void main() {
  testWidgets('opening warms /health, starts the IMU window, lists the '
      'saved payees with the last payment date', (tester) async {
    final imu = _FakeImu();
    final h = ScreenHarness(imu: imu);
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);

    expect(find.byType(SendRecipientStep), findsOneWidget);
    expect(h.api.callsTo(RiskRoutes.health), hasLength(1));
    expect(imu.listeners, 1);
    expect(c.read(payControllerProvider.notifier).imuWindow.length, 3);
    expect(c.read(payControllerProvider).kind, PayKind.send);
    expect(find.text('টাকা পাঠান'), findsOneWidget);
    expect(find.text('কাকে পাঠাবেন'), findsOneWidget);
    expect(find.text('মা'), findsWidgets);
    expect(find.text('রফিক ইসলাম'), findsOneWidget);
    // Rafiq was paid in the (rebased) seed: "শেষ <date>" after the number.
    expect(find.textContaining('০১৮XX-XXX২০৭ · শেষ'), findsOneWidget);
    expect(find.text('০১৯XX-XXX৮৮১'), findsOneWidget);
    expect(find.byKey(const Key('step_progress')), findsOneWidget);
    expect(find.byKey(const Key('apa_bar_send')), findsOneWidget);
  });

  testWidgets('tapping a saved row selects it and opens the amount step', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);

    await tester.tap(find.byKey(const Key('payee_acct_rahima')));
    await tester.pumpAndSettle();
    final s = c.read(payControllerProvider);
    expect(s.counterparty?.acctId, 'acct_rahima');
    expect(s.counterparty?.isSaved, isTrue);
    expect(s.isNewPayee, isFalse);
    expect(locationOf(c), PayPaths.sendAmount);
    expect(find.byType(AmountStep), findsOneWidget);
  });

  testWidgets('new number: the panel validates 11 digits and the prefix; '
      'confirm builds a new payee', (tester) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    const confirm = Key('number_confirm');

    await tester.tap(find.byKey(const Key('send_new_number')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('number_panel')), findsOneWidget);
    expect(buttonLabel(tester, confirm), '১১ সংখ্যা লিখুন');
    expect(buttonEnabled(tester, confirm), isFalse);

    await padDigits(tester, '0121234567');
    expect(find.text('০১২১২-৩৪৫৬৭'), findsOneWidget);
    expect(find.text('১০/১১ সংখ্যা'), findsOneWidget);
    await padDigit(tester, 8);
    expect(buttonLabel(tester, confirm), 'নম্বরটি ঠিক নয়');
    expect(buttonEnabled(tester, confirm), isFalse);

    // Eleven is the cap; backspace edits.
    await padDigit(tester, 9);
    expect(find.text('০১২১২-৩৪৫৬৭৮'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.bySemanticsLabel('মুছুন'));
      await tester.pump();
    }
    await padDigits(tester, '1712345678');
    expect(buttonLabel(tester, confirm), 'এই নম্বরে পাঠান →');
    expect(buttonEnabled(tester, confirm), isTrue);

    await tester.tap(find.byKey(confirm));
    await tester.pumpAndSettle();
    final s = c.read(payControllerProvider);
    expect(s.counterparty?.acctId, 'acct_01712345678');
    expect(s.counterparty?.isSaved, isFalse);
    expect(s.isNewPayee, isTrue);
    expect(locationOf(c), PayPaths.sendAmount);
  });

  testWidgets('cancel and system back close the panel and keep the digits', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    await tester.tap(find.byKey(const Key('send_new_number')));
    await tester.pumpAndSettle();
    await padDigits(tester, '0171');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('number_panel')), findsNothing);
    expect(locationOf(c), PayPaths.send);

    await tester.tap(find.byKey(const Key('send_new_number')));
    await tester.pumpAndSettle();
    expect(find.text('০১৭১'), findsOneWidget, reason: 'kept for 30 s');
    await tester.tap(find.byKey(const Key('number_cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payee_list')), findsOneWidget);
  });

  testWidgets('back from step 1 goes Home (button and system back)', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.home);

    routerOf(c).go(PayPaths.send);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.home);
  });

  testWidgets('FR-5: FLAG_SECURE on for /pay/*, off after leaving /pay', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    expect(h.native.secureCalls, [true]);

    await tester.tap(find.byKey(const Key('payee_acct_rahima')));
    await tester.pumpAndSettle();
    expect(h.native.secureCalls, [true, true], reason: 'amount turns it on');

    routerOf(c).go(PayPaths.home);
    await tester.pumpAndSettle();
    expect(h.native.secureCalls.last, isFalse);
  });

  testWidgets('scrolling the list records a swipe in physical px', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);

    await tester.drag(
      find.byKey(const Key('payee_list')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    final strokes = c.read(payControllerProvider.notifier).swipeStrokes;
    expect(strokes, hasLength(1));
    expect(strokes.single.points.length, greaterThanOrEqualTo(2));
    final dy = strokes.single.points.last.p.y - strokes.single.points.first.p.y;
    expect(dy, closeTo(-80 * 2.625, 1.0));
  });

  testWidgets('English: labels and digits follow the language', (tester) async {
    final h = ScreenHarness();
    await pumpPay(
      tester,
      harness: h,
      location: PayPaths.send,
      locale: const Locale('en'),
    );
    expect(find.text('Who are you sending to'), findsOneWidget);
    expect(find.text('Ma (Rahima Begum)'), findsOneWidget);
    expect(find.text('019XX-XXX881'), findsOneWidget);
  });
}

class _FakeImu implements ImuSource {
  int listeners = 0;

  @override
  Stream<ImuSample> samples() {
    listeners++;
    return Stream.fromIterable([
      for (var i = 0; i < 3; i++)
        ImuSample(
          tMs: 1000 + i * 20,
          ax: 0,
          ay: 0,
          az: 9.8,
          gx: 0,
          gy: 0,
          gz: 0,
        ),
    ]);
  }
}
