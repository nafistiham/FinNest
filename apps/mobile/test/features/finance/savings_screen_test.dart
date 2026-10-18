import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/animated/rolling_amount.dart';
import 'package:bhorosha/app/widgets/animated/sheet_reveal.dart';
import 'package:bhorosha/app/widgets/bh_button.dart';
import 'package:bhorosha/app/widgets/choice_tile.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/finance/logic/finance_models.dart';
import 'package:bhorosha/features/finance/logic/finance_providers.dart';
import 'package:bhorosha/features/finance/logic/finance_repo.dart';
import 'package:bhorosha/features/finance/ui/savings_screen.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pin_pad/ui/pin_pad_screen.dart';
import 'package:bhorosha/features/result/ui/result_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/screen_harness.dart';
import 'finance_test_support.dart';

Finder _rolling(num value) =>
    find.byWidgetPredicate((w) => w is RollingAmount && w.amount == value);

double _progress(WidgetTester tester, Finder card) => tester
    .widget<FractionallySizedBox>(
      find.descendant(
        of: card,
        matching: find.byKey(const Key('finance_progress_fill')),
      ),
    )
    .widthFactor!;

void main() {
  testWidgets(
    'Rina: title, her plan card with progress, maturity and demo tag',
    (tester) async {
      await pumpFinance(tester, child: const SavingsScreen());

      expect(find.text('সঞ্চয়'), findsOneWidget);
      expect(find.byType(DpsPlanCard), findsOneWidget);
      expect(find.text('মাসিক জমা'), findsOneWidget);
      expect(_rolling(500), findsOneWidget);
      expect(find.text('১৪/৩৬ কিস্তি'), findsOneWidget);
      expect(find.text('৩ বছর'), findsOneWidget);
      expect(find.text('এ পর্যন্ত জমা'), findsOneWidget);
      expect(find.text('৳ ৭,০০০'), findsOneWidget);
      expect(find.text('মেয়াদ শেষে পাবেন'), findsOneWidget);
      expect(find.text('৳ ২১,৫১০'), findsOneWidget);
      expect(find.text('ডেমো হার ৬.৫%'), findsOneWidget);
      // A demo rate is a neutral fact: info, never the amber of a hold.
      expect(
        tester
            .widget<StatusTag>(
              find.ancestor(
                of: find.text('ডেমো হার ৬.৫%'),
                matching: find.byType(StatusTag),
              ),
            )
            .status,
        BhStatus.info,
      );
      final card = find.byType(DpsPlanCard);
      expect(_progress(tester, card), closeTo(14 / 36, 1e-9));
      expect(tester.getSize(find.byKey(const Key('dps_progress'))).height, 6);

      // Primary action: 56 dp, in the thumb zone.
      final open = find.byKey(const Key('savings_open_dps'));
      expect(find.text('নতুন ডিপিএস খুলুন'), findsOneWidget);
      expect(tester.getSize(open).height, greaterThanOrEqualTo(BhSize.touch));
      final screen = tester.getSize(find.byType(Scaffold));
      expect(tester.getBottomLeft(open).dy, greaterThan(screen.height * 0.8));
    },
  );

  testWidgets('the sheet projects live; chips are 56 dp', (tester) async {
    await pumpFinance(tester, child: const SavingsScreen());

    await tester.tap(find.byKey(const Key('savings_open_dps')));
    await tester.pumpAndSettle();
    final sheet = find.byType(DpsOpenSheet);
    expect(sheet, findsOneWidget);
    expect(find.text('মাসে কত জমাবেন?'), findsOneWidget);
    expect(find.text('কত বছরের জন্য?'), findsOneWidget);

    // Defaults ৳ ৫০০ x ৩ বছর: 18000 * (1 + 0.065 * 3) = 21510.
    Finder projected(String text) => find.descendant(
      of: find.byKey(const Key('dps_projection')),
      matching: find.text(text),
    );
    expect(find.text('মেয়াদ শেষে প্রায় পাবেন'), findsOneWidget);
    expect(projected('৳ ২১,৫১০'), findsOneWidget);
    expect(find.text('আজই প্রথম কিস্তি ৳ ৫০০ কেটে নেওয়া হবে'), findsOneWidget);

    // Every chip is a 56 dp target.
    final chips = find.byType(ChoiceTile);
    expect(chips, findsNWidgets(6));
    for (final chip in chips.evaluate()) {
      expect(
        tester.getSize(find.byWidget(chip.widget)).height,
        greaterThanOrEqualTo(BhSize.touch),
      );
    }

    await tester.tap(
      find.descendant(of: sheet, matching: find.text('৳ ১,০০০')),
    );
    await tester.pumpAndSettle();
    expect(projected('৳ ৪৩,০২০'), findsOneWidget);
    await tester.tap(find.descendant(of: sheet, matching: find.text('৫ বছর')));
    await tester.pumpAndSettle();
    // 60000 * (1 + 0.065 * 5) = 79500.
    expect(projected('৳ ৭৯,৫০০'), findsOneWidget);
    expect(
      find.text('আজই প্রথম কিস্তি ৳ ১,০০০ কেটে নেওয়া হবে'),
      findsOneWidget,
    );

    final confirm = find.byKey(const Key('dps_confirm'));
    expect(tester.getSize(confirm).height, greaterThanOrEqualTo(BhSize.touch));
  });

  testWidgets('confirm goes through the PIN step: the plan opens only after '
      'the right PIN, the result says so, back returns to Savings', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.savings);
    final ledger = c.read(ledgerRepoProvider);
    final before = (await tester.runAsync(
      () => ledger.watchBalance('rina').first,
    ))!;
    final plansBefore = (await tester.runAsync(
      () => c.read(financeRepoProvider).watch('rina').first,
    ))!.plans.length;

    await tester.tap(find.byKey(const Key('savings_open_dps')));
    await tester.pumpAndSettle();
    final sheet = find.byType(DpsOpenSheet);
    await tester.tap(
      find.descendant(of: sheet, matching: find.text('৳ ১,০০০')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: sheet, matching: find.text('৫ বছর')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dps_confirm')));
    await tester.pumpAndSettle();

    // The shared PIN step, with the plan; nothing has moved yet.
    expect(find.byType(DpsOpenSheet), findsNothing);
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(routerOf(c).state.uri.path, PayPaths.pin(PayKind.dps));
    expect(find.text('মাসে ৳ ১,০০০ · ৫ বছর'), findsOneWidget);
    expect(
      (await tester.runAsync(
        () => c.read(financeRepoProvider).watch('rina').first,
      ))!.plans,
      hasLength(plansBefore),
    );

    // Back from the PIN pad returns to Savings, the plan not opened.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SavingsScreen), findsOneWidget);

    // Again, this time with the PIN.
    await tester.tap(find.byKey(const Key('savings_open_dps')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(DpsOpenSheet),
        matching: find.text('৳ ১,০০০'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(DpsOpenSheet),
        matching: find.text('৫ বছর'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dps_confirm')));
    await tester.pumpAndSettle();
    await tapDigits(tester, '1234');
    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);
    // The local allow keeps the verifying rhythm for 600 ms.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.byType(ResultScreen), findsOneWidget);
    expect(find.text('ডিপিএস খোলা হয়েছে'), findsOneWidget);
    expect(find.text('মাসে ৳ ১,০০০ · ৫ বছর'), findsOneWidget);

    final state = (await tester.runAsync(
      () => c.read(financeRepoProvider).watch('rina').first,
    ))!;
    expect(state.plans, hasLength(plansBefore + 1));
    expect(state.plans.first.monthlyBdt, 1000);
    expect(state.plans.first.tenureMonths, 60);
    expect(state.plans.first.instalmentsPaid, 1);

    final rows = (await tester.runAsync(
      () => ledger.watchRecent('rina').first,
    ))!;
    expect(rows.first.type, 'dps_deposit');
    expect(rows.first.amountBdt, 1000);
    expect(rows.first.toAcct, 'acct_bhorosha_dps');
    expect(rows.first.status, LedgerStatus.done);
    final after = await tester.runAsync(
      () => ledger.watchBalance('rina').first,
    );
    expect(after, before - 1000);
  });

  testWidgets('Rahima sees her ৳ ২০০ plan', (tester) async {
    await pumpFinance(
      tester,
      child: const SavingsScreen(),
      persona: Persona.rahima,
    );
    expect(_rolling(200), findsOneWidget);
    expect(find.text('৯/৬০ কিস্তি'), findsOneWidget);
    expect(find.text('৫ বছর'), findsOneWidget);
    expect(find.text('৳ ১৫,৯০০'), findsOneWidget);
    expect(find.byType(BhButton), findsOneWidget);
  });

  testWidgets('the demo-rate tag sits on the card\'s trailing padding line', (
    tester,
  ) async {
    await pumpFinance(tester, child: const SavingsScreen());
    final card = tester.getRect(find.byType(DpsPlanCard));
    final tag = tester.getRect(
      find.descendant(
        of: find.byType(DpsPlanCard),
        matching: find.text('ডেমো হার ৬.৫%'),
      ),
    );
    // Tag text ends 8 dp inside the tag, whose edge is the 16 dp line.
    expect(tag.right, lessThanOrEqualTo(card.right - 16));
    expect(tag.right, greaterThan(card.right - 40));
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpFinanceEverywhere(tester, () => const SavingsScreen());
  });

  testWidgets('every text is at least 16 sp', (tester) async {
    await pumpFinance(tester, child: const SavingsScreen());
    await tester.tap(find.byKey(const Key('savings_open_dps')));
    await tester.pumpAndSettle();
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      final size = rich.text.style?.fontSize;
      expect(
        size,
        anyOf(isNull, greaterThanOrEqualTo(16)),
        reason: '"${rich.text.toPlainText()}" is $size sp',
      );
    }
  });

  testWidgets('no plan yet: the empty state says what to do next', (
    tester,
  ) async {
    await pumpFinance(
      tester,
      child: const SavingsScreen(),
      overrides: [financeRepoProvider.overrideWithValue(_EmptyFinanceRepo())],
    );
    expect(find.byKey(const Key('savings_empty')), findsOneWidget);
    expect(find.text('এখনো কোনো ডিপিএস নেই'), findsOneWidget);
    expect(find.text('নিচের ‘নতুন ডিপিএস খুলুন’ চাপুন।'), findsOneWidget);
  });

  testWidgets('English tenure is a real plural: "1 year", "3 years"', (
    tester,
  ) async {
    await pumpFinance(
      tester,
      child: const SavingsScreen(),
      locale: const Locale('en'),
    );
    expect(find.text('3 years'), findsOneWidget);
    await tester.tap(find.byKey(SavingsScreen.openKey));
    await tester.pumpAndSettle();
    expect(find.text('1 year'), findsOneWidget);
    expect(find.text('5 years'), findsOneWidget);
    expect(find.text('1 years'), findsNothing);
    // The sheet's drag handle (SheetHandleReveal) is there.
    expect(find.byType(SheetHandleReveal), findsOneWidget);
  });
}

class _EmptyFinanceRepo implements FinanceRepo {
  @override
  Stream<FinanceState> watch(String uid) =>
      Stream.value(const FinanceState(plans: [], loanLimitBdt: 0));

  @override
  Future<DpsPlan> openDps(
    String uid, {
    required int monthlyBdt,
    required int tenureMonths,
  }) => throw UnimplementedError();

  @override
  Future<LoanApplication> applyLoan(String uid, LoanProduct product) =>
      throw UnimplementedError();

  @override
  Future<void> reset(String uid) async {}
}
