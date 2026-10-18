/// Pumps a widget inside the app theme in a chosen preset, brightness,
/// locale and width, for the shared-widget and theme tests. Not a test file.
library;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.x contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Sets a [width] x [height] dp phone viewport for this test.
void useViewport(
  WidgetTester tester, {
  double width = 360,
  double height = 800,
}) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = Size(width * 3, height * 3);
  addTearDown(tester.view.reset);
}

Widget themedApp(
  Widget child, {
  Brightness brightness = Brightness.light,
  BhPreset preset = BhPreset.teal,
  Locale locale = const Locale('bn'),
  List<Override> overrides = const [],
  bool scaffold = true,
  bool disableAnimations = false,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildTheme(brightness, preset: preset, locale: locale),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: disableAnimations
          ? (context, c) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: c!,
            )
          : null,
      home: scaffold
          ? Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: child,
              ),
            )
          : child,
    ),
  );
}

/// Pumps [build] in both brightnesses, both locales and at 360 and 412 dp;
/// any overflow fails the test through the framework's error reporting.
Future<void> pumpEverywhere(
  WidgetTester tester,
  Widget Function() build, {
  List<Override> overrides = const [],
  bool scaffold = true,
}) async {
  for (final width in [360.0, 412.0]) {
    useViewport(tester, width: width);
    for (final b in Brightness.values) {
      for (final l in const [Locale('bn'), Locale('en')]) {
        await tester.pumpWidget(
          themedApp(
            build(),
            brightness: b,
            locale: l,
            overrides: overrides,
            scaffold: scaffold,
          ),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.takeException(), isNull, reason: '$width $b $l');
      }
    }
  }
}
