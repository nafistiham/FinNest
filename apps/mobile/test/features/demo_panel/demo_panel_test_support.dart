/// Fixtures for the demo panel tests: a `ProviderContainer` on the local
/// stores (`FirebaseStatus.absent`), the real bundled assets from disk, a
/// `FakeRiskApi` and a pump helper for the sheet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/demo_panel/logic/demo_panel_controller.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves `assets/demo/*` from disk with a synchronous read wrapped in a
/// future created in the caller's zone. Widget tests run in a fake-async
/// zone: a future completed by real I/O (or warmed up in `runAsync`) lives in
/// the root zone and its completion never reaches the fake zone, so the
/// controller's `await scamScript()` would hang forever.
class SyncDiskAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      Future.value(ByteData.sublistView(File(key).readAsBytesSync()));

  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      Future.value(File(key).readAsStringSync(encoding: utf8));
}

/// What the stub answers once the caller asks for the OTP.
const otpScam = ScamTurnResponse(
  scamType: 'otp_phishing',
  urgency: 'high',
  requestedSecret: 'otp',
  confidence: 0.9,
  evidenceQuote: 'সেই ওটিপি কোডটা আমাকে বলুন',
  recommendedAction: 'hold',
  rollingScore: 0.85,
);

class DemoPanelHarness {
  DemoPanelHarness({ScamTurnResponse scam = otpScam})
    : api = FakeRiskApi(scamTurnResponse: scam, lastServerTimingMs: 42),
      clock = FakeClock(DateTime(2026, 10, 16, 9)),
      native = FakeBhoroshaNative();

  final FakeRiskApi api;
  final FakeClock clock;
  final FakeBhoroshaNative native;

  List<Override> get overrides => [
    riskApiProvider.overrideWithValue(api),
    nativeProvider.overrideWithValue(native),
    clockProvider.overrideWithValue(clock),
    demoAssetsProvider.overrideWithValue(
      DemoAssets(bundle: SyncDiskAssetBundle()),
    ),
  ];

  /// A container signed in as [persona] with the demo-state and user streams
  /// kept alive, so the controller sees the current world.
  Future<ProviderContainer> container({Persona? persona = Persona.rina}) async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    c.listen(currentUserProvider, (_, _) {});
    c.listen(demoStateProvider, (_, _) {});
    if (persona != null) {
      await c.read(authRepoProvider).demoLogin(persona);
    }
    await pumpEventQueue();
    c.listen(demoPanelControllerProvider, (_, _) {});
    await pumpEventQueue();
    return c;
  }
}

DemoPanelController ctl(ProviderContainer c) =>
    c.read(demoPanelControllerProvider.notifier);

DemoPanelState panel(ProviderContainer c) =>
    c.read(demoPanelControllerProvider);

/// The stored document for [uid], as a new subscriber would see it.
Future<DemoState> stored(ProviderContainer c, String uid) =>
    c.read(demoStateRepoProvider).watch(uid).first;

/// [stored] from inside a widget test: the repo's SharedPreferences future
/// lives in the real zone, so read it there and fail fast instead of hanging.
Future<DemoState> storedIn(
  WidgetTester tester,
  ProviderContainer c,
  String uid,
) async {
  final s = await tester.runAsync(
    () => stored(c, uid).timeout(const Duration(seconds: 5)),
  );
  return s!;
}

/// Mounts [child] in the app chrome with the harness overrides; returns the
/// scope's container.
Future<ProviderContainer> pumpDemo(
  WidgetTester tester, {
  required DemoPanelHarness harness,
  required Widget child,
  Persona? persona = Persona.rina,
  List<Override> extraOverrides = const [],
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('bn'),
}) async {
  SharedPreferences.setMockInitialValues({});
  final key = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...harness.overrides, ...extraOverrides],
      child: MaterialApp(
        key: key,
        theme: buildTheme(brightness, locale: locale),
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: child,
      ),
    ),
  );
  final c = ProviderScope.containerOf(key.currentContext!);
  if (persona != null) {
    // Resolves through fake-zone microtasks, which `pump` flushes.
    final login = c.read(authRepoProvider).demoLogin(persona);
    await tester.pump();
    await login;
  }
  await tester.pumpAndSettle();
  return c;
}
