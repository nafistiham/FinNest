import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/case_zero/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('CaseReport', () {
    test('a finished case from the live shape', () {
      final r = CaseReport.fromJson(fixture('case_report_done.json'));
      expect(r.caseId, 'CZ-0002');
      expect(r.acctId, 'acct_01070');
      expect(r.status, CaseStatus.done);
      expect(r.status.isTerminal, isTrue);
      expect(r.summaryEn, startsWith('On 2026-11-10'));
      expect(r.summaryBn, startsWith('২০২৬-১১-১০'));
      expect(r.evidence, const [
        CaseEvidence(
          rowId: 'txn_011308',
          claim:
              'Seed acct_01070 forwarded received funds rapidly within '
              'minutes.',
        ),
      ]);
      expect(r.ring, hasLength(6));
      expect(r.ring.first, 'acct_01070');
      expect(r.confidence, 0.8697);
      expect(r.recommendedAction, 'freeze');
      expect(r.action, CaseAction.freeze);
      expect(r.modelVersion, 'mule-lgbm-0.1+gemini-3.8-flash');
      expect(CaseReport.fromJson(r.toJson()), r);
    });

    test('a running case: empty evidence and ring, pending action', () {
      final r = CaseReport.fromJson(fixture('case_report_running.json'));
      expect(r.status, CaseStatus.running);
      expect(r.status.isTerminal, isFalse);
      expect(r.summaryBn, 'তদন্ত চলছে।');
      expect(r.evidence, isEmpty);
      expect(r.ring, isEmpty);
      expect(r.confidence, 0.0);
      expect(r.action, CaseAction.pending);
    });

    test('a missing required key is a FormatException', () {
      final json = fixture('case_report_done.json')..remove('ring');
      expect(() => CaseReport.fromJson(json), throwsFormatException);
    });

    test('unknown status and action values degrade, the raw action stays', () {
      final json = fixture('case_report_done.json')
        ..['status'] = 'archived'
        ..['recommended_action'] = 'call_the_police';
      final r = CaseReport.fromJson(json);
      expect(r.status, CaseStatus.unknown);
      expect(r.action, CaseAction.unknown);
      expect(r.recommendedAction, 'call_the_police');
    });
  });

  test('CaseStatus and CaseAction read every wire value', () {
    for (final (wire, status) in const [
      ('queued', CaseStatus.queued),
      ('running', CaseStatus.running),
      ('done', CaseStatus.done),
      ('failed', CaseStatus.failed),
      ('unknown', CaseStatus.unknown),
    ]) {
      expect(CaseStatus.fromWire(wire), status);
    }
    for (final (wire, action) in const [
      ('freeze', CaseAction.freeze),
      ('edd', CaseAction.edd),
      ('monitor', CaseAction.monitor),
      ('close_no_action', CaseAction.closeNoAction),
      ('pending', CaseAction.pending),
      ('route_to_risk_reviewer', CaseAction.routeToRiskReviewer),
      ('', CaseAction.unknown),
    ]) {
      expect(CaseAction.fromWire(wire), action);
    }
    expect(CaseStatus.failed.isTerminal, isTrue);
    expect(CaseStatus.queued.isTerminal, isFalse);
  });

  test('InvestigateResponse round-trips and requires both keys', () {
    const r = InvestigateResponse(
      caseId: 'CZ-0002',
      streamUrl: '/v1/investigations/CZ-0002/events',
    );
    expect(InvestigateResponse.fromJson(r.toJson()), r);
    expect(
      () => InvestigateResponse.fromJson({'case_id': 'CZ-0002'}),
      throwsFormatException,
    );
  });

  group('PayeeRisk', () {
    test('reads the live list and tolerates unknown keys (as_of)', () {
      final risk = PayeeRisk.fromJson(fixture('payee_risk.json'));
      expect(risk.version, 'payee-risk/1');
      expect(risk.generatedAt, '2026-10-17T04:47:08+00:00');
      expect(risk.payees, const [
        PayeeRiskEntry(
          acctId: 'acct_00036',
          status: 'suspected',
          caseId: 'CZ-0002',
          role: 'mule_L2',
          modelScore: 0.0,
          analystApproved: false,
          facts: [
            'Seed acct_01070 split incoming funds to five separate '
                'recipients.',
          ],
        ),
      ]);
      expect(risk.entryFor('acct_00036')?.caseId, 'CZ-0002');
      expect(risk.entryFor('acct_99999'), isNull);
      expect(PayeeRisk.fromJson(risk.toJson()), risk);
    });

    test('an empty list claims nothing; a payee without acct_id fails', () {
      expect(
        PayeeRisk.fromJson({
          'version': 'payee-risk/1',
          'generated_at': 'x',
          'payees': <Object>[],
        }).payees,
        isEmpty,
      );
      expect(
        () => PayeeRisk.fromJson({
          'version': 'payee-risk/1',
          'generated_at': 'x',
          'payees': [
            {'status': 'suspected'},
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
