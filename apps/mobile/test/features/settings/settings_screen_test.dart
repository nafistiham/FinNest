import 'package:bhorosha/app/appearance.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/settings_row.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/features/settings/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/screen_harness.dart';
import '../../app/theme_harness.dart';
import '../safety/safety_test_support.dart' show loadAppFonts;

void main() {
  testWidgets('switches preset, mode and text size and remembers them', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.settings);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('সেটিংস'), findsWidgets);

    await tester.tap(find.byKey(SettingsScreen.presetKey(BhPreset.jamdani)));
    await tester.pumpAndSettle();
    expect(c.read(themePresetProvider), BhPreset.jamdani);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      app.theme!.extension<BhPalette>()!.primary,
      BhPalette.of(BhPreset.jamdani, Brightness.light).primary,
    );

    await tester.ensureVisible(
      find.byKey(SettingsScreen.modeKey(ThemeMode.dark)),
    );
    await tester.tap(find.byKey(SettingsScreen.modeKey(ThemeMode.dark)));
    await tester.pumpAndSettle();
    expect(c.read(themeModeProvider), ThemeMode.dark);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    final sampleBefore = tester
        .getSize(find.byKey(SettingsScreen.sampleKey))
        .height;
    await tester.ensureVisible(
      find.byKey(SettingsScreen.textSizeKey(BhTextSize.large)),
    );
    await tester.tap(find.byKey(SettingsScreen.textSizeKey(BhTextSize.large)));
    await tester.pumpAndSettle();
    expect(c.read(textSizeProvider), BhTextSize.large);
    expect(
      tester.getSize(find.byKey(SettingsScreen.sampleKey)).height,
      greaterThan(sampleBefore),
      reason: 'the live sample grows with the text size',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_preset'), 'jamdani');
    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.getString('text_size'), 'large');
  });

  testWidgets('every preset card, both modes, at 360 dp without overflow', (
    tester,
  ) async {
    for (final b in Brightness.values) {
      for (final l in const [Locale('bn'), Locale('en')]) {
        useViewport(tester, width: 360, height: 1600);
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          themedApp(
            const SettingsScreen(haptics: NoHaptics()),
            brightness: b,
            locale: l,
            scaffold: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final p in BhPreset.values) {
          expect(find.byKey(SettingsScreen.presetKey(p)), findsOneWidget);
        }
        expect(
          tester
              .getSize(find.byKey(SettingsScreen.presetKey(BhPreset.teal)))
              .width,
          closeTo((360 - 32 - 8) / 2, 0.5),
        );
      }
    }
  });

  testWidgets('the selected preset is announced as selected', (tester) async {
    useViewport(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      themedApp(const SettingsScreen(haptics: NoHaptics()), scaffold: false),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(SettingsScreen.presetKey(BhPreset.teal))),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.byKey(SettingsScreen.presetKey(BhPreset.padma))),
      isSemantics(isSelected: false),
    );
  });

  testWidgets('log out clears the persona and lands on login', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.settings);
    final session = c.read(sessionRepoProvider).sessionId;
    await tester.scrollUntilVisible(find.byKey(SettingsScreen.logoutKey), 200);
    await tester.tap(find.byKey(SettingsScreen.logoutKey));
    await tester.pumpAndSettle();
    expect(c.read(authRepoProvider).current, isNull);
    expect(c.read(sessionRepoProvider).sessionId, isNot(session));
    expect(locationOf(c), Routes.login);
  });

  for (final locale in ['bn', 'en']) {
    testWidgets('360 dp ($locale): no segmented label is cut', (tester) async {
      await loadAppFonts();
      final h = ScreenHarness();
      await pumpApp(
        tester,
        harness: h,
        location: Routes.settings,
        extraOverrides: [
          initialLocaleProvider.overrideWithValue(Locale(locale)),
        ],
      );
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(locale == 'bn' ? 'ফোনের মতো' : 'Auto'), findsOneWidget);
      final segmented = find.byType(BhSegmented<ThemeMode>);
      expect(segmented, findsOneWidget);
      for (final r in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: segmented, matching: find.byType(RichText)),
      )) {
        expect(r.didExceedMaxLines, isFalse, reason: r.text.toPlainText());
      }
    });
  }
}
