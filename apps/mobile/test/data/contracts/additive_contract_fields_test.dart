// The contract fields the app reads and sends, against main's risk-mw contracts.py.

import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InterveneResponse.intervention_id', () {
    const base = {
      'intervene': true,
      'script_bn': '',
      'script_en': '',
      'ui': 'fullscreen',
      'cooldown_s': 300,
    };

    test('the id /v1/intervene opened wins', () {
      final r = InterveneResponse.fromJson({
        ...base,
        'intervention_id': 'iv-opened',
        'identity_source': 'demo',
        'actions': [
          {
            'type': 'freeze_pin_reset',
            'params': {'minutes': 60, 'intervention_id': 'iv-hold'},
          },
        ],
      });
      expect(r.interventionId, 'iv-opened');
      expect(r.identitySource, 'demo');
      expect(r.serverInterventionId, 'iv-opened');
    });

    test("without it, the hold's actions[].params.intervention_id", () {
      final r = InterveneResponse.fromJson({
        ...base,
        'actions': [
          {
            'type': 'delay_new_payee',
            'params': {'minutes': 60},
          },
          {
            'type': 'trusted_contact_check',
            'params': {'intervention_id': 'iv-hold', 'contact_uid': 'rafiq'},
          },
        ],
      });
      expect(r.interventionId, isNull);
      expect(r.serverInterventionId, 'iv-hold');
    });

    test('an older server names none', () {
      final r = InterveneResponse.fromJson({...base, 'actions': <Object>[]});
      expect(r.serverInterventionId, isNull);
      expect(interventionIdOf(const [ActionItem(type: 'x')]), isNull);
      expect(
        interventionIdOf(const [
          ActionItem(type: 'x', params: {'intervention_id': ''}),
        ]),
        isNull,
      );
    });
  });

  group(
    'TrustedContactDecision: decided_by, contact_verified',
    () {
      test('a self-approval in demo mode reads as not by the contact', () {
        final d = TrustedContactDecision.fromJson(const {
          'request_id': 'tc-1',
          'status': 'approved',
          'decided_by': 'rina',
          'contact_verified': false,
        });
        expect(d.decidedBy, 'rina');
        expect(d.contactVerified, isFalse);
        expect(d.notByContact, isTrue);
        expect(TrustedContactDecision.fromJson(d.toJson()), d);
      });

      test('the contact, and an older server without the fields', () {
        final contact = TrustedContactDecision.fromJson(const {
          'request_id': 'tc-1',
          'status': 'approved',
          'decided_by': 'rafiq',
          'contact_verified': true,
        });
        expect(contact.notByContact, isFalse);
        final old = TrustedContactDecision.fromJson(const {
          'request_id': 'tc-1',
          'status': 'approved',
        });
        expect(old.contactVerified, isNull);
        expect(old.notByContact, isFalse);
      });
    },
  );

  group('the additive identity, payee-score and session fields', () {
    test('ScoreResponse reads identity_source and the payee scores', () {
      final r = ScoreResponse.fromJson(const {
        'decision': 'hold',
        'risk_score': 0.9,
        'band': 'critical',
        'reasons': <Object>[],
        'actions': <Object>[],
        'model_version': 'rules',
        'identity_source': 'verified',
        'payee_score_before': 0.41,
        'payee_score_with_this_transfer': 0.87,
        'payee_moved_feature': 'inbound_count_24h',
        'payee_score_as_of': '2026-11-03T10:00:00+00:00',
      });
      expect(r.identitySource, 'verified');
      expect(r.payeeScoreBefore, 0.41);
      expect(r.payeeScoreWithThisTransfer, 0.87);
      expect(r.payeeMovedFeature, 'inbound_count_24h');
      expect(r.payeeScoreAsOf, '2026-11-03T10:00:00+00:00');
      expect(ScoreResponse.fromJson(r.toJson()), r);
    });

    test('requests leave the session keys out when unset (the deployed '
        'service forbids extras) and send them when set', () {
      const bare = InterveneRequest(
        userId: 'rina',
        trigger: 'call_active',
        txn: Txn(type: TxnType.sendMoney),
      );
      final json = bare.toJson();
      expect(json.containsKey('session_id'), isFalse);
      expect(json.containsKey('intervention_id'), isFalse);
      expect((json['txn'] as Map).containsKey('txn_id'), isFalse);

      const full = InterveneRequest(
        userId: 'rina',
        trigger: 'call_active',
        txn: Txn(type: TxnType.sendMoney, txnId: 'txn_1'),
        sessionId: 'sess_1',
        interventionId: 'iv-hold',
      );
      final wire =
          jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>;
      expect(wire['session_id'], 'sess_1');
      expect(wire['intervention_id'], 'iv-hold');
      expect((wire['txn'] as Map)['txn_id'], 'txn_1');
      expect(InterveneRequest.fromJson(wire), full);
      expect(
        const Txn(type: TxnType.sendMoney, txnId: 'a').copyWith(txnId: null),
        const Txn(type: TxnType.sendMoney),
      );
    });
  });

  test('CaseStatus.degraded is a wire value and terminal', () {
    expect(CaseStatus.fromWire('degraded'), CaseStatus.degraded);
    expect(CaseStatus.degraded.wire, 'degraded');
    expect(CaseStatus.degraded.isTerminal, isTrue);
    expect(CaseStatus.queued.isTerminal, isFalse);
    expect(CaseStatus.unknown.isTerminal, isFalse);
  });
}
