import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

InterventionRecord _rec(String id, String uid, DateTime at) =>
    InterventionRecord(
      id: id,
      uid: uid,
      txnId: 'txn_$id',
      trigger: 'call_active',
      scriptBn: 'স্ক্রিপ্ট',
      reasons: const [],
      actions: const [],
      status: InterventionStatus.open,
      createdAt: at,
    );

void main() {
  test(
    'emits current list, newest first, per uid; finds by request id',
    () async {
      final repo = LocalInterventionRepo();
      final seen = <List<InterventionRecord>>[];
      final sub = repo.watch('rina').listen(seen.add);
      await pumpEventQueue();
      expect(seen.single, isEmpty);

      await repo.upsert(_rec('a', 'rina', DateTime.utc(2026, 1, 1)));
      await repo.upsert(_rec('b', 'rina', DateTime.utc(2026, 1, 2)));
      await repo.upsert(_rec('c', 'rahima', DateTime.utc(2026, 1, 3)));
      await pumpEventQueue();
      expect(seen.last.map((r) => r.id), ['b', 'a']);

      final pending = seen.last.first.copyWith(
        status: InterventionStatus.pending,
        requestId: 'req_1',
      );
      await repo.upsert(pending);
      expect(await repo.findByRequestId('req_1'), pending);
      expect(await repo.findByRequestId('nope'), isNull);

      await repo.reset('rina');
      await pumpEventQueue();
      expect(seen.last, isEmpty);
      expect(await repo.watch('rahima').first, hasLength(1));
      await sub.cancel();
      await repo.dispose();
    },
  );

  test('upsert merges fields: a stale copy keeps request_id and contact_uid '
      '; byId reads the stored record', () async {
    final repo = LocalInterventionRepo();
    final opened = _rec('a', 'rina', DateTime.utc(2026, 1, 1));
    await repo.upsert(opened);
    await repo.upsert(
      opened.copyWith(
        status: InterventionStatus.pending,
        requestId: 'req_1',
        contactUid: 'rahima',
        expiresAt: DateTime.utc(2026, 1, 1, 0, 10),
      ),
    );
    // A writer holding the copy from before the request.
    await repo.upsert(opened.copyWith(scriptBn: 'নতুন'));
    final stored = await repo.byId('a');
    expect(stored?.scriptBn, 'নতুন');
    expect(stored?.requestId, 'req_1');
    expect(stored?.contactUid, 'rahima');
    expect(stored?.expiresAt, DateTime.utc(2026, 1, 1, 0, 10));
    expect(stored?.status, InterventionStatus.open, reason: 'set fields win');
    expect(await repo.findByRequestId('req_1'), isNotNull);
    expect(await repo.byId('nope'), isNull);
    await repo.dispose();
  });
}
