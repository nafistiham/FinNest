/// The seeded history must read as "today / yesterday / N days ago" on any
/// demo date: the owner's phone showed rows dated "১১ নভে." on 17 October.
/// The bundled seed carries fixed November timestamps, so the local ledger
/// rebases them to the clock; nothing may land after "now" and the newest
/// row must be within two days of it. The same rows feed the payee
/// "শেষ …" labels on Send money.
library;

import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/pay_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../data/local/test_bundle.dart';

void main() {
  for (final persona in Persona.values) {
    for (final now in [
      DateTime.now(),
      DateTime.utc(2026, 10, 17, 3, 45),
      DateTime.utc(2027, 3, 1, 12),
    ]) {
      test(
        '${persona.uid}: no seed row is after now ($now); the newest is '
        'within two days; every payee last-used date is in the past',
        () async {
          final repo = LocalLedgerRepo(
            DemoAssets(bundle: DiskAssetBundle()),
            now: () => now,
          );
          addTearDown(repo.dispose);
          final rows = await repo.watchRecent(persona.uid, limit: 500).first;
          expect(rows, isNotEmpty);
          for (final t in rows) {
            expect(
              t.ts.isAfter(now),
              isFalse,
              reason: '${t.txnId} ${t.ts} is after $now',
            );
          }
          final newest = rows
              .map((t) => t.ts)
              .reduce((a, b) => a.isAfter(b) ? a : b);
          expect(
            now.difference(newest),
            lessThanOrEqualTo(const Duration(days: 2)),
          );
          for (final p in repo.savedPayees(persona)) {
            final last = lastPaidTo(rows, p.acctId);
            if (last != null) expect(last.isAfter(now), isFalse);
          }
        },
      );
    }
  }

  test('the bundled seed itself is still dated in the future: the rebase is '
      'what makes it relative', () async {
    final seed = await DemoAssets(bundle: DiskAssetBundle())
        .persona(Persona.rina);
    final fixed = DateTime.utc(2026, 10, 17, 6);
    expect(seed.transactions.any((t) => t.ts.isAfter(fixed)), isTrue);
    final rebased = LocalLedgerRepo.rebase(seed.transactions, fixed);
    expect(rebased.every((t) => !t.ts.isAfter(fixed)), isTrue);
    // Gaps between rows are kept, so "yesterday" rows stay yesterday.
    final a = seed.transactions[0].ts.difference(seed.transactions[1].ts);
    final b = rebased[0].ts.difference(rebased[1].ts);
    expect(a, b);
  });
}
