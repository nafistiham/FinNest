import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../contracts/samples.dart' as samples;

void main() {
  test('answers with sensible defaults and records every call', () async {
    final api = FakeRiskApi();

    final score = await api.postScore(samples.scoreRequest);
    final intervene = await api.postIntervene(samples.interveneRequest);
    final token = await api.postAppSafetyDemoToken(
      const DemoIntegrityRequest(),
    );
    final latest = await api.getAppSafetyLatest('rina');
    final approved = await api.approveTrustedContact('req_9');
    final declined = await api.declineTrustedContact('req_9');
    final healthy = await api.health();

    expect(score.decision, Decision.allow);
    expect(score.reasons, isEmpty);
    expect(score.actions, isEmpty);
    expect(score.modelVersion, 'fake');
    expect(intervene.audioAssetId, 'apa_generic_caution');
    expect(token, FakeRiskApi.fakeDemoToken);
    expect(token.integrityToken, 'demo.fake');
    expect(latest.known, isFalse);
    expect(approved.status, TrustedContactDecision.statusApproved);
    expect(approved.requestId, 'req_9');
    expect(declined.status, TrustedContactDecision.statusDeclined);
    expect(healthy, isTrue);
    expect(api.lastServerTimingMs, isNull);

    expect(api.calls.map((c) => c.route), [
      RiskRoutes.score,
      RiskRoutes.intervene,
      RiskRoutes.appSafetyDemoToken,
      RiskRoutes.appSafetyLatest,
      RiskRoutes.trustedApprove,
      RiskRoutes.trustedDecline,
      RiskRoutes.health,
    ]);
    expect(api.calls.first.body, samples.scoreRequest.toJson());
    expect(api.calls[2].body, const DemoIntegrityRequest().toJson());
    expect(api.calls[3].body, 'rina');
    expect(api.calls[4].body, 'req_9');
    expect(api.callsTo(RiskRoutes.score), hasLength(1));
  });

  test('canned responses and decision are returned as set', () async {
    final api =
        FakeRiskApi(
            scoreResponse: samples.scoreResponse,
            decision: samples.trustedContactDecision,
          )
          ..interveneResponse = samples.interveneResponse
          ..appSafetyResponse = samples.appSafetyResponse
          ..scamTurnResponse = samples.scamTurnResponse
          ..apaTurnResponse = samples.apaTurnResponse
          ..trustedResponse = samples.trustedContactResponse
          ..signalsResponse = const SignalsResponse(stored: false)
          ..demoTokenResponse = const DemoIntegrityResponse(
            integrityToken: 't',
            bundleHash: 'b',
            expiresInS: 1,
          )
          ..latestResponse = const AppSafetyLatest(uid: 'rina', known: true)
          ..lastServerTimingMs = 42;

    expect(await api.postScore(samples.scoreRequest), samples.scoreResponse);
    expect(
      await api.postIntervene(samples.interveneRequest),
      samples.interveneResponse,
    );
    expect(
      await api.postAppSafety(samples.appSafetyRequest),
      samples.appSafetyResponse,
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
    expect(
      await api.declineTrustedContact('x'),
      samples.trustedContactDecision,
    );
    expect((await api.postSignals(samples.signalsRequest)).stored, isFalse);
    expect(
      (await api.postAppSafetyDemoToken(const DemoIntegrityRequest()))
          .integrityToken,
      't',
    );
    expect((await api.getAppSafetyLatest('rina')).known, isTrue);
    expect(api.lastServerTimingMs, 42);
  });

  test(
    'throws the configured failure for a route and records the call',
    () async {
      final api = FakeRiskApi()
        ..failures[RiskRoutes.score] = const TimeoutFailure()
        ..failures[RiskRoutes.health] = const NetworkFailure()
        ..healthy = true;

      await expectLater(
        api.postScore(samples.scoreRequest),
        throwsA(isA<TimeoutFailure>()),
      );
      expect(await api.health(), isFalse);
      expect(
        await api
            .postIntervene(samples.interveneRequest)
            .then((r) => r.intervene),
        isTrue,
      );
      expect(api.calls.map((c) => c.route), [
        RiskRoutes.score,
        RiskRoutes.health,
        RiskRoutes.intervene,
      ]);
    },
  );

  test('healthy=false answers false without a failure', () async {
    expect(await FakeRiskApi(healthy: false).health(), isFalse);
  });

  test('holdIntervene gates the call until released', () async {
    final api = FakeRiskApi();
    final release = api.holdIntervene();
    final order = <String>[];

    final pending = api
        .postIntervene(samples.interveneRequest)
        .then((_) => order.add('intervene'));
    await api.postScore(samples.scoreRequest);
    order.add('score');
    await Future<void>.delayed(Duration.zero);

    expect(order, ['score']);
    expect(api.calls.map((c) => c.route), [
      RiskRoutes.intervene,
      RiskRoutes.score,
    ]);

    release();
    release(); // idempotent
    await pending;
    expect(order, ['score', 'intervene']);

    // Later calls are not held.
    expect(
      await api
          .postIntervene(samples.interveneRequest)
          .timeout(const Duration(milliseconds: 100)),
      FakeRiskApi.genericCaution,
    );
  });

  test('delay applies to every call', () async {
    final api = FakeRiskApi(delay: const Duration(milliseconds: 30));
    final sw = Stopwatch()..start();
    await api.postScore(samples.scoreRequest);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(25));
  });

  test('reset clears the log, failures and open gates', () async {
    final api = FakeRiskApi()
      ..failures[RiskRoutes.score] = const NetworkFailure();
    api.holdIntervene();
    final pending = api.postIntervene(samples.interveneRequest);

    api.reset();

    expect(api.calls, isEmpty);
    expect(api.failures, isEmpty);
    expect(await pending, FakeRiskApi.genericCaution);
    expect(
      (await api.postScore(samples.scoreRequest)).decision,
      Decision.allow,
    );
  });
}
