/// Type scale. Two tables: Bangla (SolaimanLipi, 400 and
/// 700 only, letter spacing 0 so matras and conjuncts join) and Latin
/// (system Roboto with SolaimanLipi as the fallback for Bangla server copy).
/// The floor is 16 sp for every role. Line heights below 1.4 only for roles
/// that hold digits or one short line (amounts, labels, numpad).
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class BhType {
  static const family = 'SolaimanLipi';

  static bool _isBangla(Locale? locale) => locale?.languageCode != 'en';

  static String? familyFor(Locale? locale) => _isBangla(locale) ? family : null;

  static List<String> fallbackFor(Locale? locale) =>
      _isBangla(locale) ? const ['Roboto'] : const [family];

  /// The Material text theme for [locale] in [ink], with muted captions.
  static TextTheme textTheme(Locale? locale, Color ink, Color muted) {
    final bn = _isBangla(locale);
    TextStyle s(
      double size,
      FontWeight weight,
      double height, {
      double spacing = 0,
      Color? color,
      bool body = false,
    }) => TextStyle(
      fontFamily: familyFor(locale),
      fontFamilyFallback: fallbackFor(locale),
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: bn ? 0 : spacing,
      color: color ?? ink,
      leadingDistribution: body ? TextLeadingDistribution.even : null,
    );
    const w4 = FontWeight.w400;
    const w7 = FontWeight.w700;
    const w5 = FontWeight.w500;
    if (bn) {
      return TextTheme(
        displayLarge: s(44, w7, 1.15),
        displayMedium: s(40, w7, 1.15),
        displaySmall: s(34, w7, 1.25),
        headlineLarge: s(30, w7, 1.3),
        headlineMedium: s(26, w7, 1.3),
        headlineSmall: s(22, w7, 1.35),
        titleLarge: s(22, w7, 1.35),
        titleMedium: s(20, w7, 1.35),
        titleSmall: s(18, w7, 1.4),
        bodyLarge: s(20, w4, 1.5, body: true),
        bodyMedium: s(18, w4, 1.5, body: true),
        bodySmall: s(16, w4, 1.45, color: muted, body: true),
        labelLarge: s(20, w7, 1.2),
        labelMedium: s(18, w7, 1.2),
        labelSmall: s(16, w7, 1.2, color: muted),
      );
    }
    return TextTheme(
      displayLarge: s(44, w5, 1.1, spacing: -0.5),
      displayMedium: s(40, w5, 1.1, spacing: -0.5),
      displaySmall: s(32, w5, 1.2, spacing: -0.25),
      headlineLarge: s(28, w5, 1.25),
      headlineMedium: s(24, w5, 1.25),
      headlineSmall: s(22, w5, 1.27),
      titleLarge: s(20, w5, 1.3),
      titleMedium: s(18, w5, 1.33, spacing: 0.1),
      titleSmall: s(17, w5, 1.35, spacing: 0.1),
      bodyLarge: s(18, w4, 1.45, spacing: 0.15, body: true),
      bodyMedium: s(17, w4, 1.45, spacing: 0.15, body: true),
      bodySmall: s(16, w4, 1.4, spacing: 0.2, color: muted, body: true),
      labelLarge: s(18, w5, 1.2, spacing: 0.1),
      labelMedium: s(16, w5, 1.2, spacing: 0.2),
      labelSmall: s(16, w5, 1.2, spacing: 0.3, color: muted),
    );
  }

  /// The app-specific roles (amounts, numpad, Apa's script) for [locale].
  static BhTextRoles roles(Locale? locale, Color ink, Color muted) {
    final bn = _isBangla(locale);
    TextStyle s(double size, double height, {Color? color, bool bold = true}) =>
        TextStyle(
          fontFamily: familyFor(locale),
          fontFamilyFallback: fallbackFor(locale),
          fontSize: size,
          fontWeight: bold
              ? (bn ? FontWeight.w700 : FontWeight.w500)
              : FontWeight.w400,
          height: height,
          letterSpacing: bn || size < 40 ? 0 : -0.5,
          color: color ?? ink,
          fontFeatures: bn ? null : const [FontFeature.tabularFigures()],
        );
    return BhTextRoles(
      amountHero: s(44, bn ? 1.15 : 1.1),
      amountEntry: s(48, bn ? 1.15 : 1.1),
      amountEntryCompact: s(40, bn ? 1.15 : 1.1),
      numpadDigit: s(bn ? 32 : 30, 1.0),
      numberEntry: s(32, 1.2),
      pinDigitCounter: s(16, 1.2, color: muted, bold: false),
      script: TextStyle(
        fontFamily: family,
        fontFamilyFallback: const ['Roboto'],
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.5,
        color: ink,
      ),
    );
  }

  /// Apa's spoken line on the overlay (bn). Prefer `context.textRoles.script`.
  static const script = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.5,
    color: BhColors.onSoft,
  );
}

/// App-specific text roles, carried on the theme so they follow the locale
/// and the palette: `context.textRoles.amountHero`.
@immutable
class BhTextRoles extends ThemeExtension<BhTextRoles> {
  const BhTextRoles({
    required this.amountHero,
    required this.amountEntry,
    required this.amountEntryCompact,
    required this.numpadDigit,
    required this.numberEntry,
    required this.pinDigitCounter,
    required this.script,
  });

  /// Home balance, PIN confirm amount, result amount (44 sp).
  final TextStyle amountHero;

  /// Amount being typed, regular (48 sp).
  final TextStyle amountEntry;

  /// Amount being typed, compact; PIN amount compact (40 sp).
  final TextStyle amountEntryCompact;

  /// Numpad keys (32 sp bn / 30 sp en), never scaled.
  final TextStyle numpadDigit;

  /// A phone or account number being typed (`NumberDisplay`, 7.6): 32 sp.
  final TextStyle numberEntry;

  /// "৮/১১ সংখ্যা".
  final TextStyle pinDigitCounter;

  /// Apa's script line (22 sp bold, bn).
  final TextStyle script;

  @override
  BhTextRoles copyWith({
    TextStyle? amountHero,
    TextStyle? amountEntry,
    TextStyle? amountEntryCompact,
    TextStyle? numpadDigit,
    TextStyle? numberEntry,
    TextStyle? pinDigitCounter,
    TextStyle? script,
  }) => BhTextRoles(
    amountHero: amountHero ?? this.amountHero,
    amountEntry: amountEntry ?? this.amountEntry,
    amountEntryCompact: amountEntryCompact ?? this.amountEntryCompact,
    numpadDigit: numpadDigit ?? this.numpadDigit,
    numberEntry: numberEntry ?? this.numberEntry,
    pinDigitCounter: pinDigitCounter ?? this.pinDigitCounter,
    script: script ?? this.script,
  );

  @override
  BhTextRoles lerp(covariant BhTextRoles? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return BhTextRoles(
      amountHero: l(amountHero, other.amountHero),
      amountEntry: l(amountEntry, other.amountEntry),
      amountEntryCompact: l(amountEntryCompact, other.amountEntryCompact),
      numpadDigit: l(numpadDigit, other.numpadDigit),
      numberEntry: l(numberEntry, other.numberEntry),
      pinDigitCounter: l(pinDigitCounter, other.pinDigitCounter),
      script: l(script, other.script),
    );
  }
}

extension BhTextRolesX on BuildContext {
  /// The app's text roles; Bangla roles in the theme's ink when a test
  /// pumps a bare `ThemeData`.
  BhTextRoles get textRoles {
    final theme = Theme.of(this);
    return theme.extension<BhTextRoles>() ??
        BhType.roles(
          Localizations.maybeLocaleOf(this),
          theme.colorScheme.onSurface,
          theme.colorScheme.onSurfaceVariant,
        );
  }
}
