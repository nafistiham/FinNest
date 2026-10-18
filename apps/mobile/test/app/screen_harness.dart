/// Boots the real app (router, theme, Bangla l10n) on the local demo stores
/// with every platform edge faked: `FakeRiskApi`, `FakeBhoroshaNative`,
/// `FakeApaAudio`, a silent IMU source and the bundled assets read from disk.
/// Not a test file.
library;

import 'package:bhorosha/app/app.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:bhorosha/features/send_money/logic/send_money_controller.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local/test_bundle.dart';
import '../features/login/biometric_fakes.dart';

class ScreenHarness {
  ScreenHarness({
    ScoreResponse? score,
    InterveneResponse? intervene,
    this.imu = const NoImuSource(),
    FakeBiometricAuth? biometric,
  }) : api = FakeRiskApi(scoreResponse: score, interveneResponse: intervene),
       native = FakeBhoroshaNative(),
       audio = FakeApaAudio(),
       biometric = biometric ?? FakeBiometricAuth();

  final FakeRiskApi api;
  final FakeBhoroshaNative native;
  final FakeApaAudio audio;
  final ImuSource imu;

  /// A phone with a strong fingerprint that always passes, unless a test
  /// scripts otherwise; Login's `demo_login` button is then the biometric one.
  final FakeBiometricAuth biometric;

  /// The bundled demo data, read from disk once (inside `runAsync`, since
  /// real I/O never completes in the fake-async zone of a widget test) and
  /// then served synchronously so no screen ever awaits a disk read.
  final PreloadedDemoAssets assets = PreloadedDemoAssets();

  Future<void> preloadAssets() => assets.load();

  List<Override> get overrides => [
    riskApiProvider.overrideWithValue(api),
    nativeProvider.overrideWithValue(native),
    apaAudioProvider.overrideWithValue(audio),
    imuSourceProvider.overrideWithValue(imu),
    demoAssetsProvider.overrideWithValue(assets),
    biometricAuthProvider.overrideWithValue(biometric),
    // The screens are tested on the live product path whatever a test run's
    // BEHAVIOUR_MODE define says.
    behaviourStartModeProvider.overrideWithValue(BehaviourMode.live),
  ];
}

/// `DemoAssets` whose reads resolve synchronously after [load]. The app code
/// awaits them as usual; `await` on a [SynchronousFuture] runs inline, so the
/// fake-async zone needs no flush.
class PreloadedDemoAssets extends DemoAssets {
  PreloadedDemoAssets() : super(bundle: DiskAssetBundle());

  Map<String, PersonaSeed>? _personas;
  List<Turn>? _scamScript;
  List<InstalledApp>? _fakeApps;

  Future<void> load() async {
    _personas = await super.personas();
    _scamScript = await super.scamScript();
    _fakeApps = await super.fakeApps();
  }

  Map<String, PersonaSeed> get _p =>
      _personas ?? (throw StateError('call load() inside runAsync first'));

  @override
  Future<Map<String, PersonaSeed>> personas() => SynchronousFuture(_p);

  @override
  Future<PersonaSeed> persona(Persona p) => SynchronousFuture(_p[p.uid]!);

  @override
  PersonaSeed? personaIfLoaded(Persona p) => _personas?[p.uid];

  @override
  Future<List<Turn>> scamScript() => SynchronousFuture(_scamScript!);

  @override
  Future<List<InstalledApp>> fakeApps() => SynchronousFuture(_fakeApps!);
}

/// A Pixel 6 class viewport so the thumb-zone layouts fit as on a phone.
void usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

/// Pumps [BhoroshaApp] with the harness, optionally demo-logs-in [persona]
/// and navigates to [location]. Returns the scope's container.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  required ScreenHarness harness,
  Persona? persona = Persona.rina,
  String? location,
  List<Override> extraOverrides = const [],
}) async {
  usePhoneViewport(tester);
  SharedPreferences.setMockInitialValues({});
  // Disk reads are real I/O: run them outside the fake-async zone.
  await tester.runAsync(harness.preloadAssets);
  final key = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...harness.overrides, ...extraOverrides],
      child: KeyedSubtree(key: key, child: const BhoroshaApp()),
    ),
  );
  final c = ProviderScope.containerOf(key.currentContext!);
  if (persona != null) {
    await c.read(authRepoProvider).demoLogin(persona);
  }
  if (location != null) {
    c.read(routerProvider).go(location);
  }
  await tester.pumpAndSettle();
  return c;
}

GoRouter routerOf(ProviderContainer c) => c.read(routerProvider);

String locationOf(ProviderContainer c) =>
    routerOf(c).routerDelegate.currentConfiguration.uri.toString();

/// Every string currently rendered by a `Text` widget.
List<String> allTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

/// Taps the numpad key showing the Bangla digit for [d].
Future<void> tapDigit(WidgetTester tester, int d) async {
  const bn = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];
  await tester.tap(find.text(bn[d]));
  await tester.pump();
}

Future<void> tapDigits(WidgetTester tester, String digits) async {
  for (final ch in digits.split('')) {
    await tapDigit(tester, int.parse(ch));
  }
}
