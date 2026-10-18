/// `LedgerRepo.expireCashIns` on the local ledger (the Home housekeeping
/// behind the cash-in code): the exact 15-minute boundary, rows that are
/// already final, a second run, and the 50-row scan window.
library;

import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../data/local/test_bundle.dart';

final _now = DateTime.utc(2026, 10, 17, 6);

LedgerTxn _cashIn(
  String id, {
  required DateTime ts,
  String status = LedgerStatus.requested,
}) => LedgerTxn(
  txnId: id,
  ts: ts,
  type: 'cash_in',
  amountBdt: 500,
  fromAcct: 'cashin_FN-4K7Q',
  toAcct: 'acct_rina',
  channel: 'agent',
  status: status,
  counterpartyNameBn: 'এজেন্ট ক্যাশ ইন',
);

void main() {
  late LocalLedgerRepo repo;
  setUp(
    () => repo = LocalLedgerRepo(
      DemoAssets(bundle: DiskAssetBundle()),
      now: () => _now,
    ),
  );
  tearDown(() => repo.dispose());

  Future<String> status(String id) async =>
      (await repo.watchRecent('rina', limit: 100).first)
          .firstWhere((t) => t.txnId == id)
          .status;

  test('exactly 15 minutes old expires; 14:59 does not', () async {
    await repo.create(
      'rina',
      _cashIn('at_ttl', ts: _now.subtract(const Duration(minutes: 15))),
    );
    await repo.create(
      'rina',
      _cashIn(
        'under_ttl',
        ts: _now.subtract(const Duration(minutes: 14, seconds: 59)),
      ),
    );
    expect(await repo.expireCashIns('rina', now: _now), 1);
    expect(await status('at_ttl'), LedgerStatus.cancelled);
    expect(await status('under_ttl'), LedgerStatus.requested);
  });

  test(
    'done and cancelled cash ins and other old rows are left alone',
    () async {
      final old = _now.subtract(const Duration(hours: 1));
      await repo.create(
        'rina',
        _cashIn('done', ts: old, status: LedgerStatus.done),
      );
      await repo.create(
        'rina',
        _cashIn('cancelled', ts: old, status: LedgerStatus.cancelled),
      );
      await repo.create(
        'rina',
        LedgerTxn(
          txnId: 'held_send',
          ts: old,
          type: 'send_money',
          amountBdt: 100,
          fromAcct: 'acct_rina',
          toAcct: 'acct_x',
          status: LedgerStatus.held,
        ),
      );
      expect(await repo.expireCashIns('rina', now: _now), 0);
      expect(await status('done'), LedgerStatus.done);
      expect(await status('cancelled'), LedgerStatus.cancelled);
      expect(await status('held_send'), LedgerStatus.held);
      // The seeded rows are untouched too.
      final rows = await repo.watchRecent('rina', limit: 100).first;
      expect(rows.where((t) => t.status == LedgerStatus.ok), hasLength(6));
    },
  );

  test('a second run is a no-op', () async {
    await repo.create(
      'rina',
      _cashIn('old', ts: _now.subtract(const Duration(minutes: 20))),
    );
    expect(await repo.expireCashIns('rina', now: _now), 1);
    expect(await repo.expireCashIns('rina', now: _now), 0);
    expect(await status('old'), LedgerStatus.cancelled);
  });

  test('a shorter ttl is honoured', () async {
    await repo.create(
      'rina',
      _cashIn('m5', ts: _now.subtract(const Duration(minutes: 5))),
    );
    expect(
      await repo.expireCashIns(
        'rina',
        now: _now,
        ttl: const Duration(minutes: 5),
      ),
      1,
    );
  });

  test('only the newest 50 rows are scanned (known limit): an old code behind 50 newer rows is not expired', () async {
    final old = _now.subtract(const Duration(hours: 2));
    await repo.create('rina', _cashIn('buried', ts: old));
    for (var i = 0; i < 50; i++) {
      await repo.create(
        'rina',
        LedgerTxn(
          txnId: 'fill_$i',
          ts: _now.subtract(Duration(minutes: 50 - i)),
          type: 'send_money',
          amountBdt: 10,
          fromAcct: 'acct_rina',
          toAcct: 'acct_x',
          status: LedgerStatus.done,
        ),
      );
    }
    expect(await repo.expireCashIns('rina', now: _now), 0);
    expect(await status('buried'), LedgerStatus.requested);
  });
}
