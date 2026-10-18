import 'package:bhorosha/app/widgets/digit_slots.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/ui/bill_confirm_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pay_test_support.dart';

void main() {
  group('cash out', () {
    testWidgets('two recent agents from the history, demo note, agent line; '
        'a recent agent is a known payee', (tester) async {
      final h = ScreenHarness();
      final c = await pumpPay(
        tester,
        harness: h,
        location: PayPaths.start(PayKind.cashOut),
      );
      expect(h.api.callsTo(RiskRoutes.health), hasLength(1), reason: 'scored');
      expect(find.text('ক্যাশ আউট'), findsOneWidget);
      expect(
        find.text('ডেমো: আসল টাকা বা আসল অপারেটরে কিছু যায় না'),
        findsOneWidget,
      );
      expect(find.text('এজেন্ট কখনো আপনার পিন জানতে চাইবে না'), findsOneWidget);
      expect(find.byKey(const Key('agent_AG-0027')), findsOneWidget);
      expect(find.byKey(const Key('agent_AG-0011')), findsOneWidget);
      expect(find.text('০১৭XX-XXX০২৭'), findsOneWidget);

      await tester.tap(find.byKey(const Key('agent_AG-0027')));
      await tester.pumpAndSettle();
      final s = c.read(payControllerProvider);
      expect(s.kind, PayKind.cashOut);
      expect(s.counterparty?.acctId, 'AG-0027');
      expect(s.isNewPayee, isFalse);
      expect(locationOf(c), PayPaths.amount(PayKind.cashOut));
    });

    testWidgets('a new agent number is a new payee agent_<digits>', (
      tester,
    ) async {
      final h = ScreenHarness();
      final c = await pumpPay(
        tester,
        harness: h,
        location: PayPaths.start(PayKind.cashOut),
      );
      await tester.tap(find.byKey(const Key('cashout_new_agent')));
      await tester.pumpAndSettle();
      expect(buttonEnabled(tester, const Key('number_confirm')), isFalse);
      await padDigits(tester, '01812345678');
      expect(
        buttonLabel(tester, const Key('number_confirm')),
        'এই নম্বর নিন →',
      );
      await tester.tap(find.byKey(const Key('number_confirm')));
      await tester.pumpAndSettle();
      final s = c.read(payControllerProvider);
      expect(s.counterparty?.acctId, 'agent_01812345678');
      expect(s.isNewPayee, isTrue);
    });
  });

  group('recharge', () {
    testWidgets('own number first, operator auto-picked and overridable, '
        'prepaid by default; no /health warm-up', (tester) async {
      final h = ScreenHarness();
      final c = await pumpPay(
        tester,
        harness: h,
        location: PayPaths.start(PayKind.recharge),
      );
      expect(h.api.callsTo(RiskRoutes.health), isEmpty);
      expect(find.text('কোন নম্বরে?'), findsOneWidget);
      expect(find.text('আমার নম্বর · ০১৭XX-XXX৪১২'), findsOneWidget);
      expect(buttonLabel(tester, const Key('recharge_next')), 'নম্বর বেছে নিন');
      expect(buttonEnabled(tester, const Key('recharge_next')), isFalse);

      await tester.tap(find.byKey(const Key('recharge_017XXXXX412')));
      await tester.pumpAndSettle();
      var s = c.read(payControllerProvider);
      expect(s.counterparty?.acctId, 'mob_017XXXXX412');
      expect(s.operator, Operator.a);
      expect(s.postpaid, isFalse);
      expect(find.text('অপারেটর ক নম্বর মনে হচ্ছে'), findsOneWidget);
      for (final name in [
        'অপারেটর ক',
        'অপারেটর খ',
        'অপারেটর গ',
        'অপারেটর ঘ',
        'অপারেটর ঙ',
      ]) {
        expect(find.text(name), findsOneWidget);
      }

      await tester.ensureVisible(find.byKey(const Key('op_b')));
      await tester.tap(find.byKey(const Key('op_b')));
      await tester.ensureVisible(find.byKey(const Key('recharge_postpaid')));
      await tester.tap(find.byKey(const Key('recharge_postpaid')));
      await tester.pump();
      s = c.read(payControllerProvider);
      expect(s.operator, Operator.b);
      expect(s.postpaid, isTrue);

      expect(buttonLabel(tester, const Key('recharge_next')), 'পরের ধাপ →');
      await tester.tap(find.byKey(const Key('recharge_next')));
      await tester.pumpAndSettle();
      expect(locationOf(c), PayPaths.amount(PayKind.recharge));
      expect(find.text('০১৭XX-XXX৪১২ · অপারেটর খ'), findsOneWidget);
    });

    testWidgets('another number from the panel, operator by its prefix', (
      tester,
    ) async {
      final h = ScreenHarness();
      final c = await pumpPay(
        tester,
        harness: h,
        location: PayPaths.start(PayKind.recharge),
      );
      await tester.tap(find.byKey(const Key('recharge_other')));
      await tester.pumpAndSettle();
      await padDigits(tester, '01512345678');
      await tester.tap(find.byKey(const Key('number_confirm')));
      await tester.pumpAndSettle();
      final s = c.read(payControllerProvider);
      expect(s.counterparty?.acctId, 'mob_01512345678');
      expect(s.operator, Operator.d);
      expect(find.byKey(const Key('recharge_01512345678')), findsOneWidget);
    });
  });

  group('pay bill', () {
    testWidgets('three billers; the account length gates "বিল দেখুন"; the '
        'bill card shows the fixed amount', (tester) async {
      final h = ScreenHarness();
      final c = await pumpPay(
        tester,
        harness: h,
        location: PayPaths.start(PayKind.bill),
      );
      expect(find.text('ডেসকো (বিদ্যুৎ)'), findsOneWidget);
      expect(find.text('ঢাকা ওয়াসা (পানি)'), findsOneWidget);
      expect(find.text('তিতাস গ্যাস'), findsOneWidget);

      await tester.tap(find.byKey(const Key('biller_desco')));
      await tester.pumpAndSettle();
      expect(
        buttonLabel(tester, const Key('bill_see')),
        '৮ সংখ্যার গ্রাহক নম্বর লিখুন',
      );
      await padDigits(tester, '1234567');
      expect(buttonEnabled(tester, const Key('bill_see')), isFalse);
      await padDigit(tester, 8);
      expect(find.text('১২৩৪ ৫৬৭৮'), findsOneWidget);
      expect(buttonLabel(tester, const Key('bill_see')), 'বিল দেখুন →');
      await tester.tap(find.byKey(const Key('bill_see')));
      await tester.pumpAndSettle();

      expect(find.byType(BillConfirmStep), findsOneWidget);
      expect(locationOf(c), PayPaths.confirm(PayKind.bill));
      final s = c.read(payControllerProvider);
      expect(s.kind, PayKind.bill);
      expect(s.amountBdt, 1240);
      expect(s.fixedAmountBdt, 1240);
      expect(s.counterparty?.acctId, 'biller_desco_12345678');
      expect(find.text('গ্রাহক নম্বর ১২৩৪ ৫৬৭৮'), findsOneWidget);
      expect(find.text('সেপ্টেম্বর ২০২৬'), findsOneWidget);
      expect(find.text('শেষ তারিখ ২৫ অক্টোবর'), findsOneWidget);
      expect(find.text('ডেমো বিল'), findsOneWidget);
      expect(
        tester.widget<TakaSlots>(find.byKey(const Key('bill_amount'))).amount,
        1240,
      );

      await tester.tap(find.byKey(const Key('bill_pay')));
      await tester.pumpAndSettle();
      expect(locationOf(c), PayPaths.pin(PayKind.bill));
    });
  });

  testWidgets('an unknown kind goes Home; a step a kind lacks goes to its '
      'step 1', (tester) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: '/pay/loans');
    expect(locationOf(c), PayPaths.home);
    routerOf(c).go('/pay/send/code');
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.send);
    routerOf(c).go('/pay/cashin/pin');
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.start(PayKind.cashIn));
  });

  testWidgets('old routes /send, /send/pin, /send/result still resolve', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: '/send');
    expect(locationOf(c), PayPaths.send);
    routerOf(c).go('/send/result?state=unavailable&amount=5');
    await tester.pumpAndSettle();
    expect(locationOf(c), '/pay/send/result?state=unavailable&amount=5');
    routerOf(c).go('/send/pin');
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.sendPin);
  });
}
