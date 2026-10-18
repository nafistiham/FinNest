import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'palette.dart';
import 'tokens.dart';
import 'typography.dart';

export 'motion.dart';
export 'palette.dart';
export 'tokens.dart';
export 'typography.dart';

const _square = RoundedRectangleBorder(borderRadius: BorderRadius.zero);

/// The `ColorScheme` of [p], built from the palette's hex values (no
/// `fromSeed`: seeded tonal palettes drift from the specified colours).
ColorScheme schemeOf(BhPalette p, BhPalette inverse) => ColorScheme(
  brightness: p.brightness,
  primary: p.primary,
  onPrimary: p.onPrimary,
  primaryContainer: p.primaryContainer,
  onPrimaryContainer: p.onPrimaryContainer,
  secondary: p.accent,
  onSecondary: p.surface,
  secondaryContainer: p.primaryContainer,
  onSecondaryContainer: p.onPrimaryContainer,
  tertiary: p.info,
  onTertiary: p.surface,
  error: p.danger,
  onError: p.surface,
  errorContainer: p.dangerContainer,
  onErrorContainer: p.onDangerContainer,
  surface: p.surface,
  onSurface: p.onSurface,
  surfaceDim: p.surface,
  surfaceBright: p.surface,
  surfaceContainerLowest: p.surface,
  surfaceContainerLow: p.surface,
  surfaceContainer: p.surfaceVariant,
  surfaceContainerHigh: p.surfaceVariant,
  surfaceContainerHighest: p.surfaceVariant,
  onSurfaceVariant: p.mutedText,
  outline: p.outline,
  outlineVariant: p.outlineVariant,
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: inverse.surface,
  onInverseSurface: inverse.onSurface,
  inversePrimary: inverse.primary,
  surfaceTint: Colors.transparent,
);

/// Material 3 theme for [preset] in [brightness] and the [locale]'s type
/// scale (5): square corners, zero elevation, 56 dp
/// targets. The palette and the text roles ride along as theme extensions
/// (`context.palette`, `context.textRoles`). Text size is applied app-wide
/// by the text scaler in `BhoroshaApp` (`appearance.dart`), not here.
ThemeData buildTheme(
  Brightness brightness, {
  BhPreset preset = BhPreset.teal,
  Locale? locale,
}) {
  final dark = brightness == Brightness.dark;
  final p = BhPalette.of(preset, brightness);
  final inverse = BhPalette.of(
    preset,
    dark ? Brightness.light : Brightness.dark,
  );
  final scheme = schemeOf(p, inverse);
  final ink = p.onSurface;
  final muted = p.mutedText;
  final text = BhType.textTheme(locale, ink, muted);
  final roles = BhType.roles(locale, ink, muted);

  final buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(BhSize.touch, BhSize.touch)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: BhSpace.l, vertical: BhSpace.m),
    ),
    shape: const WidgetStatePropertyAll(_square),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: BhType.familyFor(locale),
    fontFamilyFallback: BhType.fallbackFor(locale),
    textTheme: text,
    extensions: [p, roles],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      toolbarHeight: BhSize.appBar,
      // Edge-to-edge: transparent system bars, icons readable on surface.
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: brightness,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
    ),
    cardTheme: CardThemeData(
      shape: _square,
      elevation: 0,
      color: p.surfaceVariant,
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonStyle.copyWith(
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? p.surfaceVariant : p.surface,
      border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: p.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.all(BhSpace.m),
      labelStyle: text.bodyMedium,
      hintStyle: text.bodyMedium?.copyWith(color: muted),
    ),
    chipTheme: ChipThemeData(
      shape: _square,
      labelStyle: text.labelMedium,
      padding: const EdgeInsets.symmetric(
        horizontal: BhSpace.m,
        vertical: BhSpace.s,
      ),
    ),
    dialogTheme: const DialogThemeData(shape: _square),
    bottomSheetTheme: BottomSheetThemeData(
      shape: _square,
      backgroundColor: scheme.surface,
      showDragHandle: true,
      dragHandleColor: p.outlineVariant,
      dragHandleSize: const Size(32, 4),
    ),
    snackBarTheme: SnackBarThemeData(
      shape: _square,
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      actionTextColor: scheme.inversePrimary,
      insetPadding: const EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.s,
        BhSpace.m,
        BhSpace.m,
      ),
      // The snackbar fill is `inverseSurface` (light in dark mode).
      contentTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: _square,
      minVerticalPadding: BhSpace.m,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
    ),
    dividerTheme: DividerThemeData(
      color: p.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    // An off switch has an `outline` thumb: a teal thumb on an off track
    // read as "on" in dark.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.outline,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: _square,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      extendedTextStyle: text.labelLarge,
    ),
  );
}
