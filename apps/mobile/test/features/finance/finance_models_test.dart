import 'package:bhorosha/features/finance/logic/finance_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DpsPlan', () {
    final rina = DpsPlan(
      id: 'dps_rina_01',
      monthlyBdt: 500,
      tenureMonths: 36,
      instalmentsPaid: 14,
      startedAt: DateTime.utc(2025, 8, 10),
    );

    test('paid, principal and simple-interest maturity at 6.5% p.a.', () {
      expect(rina.demoRatePct, 6.5);
      expect(rina.paidBdt, 7000);
      expect(rina.principalBdt, 18000);
      // 18000 * (1 + 0.065 * 3) = 21510
      expect(rina.maturityBdt, 21510);
      expect(rina.progress, closeTo(14 / 36, 1e-9));
      expect(rina.matured, isFalse);
    });

    test('Rahima: ৳ 200 x 60 at 6.5% matures at 15900', () {
      final p = DpsPlan(
        id: 'x',
        monthlyBdt: 200,
        tenureMonths: 60,
        instalmentsPaid: 9,
        startedAt: DateTime.utc(2026, 1, 10),
      );
      expect(p.paidBdt, 1800);
      expect(p.maturityBdt, 15900);
      expect(p.progress, closeTo(0.15, 1e-9));
    });

    test('maturity rounds; progress clamps; one-year plan', () {
      final p = DpsPlan(
        id: 'x',
        monthlyBdt: 1000,
        tenureMonths: 12,
        instalmentsPaid: 15,
        startedAt: DateTime.utc(2025),
        demoRatePct: 7.25,
      );
      // 12000 * 1.0725 = 12870
      expect(p.maturityBdt, 12870);
      expect(p.progress, 1.0);
      expect(p.matured, isTrue);
      expect(
        DpsPlan(
          id: 'z',
          monthlyBdt: 1,
          tenureMonths: 0,
          instalmentsPaid: 0,
          startedAt: DateTime.utc(2025),
        ).progress,
        0,
      );
    });

    test('JSON round trip keeps every field', () {
      final back = DpsPlan.fromJson(rina.toJson());
      expect(back, rina);
      expect(rina.toJson()['monthly_bdt'], 500);
      expect(rina.toJson()['started_at'], '2025-08-10T00:00:00.000Z');
    });
  });

  group('LoanProduct', () {
    test('emergency: 5000 / 3 months / 3% flat', () {
      const p = LoanProducts.emergency;
      expect(p.nameBn, 'জরুরি ঋণ');
      expect(p.feeBdt, 150);
      expect(p.totalRepayableBdt, 5150);
      // 5150 / 3 = 1716.67, rounded up.
      expect(p.monthlyBdt, 1717);
    });

    test('business: 20000 / 12 months / 8% flat', () {
      const p = LoanProducts.business;
      expect(p.nameBn, 'ব্যবসা ঋণ');
      expect(p.totalRepayableBdt, 21600);
      expect(p.monthlyBdt, 1800);
    });

    test('catalogue has the two products, findable by id', () {
      expect(LoanProducts.all, hasLength(2));
      expect(LoanProducts.byId('loan_business'), LoanProducts.business);
      expect(LoanProducts.byId('nope'), isNull);
    });
  });

  group('FinanceState', () {
    test('canBorrow compares the product amount with the limit', () {
      const s = FinanceState(loanLimitBdt: 5000);
      expect(s.canBorrow(LoanProducts.emergency), isTrue);
      expect(s.canBorrow(LoanProducts.business), isFalse);
    });

    test('JSON round trip', () {
      final s = FinanceState(
        plans: [
          DpsPlan(
            id: 'p',
            monthlyBdt: 500,
            tenureMonths: 36,
            instalmentsPaid: 1,
            startedAt: DateTime.utc(2026, 10, 16),
          ),
        ],
        applications: [
          LoanApplication(
            id: 'a',
            productId: 'loan_emergency',
            amountBdt: 5000,
            status: LoanStatus.pending,
            appliedAt: DateTime.utc(2026, 10, 16, 9),
          ),
        ],
        loanLimitBdt: 20000,
        monthlyIncomeBdt: 13500,
      );
      final back = FinanceState.fromJson(s.toJson());
      expect(back, s);
      expect(back.applications.single.product, LoanProducts.emergency);
    });

    test('empty state has nothing and no limit', () {
      expect(FinanceState.empty.plans, isEmpty);
      expect(FinanceState.empty.applications, isEmpty);
      expect(FinanceState.empty.loanLimitBdt, 0);
    });
  });
}
