import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/app_safety_flow.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../data/local/test_bundle.dart';
import 'safety_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRiskApi api;
  late FakeBhoroshaNative native;
  late AppSafetyFlow flow;

  setUp(() {
    api = FakeRiskApi(appSafetyResponse: blockResponse);
    native = FakeBhoroshaNative(bundle: realBundle);
    flow = AppSafetyFlow(api: api, native: native, demoFakeApps: [takaNow]);
  });

  Map<String, dynamic> bodyOf(String route) {
    final calls = api.callsTo(route).toList();
    expect(calls, hasLength(1), reason: 'exactly one call to $route');
    return calls.single.body! as Map<String, dynamic>;
  }

  Map<String, dynamic> checkBody() => bodyOf(RiskRoutes.appSafety);
  Map<String, dynamic> demoTokenBody() => bodyOf(RiskRoutes.appSafetyDemoToken);

  List<String> packagesOf(Map<String, dynamic> body) =>
      (body['installed_apps'] as List)
          .map((a) => (a as Map)['package'] as String)
          .toList();

  group('scan failed', () {
    for (final forced in [null, SafetyVerdict.block]) {
      test('nothing is posted and the check fails as "could not verify" '
          '(forced ${forced?.wire ?? 'none'})', () async {
        native.bundle = AppSafetyBundle.unavailable;
        await expectLater(
          flow.check(demo: DemoState(forcedSafetyVerdict: forced)),
          throwsA(isA<AppSafetyScanFailed>()),
        );
        expect(api.callsTo(RiskRoutes.appSafety), isEmpty);
        expect(api.callsTo(RiskRoutes.appSafetyDemoToken), isEmpty);
      });
    }
  });

  group('fake apps', () {
    for (final forced in [SafetyVerdict.caution, SafetyVerdict.block]) {
      test(
        'appended after the real bundle for forced ${forced.wire}',
        () async {
          final response = await flow.check(
            demo: DemoState(forcedSafetyVerdict: forced),
          );

          expect(response, blockResponse);
          expect(packagesOf(checkBody()), [
            'com.example.bank',
            'com.demo.takanow',
          ]);
          expect(native.bundleCalls, 1);
          // The device half is the real one, untouched.
          expect(checkBody()['device'], realBundle.device.toJson());
        },
      );
    }

    test(
      'skipped when a real integrity token is bound to the bundle',
      () async {
        native.attestation = const AppSafetyAttestation(
          bundle: realBundle,
          bundleHash: 'abc',
          integrityToken: 'play.real.token',
        );
        await flow.check(
          demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
        );
        expect(packagesOf(checkBody()), ['com.example.bank']);
        expect(checkBody()['integrity_token'], 'play.real.token');
      },
    );

    test('appended even when the native bundle is empty (emulator)', () async {
      native.bundle = AppSafetyBundle.empty;
      await flow.check(
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
      );
      expect(packagesOf(checkBody()), ['com.demo.takanow']);
    });

    test('not sent for forced SAFE', () async {
      await flow.check(
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.safe),
      );
      expect(packagesOf(checkBody()), ['com.example.bank']);
    });

    test('not sent without a forced verdict', () async {
      await flow.check(demo: DemoState.initial);
      expect(packagesOf(checkBody()), ['com.example.bank']);
      expect(flow.lastRequest?.installedApps, [realApp]);
    });

    test('deduplicated by package: the real entry wins', () async {
      native.bundle = const AppSafetyBundle(
        installedApps: [
          realApp,
          InstalledApp(package: 'com.demo.takanow', label: 'Real TakaNow'),
        ],
        device: DeviceState(),
      );
      await flow.check(
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
      );
      expect(packagesOf(checkBody()), ['com.example.bank', 'com.demo.takanow']);
      final labels = (checkBody()['installed_apps'] as List)
          .map((a) => (a as Map)['label'])
          .toList();
      expect(labels, ['Bank', 'Real TakaNow']);
    });

    test('the bundled fake_apps.json carries TakaNow', () async {
      final assets = DemoAssets(bundle: DiskAssetBundle());
      final fromDisk = AppSafetyFlow(
        api: api,
        native: native,
        demoFakeApps: await assets.fakeApps(),
      );
      await fromDisk.check(
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.caution),
      );
      expect(packagesOf(checkBody()), contains('com.demo.takanow'));
    });

    test('keeps every fake entry when the real list hits the cap', () {
      final many = List.generate(
        AppSafetyRequest.maxInstalledApps,
        (i) => InstalledApp(package: 'com.app$i'),
      );
      final apps = flow.installedAppsFor(
        AppSafetyBundle(installedApps: many, device: const DeviceState()),
        const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
      );
      expect(apps, hasLength(AppSafetyRequest.maxInstalledApps));
      expect(apps.last.package, 'com.demo.takanow');
    });
  });

  group('integrity token', () {
    test(
      'real Play Integrity token from the attestation is sent as-is',
      () async {
        native.attestation = const AppSafetyAttestation(
          bundle: realBundle,
          bundleHash: 'abc',
          integrityToken: 'play.real.token',
        );
        await flow.check(demo: DemoState.initial);

        expect(checkBody()['integrity_token'], 'play.real.token');
        expect(api.callsTo(RiskRoutes.appSafetyDemoToken), isEmpty);
      },
    );

    test('an explicit token wins over everything', () async {
      native.integrityToken = 'play.real.token';
      await flow.check(demo: DemoState.initial, integrityToken: 'tok-123');
      expect(checkBody()['integrity_token'], 'tok-123');
      expect(api.callsTo(RiskRoutes.appSafetyDemoToken), isEmpty);
    });

    test(
      'no native token: a demo token is minted over the identical lists',
      () async {
        api.demoTokenResponse = const DemoIntegrityResponse(
          integrityToken: 'demo.minted.sig',
          bundleHash: 'h',
          expiresInS: 600,
        );
        await flow.check(
          demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
        );

        final mint = demoTokenBody();
        final check = checkBody();
        expect(api.calls.map((c) => c.route), [
          RiskRoutes.appSafetyDemoToken,
          RiskRoutes.appSafety,
        ]);
        // The fake app is in both bodies and the lists are byte-identical.
        expect(packagesOf(mint), ['com.example.bank', 'com.demo.takanow']);
        expect(mint['installed_apps'], check['installed_apps']);
        expect(mint['device'], check['device']);
        expect(check['integrity_token'], 'demo.minted.sig');
        // Clean scenario defaults.
        expect(mint['apps_detected'], isEmpty);
        expect(mint['app_recognition'], 'PLAY_RECOGNIZED');
        expect(mint['device_recognition'], ['MEETS_DEVICE_INTEGRITY']);
        expect(mint['bound'], isTrue);
      },
    );

    test(
      'demo-token failure (404 outside demo mode) proceeds with null',
      () async {
        api.failures[RiskRoutes.appSafetyDemoToken] = const ServerFailure(404);
        final response = await flow.check(demo: DemoState.initial);

        expect(response, blockResponse);
        expect(checkBody()['integrity_token'], isNull);
      },
    );

    test('an empty minted token is treated as none', () async {
      api.demoTokenResponse = const DemoIntegrityResponse(
        integrityToken: '',
        bundleHash: '',
        expiresInS: 0,
      );
      await flow.check(demo: DemoState.initial);
      expect(checkBody()['integrity_token'], isNull);
    });
  });

  group('integrity scenario mapping', () {
    const cases = <String?, Map<String, Object>>{
      null: {
        'apps_detected': <String>[],
        'app_recognition': 'PLAY_RECOGNIZED',
        'device_recognition': ['MEETS_DEVICE_INTEGRITY'],
        'bound': true,
      },
      'UNKNOWN_CONTROLLING': {
        'apps_detected': ['UNKNOWN_CONTROLLING'],
        'app_recognition': 'PLAY_RECOGNIZED',
        'device_recognition': ['MEETS_DEVICE_INTEGRITY'],
        'bound': true,
      },
      'UNRECOGNIZED_VERSION': {
        'apps_detected': <String>[],
        'app_recognition': 'UNRECOGNIZED_VERSION',
        'device_recognition': ['MEETS_DEVICE_INTEGRITY'],
        'bound': true,
      },
      'MEETS_VIRTUAL_INTEGRITY': {
        'apps_detected': <String>[],
        'app_recognition': 'PLAY_RECOGNIZED',
        'device_recognition': ['MEETS_VIRTUAL_INTEGRITY'],
        'bound': true,
      },
      'unbound': {
        'apps_detected': <String>[],
        'app_recognition': 'PLAY_RECOGNIZED',
        'device_recognition': ['MEETS_DEVICE_INTEGRITY'],
        'bound': false,
      },
    };

    for (final entry in cases.entries) {
      test('scenario ${entry.key ?? 'null'}', () async {
        await flow.check(demo: DemoState(integrityScenario: entry.key));
        final mint = demoTokenBody();
        for (final field in entry.value.entries) {
          expect(mint[field.key], field.value, reason: field.key);
        }
        expect(mint['play_protect_verdict'], 'NO_ISSUES');
        expect(mint['installed_apps'], checkBody()['installed_apps']);
      });
    }

    test('demoTokenRequest binds the given lists', () {
      final r = AppSafetyFlow.demoTokenRequest(
        apps: const [takaNow],
        device: realBundle.device,
        scenario: 'unbound',
      );
      expect(r.installedApps, [takaNow]);
      expect(r.device, realBundle.device);
      expect(r.bound, isFalse);
    });
  });

  group('latest', () {
    test('returns the standing verdict', () async {
      api.latestResponse = blockLatest;
      expect(await flow.latest('rina'), blockLatest);
      expect(api.callsTo(RiskRoutes.appSafetyLatest).single.body, 'rina');
    });

    test('null on any ApiFailure (route may not be deployed)', () async {
      api.failures[RiskRoutes.appSafetyLatest] = const ServerFailure(404);
      expect(await flow.latest('rina'), isNull);
    });
  });

  test(
    'ApiFailure propagates unchanged and lastRequest is still recorded',
    () async {
      api.failures[RiskRoutes.appSafety] = const TimeoutFailure();
      await expectLater(
        flow.check(demo: DemoState.initial),
        throwsA(isA<TimeoutFailure>()),
      );
      expect(flow.lastRequest?.installedApps, [realApp]);
    },
  );
}
