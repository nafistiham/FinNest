import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 17, 8);
  final a = CaseLink(caseId: 'CZ-1', acctId: 'acct_01070', openedAt: t0);
  final b = CaseLink(
    caseId: 'CZ-2',
    acctId: 'acct_00036',
    openedAt: t0.add(const Duration(minutes: 5)),
    lastStatus: CaseStatus.done,
    lastAction: 'monitor',
    modelVersion: 'stub-fallback',
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('json round trip', () {
    for (final l in [a, b]) {
      expect(CaseLink.fromJson(l.toJson()), l);
    }
    expect(b.isStubFallback, isTrue);
    expect(a.isOpen, isTrue);
    expect(b.isOpen, isFalse);
  });

  test('an unknown status reads as unknown', () {
    final json = a.toJson()..['last_status'] = 'paused';
    expect(CaseLink.fromJson(json).lastStatus, CaseStatus.unknown);
  });

  test(
    'upsert, newest first, replace by case id, persisted per persona',
    () async {
      final repo = CaseLinkRepo();
      await repo.upsert('rina', a);
      await repo.upsert('rina', b);
      expect(await repo.all('rina'), [b, a]);
      expect(await repo.all('rahima'), isEmpty);

      final updated = a.withStatus(CaseStatus.failed);
      await repo.upsert('rina', updated);
      expect(await repo.all('rina'), [b, updated]);
      expect(
        (await repo.latestFor('rina', 'acct_01070'))!.lastStatus,
        CaseStatus.failed,
      );
      expect(await repo.latestFor('rina', 'acct_x'), isNull);

      // A fresh repo reads the same list back from SharedPreferences.
      final again = CaseLinkRepo();
      expect(await again.all('rina'), [b, updated]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(CaseLinkRepo.keyFor('rina'))!),
        hasLength(2),
      );
      await repo.dispose();
      await again.dispose();
    },
  );

  test('withReport takes status, action and model version', () {
    const report = CaseReport(
      caseId: 'CZ-1',
      acctId: 'acct_01070',
      status: CaseStatus.done,
      summaryEn: '',
      summaryBn: '',
      evidence: [],
      ring: [],
      confidence: 0.5,
      recommendedAction: 'edd',
      modelVersion: 'm1',
    );
    final l = a.withReport(report);
    expect(l.lastStatus, CaseStatus.done);
    expect(l.lastAction, 'edd');
    expect(l.modelVersion, 'm1');
    expect(l.openedAt, t0);
  });

  test('watch replays the current list, then every change; clear', () async {
    final repo = CaseLinkRepo();
    await repo.upsert('rina', a);
    final seen = <List<CaseLink>>[];
    final sub = repo.watch('rina').listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    await repo.upsert('rina', b);
    await repo.clear('rina');
    await Future<void>.delayed(Duration.zero);
    expect(seen, [
      [a],
      [b, a],
      <CaseLink>[],
    ]);
    await sub.cancel();
    await repo.dispose();
  });

  test('unreadable stored data is ignored', () async {
    SharedPreferences.setMockInitialValues({
      CaseLinkRepo.keyFor('rina'): 'not json',
    });
    expect(await CaseLinkRepo().all('rina'), isEmpty);
  });

  test('adopted is persisted and survives withReport/withStatus', () {
    final adopted = CaseLink(
      caseId: 'CZ-9',
      acctId: 'acct_01070',
      openedAt: t0,
      adopted: true,
    );
    final back = CaseLink.fromJson(
      jsonDecode(jsonEncode(adopted.toJson())) as Map<String, dynamic>,
    );
    expect(back, adopted);
    expect(back.adopted, isTrue);
    expect(back.withStatus(CaseStatus.failed).adopted, isTrue);
    expect(a.toJson().containsKey('adopted'), isFalse, reason: 'old shape');
    expect(CaseLink.fromJson(a.toJson()).adopted, isFalse);
  });

  test('concurrent upserts of one persona keep every link', () async {
    final repo = CaseLinkRepo();
    await Future.wait([
      for (var i = 0; i < 5; i++)
        repo.upsert(
          'rina',
          CaseLink(
            caseId: 'CZ-$i',
            acctId: 'acct_$i',
            openedAt: t0.add(Duration(minutes: i)),
          ),
        ),
    ]);
    expect((await repo.all('rina')).map((l) => l.caseId).toSet(), {
      'CZ-0',
      'CZ-1',
      'CZ-2',
      'CZ-3',
      'CZ-4',
    });
    final fresh = CaseLinkRepo();
    expect(await fresh.all('rina'), hasLength(5), reason: 'persisted');
    await repo.dispose();
    await fresh.dispose();
  });
}
