import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/api/risk_api_client.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_http_adapter.dart';
import 'risk_api_client_test.dart' show client, failureOf;

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/case_zero/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('POST /v1/investigate', () {
    test(
      'sends {acct_id} with the identity header and parses the case',
      () async {
        final adapter = always(
          () => jsonBody({
            'case_id': 'CZ-0002',
            'stream_url': '/v1/investigations/CZ-0002/events',
          }),
        );
        final res = await client(adapter).postInvestigate('acct_01070');

        expect(
          res,
          const InvestigateResponse(
            caseId: 'CZ-0002',
            streamUrl: '/v1/investigations/CZ-0002/events',
          ),
        );
        final req = adapter.last;
        expect(req.method, 'POST');
        expect(req.uri.toString(), 'https://risk.test/v1/investigate');
        expect(req.headers['X-Demo-User'], 'rina');
        expect(req.receiveTimeout, const Duration(seconds: 10));
        expect(adapter.lastJson(), {'acct_id': 'acct_01070'});
      },
    );

    test('502 → InvestigatorUnavailable', () async {
      final f = await failureOf(
        client(
          always(() => jsonBody({'detail': 'investigator down'}, status: 502)),
        ).postInvestigate('acct_01070'),
      );
      expect(f, isA<InvestigatorUnavailable>());
      expect((f as ServerFailure).status, 502);
      expect(f.serverMessage, 'investigator down');
    });

    test('429 → RateLimited with Retry-After seconds', () async {
      final f = await failureOf(
        client(
          always(
            () => jsonBody(
              {'detail': 'slow down'},
              status: 429,
              headers: {'retry-after': '12'},
            ),
          ),
        ).postInvestigate('acct_01070'),
      );
      expect(f, isA<RateLimited>());
      expect((f as RateLimited).retryAfterSeconds, 12);
      expect(f.status, 429);
    });

    test('429 without Retry-After → RateLimited(null)', () async {
      final f = await failureOf(
        client(always(() => jsonBody({'detail': 'x'}, status: 429)))
            .postInvestigate('acct_01070'),
      );
      expect((f as RateLimited).retryAfterSeconds, isNull);
    });
  });

  group('GET /v1/investigations/{case_id}', () {
    test('a finished case from the live fixture', () async {
      final adapter = always(() => jsonBody(fixture('case_report_done.json')));
      final r = await client(adapter).getCase('CZ-0002');

      expect(r.status, CaseStatus.done);
      expect(r.action, CaseAction.freeze);
      expect(r.ring, hasLength(6));
      expect(adapter.last.method, 'GET');
      expect(
        adapter.last.uri.toString(),
        'https://risk.test/v1/investigations/CZ-0002',
      );
      expect(adapter.last.receiveTimeout, const Duration(seconds: 10));
    });

    test('a running case parses as partial', () async {
      final r = await client(
        always(() => jsonBody(fixture('case_report_running.json'))),
      ).getCase('CZ-0003');
      expect(r.status, CaseStatus.running);
      expect(r.action, CaseAction.pending);
    });

    test('404 → CaseNotFound', () async {
      final f = await failureOf(
        client(always(() => jsonBody({'detail': 'Not Found'}, status: 404)))
            .getCase('CZ-9999'),
      );
      expect(f, isA<CaseNotFound>());
      expect((f as ServerFailure).serverMessage, 'Not Found');
    });

    test('502 → InvestigatorUnavailable, 429 → RateLimited', () async {
      expect(
        await failureOf(
          client(always(() => jsonBody({}, status: 502))).getCase('CZ-1'),
        ),
        isA<InvestigatorUnavailable>(),
      );
      expect(
        await failureOf(
          client(
            always(
              () => jsonBody({}, status: 429, headers: {'Retry-After': '5'}),
            ),
          ).getCase('CZ-1'),
        ),
        isA<RateLimited>().having((r) => r.retryAfterSeconds, 'retry', 5),
      );
    });

    test('a body that breaks the contract → ContractFailure', () async {
      final json = fixture('case_report_done.json')..remove('status');
      expect(
        await failureOf(client(always(() => jsonBody(json))).getCase('CZ-1')),
        isA<ContractFailure>(),
      );
    });

    test('the case id is path-encoded', () {
      expect(RiskRoutes.investigation('a/b'), '/v1/investigations/a%2Fb');
    });
  });

  group('deadline', () {
    test('both Case Zero routes have a 10 s overall deadline', () {
      const t = RouteTimeouts();
      expect(t.investigate, const Duration(seconds: 10));
      expect(
        t.deadlineFor(RiskRoutes.investigate, t.investigate),
        const Duration(seconds: 10),
      );
      expect(
        t.deadlineFor(RiskRoutes.investigationTemplate, t.investigate),
        const Duration(seconds: 10),
      );
    });

    test('a stalled investigator → TimeoutFailure at the deadline', () async {
      final api = RiskApiClient(
        baseUrl: 'https://risk.test',
        identity: const DemoIdentityHeaders('rina'),
        dio: Dio()
          ..httpClientAdapter = FakeHttpClientAdapter(
            (_, _) => Future<ResponseBody>.delayed(
              const Duration(milliseconds: 400),
              () => jsonBody(fixture('case_report_done.json')),
            ),
          ),
        timeouts: const RouteTimeouts(
          investigate: Duration(seconds: 5),
          investigateDeadline: Duration(milliseconds: 40),
        ),
      );
      final sw = Stopwatch()..start();
      for (final call in [api.getCase('CZ-1'), api.postInvestigate('a')]) {
        final f = await failureOf(call);
        expect(f, isA<TimeoutFailure>());
        expect((f as TimeoutFailure).timeout, const Duration(milliseconds: 40));
      }
      expect(sw.elapsedMilliseconds, lessThan(350));
    });
  });

  test('parseRetryAfter reads whole seconds only', () {
    expect(parseRetryAfter('30'), 30);
    expect(parseRetryAfter(' 7 '), 7);
    expect(parseRetryAfter(null), isNull);
    expect(parseRetryAfter('-1'), isNull);
    expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
  });
}
