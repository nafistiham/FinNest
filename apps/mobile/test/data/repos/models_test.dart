import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LedgerTxn round-trips its snake_case JSON', () {
    final t = LedgerTxn(
      txnId: 'txn_1',
      ts: DateTime.parse('2026-11-10T12:30:27+06:00'),
      type: 'send_money',
      amountBdt: 5000,
      fromAcct: 'acct_rina',
      toAcct: 'acct_rafiq',
      status: LedgerStatus.held,
      counterpartyNameBn: 'রফিক ইসলাম',
      interventionId: 'int_1',
    );
    final json = t.toJson();
    expect(
      json.keys,
      containsAll(['txn_id', 'amount_bdt', 'from_acct', 'to_acct']),
    );
    expect(LedgerTxn.fromJson(json), t);
    expect(t.isDebitFor('acct_rina'), isTrue);
    expect(t.isDebitFor('acct_rafiq'), isFalse);
    expect(t.copyWith(interventionId: null).interventionId, isNull);
  });

  test('InterventionRecord round-trips through toDoc/fromDoc', () {
    final r = InterventionRecord(
      id: 'int_1',
      uid: 'rina',
      txnId: 'txn_1',
      trigger: 'call_active',
      scriptBn: 'আপা বলছে',
      reasons: const [
        Reason(
          code: 'call_active',
          weight: 0.6,
          textBn: 'কল চলছে',
          textEn: 'Call',
        ),
      ],
      actions: const [
        ActionItem(type: 'trusted_contact_check', params: {'ttl_s': 300}),
      ],
      status: InterventionStatus.pending,
      createdAt: DateTime.utc(2026, 10, 16, 10),
      requestId: 'req_1',
      expiresAt: DateTime.utc(2026, 10, 16, 10, 5),
      contactUid: 'rafiq',
      audioAssetId: 'apa_call_active',
    );
    final doc = r.toDoc();
    expect(doc['script_bn'], 'আপা বলছে');
    expect(doc['request_id'], 'req_1');
    expect(doc['audio_asset_id'], 'apa_call_active');
    expect(InterventionRecord.fromDoc('int_1', doc), r);
    // copyWith keeps the served clip; older docs without it read null.
    expect(r.copyWith(status: 'open').audioAssetId, 'apa_call_active');
    expect(
      InterventionRecord.fromDoc(
        'int_1',
        {...doc}..remove('audio_asset_id'),
      ).audioAssetId,
      isNull,
    );
  });

  test('UserProfile reads the users/{uid} shape with defaults', () {
    final p = UserProfile.fromJson(const {
      'uid': 'rina',
      'name_bn': 'রিনা আক্তার',
      'name_en': 'Rina Akter',
      'phone_masked': '017XXXXX412',
      'trusted_contact_uid': 'rafiq',
      'p95_send_bdt': 5000,
      'acct_id': 'acct_rina',
      'district': 'Gazipur',
    });
    expect(p.persona, Persona.rina);
    expect(p.balanceBdt, 0);
    expect(UserProfile.fromJson(p.toJson()), p);
  });
}
