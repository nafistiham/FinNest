/// Shared fixtures for the safety feature tests: canned responses, the fake
/// TakaNow entry, and a pump helper that mounts a widget inside the app's
/// theme, Bangla localisation and a `ProviderScope` with fakes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/external_links.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

const takaNow = InstalledApp(
  package: 'com.demo.takanow',
  label: 'TakaNow',
  permissions: ['android.permission.READ_SMS'],
  hasAccessibilityService: true,
  accessibilityEnabled: true,
  targetSdk: 28,
);

const realApp = InstalledApp(
  package: 'com.example.bank',
  label: 'Bank',
  installer: 'com.android.vending',
  version: '1.0',
);

const realBundle = AppSafetyBundle(
  installedApps: [realApp],
  device: DeviceState(devOptions: true),
);

const blockFinding = Finding(
  package: 'com.demo.takanow',
  signal: 'SIDELOADED_ACCESSIBILITY',
  severity: 'critical',
  evidence: 'installer=null, accessibility_enabled=true',
  explanationBn: 'এই অ্যাপটি সাইডলোড করা এবং আপনার স্ক্রিন পড়তে পারে।',
  explanationEn: 'This app is sideloaded and can read your screen.',
  titleBn: 'অজানা অ্যাপ আপনার স্ক্রিন পড়ছে',
  titleEn: 'Unknown app reads your screen',
);

const mediumFinding = Finding(
  package: 'com.example.bank',
  signal: 'LOAN_APP_DATA_HARVEST',
  severity: 'medium',
  evidence: 'READ_CONTACTS, READ_MEDIA_IMAGES',
  explanationBn: 'এই অ্যাপ আপনার কন্ট্যাক্ট ও ছবি নিতে চায়।',
  explanationEn: 'This app wants your contacts and photos.',
);

const deviceFinding = Finding(
  package: '',
  signal: 'DEV_OPTIONS_ON',
  severity: 'low',
  evidence: 'dev_options=true',
  explanationBn: 'ডেভেলপার অপশন চালু আছে।',
  explanationEn: 'Developer options are on.',
  titleBn: 'ডেভেলপার অপশন চালু',
  titleEn: 'Developer options on',
  scope: Finding.scopeDevice,
);

const takaNowTarget = UninstallTarget(
  package: 'com.demo.takanow',
  label: 'TakaNow',
  primarySignal: 'SIDELOADED_ACCESSIBILITY',
  deepLink: 'package:com.demo.takanow',
);

const safeResponse = AppSafetyResponse(
  verdict: SafetyVerdict.safe,
  riskScore: 0.02,
  findings: [],
  recommendedAction: 'none',
  appsToUninstall: [],
  userMessageBn: 'আপনার ফোনে কোনো সমস্যা পাওয়া যায়নি।',
  userMessageEn: 'Nothing wrong was found on your phone.',
  simulatedVerdict: false,
  modelVersion: 'test',
  attestation: 'device',
  resolution: 'NONE',
);

const cautionResponse = AppSafetyResponse(
  verdict: SafetyVerdict.caution,
  riskScore: 0.55,
  findings: [mediumFinding, deviceFinding],
  recommendedAction: 'review',
  appsToUninstall: [],
  userMessageBn: 'Bank অ্যাপটি বেশি অনুমতি চাইছে, সাবধান থাকুন।',
  userMessageEn: 'Bank asks for too many permissions, be careful.',
  simulatedVerdict: false,
  modelVersion: 'test',
  attestation: 'device',
  resolution: 'FIX_PHONE_AND_RECHECK',
  // Sent explicitly: the contract default is false.
  recheckLiftsBlock: true,
);

const blockResponse = AppSafetyResponse(
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  findings: [blockFinding, mediumFinding],
  recommendedAction: 'uninstall',
  appsToUninstall: ['com.demo.takanow'],
  userMessageBn: 'TakaNow অ্যাপটি বিপজ্জনক। এখনই আনইনস্টল করুন।',
  userMessageEn: 'TakaNow is dangerous. Uninstall it now.',
  simulatedVerdict: true,
  modelVersion: 'test',
  attestation: 'device',
  resolution: 'UNINSTALL_AND_RECHECK',
  recheckLiftsBlock: true,
  uninstallTargets: [takaNowTarget],
  checkId: 'chk-1',
);

/// A modded-app BLOCK: nothing to uninstall, reinstall from Play instead.
const reinstallResponse = AppSafetyResponse(
  verdict: SafetyVerdict.block,
  riskScore: 0.9,
  findings: [],
  recommendedAction: 'reinstall',
  appsToUninstall: [],
  userMessageBn: 'এই ভরসা অ্যাপটি আসল নয়।',
  userMessageEn: 'This Bhorosha app is not genuine.',
  simulatedVerdict: true,
  attestation: 'tampered',
  resolution: 'REINSTALL_FROM_PLAY',
  recheckLiftsBlock: false,
);

const callBankResponse = AppSafetyResponse(
  verdict: SafetyVerdict.block,
  riskScore: 0.99,
  findings: [],
  recommendedAction: 'call_bank',
  appsToUninstall: [],
  userMessageBn: 'আপনার অ্যাকাউন্ট সুরক্ষার জন্য ব্যাংকে কথা বলুন।',
  userMessageEn: 'Talk to the bank to protect your account.',
  simulatedVerdict: true,
  attestation: 'mismatch',
  resolution: 'CALL_BANK',
  recheckLiftsBlock: false,
);

const rinaProfile = UserProfile(
  uid: 'rina',
  nameBn: 'রিনা',
  nameEn: 'Rina',
  phoneMasked: '017****123',
  persona: Persona.rina,
  trustedContactUid: 'rafiq',
  p95SendBdt: 5000,
  acctId: 'acct_rina',
  balanceBdt: 12000,
);

const blockLatest = AppSafetyLatest(
  uid: 'rina',
  known: true,
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  flaggedPackages: ['com.demo.takanow'],
  attestation: 'device',
  checkedAt: '2026-10-16T10:00:00+00:00',
  validUntil: '2026-10-16T22:00:00+00:00',
);

/// Every user-visible string the Bangla ARB carries (placeholders excluded).
Set<String> arbStringsBn() {
  final raw = jsonDecode(File('lib/l10n/app_bn.arb').readAsStringSync());
  return {
    for (final entry in (raw as Map<String, dynamic>).entries)
      if (!entry.key.startsWith('@') &&
          entry.value is String &&
          !(entry.value as String).contains('{'))
        entry.value as String,
  };
}

/// Fakes and the overrides that plug them into the safety providers.
class SafetyHarness {
  SafetyHarness({
    this.demo = DemoState.initial,
    AppSafetyResponse response = safeResponse,
    AppSafetyBundle bundle = realBundle,
    this.fakeApps = const [takaNow],
    this.user,
    this.launchResult = true,
  }) : api = FakeRiskApi(appSafetyResponse: response),
       native = FakeBhoroshaNative(bundle: bundle);

  final FakeRiskApi api;
  final FakeBhoroshaNative native;
  final List<InstalledApp> fakeApps;
  final DemoState demo;

  /// Signed-in user for the `latest` fallback; `null` keeps "signed out".
  final UserProfile? user;

  /// What the fake URI launcher answers.
  bool launchResult;

  /// URIs the resolution block tried to open, in order.
  final List<Uri> launched = [];

  List<Override> get overrides => [
    riskApiProvider.overrideWithValue(api),
    nativeProvider.overrideWithValue(native),
    demoFakeAppsProvider.overrideWith((_) async => fakeApps),
    demoStateProvider.overrideWith((_) => Stream.value(demo)),
    currentUserProvider.overrideWith((_) => Stream.value(user)),
    uriLauncherProvider.overrideWithValue((uri) async {
      launched.add(uri);
      return launchResult;
    }),
  ];

  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    return c;
  }
}

/// Mounts [child] (or [home] via [router]) in the app chrome with [harness].
/// Returns the `ProviderContainer` of the scope for direct reads.
Future<ProviderContainer> pumpSafety(
  WidgetTester tester, {
  required SafetyHarness harness,
  Widget? child,
  RouterConfig<Object>? router,
  Locale locale = const Locale('bn'),
  Brightness brightness = Brightness.light,
}) async {
  assert((child == null) != (router == null), 'pass child or router');
  final key = GlobalKey();
  final app = router != null
      ? MaterialApp.router(
          key: key,
          theme: buildTheme(brightness, locale: locale),
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        )
      : MaterialApp(
          key: key,
          theme: buildTheme(brightness, locale: locale),
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: child,
        );
  await tester.pumpWidget(
    ProviderScope(overrides: harness.overrides, child: app),
  );
  await tester.pump();
  return ProviderScope.containerOf(key.currentContext!);
}

/// Every `Text` currently on screen, as plain strings.
List<String> allTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

/// Loads the bundled SolaimanLipi (400 and 700) so layout tests measure real
/// Bangla widths; the default test font draws every glyph as a 1 em box,
/// which overstates Bangla text roughly twofold. Call from `setUpAll`.
Future<void> loadBanglaFont() async {
  ByteData read(String path) =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final loader = FontLoader('SolaimanLipi')
    ..addFont(Future.value(read('assets/fonts/SolaimanLipi.ttf')))
    ..addFont(Future.value(read('assets/fonts/SolaimanLipiBold.ttf')));
  await loader.load();
}

/// [loadBanglaFont] plus Roboto from the Flutter SDK (the platform font the
/// English theme falls to on Android), so English text measures like the
/// phone instead of the 1 em test glyphs. No-op for Roboto when the SDK path
/// is unknown.
Future<void> loadAppFonts() async {
  await loadBanglaFont();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  if (!File('$dir/Roboto-Regular.ttf').existsSync()) return;
  ByteData read(String path) =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final loader = FontLoader('Roboto');
  for (final f in const [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    if (File('$dir/$f').existsSync()) {
      loader.addFont(Future.value(read('$dir/$f')));
    }
  }
  await loader.load();
}
