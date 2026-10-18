import 'dart:io';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/firebase/firestore_intervention_repo.dart';
import 'package:bhorosha/data/firebase/firestore_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

final at = DateTime.utc(2026, 10, 17, 9, 30);

final stepUp = StepUpRecord(
  method: StepUpRecord.biometric,
  at: at,
  decisionId: 'int_1',
  serverDecision: 'hold',
  reasonCodes: const ['ATO_BEHAVIOUR_MISMATCH'],
);

void main() {
  group('FirestoreLedgerRepo documents', () {
    final old = <String, dynamic>{
      'ts': Timestamp.fromDate(at),
      'type': 'send_money',
      'amount_bdt': 500.0,
      'from_acct': 'acct_rina',
      'to_acct': 'acct_rafiq',
      'channel': 'app',
      'status': 'held',
      'uid': 'rina',
    };

    test('an old document (Timestamp ts) still reads', () {
      final t = FirestoreLedgerRepo.fromData('txn_9', old);
      expect(t.txnId, 'txn_9');
      expect(t.ts.isAtSameMomentAs(at), isTrue);
      expect(t.stepUp, isNull);
      expect(t.simulated, isFalse);
      expect(t.warningShown, isNull);
    });

    test('a new row round-trips through the stored shape', () {
      final t = FirestoreLedgerRepo.fromData('txn_9', old).copyWith(
        status: LedgerStatus.releasedByStepUp,
        stepUp: stepUp,
        warningShown: 'unfamiliar_payee',
        warningChoice: 'continued',
        simulated: true,
      );
      final doc = FirestoreLedgerRepo.toData('rina', t);
      expect(doc['ts'], isA<Timestamp>());
      expect(doc['uid'], 'rina');
      expect(doc['status'], 'released_by_step_up');
      expect((doc['step_up']! as Map)['decision_id'], 'int_1');
      final back = FirestoreLedgerRepo.fromData('txn_9', doc);
      expect(back.stepUp, stepUp);
      expect(back.warningChoice, 'continued');
      expect(back.simulated, isTrue);
      expect(back.status, t.status);
    });
  });

  group('FirestoreInterventionRepo documents', () {
    test('old and new documents round-trip with Timestamps', () {
      final created = DateTime.utc(2026, 10, 17, 9);
      final r = InterventionRecord(
        id: 'int_1',
        uid: 'rina',
        txnId: 'txn_1',
        trigger: 'behaviour_mismatch',
        scriptBn: '',
        reasons: const [],
        actions: const [],
        status: InterventionStatus.open,
        createdAt: created,
      );
      final oldDoc = FirestoreInterventionRepo.toData(r);
      expect(oldDoc['created_at'], isA<Timestamp>());
      expect(oldDoc.containsKey('step_up'), isFalse);
      final oldBack = FirestoreInterventionRepo.fromData('int_1', oldDoc);
      expect(oldBack.stepUp, isNull);
      expect(oldBack.createdAt.isAtSameMomentAs(created), isTrue);

      final released = r.copyWith(
        status: InterventionStatus.releasedByStepUp,
        stepUp: stepUp,
        simulated: true,
        signalSources: const SignalSources(callActive: SignalSource.none),
      );
      final back = FirestoreInterventionRepo.fromData(
        'int_1',
        FirestoreInterventionRepo.toData(released),
      );
      expect(back.status, 'released_by_step_up');
      expect(back.stepUp, stepUp);
      expect(back.simulated, isTrue);
      expect(back.signalSources, const SignalSources());
    });

    test('upsert merges: the null fields are left out, so a stale copy '
        'never erases request_id or contact_uid', () {
      final r = InterventionRecord(
        id: 'int_1',
        uid: 'rina',
        txnId: 'txn_1',
        trigger: 'behaviour_mismatch',
        scriptBn: 'স্ক্রিপ্ট',
        reasons: const [],
        actions: const [],
        status: InterventionStatus.releasedByStepUp,
        createdAt: DateTime.utc(2026, 10, 17, 9),
        stepUp: stepUp,
      );
      final doc = FirestoreInterventionRepo.mergeData(r);
      expect(doc.containsKey('request_id'), isFalse);
      expect(doc.containsKey('contact_uid'), isFalse);
      expect(doc.containsKey('expires_at'), isFalse);
      expect(doc.containsKey('audio_asset_id'), isFalse);
      expect(doc.values, isNot(contains(null)));
      expect(doc['status'], 'released_by_step_up');
      expect(doc['created_at'], isA<Timestamp>());
    });
  });

  group('review fixes: server id and owner stamp', () {
    InterventionRecord record({String? serverId}) => InterventionRecord(
      id: 'int_1',
      uid: 'rina',
      txnId: 'txn_1',
      trigger: 'behaviour_mismatch',
      scriptBn: '',
      reasons: const [],
      actions: const [],
      status: InterventionStatus.open,
      createdAt: at,
      serverInterventionId: serverId,
    );

    test('server_intervention_id round-trips; an old document '
        'without it still loads', () {
      final r = record(serverId: 'iv-0123');
      final doc = FirestoreInterventionRepo.toData(r);
      expect(doc['server_intervention_id'], 'iv-0123');
      final back = FirestoreInterventionRepo.fromData('int_1', doc);
      expect(back.serverInterventionId, 'iv-0123');
      expect(back.idForServer, 'iv-0123');

      final old = FirestoreInterventionRepo.toData(record())
        ..remove('server_intervention_id');
      final legacy = FirestoreInterventionRepo.fromData('int_1', old);
      expect(legacy.serverInterventionId, isNull);
      expect(legacy.idForServer, 'int_1');
      expect(
        FirestoreInterventionRepo.toData(record())
            .containsKey('server_intervention_id'),
        isFalse,
        reason: 'written only when known',
      );
    });

    test('a merge keeps a stored server id the copy lacks', () {
      final stored = record(serverId: 'iv-0123');
      final merged = record().mergedOnto(stored);
      expect(merged.serverInterventionId, 'iv-0123');
    });

    test('writes carry the owner stamp the rules check', () {
      final doc = FirestoreInterventionRepo.mergeData(
        record(),
        ownerAuthUid: 'anon-1',
      );
      expect(doc[FirestoreInterventionRepo.ownerAuthKey], 'anon-1');
      expect(
        FirestoreInterventionRepo.mergeData(record())
            .containsKey(FirestoreInterventionRepo.ownerAuthKey),
        isFalse,
      );
      final row = FirestoreLedgerRepo.fromData('txn_9', const {
        'ts': '2026-10-17T09:30:00.000Z',
        'type': 'send_money',
        'amount_bdt': 500.0,
        'from_acct': 'acct_rina',
        'to_acct': 'acct_rafiq',
        'channel': 'app',
        'status': 'held',
      });
      final data = FirestoreLedgerRepo.toData(
        'rina',
        row,
        ownerAuthUid: 'anon-1',
      );
      expect(data[FirestoreLedgerRepo.ownerAuthKey], 'anon-1');
      // A stamped document still reads as the same row.
      expect(FirestoreLedgerRepo.fromData('txn_9', data).status, 'held');
    });

    test('firestore.rules let only the owner change a status', () {
      final rules = File('firebase/firestore.rules').readAsStringSync();
      for (final col in ['transactions', 'interventions']) {
        final block = RegExp('match /$col/\\{[^}]+\\} \\{([^}]*)\\}')
            .firstMatch(rules)!
            .group(1)!;
        expect(
          block,
          contains('allow create: if signedIn() && stampedByCaller()'),
        );
        expect(
          block,
          contains(
            'allow update: if signedIn() && ownerKept() && statusChangeAllowed()',
          ),
        );
        expect(block, contains('allow delete: if false'));
      }
      expect(rules, contains("data.get('owner_auth_uid', null)"));
      expect(rules, contains('ownerOf(resource.data) == request.auth.uid'));
    });
  });
}
