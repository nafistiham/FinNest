import 'package:bhorosha/data/firebase/firestore_ledger_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

LedgerTxn _row(String id, DateTime ts) => LedgerTxn(
  txnId: id,
  ts: ts,
  type: 'cash_in',
  amountBdt: 100,
  fromAcct: 'a',
  toAcct: 'b',
  status: LedgerStatus.done,
);

void main() {
  test('seed rows read from Firestore are rebased like the local ledger; '
      'session rows keep their time; newest first', () {
    final now = DateTime(2026, 10, 17, 3);
    final seed = [
      _row('s1', DateTime(2026, 11, 11, 9)),
      _row('s2', DateTime(2026, 11, 10, 8)),
    ];
    final rebased = LocalLedgerRepo.rebase(seed, now);
    final seedTimes = {for (final t in rebased) t.txnId: t.ts};
    final created = _row('c1', now.subtract(const Duration(minutes: 5)));

    final rows = FirestoreLedgerRepo.withSeedTimes(
      [seed[0], seed[1], created],
      seedTimes,
      now: now,
    );

    expect(rows.map((t) => t.txnId), ['c1', 's1', 's2']);
    expect(rows[1].ts, now.subtract(LocalLedgerRepo.seedLead));
    expect(rows[2].ts, rows[1].ts.subtract(const Duration(hours: 25)));
    expect(rows.every((t) => !t.ts.isAfter(now)), isTrue);
    expect(rows[0].ts, created.ts);
  });

  test('a row dated more than 24 h after now is dropped; one within 24 h '
      'stays', () {
    final now = DateTime(2026, 10, 17, 3);
    final stray = _row('stray', DateTime(2026, 10, 22, 9));
    final skewed = _row('skew', now.add(const Duration(hours: 23)));
    final today = _row('today', now.subtract(const Duration(hours: 1)));

    final rows = FirestoreLedgerRepo.withSeedTimes(
      [stray, today, skewed],
      const {},
      now: now,
    );

    expect(rows.map((t) => t.txnId), ['skew', 'today']);
  });

  test('a seed row is judged on its rebased time, not the stored one', () {
    final now = DateTime(2026, 10, 17, 3);
    // Stored in November (far future); rebased to just before now.
    final seed = _row('s1', DateTime(2026, 11, 11, 9));
    final rows = FirestoreLedgerRepo.withSeedTimes(
      [seed],
      {'s1': now.subtract(LocalLedgerRepo.seedLead)},
      now: now,
    );
    expect(rows.single.txnId, 's1');
  });
}
