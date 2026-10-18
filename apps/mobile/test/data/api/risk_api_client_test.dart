import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/api/risk_api_client.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../contracts/samples.dart' as samples;
import 'fake_http_adapter.dart';

RiskApiClient client(
  FakeHttpClientAdapter adapter, {
  IdentityHeaders identity = const DemoIdentityHeaders('rina'),
  RouteTimeouts timeouts = const RouteTimeouts(),
}) => RiskApiClient(
  baseUrl: 'https://risk.test',
  identity: identity,
  dio: Dio()..httpClientAdapter = adapter,
  timeouts: timeouts,
);

Future<ApiFailure> failureOf(Future<Object?> call) async {
  try {
    await call;
  } on ApiFailure catch (e) {
    return e;
  }
  fail('expected an ApiFailure');
}

void main() {
  group('request shape', () {
    test(
      'POST /v1/risk/score with demo header, JSON body and 200 parse',
      () async {
        final adapter = always(() => jsonBody(samples.scoreResponse.toJson()));
        final api = client(adapter);

        final res = await api.postScore(samples.scoreRequest);

        expect(res, samples.scoreResponse);
        final req = adapter.last;
        expect(req.method, 'POST');
        expect(req.uri.toString(), 'https://risk.test/v1/risk/score');
        expect(req.headers['X-Demo-User'], 'rina');
        expect(req.headers.containsKey('Authorization'), isFalse);
        expect(req.contentType, contains('application/json'));
        expect(req.connectTimeout, const Duration(seconds: 3));
        expect(req.receiveTimeout, const Duration(seconds: 4));
        expect(adapter.lastJson(), samples.scoreRequest.toJson());
      },
    );

    test('bearer identity is attached per request', () async {
      var n = 0;
      final adapter = always(() => jsonBody(samples.scoreResponse.toJson()));
      final api = client(
        adapter,
        identity: BearerIdentityHeaders(() async => 'tok${++n}'),
      );

      await api.postScore(samples.scoreRequest);
      await api.postScore(samples.scoreRequest);

      expect(adapter.requests[0].headers['Authorization'], 'Bearer tok1');
      expect(adapter.requests[1].headers['Authorization'], 'Bearer tok2');
    });

    test('every route hits its path with its receive timeout', () async {
      final adapter = FakeHttpClientAdapter((o, _) async {
        final body = switch (o.path) {
          '/v1/risk/signals' => samples.signalsResponse.toJson(),
          '/v1/appsafety/check' => samples.appSafetyResponse.toJson(),
          '/v1/intervene' => samples.interveneResponse.toJson(),
          '/v1/scam/turn' => samples.scamTurnResponse.toJson(),
          '/v1/apa/turn' => samples.apaTurnResponse.toJson(),
          '/v1/actions/trusted-contact' =>
            samples.trustedContactResponse.toJson(),
          _ => throw StateError('unexpected ${o.path}'),
        };
        return jsonBody(body);
      });
      final api = client(adapter);

      expect(
        await api.postSignals(samples.signalsRequest),
        samples.signalsResponse,
      );
      expect(
        await api.postAppSafety(samples.appSafetyRequest),
        samples.appSafetyResponse,
      );
      expect(
        await api.postIntervene(samples.interveneRequest),
        samples.interveneResponse,
      );
      expect(
        await api.postScamTurn(samples.scamTurnRequest),
        samples.scamTurnResponse,
      );
      expect(
        await api.postApaTurn(samples.apaTurnRequest),
        samples.apaTurnResponse,
      );
      expect(
        await api.createTrustedContact(samples.trustedContactRequest),
        samples.trustedContactResponse,
      );

      expect(adapter.requests.map((r) => r.receiveTimeout?.inSeconds), [
        2,
        15, // app-safety: Gemini triage over a real phone's app list
        4,
        12, // scam turn: Gemini per turn, slow on a cold instance
        8,
        4,
      ]);
      expect(adapter.requests.every((r) => r.method == 'POST'), isTrue);
    });

    test('POST /v1/appsafety/demo-token parses the demo token', () async {
      final adapter = always(
        () => jsonBody({
          'integrity_token': 'demo.abc',
          'bundle_hash': 'h1',
          'expires_in_s': 600,
        }),
      );
      final api = client(adapter);

      final res = await api.postAppSafetyDemoToken(
        const DemoIntegrityRequest(appsDetected: ['com.takanow.app']),
      );

      expect(res.integrityToken, 'demo.abc');
      expect(res.bundleHash, 'h1');
      expect(res.expiresInS, 600);
      expect(adapter.last.method, 'POST');
      expect(
        adapter.last.uri.toString(),
        'https://risk.test/v1/appsafety/demo-token',
      );
      expect(adapter.last.receiveTimeout, const Duration(seconds: 4));
      expect(adapter.lastJson()?['apps_detected'], ['com.takanow.app']);
    });

    test('GET /v1/appsafety/latest/{uid} encodes the uid and parses', () async {
      final adapter = always(
        () => jsonBody({
          'uid': 'rina@demo',
          'known': true,
          'verdict': 'CAUTION',
          'risk_score': 0.4,
          'flagged_packages': ['com.takanow.app'],
          'attestation': 'demo',
          'checked_at': '2026-10-16T10:00:00+00:00',
          'valid_until': '2026-10-16T10:15:00+00:00',
        }),
      );
      final api = client(adapter);

      final res = await api.getAppSafetyLatest('rina@demo');

      expect(res.known, isTrue);
      expect(res.verdict, SafetyVerdict.caution);
      expect(res.flaggedPackages, ['com.takanow.app']);
      expect(adapter.last.method, 'GET');
      expect(
        adapter.last.uri.toString(),
        'https://risk.test/v1/appsafety/latest/rina%40demo',
      );
      expect(adapter.bodies, [null]);
      expect(adapter.last.receiveTimeout, const Duration(seconds: 2));
    });

    test('approve and decline build the trusted-contact URLs', () async {
      final adapter = FakeHttpClientAdapter(
        (o, _) async => jsonBody({
          'request_id': 'req 1',
          'status': o.path.endsWith('approve') ? 'approved' : 'declined',
        }),
      );
      final api = client(adapter);

      final approved = await api.approveTrustedContact('req 1');
      final declined = await api.declineTrustedContact('req 1');

      expect(approved.status, TrustedContactDecision.statusApproved);
      expect(declined.status, TrustedContactDecision.statusDeclined);
      expect(adapter.requests.map((r) => r.uri.toString()), [
        'https://risk.test/v1/actions/trusted-contact/req%201/approve',
        'https://risk.test/v1/actions/trusted-contact/req%201/decline',
      ]);
      expect(adapter.bodies, [null, null]);
      expect(adapter.last.receiveTimeout, const Duration(seconds: 4));
    });
  });

  group('failure mapping', () {
    test('422 → ServerFailure with FastAPI detail', () async {
      final api = client(
        always(
          () => jsonBody({
            'detail': [
              {
                'type': 'missing',
                'loc': ['body', 'session_id'],
                'msg': 'Field required',
                'input': {'user_id': 'rina'},
              },
            ],
          }, status: 422),
        ),
      );

      final f = await failureOf(api.postScore(samples.scoreRequest));

      expect(f, isA<ServerFailure>());
      final s = f as ServerFailure;
      expect(s.status, 422);
      expect(s.serverMessage, 'Field required (body.session_id)');
    });

    test('404 on the app-safety routes → ServerFailure(404)', () async {
      final api = client(
        always(() => jsonBody({'detail': 'Not Found'}, status: 404)),
      );
      expect(
        await failureOf(api.getAppSafetyLatest('rina')),
        isA<ServerFailure>().having((s) => s.status, 'status', 404),
      );
      expect(
        await failureOf(
          api.postAppSafetyDemoToken(const DemoIntegrityRequest()),
        ),
        isA<ServerFailure>()
            .having((s) => s.status, 'status', 404)
            .having((s) => s.serverMessage, 'serverMessage', 'Not Found'),
      );
    });

    test('404 → ServerFailure with the string detail', () async {
      final api = client(
        always(
          () => jsonBody({
            'detail': 'unknown trusted-contact request',
          }, status: 404),
        ),
      );
      final f = await failureOf(api.approveTrustedContact('nope'));
      expect(
        f,
        isA<ServerFailure>()
            .having((s) => s.status, 'status', 404)
            .having(
              (s) => s.serverMessage,
              'serverMessage',
              'unknown trusted-contact request',
            ),
      );
    });

    test('500 with an HTML body → ServerFailure(500)', () async {
      final api = client(
        always(() => textBody('<h1>bad gateway</h1>', status: 500)),
      );
      final f = await failureOf(api.postIntervene(samples.interveneRequest));
      expect(
        f,
        isA<ServerFailure>()
            .having((s) => s.status, 'status', 500)
            .having((s) => s.serverMessage, 'serverMessage', isNull)
            .having((s) => s.isServerError, 'isServerError', isTrue),
      );
    });

    test('dio receive timeout → TimeoutFailure', () async {
      final api = client(
        FakeHttpClientAdapter(
          (o, _) => throw DioException.receiveTimeout(
            timeout: o.receiveTimeout!,
            requestOptions: o,
          ),
        ),
      );
      final f = await failureOf(api.postScore(samples.scoreRequest));
      expect(
        f,
        isA<TimeoutFailure>().having(
          (t) => t.timeout,
          'timeout',
          const Duration(seconds: 4),
        ),
      );
    });

    test('connection timeout → TimeoutFailure', () async {
      final api = client(
        FakeHttpClientAdapter(
          (o, _) => throw DioException.connectionTimeout(
            timeout: o.connectTimeout!,
            requestOptions: o,
          ),
        ),
      );
      expect(
        await failureOf(api.postScore(samples.scoreRequest)),
        isA<TimeoutFailure>(),
      );
    });

    test('a server that stalls past the deadline → TimeoutFailure', () async {
      final api = client(
        FakeHttpClientAdapter(
          (_, _) => Future<ResponseBody>.delayed(
            const Duration(milliseconds: 400),
            () => jsonBody(samples.scoreResponse.toJson()),
          ),
        ),
        timeouts: const RouteTimeouts(
          connect: Duration(milliseconds: 20),
          score: Duration(milliseconds: 20),
          scoreDeadline: Duration(milliseconds: 40),
        ),
      );
      final sw = Stopwatch()..start();
      final f = await failureOf(api.postScore(samples.scoreRequest));
      expect(f, isA<TimeoutFailure>());
      expect(sw.elapsedMilliseconds, lessThan(350));
    });

    test('/score has a hard 4 s overall deadline; other routes keep '
        'connect + receive', () {
      const t = RouteTimeouts();
      expect(t.scoreDeadline, const Duration(seconds: 4));
      expect(
        t.deadlineFor(RiskRoutes.score, t.score),
        const Duration(seconds: 4),
      );
      expect(
        t.deadlineFor(RiskRoutes.intervene, t.intervene),
        t.intervene + t.connect,
      );
    });

    test('past the /score deadline the request is cancelled and a '
        'TimeoutFailure names the deadline', () async {
      final adapter = _StallingAdapter();
      final api = RiskApiClient(
        baseUrl: 'https://risk.test',
        identity: const DemoIdentityHeaders('rina'),
        dio: Dio()..httpClientAdapter = adapter,
        timeouts: const RouteTimeouts(
          // A slow connect must not stretch the score budget.
          connect: Duration(seconds: 3),
          scoreDeadline: Duration(milliseconds: 50),
        ),
      );
      final sw = Stopwatch()..start();
      final f = await failureOf(api.postScore(samples.scoreRequest));
      expect(f, isA<TimeoutFailure>());
      expect((f as TimeoutFailure).timeout, const Duration(milliseconds: 50));
      expect(sw.elapsedMilliseconds, lessThan(1000));
      await adapter.cancelled.future.timeout(const Duration(seconds: 1));
    });

    test('SocketException (connectionError) → NetworkFailure', () async {
      final api = client(
        FakeHttpClientAdapter(
          (o, _) => throw DioException.connectionError(
            requestOptions: o,
            reason: 'refused',
            error: const SocketException('Connection refused'),
          ),
        ),
      );
      expect(
        await failureOf(api.postScore(samples.scoreRequest)),
        isA<NetworkFailure>(),
      );
    });

    test('raw SocketException from the transport → NetworkFailure', () async {
      final api = client(
        FakeHttpClientAdapter(
          (_, _) => throw const SocketException('Network is unreachable'),
        ),
      );
      final f = await failureOf(api.postScore(samples.scoreRequest));
      expect(f, isA<NetworkFailure>());
      expect(f.message, 'SocketException');
    });

    test('non-JSON 200 body → ContractFailure', () async {
      final api = client(always(() => textBody('<html>captive portal</html>')));
      final f = await failureOf(api.postScore(samples.scoreRequest));
      expect(f, isA<ContractFailure>());
      expect(f.message, contains('not JSON'));
    });

    test(
      'JSON missing a required key → ContractFailure naming the key',
      () async {
        final json = samples.scoreResponse.toJson()..remove('decision');
        final api = client(always(() => jsonBody(json)));
        final f = await failureOf(api.postScore(samples.scoreRequest));
        expect(f, isA<ContractFailure>());
        expect(f.message, contains('"decision"'));
      },
    );

    test('JSON array body → ContractFailure', () async {
      final api = client(always(() => jsonBody([1, 2])));
      expect(
        await failureOf(api.postScore(samples.scoreRequest)),
        isA<ContractFailure>(),
      );
    });

    test(
      'identity provider failure → NetworkFailure, request not sent',
      () async {
        final adapter = always(() => jsonBody(samples.scoreResponse.toJson()));
        final api = client(
          adapter,
          identity: BearerIdentityHeaders(
            () async => throw const SocketException('token refresh'),
          ),
        );
        expect(
          await failureOf(api.postScore(samples.scoreRequest)),
          isA<NetworkFailure>(),
        );
        expect(adapter.requests, isEmpty);
      },
    );

    test('mapDioException covers the remaining types', () {
      final o = RequestOptions(path: '/x');
      expect(
        mapDioException(
          DioException.requestCancelled(requestOptions: o, reason: 'gone'),
        ),
        isA<NetworkFailure>(),
      );
      expect(
        mapDioException(DioException.badCertificate(requestOptions: o)),
        isA<NetworkFailure>(),
      );
      expect(
        mapDioException(
          DioException(requestOptions: o, error: const FormatException('x')),
        ),
        isA<ContractFailure>(),
      );
      expect(
        mapDioException(
          DioException(requestOptions: o, error: const ServerFailure(503)),
        ),
        isA<ServerFailure>(),
      );
      expect(
        mapDioException(DioException(requestOptions: o, message: 'odd')),
        isA<NetworkFailure>().having((n) => n.message, 'message', 'odd'),
      );
    });
  });

  group('server timing', () {
    test('X-Processing-Time-Ms is captured and rounded', () async {
      final adapter = always(
        () => jsonBody(
          samples.scoreResponse.toJson(),
          headers: {'X-Processing-Time-Ms': '12.6'},
        ),
      );
      final api = client(adapter);
      final seen = <int?>[];
      api.serverTiming.addListener(() => seen.add(api.serverTiming.value));

      expect(api.lastServerTimingMs, isNull);
      await api.postScore(samples.scoreRequest);

      expect(api.lastServerTimingMs, 13);
      expect(seen, [13]);
    });

    test('timing is also read from error responses', () async {
      final api = client(
        always(
          () => jsonBody(
            {'detail': 'nope'},
            status: 404,
            headers: {'x-processing-time-ms': '2.0'},
          ),
        ),
      );
      await failureOf(api.approveTrustedContact('nope'));
      expect(api.lastServerTimingMs, 2);
    });

    test('a missing or garbage header leaves the last value alone', () async {
      var calls = 0;
      final api = client(
        FakeHttpClientAdapter(
          (_, _) async => jsonBody(
            samples.scoreResponse.toJson(),
            headers: ++calls == 1
                ? {'X-Processing-Time-Ms': '7'}
                : {'X-Processing-Time-Ms': 'fast'},
          ),
        ),
      );
      await api.postScore(samples.scoreRequest);
      await api.postScore(samples.scoreRequest);
      expect(api.lastServerTimingMs, 7);
    });
  });

  group('health', () {
    test('true only on 200 with status ok', () async {
      final adapter = always(
        () => jsonBody({
          'status': 'ok',
          'service': 'risk-api',
          'model_version': 'stub-0.1',
          'demo_mode': true,
        }),
      );
      expect(await client(adapter).health(), isTrue);
      expect(adapter.last.method, 'GET');
      expect(adapter.last.uri.toString(), 'https://risk.test/health');
      expect(adapter.last.receiveTimeout, const Duration(seconds: 2));
    });

    test(
      'false on degraded status, 5xx, timeout, socket error, non-JSON',
      () async {
        expect(
          await client(always(() => jsonBody({'status': 'degraded'}))).health(),
          isFalse,
        );
        expect(
          await client(always(() => jsonBody({'status': 'ok'}, status: 503)))
              .health(),
          isFalse,
        );
        expect(
          await client(
            FakeHttpClientAdapter(
              (o, _) => throw DioException.receiveTimeout(
                timeout: o.receiveTimeout!,
                requestOptions: o,
              ),
            ),
          ).health(),
          isFalse,
        );
        expect(
          await client(
            FakeHttpClientAdapter(
              (_, _) => throw const SocketException('down'),
            ),
          ).health(),
          isFalse,
        );
        expect(await client(always(() => textBody('nginx'))).health(), isFalse);
      },
    );
  });
}

/// Never answers; completes [cancelled] when dio cancels the request.
class _StallingAdapter implements HttpClientAdapter {
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    unawaited(
      cancelFuture?.then((_) {
        if (!cancelled.isCompleted) cancelled.complete();
      }),
    );
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}
