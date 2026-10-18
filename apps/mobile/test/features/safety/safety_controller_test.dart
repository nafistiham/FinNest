import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/session/logic/session_reset.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'safety_test_support.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('starts as null and does not check on its own', () async {
    final h = SafetyHarness();
    final c = h.container();
    c.listen(safetyControllerProvider, (_, _) {});

    expect(
      c.read(safetyControllerProvider),
      const AsyncData<AppSafetyResponse?>(null),
    );
    expect(await c.read(safetyControllerProvider.future), isNull);
    expect(c.read(lastSafetyVerdictProvider), isNull);
    expect(h.api.calls, isEmpty);
    expect(h.native.bundleCalls, 0);
  });

  test('refresh: loading, then the response and the verdict', () async {
    final h = SafetyHarness(response: blockResponse);
    final c = h.container();
    final seen = <AsyncValue<AppSafetyResponse?>>[];
    c.listen(safetyControllerProvider, (_, next) => seen.add(next));

    final release = h.api.hold(RiskRoutes.appSafety);
    final done = c.read(safetyControllerProvider.notifier).refresh();
    await pumpEventQueue();
    expect(c.read(safetyControllerProvider).isLoading, isTrue);
    expect(c.read(lastSafetyVerdictProvider), isNull);

    release();
    await done;
    expect(c.read(safetyControllerProvider).value, blockResponse);
    expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.block);
    expect(seen.last, const AsyncData<AppSafetyResponse?>(blockResponse));
  });

  test('refresh sends the fake app for a forced BLOCK demo state', () async {
    final h = SafetyHarness(
      response: blockResponse,
      demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
    );
    final c = h.container();
    c.listen(safetyControllerProvider, (_, _) {});

    await c.read(safetyControllerProvider.notifier).refresh();
    final body =
        h.api.callsTo(RiskRoutes.appSafety).single.body!
            as Map<String, dynamic>;
    final packages = (body['installed_apps'] as List)
        .map((a) => (a as Map)['package'])
        .toList();
    expect(packages, contains('com.demo.takanow'));
    expect(c.read(safetyAppLabelsProvider), {
      'com.example.bank': 'Bank',
      'com.demo.takanow': 'TakaNow',
    });
  });

  test(
    'refresh error: ApiFailure in state, verdict null, no user → no fallback',
    () async {
      final h = SafetyHarness(response: blockResponse);
      h.api.failures[RiskRoutes.appSafety] = const ServerFailure(503);
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});

      await c.read(safetyControllerProvider.notifier).refresh();
      final state = c.read(safetyControllerProvider);
      expect(state.hasError, isTrue);
      expect(state.error, isA<ServerFailure>());
      expect(c.read(lastSafetyVerdictProvider), isNull);
      expect(c.read(safetyLatestFallbackProvider), isNull);
      expect(h.api.callsTo(RiskRoutes.appSafetyLatest), isEmpty);

      // A later success replaces the error.
      h.api.failures.clear();
      await c.read(safetyControllerProvider.notifier).refresh();
      expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.block);
    },
  );

  group('latest fallback', () {
    test('a failed check falls back to the standing verdict', () async {
      final h = SafetyHarness(response: safeResponse, user: rinaProfile);
      h.api.failures[RiskRoutes.appSafety] = const TimeoutFailure();
      h.api.latestResponse = blockLatest;
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});
      c.listen(currentUserProvider, (_, _) {});
      await pumpEventQueue();

      await c.read(safetyControllerProvider.notifier).refresh();
      expect(c.read(safetyControllerProvider).hasError, isTrue);
      expect(h.api.callsTo(RiskRoutes.appSafetyLatest).single.body, 'rina');
      expect(c.read(safetyLatestFallbackProvider), blockLatest);
      expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.block);

      // The next successful check clears the fallback.
      h.api.failures.clear();
      await c.read(safetyControllerProvider.notifier).refresh();
      expect(c.read(safetyLatestFallbackProvider), isNull);
      expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.safe);
    });

    test('unknown or failing latest leaves no fallback', () async {
      final h = SafetyHarness(response: safeResponse, user: rinaProfile);
      h.api.failures[RiskRoutes.appSafety] = const TimeoutFailure();
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});
      c.listen(currentUserProvider, (_, _) {});
      await pumpEventQueue();

      await c.read(safetyControllerProvider.notifier).refresh();
      expect(c.read(safetyLatestFallbackProvider), isNull);

      h.api.failures[RiskRoutes.appSafetyLatest] = const ServerFailure(404);
      await c.read(safetyControllerProvider.notifier).refresh();
      expect(c.read(safetyLatestFallbackProvider), isNull);
      expect(c.read(lastSafetyVerdictProvider), isNull);
    });
  });

  group('resume re-check', () {
    /// Leaves the app and comes back along the transitions the platform
    /// really sends; AppLifecycleListener asserts on illegal jumps.
    Future<void> cycle() async {
      for (final s in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(s);
      }
      await pumpEventQueue();
    }

    tearDown(() {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    test(
      'openUninstall opens the package and arms a re-check on resume',
      () async {
        final h = SafetyHarness(response: blockResponse);
        final c = h.container();
        c.listen(safetyControllerProvider, (_, _) {});
        final controller = c.read(safetyControllerProvider.notifier);
        await controller.refresh();
        expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));

        await controller.openUninstall(takaNowTarget);
        expect(h.native.openedPackages, ['com.demo.takanow']);
        expect(controller.pendingRecheck, isTrue);

        await cycle();
        expect(controller.pendingRecheck, isFalse);
        expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));

        // Only once per uninstall.
        await cycle();
        expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));
      },
    );

    test('a resume without a pending uninstall does nothing', () async {
      final h = SafetyHarness(response: blockResponse);
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});
      await c.read(safetyControllerProvider.notifier).refresh();

      await cycle();
      expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));
    });

    test('a disposed controller stops listening', () async {
      final h = SafetyHarness(response: blockResponse);
      final c = ProviderContainer(overrides: h.overrides);
      c.listen(safetyControllerProvider, (_, _) {});
      final controller = c.read(safetyControllerProvider.notifier);
      await controller.openUninstall(takaNowTarget);
      c.dispose();

      await cycle();
      expect(h.api.callsTo(RiskRoutes.appSafety), isEmpty);
    });
  });

  test('a missing fake_apps asset degrades to an empty list', () async {
    final h = SafetyHarness();
    // No demoFakeAppsProvider override and an asset bundle that throws: the
    // provider must swallow that and the check must still run.
    final c = ProviderContainer(
      overrides: [
        riskApiProvider.overrideWithValue(h.api),
        nativeProvider.overrideWithValue(h.native),
        demoStateProvider.overrideWith((_) => Stream.value(h.demo)),
        demoAssetsProvider.overrideWithValue(
          DemoAssets(bundle: _MissingAssets()),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(safetyControllerProvider, (_, _) {});
    expect(await c.read(demoFakeAppsProvider.future), isEmpty);
    await c.read(safetyControllerProvider.notifier).refresh();
    expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.safe);
  });

  group('session reset', () {
    test(
      'a persona switch drops the previous verdict and its fallback',
      () async {
        final h = SafetyHarness(response: blockResponse);
        final c = h.container();
        c.listen(safetyControllerProvider, (_, _) {});
        await c.read(safetyControllerProvider.notifier).refresh();
        expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.block);

        await resetSessionState(c.read);
        expect(c.read(safetyControllerProvider).value, isNull);
        expect(c.read(safetyLatestFallbackProvider), isNull);
        expect(c.read(lastSafetyVerdictProvider), isNull);
      },
    );

    test('a check still in flight when the reset lands is dropped', () async {
      final h = SafetyHarness(response: blockResponse);
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});
      final release = h.api.hold(RiskRoutes.appSafety);
      final done = c.read(safetyControllerProvider.notifier).refresh();
      await pumpEventQueue();

      c.read(safetyControllerProvider.notifier).reset();
      release();
      await done;
      expect(c.read(lastSafetyVerdictProvider), isNull);

      // The next check runs normally.
      await c.read(safetyControllerProvider.notifier).refresh();
      expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.block);
    });
  });
}

class _MissingAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => throw FlutterError('no asset $key');

  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      throw FlutterError('no asset $key');
}
