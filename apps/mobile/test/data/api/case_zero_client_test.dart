import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/case_zero_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_http_adapter.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/case_zero/$name').readAsStringSync())
        as Map<String, dynamic>;

CaseZeroClient czClient(
  FakeHttpClientAdapter adapter, {
  Duration deadline = const Duration(seconds: 3),
}) => CaseZeroClient(
  Dio()..httpClientAdapter = adapter,
  'https://cz.test',
  payeeRiskDeadline: deadline,
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
  test('GET /api/payee-risk parses the live list, no auth headers', () async {
    final adapter = always(() => jsonBody(fixture('payee_risk.json')));
    final risk = await czClient(adapter).getPayeeRisk();

    expect(risk.version, 'payee-risk/1');
    expect(risk.payees.single.acctId, 'acct_00036');
    expect(risk.payees.single.role, 'mule_L2');
    final req = adapter.last;
    expect(req.method, 'GET');
    expect(req.uri.toString(), 'https://cz.test/api/payee-risk');
    expect(req.headers.containsKey('X-Demo-User'), isFalse);
    expect(req.headers.containsKey('Authorization'), isFalse);
    expect(req.receiveTimeout, const Duration(seconds: 3));
  });

  test('3 s default deadline; a stalled server → TimeoutFailure', () async {
    expect(
      czClient(always(() => jsonBody({}))).payeeRiskDeadline,
      const Duration(seconds: 3),
    );
    final api = czClient(
      FakeHttpClientAdapter(
        (_, _) => Future<ResponseBody>.delayed(
          const Duration(milliseconds: 400),
          () => jsonBody(fixture('payee_risk.json')),
        ),
      ),
      deadline: const Duration(milliseconds: 40),
    );
    final sw = Stopwatch()..start();
    final f = await failureOf(api.getPayeeRisk());
    expect(f, isA<TimeoutFailure>());
    expect(sw.elapsedMilliseconds, lessThan(350));
  });

  test('a 5xx is a ServerFailure, a bad body a ContractFailure', () async {
    expect(
      await failureOf(
        czClient(always(() => jsonBody({}, status: 503))).getPayeeRisk(),
      ),
      isA<ServerFailure>().having((s) => s.status, 'status', 503),
    );
    expect(
      await failureOf(
        czClient(always(() => jsonBody({'payees': <Object>[]}))).getPayeeRisk(),
      ),
      isA<ContractFailure>(),
    );
    expect(
      await failureOf(
        czClient(always(() => textBody('<html>'))).getPayeeRisk(),
      ),
      isA<ContractFailure>(),
    );
  });

  test('AppEnv points the client and the console at the Case Zero root', () {
    // Without defines both default to a local Case Zero for the emulator.
    const root = 'http://10.0.2.2:8090';
    expect(AppEnv.caseZeroUrl, root);
    expect(AppEnv.consoleUrl, root);
  });
}
