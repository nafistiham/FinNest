import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/animated/rolling_amount.dart';
import 'package:bhorosha/app/widgets/bh_button.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/finance/logic/finance_models.dart';
import 'package:bhorosha/features/finance/logic/finance_providers.dart';
import 'package:bhorosha/features/finance/logic/finance_repo.dart';
import 'package:bhorosha/features/finance/ui/loans_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'finance_test_support.dart';

Finder _rolling(num value) =>
    find.byWidgetPredicate((w) => w is RollingAmount && w.amount == value);

void main() {
  testWidgets(
    'Rahima: limit hero, business loan not selectable with a reason',
    (tester) async {
      await pumpFinance(
        tester,
        child: const LoansScreen(),
        persona: Persona.rahima,
      );

      expect(find.text('ঋণ'), findsOneWidget);
      expect(find.text('আপনি পেতে পারেন'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('loan_eligibility')),
          matching: _rolling(5000),
        ),
        findsOneWidget,
      );
      // No salary: no income line.
      expect(find.textContaining('মাসিক আয়'), findsNothing);

      expect(find.byType(LoanProductCard), findsNWidgets(2));
      expect(find.text('জরুরি ঋণ'), findsOneWidget);
      expect(find.text('ব্যবসা ঋণ'), findsOneWidget);
      expect(find.text('৩ মাস · মাসিক কিস্তি ৳ ১,৭১৭'), findsOneWidget);
      expect(find.text('১২ মাস · মাসিক কিস্তি ৳ ১,৮০০'), findsOneWidget);
      expect(find.text('ডেমো ফি ৩%'), findsOneWidget);
      expect(find.text('ডেমো ফি ৮%'), findsOneWidget);
      expect(find.text('আপনার সীমার বেশি'), findsOneWidget);

      // The demo-fee tag sits on the row's trailing padding line.
      final row = tester.getRect(
        find.byKey(const Key('loan_product_loan_emergency')),
      );
      final tag = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('loan_product_loan_emergency')),
          matching: find.byType(StatusTag),
        ),
      );
      expect(tag.right, moreOrLessEquals(row.right - 16, epsilon: 1));
      // Demo fees are neutral facts: info, never the amber of a hold.
      for (final fee in ['ডেমো ফি ৩%', 'ডেমো ফি ৮%']) {
        expect(
          tester
              .widget<StatusTag>(
                find.ancestor(
                  of: find.text(fee),
                  matching: find.byType(StatusTag),
                ),
              )
              .status,
          BhStatus.info,
        );
      }

      // One primary action, in the bottom bar, for the first eligible row.
      final apply = find.byKey(LoansScreen.applyKey);
      expect(find.byType(BhButton), findsOneWidget);
      expect(tester.widget<BhButton>(apply).onPressed, isNotNull);
      expect(tester.getSize(apply).height, greaterThanOrEqualTo(BhSize.touch));
      expect(
        tester.getSemantics(
          find.byKey(const Key('loan_product_loan_emergency')),
        ),
        isSemantics(isSelected: true),
      );

      // The fixed product line below the products.
      await tester.scrollUntilVisible(
        find.byKey(const Key('loan_never_otp')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'ফিননেস্ট কখনো ঋণের জন্য ওটিপি (এসএমএসে আসা গোপন কোড) বা পিন চায় না',
        ),
        findsOneWidget,
      );
      expect(find.text('আপনার আবেদন'), findsNothing);
    },
  );

  testWidgets('Rahima applies for the micro loan: snackbar and pending tag', (
    tester,
  ) async {
    final c = await pumpFinance(
      tester,
      child: const LoansScreen(),
      persona: Persona.rahima,
    );

    // The over-limit row does not take the selection.
    await tester.tap(find.byKey(const Key('loan_product_loan_business')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LoansScreen.applyKey));
    await tester.pumpAndSettle();

    expect(find.text('আবেদন জমা হয়েছে'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(LoanApplicationRow),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('আপনার আবেদন'), findsOneWidget);
    expect(find.byType(LoanApplicationRow), findsOneWidget);
    expect(find.text('অনুমোদনের অপেক্ষায়'), findsOneWidget);

    final state = c.read(financeStateProvider).requireValue;
    expect(state.applications.single.productId, 'loan_emergency');
    expect(state.applications.single.status, LoanStatus.pending);
    expect(c.read(financeControllerProvider).busy, isFalse);
  });

  testWidgets('Rina: limit ৳ ২০,০০০ with the income line; picks business', (
    tester,
  ) async {
    final c = await pumpFinance(tester, child: const LoansScreen());

    expect(_rolling(20000), findsOneWidget);
    expect(find.text('মাসিক আয় ৳ ১৩,৫০০ অনুসারে'), findsOneWidget);
    expect(find.text('আপনার সীমার বেশি'), findsNothing);

    await tester.tap(find.byKey(const Key('loan_product_loan_business')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(const Key('loan_product_loan_business'))),
      isSemantics(isSelected: true),
    );
    await tester.tap(find.byKey(LoansScreen.applyKey));
    await tester.pumpAndSettle();
    final state = c.read(financeStateProvider).requireValue;
    expect(state.applications.single.productId, 'loan_business');
  });

  testWidgets('every text is at least 16 sp', (tester) async {
    await pumpFinance(
      tester,
      child: const LoansScreen(),
      persona: Persona.rahima,
    );
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      final size = rich.text.style?.fontSize;
      expect(
        size,
        anyOf(isNull, greaterThanOrEqualTo(16)),
        reason: '"${rich.text.toPlainText()}" is $size sp',
      );
    }
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpFinanceEverywhere(tester, () => const LoansScreen());
  });

  testWidgets('a failed load says what to do next and retries; loading is '
      'skeleton rows, not a spinner', (tester) async {
    final repo = _ScriptedFinanceRepo();
    await pumpFinance(
      tester,
      child: const LoansScreen(),
      overrides: [financeRepoProvider.overrideWithValue(repo)],
    );
    expect(find.byKey(const Key('finance_failed')), findsOneWidget);
    expect(
      find.text('ইন্টারনেট চালু আছে কি না দেখে আবার চেষ্টা করুন।'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    repo.fail = false;
    repo.hang = true;
    await tester.tap(find.text('আবার চেষ্টা করুন'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('finance_loading')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('finance_loading')))
          .properties
          .label,
      isNotEmpty,
    );
  });

  testWidgets('English tenure reads "3 months", never "1 months"', (
    tester,
  ) async {
    await pumpFinance(
      tester,
      child: const LoansScreen(),
      persona: Persona.rahima,
      locale: const Locale('en'),
    );
    expect(find.textContaining('3 months · '), findsOneWidget);
    expect(find.textContaining('12 months · '), findsOneWidget);
    expect(find.textContaining('months months'), findsNothing);
  });
}

/// A finance store the tests steer: [fail] emits an error, [hang] never
/// emits, otherwise the Rina seed.
class _ScriptedFinanceRepo implements FinanceRepo {
  bool fail = true;
  bool hang = false;

  @override
  Stream<FinanceState> watch(String uid) {
    if (fail) return Stream.error(StateError('offline'));
    if (hang) return const Stream.empty();
    return Stream.value(FinanceSeeds.forUid(uid));
  }

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
