import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_bundle.dart';

LedgerTxn _send(
  String id,
  double amount, {
  String status = LedgerStatus.done,
}) => LedgerTxn(
  txnId: id,
  ts: DateTime.utc(2026, 10, 16, 12),
  type: 'send_money',
  amountBdt: amount,
  fromAcct: 'acct_rina',
  toAcct: 'acct_01999',
  status: status,
  counterpartyNameBn: 'নতুন নম্বর',
);

void main() {
  late LocalLedgerRepo repo;
  setUp(() => repo = LocalLedgerRepo(DemoAssets(bundle: DiskAssetBundle())));
  tearDown(() => repo.dispose());

  test('seeds six rows for Rina, newest first, and honours limit', () async {
    final rows = await repo.watchRecent('rina').first;
    expect(rows, hasLength(6));
    expect(rows.map((t) => t.txnId), [
      'txn_011989',
      'txn_011665',
      'txn_011308',
      'txn_011245',
      'txn_011093',
      'txn_010187',
    ]);
    expect(rows[3].counterpartyNameBn, 'রফিক ইসলাম');
    expect((await repo.watchRecent('rina', limit: 2).first), hasLength(2));
    expect(await repo.watchBalance('rina').first, 9841);
  });

  test('create prepends and a done debit lowers the balance', () async {
    await repo.create('rina', _send('txn_new', 5000));
    final rows = await repo.watchRecent('rina').first;
    expect(rows.first.txnId, 'txn_new');
    expect(rows, hasLength(7));
    expect(await repo.watchBalance('rina').first, 4841);
  });

  test('a held row does not move the balance until setStatus(done)', () async {
    final balances = <double>[];
    final sub = repo.watchBalance('rina').listen(balances.add);
    await pumpEventQueue();
    await repo.create(
      'rina',
      _send('txn_held', 1000, status: LedgerStatus.held),
    );
    await pumpEventQueue();
    expect(balances.last, 9841);

    final rowsSeen = <List<LedgerTxn>>[];
    final rowSub = repo.watchRecent('rina').listen(rowsSeen.add);
    await pumpEventQueue();
    await repo.setStatus('txn_held', LedgerStatus.done);
    await pumpEventQueue();
    expect(rowsSeen.last.first.status, LedgerStatus.done);
    expect(balances.last, 8841);

    await repo.setStatus('txn_held', LedgerStatus.cancelled);
    await pumpEventQueue();
    expect(balances.last, 9841);
    await sub.cancel();
    await rowSub.cancel();
  });

  test('seeded debits never count and credits never add', () async {
    // txn_011093 is a seeded salary credit; flipping it must not change anything.
    await repo.watchRecent('rina').first;
    await repo.setStatus('txn_011093', LedgerStatus.done);
    expect(await repo.watchBalance('rina').first, 9841);
  });

  test(
    'savedPayees comes from the seed once loaded; reset restores it',
    () async {
      expect(repo.savedPayees(Persona.rina), isEmpty);
      await repo.watchRecent('rina').first;
      expect(repo.savedPayees(Persona.rina).map((p) => p.acctId), [
        'acct_rahima',
        'acct_rafiq',
      ]);
      await repo.create('rina', _send('txn_x', 100));
      await repo.reset('rina');
      expect(await repo.watchRecent('rina').first, hasLength(6));
      expect(await repo.watchBalance('rina').first, 9841);
    },
  );

  test('seed dates are rebased: the newest row is two hours before now, '
      'gaps kept', () async {
    final now = DateTime.utc(2026, 10, 17, 6);
    final r = LocalLedgerRepo(
      DemoAssets(bundle: DiskAssetBundle()),
      now: () => now,
    );
    addTearDown(r.dispose);
    final rows = await r.watchRecent('rina').first;
    expect(rows.first.ts, now.subtract(const Duration(hours: 2)));
    // Seed: 2026-11-11T18:06:35 and 2026-11-10T22:18:07 (+06:00).
    expect(
      rows.first.ts.difference(rows[1].ts),
      const Duration(hours: 19, minutes: 48, seconds: 28),
    );
    expect(rows.every((t) => !t.ts.isAfter(now)), isTrue);
    // Rahima's seed is rebased to her own newest row.
    final rahima = await r.watchRecent('rahima').first;
    expect(rahima.first.ts, now.subtract(const Duration(hours: 2)));
    // Reset rebases again.
    await r.reset('rina');
    expect(
      (await r.watchRecent('rina').first).first.ts,
      now.subtract(const Duration(hours: 2)),
    );
  });

  test('seed dates follow the real clock by default', () async {
    final rows = await repo.watchRecent('rina').first;
    final age = DateTime.now().difference(rows.first.ts);
    expect(age, greaterThan(const Duration(hours: 1, minutes: 59)));
    expect(age, lessThan(const Duration(hours: 2, minutes: 1)));
  });

  group('cash in', () {
    LedgerTxn cashIn(String id, double amount, {DateTime? ts}) => LedgerTxn(
      txnId: id,
      ts: ts ?? DateTime.now(),
      type: 'cash_in',
      amountBdt: amount,
      fromAcct: 'cashin_BH-4K7Q',
      toAcct: 'acct_rina',
      channel: 'agent',
      status: LedgerStatus.requested,
      counterpartyNameBn: 'এজেন্ট ক্যাশ ইন',
    );

    test('a requested row never moves the balance; confirmCashIn credits '
        'it', () async {
      final balances = <double>[];
      final sub = repo.watchBalance('rina').listen(balances.add);
      await pumpEventQueue();
      await repo.create('rina', cashIn('txn_ci', 1000));
      await pumpEventQueue();
      expect(balances.last, 9841);
      expect((await repo.newestRequestedCashIn('rina'))?.txnId, 'txn_ci');

      await repo.confirmCashIn('txn_ci');
      await pumpEventQueue();
      expect(balances.last, 10841);
      final row = (await repo.watchRecent('rina').first).first;
      expect(row.status, LedgerStatus.done);
      expect(await repo.newestRequestedCashIn('rina'), isNull);

      // Confirming twice changes nothing.
      await repo.confirmCashIn('txn_ci');
      await pumpEventQueue();
      expect(balances.last, 10841);
      await sub.cancel();
    });

    test(
      'confirmCashIn ignores anything that is not a waiting cash in',
      () async {
        await repo.create(
          'rina',
          _send('txn_held', 1000, status: LedgerStatus.held),
        );
        await repo.confirmCashIn('txn_held');
        expect(
          (await repo.watchRecent('rina').first).first.status,
          LedgerStatus.held,
        );
        await repo.confirmCashIn('txn_nope');
        expect(await repo.watchBalance('rina').first, 9841);
      },
    );

    test('expireCashIns cancels codes older than 15 minutes', () async {
      final now = DateTime.now();
      await repo.create(
        'rina',
        cashIn('txn_old', 500, ts: now.subtract(const Duration(minutes: 16))),
      );
      await repo.create('rina', cashIn('txn_new', 700, ts: now));
      expect(await repo.expireCashIns('rina', now: now), 1);
      final rows = await repo.watchRecent('rina').first;
      expect(
        rows.firstWhere((t) => t.txnId == 'txn_old').status,
        LedgerStatus.cancelled,
      );
      expect(
        rows.firstWhere((t) => t.txnId == 'txn_new').status,
        LedgerStatus.requested,
      );
      expect(await repo.watchBalance('rina').first, 9841);
    });

    test('requested is a known status', () {
      expect(LedgerStatus.all, contains(LedgerStatus.requested));
    });
  });

  test('a done credit created in this session raises the balance', () async {
    await repo.create(
      'rina',
      LedgerTxn(
        txnId: 'txn_in',
        ts: DateTime.now(),
        type: 'send_money',
        amountBdt: 250,
        fromAcct: 'acct_rafiq',
        toAcct: 'acct_rina',
        status: LedgerStatus.done,
      ),
    );
    expect(await repo.watchBalance('rina').first, 10091);
  });

  test('personas are isolated', () async {
    await repo.create('rina', _send('txn_r', 500));
    expect(await repo.watchRecent('rahima').first, hasLength(6));
    expect(await repo.watchBalance('rahima').first, 3260);
  });
}
