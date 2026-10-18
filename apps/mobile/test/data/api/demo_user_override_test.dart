import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/api/case_zero_client.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/api/risk_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../contracts/samples.dart' as samples;
import 'fake_http_adapter.dart';

/// The per-call `X-Demo-User` override: the approve screen speaks as the
/// trusted contact, the Fraud desk as staff, and every other call keeps the
/// signed-in persona.
void main() {
  RiskApiClient client(
    FakeHttpClientAdapter adapter, {
    IdentityHeaders identity = const DemoIdentityHeaders('rina'),
  }) => RiskApiClient(
    baseUrl: 'https://risk.test',
    identity: identity,
    dio: Dio()..httpClientAdapter = adapter,
  );

  FakeHttpClientAdapter decisions() => FakeHttpClientAdapter(
    (o, _) async => jsonBody({
      'request_id': 'req_1',
      'status': 'approved',
      'decided_by': 'rafiq',
      'contact_verified': true,
    }),
  );

  test(
    'approve as the contact sends X-Demo-User: rafiq for that call only',
    () async {
      final adapter = decisions();
      final api = client(adapter);

      final d = await api.approveTrustedContact('req_1', asUser: 'rafiq');
      expect(d.decidedBy, 'rafiq');
      expect(d.contactVerified, isTrue);
      expect(adapter.last.headers['X-Demo-User'], 'rafiq');

      await api.declineTrustedContact('req_1');
      expect(adapter.last.headers['X-Demo-User'], 'rina');
    },
  );

  test(
    'the override replaces the persona header and leaves the bearer',
    () async {
      final adapter = decisions();
      final api = client(
        adapter,
        identity: BearerIdentityHeaders(
          () async => 'tok',
          fallbackDemoUid: 'rina',
        ),
      );
      await api.approveTrustedContact('req_1', asUser: 'rafiq');
      expect(adapter.last.headers['X-Demo-User'], 'rafiq');
      expect(adapter.last.headers['Authorization'], 'Bearer tok');
    },
  );

  test('an empty override is no override', () async {
    final adapter = decisions();
    await client(adapter).approveTrustedContact('req_1', asUser: '');
    expect(adapter.last.headers['X-Demo-User'], 'rina');
  });

  test(
    'the desk case calls carry the staff persona; customer calls do not',
    () async {
      final adapter = FakeHttpClientAdapter((o, _) async {
        if (o.path == RiskRoutes.investigate) {
          return jsonBody(samples.investigateResponse.toJson());
        }
        if (o.path.startsWith('/v1/investigations/')) {
          return jsonBody(samples.caseReport.toJson());
        }
        return jsonBody(samples.scoreResponse.toJson());
      });
      final risk = client(adapter);
      final desk = LiveCaseDeskApi(
        watchList: CaseZeroClient(Dio(), 'https://cz.test'),
        risk: risk,
      );

      await desk.postInvestigate('acct_01070');
      expect(adapter.last.headers['X-Demo-User'], AppEnv.staffDemoUser);
      expect(AppEnv.staffDemoUser, 'staff_fraud_desk');

      await desk.getCase('CZ-0002');
      expect(adapter.last.headers['X-Demo-User'], 'staff_fraud_desk');

      await risk.postScore(samples.scoreRequest);
      expect(adapter.last.headers['X-Demo-User'], 'rina');
    },
  );

  test('LiveCaseDeskApi passes its staff uid through any RiskApi', () async {
    final fake = FakeRiskApi()..cases['CZ-1'] = samples.caseReport;
    final desk = LiveCaseDeskApi(
      watchList: CaseZeroClient(Dio(), 'https://cz.test'),
      risk: fake,
      staffUser: 'staff_x',
    );
    await desk.postInvestigate('acct_1');
    await desk.getCase('CZ-1');
    await fake.postScore(samples.scoreRequest);
    expect(fake.actingAsFor(RiskRoutes.investigate), 'staff_x');
    expect(fake.actingAsFor(RiskRoutes.investigationTemplate), 'staff_x');
    expect(fake.actingAsFor(RiskRoutes.score), isNull);
  });
}
