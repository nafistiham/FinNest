/// Mounts a finance screen in the app chrome (theme, Bangla l10n) on the
/// local stores: the bundled personas read from disk, the local ledger, and
/// `LocalFinanceRepo` over mocked SharedPreferences. Not a test file.
library;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/screen_harness.dart' show usePhoneViewport;
import '../../data/local/test_bundle.dart';

/// Pumps [child] signed in as [persona]. Returns the scope's container.
Future<ProviderContainer> pumpFinance(
  WidgetTester tester, {
  required Widget child,
  Persona persona = Persona.rina,
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('bn'),
  Size? size,
  List<Override> overrides = const [],
}) async {
  if (size == null) {
    usePhoneViewport(tester);
  } else {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = size * 3;
    addTearDown(tester.view.reset);
  }
  SharedPreferences.setMockInitialValues({});
  final assets = DemoAssets(bundle: DiskAssetBundle());
  // Disk reads are real I/O: run them outside the fake-async zone.
  final profile = await tester.runAsync(
    () async => (await assets.persona(persona)).profile,
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        demoAssetsProvider.overrideWithValue(assets),
        currentUserProvider.overrideWith((_) => Stream.value(profile)),
        ...overrides,
      ],
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
  // Seed the local ledger in the real zone too: `openDps` is the first thing
  // to touch it from a screen, and a seed awaited inside the fake-async test
  // zone never resolves.
  await tester.runAsync(
    () => c.read(ledgerRepoProvider).watchRecent(persona.uid).first,
  );
  await tester.pumpAndSettle();
  return c;
}

/// Pumps [build] at 360 x 640 and 412 x 915, in both brightnesses and both
/// languages; any overflow fails through the framework's error reporting.
Future<void> pumpFinanceEverywhere(
  WidgetTester tester,
  Widget Function() build, {
  Persona persona = Persona.rina,
}) async {
  for (final size in const [Size(360, 640), Size(412, 915)]) {
    for (final b in Brightness.values) {
      for (final l in const [Locale('bn'), Locale('en')]) {
        await pumpFinance(
          tester,
          child: build(),
          persona: persona,
          brightness: b,
          locale: l,
          size: size,
        );
        expect(tester.takeException(), isNull, reason: '$size $b $l');
      }
    }
  }
}
