import 'package:bhorosha/app/appearance.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults: Bangla, Teal trust, system mode, normal text', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(localeProvider), const Locale('bn'));
    expect(c.read(themePresetProvider), BhPreset.teal);
    expect(c.read(themeModeProvider), ThemeMode.system);
    expect(c.read(textSizeProvider), BhTextSize.normal);
    expect(await Appearance.load(), Appearance.defaults);
  });

  test('choices persist under theme_preset, theme_mode, text_size', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(themePresetProvider.notifier).set(BhPreset.jamdani);
    await c.read(themeModeProvider.notifier).set(ThemeMode.dark);
    await c.read(textSizeProvider.notifier).set(BhTextSize.large);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_preset'), 'jamdani');
    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.getString('text_size'), 'large');
    expect(
      await Appearance.load(),
      const Appearance(
        preset: BhPreset.jamdani,
        mode: ThemeMode.dark,
        textSize: BhTextSize.large,
      ),
    );
  });

  test(
    'a cold start with the loaded appearance is right on the first read',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme_preset': 'shapla',
        'theme_mode': 'light',
        'text_size': 'large',
      });
      final saved = await Appearance.load();
      final c = ProviderContainer(
        overrides: [initialAppearanceProvider.overrideWithValue(saved)],
      );
      addTearDown(c.dispose);
      expect(c.read(themePresetProvider), BhPreset.shapla);
      expect(c.read(themeModeProvider), ThemeMode.light);
      expect(c.read(textSizeProvider), BhTextSize.large);
    },
  );

  test('without the boot read the notifiers restore asynchronously', () async {
    SharedPreferences.setMockInitialValues({'theme_preset': 'slate'});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(themePresetProvider), BhPreset.teal);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(themePresetProvider), BhPreset.slate);
  });

  test('unknown stored values fall back to the defaults', () async {
    SharedPreferences.setMockInitialValues({
      'theme_preset': 'sunset_amber',
      'theme_mode': 'night',
      'text_size': 'huge',
    });
    expect(await Appearance.load(), Appearance.defaults);
  });

  test('resetAppearance goes back to the defaults and saves them', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(themePresetProvider.notifier).set(BhPreset.padma);
    await c.read(themeModeProvider.notifier).set(ThemeMode.dark);
    await c.read(textSizeProvider.notifier).set(BhTextSize.large);
    await resetAppearance(c.read);
    expect(c.read(themePresetProvider), BhPreset.teal);
    expect(c.read(themeModeProvider), ThemeMode.system);
    expect(c.read(textSizeProvider), BhTextSize.normal);
    expect(await Appearance.load(), Appearance.defaults);
  });

  test('text scale: large is x1.15, clamped to 1.0..1.4', () {
    double s(double system, BhTextSize size) =>
        bhTextScaler(TextScaler.linear(system), size).scale(100) / 100;
    expect(s(1.0, BhTextSize.normal), 1.0);
    expect(s(1.0, BhTextSize.large), closeTo(1.15, 1e-9));
    expect(s(0.85, BhTextSize.normal), 1.0);
    expect(s(1.3, BhTextSize.large), 1.4);
    expect(s(2.0, BhTextSize.normal), 1.4);
  });
}
