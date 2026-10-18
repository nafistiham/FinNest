import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/finance/logic/finance_models.dart';
import 'package:bhorosha/features/finance/logic/finance_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/test_bundle.dart';

void main() {
  late LocalLedgerRepo ledger;
  late LocalFinanceRepo repo;
  late FakeClock clock;

  LocalFinanceRepo build() => LocalFinanceRepo(ledger: ledger, clock: clock);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ledger = LocalLedgerRepo(DemoAssets(bundle: DiskAssetBundle()));
    clock = FakeClock(DateTime.utc(2026, 10, 16, 10));
    repo = build();
  });
  tearDown(() async {
    await repo.dispose();
    await ledger.dispose();
  });

  test('seeds Rina: one DPS, limit 20000, income 13500', () async {
    final s = await repo.watch('rina').first;
    expect(s.plans, hasLength(1));
    final plan = s.plans.single;
    expect(plan.monthlyBdt, 500);
    expect(plan.tenureMonths, 36);
    expect(plan.instalmentsPaid, 14);
    expect(plan.startedAt, DateTime.utc(2025, 8, 10));
    expect(plan.demoRatePct, 6.5);
    expect(s.loanLimitBdt, 20000);
    expect(s.monthlyIncomeBdt, 13500);
    expect(s.applications, isEmpty);
  });

  test(
    'seeds Rahima: ৳ 200 x 60, 9 paid, micro-limit 5000, no income',
    () async {
      final s = await repo.watch('rahima').first;
      expect(s.plans.single.monthlyBdt, 200);
      expect(s.plans.single.tenureMonths, 60);
      expect(s.plans.single.instalmentsPaid, 9);
      expect(s.loanLimitBdt, 5000);
      expect(s.monthlyIncomeBdt, 0);
    },
  );

  test('unknown uid gets the empty state', () async {
    expect(await repo.watch('nobody').first, FinanceState.empty);
  });

  test(
    'openDps prepends a plan with one instalment and debits the ledger',
    () async {
      final seen = <FinanceState>[];
      final sub = repo.watch('rina').listen(seen.add);
      await pumpEventQueue();

      final plan = await repo.openDps(
        'rina',
        monthlyBdt: 1000,
        tenureMonths: 36,
      );
      await pumpEventQueue();

      expect(plan.instalmentsPaid, 1);
      expect(plan.monthlyBdt, 1000);
      expect(plan.tenureMonths, 36);
      expect(plan.startedAt, clock.now());
      expect(seen.last.plans, hasLength(2));
      expect(seen.last.plans.first, plan);
      expect(seen.last.plans.last.id, 'dps_rina_01');

      final rows = await ledger.watchRecent('rina').first;
      final txn = rows.first;
      expect(txn.type, 'dps_deposit');
      expect(txn.amountBdt, 1000);
      expect(txn.fromAcct, 'acct_rina');
      expect(txn.toAcct, 'acct_bhorosha_dps');
      expect(txn.channel, 'app');
      expect(txn.status, LedgerStatus.done);
      expect(txn.counterpartyNameBn, 'ডিপিএস জমা');
      expect(txn.ts, clock.now());
      expect(await ledger.watchBalance('rina').first, 9841 - 1000);
      await sub.cancel();
    },
  );

  test('openDps rejects a non-positive amount or tenure', () async {
    expect(
      () => repo.openDps('rina', monthlyBdt: 0, tenureMonths: 12),
      throwsArgumentError,
    );
    expect(
      () => repo.openDps('rina', monthlyBdt: 500, tenureMonths: 0),
      throwsArgumentError,
    );
  });

  test('state survives a new repo instance (SharedPreferences)', () async {
    await repo.openDps('rina', monthlyBdt: 2000, tenureMonths: 12);
    await repo.applyLoan('rina', LoanProducts.emergency);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('finance/rina'), isNotNull);

    final again = build();
    addTearDown(again.dispose);
    final s = await again.watch('rina').first;
    expect(s.plans, hasLength(2));
    expect(s.plans.first.monthlyBdt, 2000);
    expect(s.applications.single.status, LoanStatus.pending);
    expect(s.loanLimitBdt, 20000);
  });

  test('applyLoan: pending within the limit, rejected above it', () async {
    final ok = await repo.applyLoan('rahima', LoanProducts.emergency);
    expect(ok.status, LoanStatus.pending);
    expect(ok.productId, 'loan_emergency');
    expect(ok.amountBdt, 5000);
    expect(ok.appliedAt, clock.now());

    final no = await repo.applyLoan('rahima', LoanProducts.business);
    expect(no.status, LoanStatus.rejected);

    final s = await repo.watch('rahima').first;
    expect(s.applications.map((a) => a.id), [no.id, ok.id]);

    // Rina's limit covers the business loan.
    final rina = await repo.applyLoan('rina', LoanProducts.business);
    expect(rina.status, LoanStatus.pending);
  });

  test('reset restores the seed and clears the stored key', () async {
    final seen = <FinanceState>[];
    final sub = repo.watch('rina').listen(seen.add);
    await pumpEventQueue();
    await repo.openDps('rina', monthlyBdt: 500, tenureMonths: 12);
    await repo.applyLoan('rina', LoanProducts.emergency);
    await pumpEventQueue();
    expect(seen.last.plans, hasLength(2));

    await repo.reset('rina');
    await pumpEventQueue();
    expect(seen.last, FinanceSeeds.forUid('rina'));
    expect(seen.last.plans.single.id, 'dps_rina_01');
    expect(seen.last.applications, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('finance/rina'), isNull);
    expect(await repo.watch('rina').first, FinanceSeeds.forUid('rina'));
    await sub.cancel();
  });

  test('personas are isolated', () async {
    await repo.openDps('rina', monthlyBdt: 500, tenureMonths: 12);
    final rahima = await repo.watch('rahima').first;
    expect(rahima.plans, hasLength(1));
    expect(await ledger.watchBalance('rahima').first, 3260);
  });
}
