import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

import '../local/test_bundle.dart';

Map<String, dynamic> wire(Map<String, dynamic> j) =>
    jsonDecode(jsonEncode(j)) as Map<String, dynamic>;

final stepUp = StepUpRecord(
  method: StepUpRecord.biometric,
  at: DateTime.utc(2026, 10, 17, 9, 30),
  decisionId: 'int_1',
  serverDecision: 'hold',
  reasonCodes: const ['ATO_BEHAVIOUR_MISMATCH'],
);

final caseLink = CaseLink(
  caseId: 'CZ-0002',
  acctId: 'acct_01070',
  openedAt: DateTime.utc(2026, 10, 17, 9),
);

/// A `transactions/{id}` document as written before the hold-record fields.
Map<String, dynamic> oldLedgerDoc() => <String, dynamic>{
  'txn_id': 'txn_old',
  'ts': '2026-10-16T12:00:00.000Z',
  'type': 'send_money',
  'amount_bdt': 500.0,
  'from_acct': 'acct_rina',
  'to_acct': 'acct_rafiq',
  'channel': 'app',
  'status': 'held',
  'counterparty_name_bn': 'রফিক ইসলাম',
  'intervention_id': 'int_1',
};

LedgerTxn send(String id, double amount, {String status = 'done'}) => LedgerTxn(
  txnId: id,
  ts: DateTime.utc(2026, 10, 16, 12),
  type: 'send_money',
  amountBdt: amount,
  fromAcct: 'acct_rina',
  toAcct: 'acct_01999',
  status: status,
);

void main() {
  group('LedgerTxn', () {
    test('an old document parses with the new fields unset and writes back '
        'the same shape', () {
      final t = LedgerTxn.fromJson(oldLedgerDoc());
      expect(t.stepUp, isNull);
      expect(t.caseLink, isNull);
      expect(t.warningShown, isNull);
      expect(t.warningChoice, isNull);
      expect(t.simulated, isFalse);
      expect(t.toJson(), oldLedgerDoc());
    });

    test('a new document round-trips every field', () {
      final t = LedgerTxn.fromJson(oldLedgerDoc()).copyWith(
        status: LedgerStatus.releasedByStepUp,
        stepUp: stepUp,
        caseLink: caseLink,
        warningShown: 'unfamiliar_payee',
        warningChoice: 'continued',
        simulated: true,
      );
      final json = wire(t.toJson());
      expect(json['status'], 'released_by_step_up');
      expect(json['step_up'], {
        'method': 'biometric',
        'at': '2026-10-17T09:30:00.000Z',
        'decision_id': 'int_1',
        'server_decision': 'hold',
        'reason_codes': ['ATO_BEHAVIOUR_MISMATCH'],
      });
      expect(json['warning_shown'], 'unfamiliar_payee');
      expect(json['simulated'], isTrue);
      final back = LedgerTxn.fromJson(json);
      expect(back, t);
      expect(back.hashCode, t.hashCode);
      expect(back == LedgerTxn.fromJson(oldLedgerDoc()), isFalse);
    });

    test('copyWith keeps the new fields and can clear the warnings', () {
      final t = send('a', 1).copyWith(
        stepUp: stepUp,
        warningShown: 'unfamiliar_payee',
        simulated: true,
      );
      final moved = t.copyWith(status: LedgerStatus.held);
      expect(moved.stepUp, stepUp);
      expect(moved.warningShown, 'unfamiliar_payee');
      expect(moved.simulated, isTrue);
      expect(t.copyWith(warningShown: null).warningShown, isNull);
    });

    test('released_by_step_up is a known status that moves money', () {
      expect(LedgerStatus.all, contains(LedgerStatus.releasedByStepUp));
      expect(LedgerStatus.movesMoney(LedgerStatus.releasedByStepUp), isTrue);
      expect(LedgerStatus.movesMoney(LedgerStatus.done), isTrue);
      expect(LedgerStatus.movesMoney(LedgerStatus.held), isFalse);
    });

    test('LedgerPatch writes only what it sets', () {
      expect(const LedgerPatch().toUpdate(), isEmpty);
      expect(LedgerPatch(status: 'x', stepUp: stepUp).toUpdate().keys, [
        'status',
        'step_up',
      ]);
    });
  });

  group('LocalLedgerRepo.patch', () {
    late LocalLedgerRepo repo;
    setUp(() => repo = LocalLedgerRepo(DemoAssets(bundle: DiskAssetBundle())));
    tearDown(() => repo.dispose());

    test('a held row released by step-up carries the record and lowers the '
        'balance like a done debit', () async {
      await repo.create('rina', send('t1', 1000, status: LedgerStatus.held));
      expect(await repo.watchBalance('rina').first, 9841);
      await repo.patch(
        't1',
        LedgerPatch(status: LedgerStatus.releasedByStepUp, stepUp: stepUp),
      );
      final row = (await repo.watchRecent('rina').first).first;
      expect(row.status, LedgerStatus.releasedByStepUp);
      expect(row.stepUp, stepUp);
      expect(await repo.watchBalance('rina').first, 8841);
    });

    test('a patch with only a case link keeps the status', () async {
      await repo.create('rina', send('t2', 10, status: LedgerStatus.held));
      await repo.patch('t2', LedgerPatch(caseLink: caseLink));
      final row = (await repo.watchRecent('rina').first).first;
      expect(row.status, LedgerStatus.held);
      expect(row.caseLink, caseLink);
    });
  });

  group('InterventionRecord', () {
    Map<String, dynamic> oldDoc() => <String, dynamic>{
      'uid': 'rina',
      'txn_id': 'txn_1',
      'trigger': 'behaviour_mismatch',
      'script_bn': 'বাংলা',
      'script_en': 'English',
      'reasons': <Object>[],
      'actions': <Object>[],
      'status': 'open',
      'created_at': '2026-10-17T09:00:00.000Z',
      'request_id': null,
      'expires_at': null,
      'contact_uid': null,
      'audio_asset_id': null,
    };

    test(
      'an old document parses with the new fields unset, same shape back',
      () {
        final r = InterventionRecord.fromDoc('int_1', oldDoc());
        expect(r.stepUp, isNull);
        expect(r.caseLink, isNull);
        expect(r.simulated, isFalse);
        expect(r.signalSources, isNull);
        expect(r.toDoc(), oldDoc());
      },
    );

    test('a new document round-trips step-up, case link, simulated and '
        'signal sources', () {
      final r = InterventionRecord.fromDoc('int_1', oldDoc()).copyWith(
        status: InterventionStatus.releasedByStepUp,
        stepUp: stepUp,
        caseLink: caseLink,
        simulated: true,
        signalSources: const SignalSources(),
      );
      final back = InterventionRecord.fromDoc('int_1', wire(r.toDoc()));
      expect(back, r);
      expect(back.status, 'released_by_step_up');
      expect(back.hashCode, r.hashCode);
    });

    test('copyWith patches the script and keeps the hold-record fields', () {
      final r = InterventionRecord.fromDoc(
        'int_1',
        oldDoc(),
      ).copyWith(simulated: true, signalSources: const SignalSources());
      final patched = r.copyWith(
        scriptBn: 'নতুন',
        actions: const [ActionItem(type: 'hold_transaction')],
        audioAssetId: 'apa_generic_caution',
      );
      expect(patched.scriptBn, 'নতুন');
      expect(patched.scriptEn, 'English');
      expect(patched.audioAssetId, 'apa_generic_caution');
      expect(patched.simulated, isTrue);
      expect(patched.signalSources, const SignalSources());
    });

    test('the local repo stores the new fields', () async {
      final repo = LocalInterventionRepo();
      addTearDown(repo.dispose);
      final r = InterventionRecord.fromDoc(
        'int_1',
        oldDoc(),
      ).copyWith(stepUp: stepUp, simulated: true);
      await repo.upsert(r);
      expect((await repo.watch('rina').first).single, r);
    });
  });
}
