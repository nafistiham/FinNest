import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'theme_harness.dart';

void main() {
  group('contrast (5.3)', () {
    for (final preset in BhPreset.values) {
      for (final b in Brightness.values) {
        test('${preset.id} ${b.name}', () {
          final p = BhPalette.of(preset, b);
          void aa(Color fg, Color bg, String what, [double min = 4.5]) =>
              expect(
                contrast(fg, bg),
                greaterThanOrEqualTo(min),
                reason: '$what ${contrast(fg, bg).toStringAsFixed(2)}',
              );
          // Brand pairs.
          aa(p.onPrimary, p.primary, 'onPrimary/primary');
          aa(p.primary, p.surface, 'primary text on surface');
          aa(p.onPrimaryContainer, p.primaryContainer, 'onPrimaryContainer');
          aa(p.onSurface, p.surface, 'onSurface/surface', 15);
          aa(p.mutedText, p.surface, 'muted/surface', 6);
          aa(
            p.mutedText,
            p.surfaceVariant,
            'muted/surfaceVariant',
            b == Brightness.light ? 5.4 : 8.1,
          );
          aa(p.accent, p.surface, 'accent text on surface', 5.1);
          aa(p.outline, p.surface, 'outline/surface', 3);
          // Status pairs on surface and surfaceVariant.
          for (final s in [p.danger, p.warning, p.success, p.info]) {
            aa(s, p.surface, 'status on surface');
            aa(s, p.surfaceVariant, 'status on surfaceVariant');
          }
          // Fills and containers.
          aa(p.onDangerFill, p.dangerFill, 'dangerFill', 6.5);
          aa(p.onWarningFill, p.warningFill, 'warningFill', 6.4);
          aa(p.onSuccessFill, p.successFill, 'successFill', 5.3);
          for (final (on, c, text) in [
            (p.onDangerContainer, p.dangerContainer, p.danger),
            (p.onWarningContainer, p.warningContainer, p.warning),
            (p.onSuccessContainer, p.successContainer, p.success),
            (p.onInfoContainer, p.infoContainer, p.info),
          ]) {
            aa(on, c, 'on container', 10);
            aa(text, c, 'status text on its container');
          }
        });
      }
    }

    test('the ratios the brief states for Teal light are what we compute', () {
      final p = BhPalette.of(BhPreset.teal, Brightness.light);
      expect(contrast(p.onPrimary, p.primary), closeTo(6.09, 0.01));
      expect(contrast(p.primary, p.surface), closeTo(5.83, 0.01));
      expect(
        contrast(p.onPrimaryContainer, p.primaryContainer),
        closeTo(11.54, 0.01),
      );
      expect(contrast(p.outline, p.surface), closeTo(3.28, 0.01));
      expect(contrast(p.onSurface, p.surface), closeTo(16.49, 0.01));
    });
  });

  test('status colours are identical in every preset, per brightness', () {
    for (final b in Brightness.values) {
      final ref = BhPalette.of(BhPreset.teal, b);
      for (final preset in BhPreset.values) {
        final p = BhPalette.of(preset, b);
        for (final s in BhStatus.values.where((s) => s != BhStatus.neutral)) {
          expect(p.statusText(s), ref.statusText(s), reason: '${preset.id} $s');
          expect(p.statusContainer(s), ref.statusContainer(s));
          expect(p.onStatusContainer(s), ref.onStatusContainer(s));
          expect(p.statusFill(s), ref.statusFill(s));
        }
      }
    }
  });

  test('dark containers are dark tints with light text', () {
    for (final preset in BhPreset.values) {
      final p = BhPalette.of(preset, Brightness.dark);
      for (final c in [
        p.primaryContainer,
        p.dangerContainer,
        p.warningContainer,
        p.successContainer,
        p.infoContainer,
      ]) {
        expect(c.computeLuminance(), lessThan(0.1), reason: preset.id);
      }
      expect(p.onDangerContainer.computeLuminance(), greaterThan(0.5));
    }
  });

  test('the five preset ids round-trip; unknown parses to null', () {
    for (final p in BhPreset.values) {
      expect(BhPreset.parse(p.id), p);
    }
    expect(BhPreset.parse('amber'), isNull);
    expect(BhPreset.values.map((p) => p.id), [
      'teal',
      'padma',
      'jamdani',
      'shapla',
      'slate',
    ]);
  });

  test('lerp blends and lands on the target', () {
    final a = BhPalette.of(BhPreset.teal, Brightness.light);
    final b = BhPalette.of(BhPreset.shapla, Brightness.dark);
    expect(a.lerp(b, 0).primary, a.primary);
    expect(a.lerp(b, 1).primary, b.primary);
    expect(a.lerp(b, 1).brightness, Brightness.dark);
    expect(a.lerp(b, 0.5).primary, isNot(a.primary));
  });

  group('buildTheme', () {
    test('builds for every preset x brightness x locale', () {
      for (final preset in BhPreset.values) {
        for (final b in Brightness.values) {
          for (final l in const [Locale('bn'), Locale('en')]) {
            final t = buildTheme(b, preset: preset, locale: l);
            final p = t.extension<BhPalette>()!;
            expect(t.colorScheme.primary, p.primary);
            expect(t.colorScheme.secondary, p.accent);
            expect(t.colorScheme.surfaceContainerHighest, p.surfaceVariant);
            expect(t.colorScheme.onSurfaceVariant, p.mutedText);
            expect(t.colorScheme.error, p.danger);
            expect(t.colorScheme.errorContainer, p.dangerContainer);
            expect(t.colorScheme.outline, p.outline);
            expect(t.colorScheme.dangerText, p.danger);
            expect(t.colorScheme.okText, p.success);
            expect(t.colorScheme.cautionText, p.warning);
            expect(t.colorScheme.mutedText, p.mutedText);
            expect(t.extension<BhTextRoles>(), isNotNull);
            expect(
              t.snackBarTheme.backgroundColor,
              t.colorScheme.inverseSurface,
            );
          }
        }
      }
    });

    test('typography: Bangla SolaimanLipi, letter spacing 0, floor 16 sp', () {
      final bn = buildTheme(Brightness.light, locale: const Locale('bn'));
      final en = buildTheme(Brightness.light, locale: const Locale('en'));
      expect(bn.textTheme.bodyMedium?.fontFamily, BhType.family);
      expect(bn.textTheme.bodyMedium?.fontSize, 18);
      expect(en.textTheme.bodyMedium?.fontFamily, isNot(BhType.family));
      expect(en.textTheme.bodyMedium?.fontFamilyFallback, [BhType.family]);
      for (final t in [bn, en]) {
        final styles = [
          t.textTheme.displayLarge,
          t.textTheme.displaySmall,
          t.textTheme.headlineMedium,
          t.textTheme.titleLarge,
          t.textTheme.titleSmall,
          t.textTheme.bodyLarge,
          t.textTheme.bodySmall,
          t.textTheme.labelLarge,
          t.textTheme.labelSmall,
        ];
        for (final s in styles) {
          expect(s!.fontSize, greaterThanOrEqualTo(16));
        }
      }
      for (final s in [bn.textTheme.titleMedium, bn.textTheme.bodySmall]) {
        expect(s!.letterSpacing, 0);
        expect(
          s.fontWeight == FontWeight.w400 || s.fontWeight == FontWeight.w700,
          isTrue,
        );
      }
      final roles = bn.extension<BhTextRoles>()!;
      expect(roles.amountHero.fontSize, 44);
      expect(roles.amountHero.height, 1.15);
      expect(roles.amountEntry.fontSize, 48);
      expect(roles.amountEntryCompact.fontSize, 40);
      expect(roles.numpadDigit.fontSize, 32);
      expect(
        en.extension<BhTextRoles>()!.amountHero.fontWeight,
        FontWeight.w500,
      );
    });

    testWidgets('context.palette falls back to Teal on a bare theme', (
      tester,
    ) async {
      late BhPalette p;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              p = context.palette;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(p.primary, BhPalette.of(BhPreset.teal, Brightness.dark).primary);
    });

    testWidgets('renders text in every preset x brightness x text size', (
      tester,
    ) async {
      for (final preset in BhPreset.values) {
        for (final b in Brightness.values) {
          for (final scale in [1.0, 1.15, 1.4]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTheme(b, preset: preset),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                locale: const Locale('bn'),
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: const Scaffold(body: Text('৳ ৫,০০০')),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
          }
        }
      }
    });
  });

  test('motion: reduce motion gives zero durations everywhere', () {
    const n = BhMotion.none;
    for (final d in [
      n.press,
      n.release,
      n.fast,
      n.normal,
      n.exit,
      n.slow,
      n.counter,
      n.pulse,
      n.nudge,
      n.caretBlink,
      n.stagger,
    ]) {
      expect(d, Duration.zero);
    }
    expect(BhMotion.standard.normal, const Duration(milliseconds: 240));
    expect(BhMotion.standard.slow, const Duration(milliseconds: 360));
    expect(BhMotion.standard.counter, const Duration(milliseconds: 600));
  });

  testWidgets('BhMotion.of follows MediaQuery.disableAnimations', (
    tester,
  ) async {
    late BhMotion reduced;
    late BhMotion full;
    await tester.pumpWidget(
      Column(
        children: [
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (c) {
                reduced = BhMotion.of(c);
                return const SizedBox();
              },
            ),
          ),
          MediaQuery(
            data: const MediaQueryData(),
            child: Builder(
              builder: (c) {
                full = BhMotion.of(c);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(reduced.reduced, isTrue);
    expect(reduced.fast, Duration.zero);
    expect(full.fast, const Duration(milliseconds: 150));
  });
}
