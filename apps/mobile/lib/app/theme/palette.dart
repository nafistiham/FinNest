/// Colour tokens. [BhPalette] is a `ThemeExtension`, so a
/// preset or brightness switch lerps through `AnimatedTheme` for free.
///
/// Brand tokens change per [BhPreset]; status tokens never do (they differ
/// only by brightness): the hold overlay, the amber delay banner and the
/// green done tick look the same whatever preset the presenter picked.
/// In dark mode the `...Container` fills are dark tints with light text.
library;

import 'package:flutter/material.dart';

/// The five theme presets. [id] is the SharedPreferences value.
enum BhPreset {
  teal('teal'),
  padma('padma'),
  jamdani('jamdani'),
  shapla('shapla'),
  slate('slate');

  const BhPreset(this.id);

  final String id;

  static const fallback = BhPreset.teal;

  /// `null` for an unknown or missing id.
  static BhPreset? parse(String? id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Meaning of a status colour (7.4). Simulated, held, delay, pending =
/// [warning]; blocked = [danger]; done, safe = [success]; requested, demo
/// notes = [info]; cancelled, released = [neutral].
enum BhStatus { danger, warning, success, info, neutral }

@immutable
class BhPalette extends ThemeExtension<BhPalette> {
  const BhPalette({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.accent,
    required this.surface,
    required this.surfaceVariant,
    required this.onSurface,
    required this.mutedText,
    required this.outline,
    required this.outlineVariant,
    required this.danger,
    required this.dangerFill,
    required this.onDangerFill,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.warning,
    required this.warningFill,
    required this.onWarningFill,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.success,
    required this.successFill,
    required this.onSuccessFill,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
  });

  /// The palette of [preset] in [brightness].
  factory BhPalette.of(BhPreset preset, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final b = _brand[preset]!;
    final brand = dark ? b.$2 : b.$1;
    final s = dark ? _statusDark : _statusLight;
    return BhPalette(
      brightness: brightness,
      primary: brand.primary,
      onPrimary: brand.onPrimary,
      primaryContainer: brand.primaryContainer,
      onPrimaryContainer: brand.onPrimaryContainer,
      accent: brand.accent,
      surface: brand.surface,
      surfaceVariant: brand.surfaceVariant,
      onSurface: brand.onSurface,
      mutedText: brand.mutedText,
      outline: brand.outline,
      outlineVariant: brand.outlineVariant,
      danger: s.danger,
      dangerFill: s.dangerFill,
      onDangerFill: s.onDangerFill,
      dangerContainer: s.dangerContainer,
      onDangerContainer: s.onDangerContainer,
      warning: s.warning,
      warningFill: s.warningFill,
      onWarningFill: s.onWarningFill,
      warningContainer: s.warningContainer,
      onWarningContainer: s.onWarningContainer,
      success: s.success,
      successFill: s.successFill,
      onSuccessFill: s.onSuccessFill,
      successContainer: s.successContainer,
      onSuccessContainer: s.onSuccessContainer,
      info: s.info,
      infoContainer: s.infoContainer,
      onInfoContainer: s.onInfoContainer,
    );
  }

  /// Teal trust light, for code that cannot reach a context.
  static final tealLight = BhPalette.of(BhPreset.teal, Brightness.light);

  final Brightness brightness;

  // Brand (changes per preset).
  final Color primary, onPrimary, primaryContainer, onPrimaryContainer;

  /// Secondary accent: Apa ring, "নতুন" badge, selected-preset tick.
  final Color accent;
  final Color surface, surfaceVariant, onSurface, mutedText;

  /// Borders that must read (chips, inputs): >= 3:1 on surface.
  final Color outline;

  /// Dividers (decorative).
  final Color outlineVariant;

  // Status (identical in every preset; differ only by brightness).
  // `danger`/`warning`/`success`/`info` are text and icon colours on
  // surface and surfaceVariant (>= 4.5:1).
  final Color danger, dangerFill, onDangerFill, dangerContainer;
  final Color onDangerContainer;
  final Color warning, warningFill, onWarningFill, warningContainer;
  final Color onWarningContainer;
  final Color success, successFill, onSuccessFill, successContainer;
  final Color onSuccessContainer;
  final Color info, infoContainer, onInfoContainer;

  bool get isDark => brightness == Brightness.dark;

  /// Logo colours of the two-tone FinNest wordmark (sampled from the logo):
  /// "Fin" in leaf green, "Nest" in navy. Brand constants, the same in every
  /// preset; dark mode uses lighter tints so the wordmark reads on the dark
  /// surface. Display sizes only (the light leaf is 3.06:1 on surface).
  Color get brandLeaf =>
      isDark ? const Color(0xFF9CCB6E) : const Color(0xFF729C4A);

  /// See [brandLeaf]. 11.9:1 light, 10.8:1 dark.
  Color get brandNavy =>
      isDark ? const Color(0xFFB7C8E8) : const Color(0xFF1E3459);

  /// Text and icon colour of [status] on surface / surfaceVariant.
  Color statusText(BhStatus status) => switch (status) {
    BhStatus.danger => danger,
    BhStatus.warning => warning,
    BhStatus.success => success,
    BhStatus.info => info,
    BhStatus.neutral => mutedText,
  };

  /// Soft card / tag fill of [status].
  Color statusContainer(BhStatus status) => switch (status) {
    BhStatus.danger => dangerContainer,
    BhStatus.warning => warningContainer,
    BhStatus.success => successContainer,
    BhStatus.info => infoContainer,
    BhStatus.neutral => surfaceVariant,
  };

  /// Text on [statusContainer].
  Color onStatusContainer(BhStatus status) => switch (status) {
    BhStatus.danger => onDangerContainer,
    BhStatus.warning => onWarningContainer,
    BhStatus.success => onSuccessContainer,
    BhStatus.info => onInfoContainer,
    BhStatus.neutral => mutedText,
  };

  /// Strong fill (stripes, buttons) of [status].
  Color statusFill(BhStatus status) => switch (status) {
    BhStatus.danger => dangerFill,
    BhStatus.warning => warningFill,
    BhStatus.success => successFill,
    BhStatus.info => info,
    BhStatus.neutral => outline,
  };

  @override
  BhPalette copyWith({
    Brightness? brightness,
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? accent,
    Color? surface,
    Color? surfaceVariant,
    Color? onSurface,
    Color? mutedText,
    Color? outline,
    Color? outlineVariant,
  }) => BhPalette(
    brightness: brightness ?? this.brightness,
    primary: primary ?? this.primary,
    onPrimary: onPrimary ?? this.onPrimary,
    primaryContainer: primaryContainer ?? this.primaryContainer,
    onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
    accent: accent ?? this.accent,
    surface: surface ?? this.surface,
    surfaceVariant: surfaceVariant ?? this.surfaceVariant,
    onSurface: onSurface ?? this.onSurface,
    mutedText: mutedText ?? this.mutedText,
    outline: outline ?? this.outline,
    outlineVariant: outlineVariant ?? this.outlineVariant,
    danger: danger,
    dangerFill: dangerFill,
    onDangerFill: onDangerFill,
    dangerContainer: dangerContainer,
    onDangerContainer: onDangerContainer,
    warning: warning,
    warningFill: warningFill,
    onWarningFill: onWarningFill,
    warningContainer: warningContainer,
    onWarningContainer: onWarningContainer,
    success: success,
    successFill: successFill,
    onSuccessFill: onSuccessFill,
    successContainer: successContainer,
    onSuccessContainer: onSuccessContainer,
    info: info,
    infoContainer: infoContainer,
    onInfoContainer: onInfoContainer,
  );

  @override
  BhPalette lerp(covariant BhPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return BhPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      primaryContainer: l(primaryContainer, other.primaryContainer),
      onPrimaryContainer: l(onPrimaryContainer, other.onPrimaryContainer),
      accent: l(accent, other.accent),
      surface: l(surface, other.surface),
      surfaceVariant: l(surfaceVariant, other.surfaceVariant),
      onSurface: l(onSurface, other.onSurface),
      mutedText: l(mutedText, other.mutedText),
      outline: l(outline, other.outline),
      outlineVariant: l(outlineVariant, other.outlineVariant),
      danger: l(danger, other.danger),
      dangerFill: l(dangerFill, other.dangerFill),
      onDangerFill: l(onDangerFill, other.onDangerFill),
      dangerContainer: l(dangerContainer, other.dangerContainer),
      onDangerContainer: l(onDangerContainer, other.onDangerContainer),
      warning: l(warning, other.warning),
      warningFill: l(warningFill, other.warningFill),
      onWarningFill: l(onWarningFill, other.onWarningFill),
      warningContainer: l(warningContainer, other.warningContainer),
      onWarningContainer: l(onWarningContainer, other.onWarningContainer),
      success: l(success, other.success),
      successFill: l(successFill, other.successFill),
      onSuccessFill: l(onSuccessFill, other.onSuccessFill),
      successContainer: l(successContainer, other.successContainer),
      onSuccessContainer: l(onSuccessContainer, other.onSuccessContainer),
      info: l(info, other.info),
      infoContainer: l(infoContainer, other.infoContainer),
      onInfoContainer: l(onInfoContainer, other.onInfoContainer),
    );
  }
}

extension BhPaletteX on BuildContext {
  /// The active palette. Falls back to Teal trust in the theme's brightness
  /// when a test pumps a bare `ThemeData` without the extension.
  BhPalette get palette {
    final theme = Theme.of(this);
    return theme.extension<BhPalette>() ??
        BhPalette.of(BhPreset.fallback, theme.brightness);
  }
}

class _Brand {
  const _Brand({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.accent,
    required this.surface,
    required this.surfaceVariant,
    required this.onSurface,
    required this.mutedText,
    required this.outline,
    required this.outlineVariant,
  });

  final Color primary, onPrimary, primaryContainer, onPrimaryContainer;
  final Color accent, surface, surfaceVariant, onSurface, mutedText;
  final Color outline, outlineVariant;
}

class _Status {
  const _Status({
    required this.danger,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
  });

  // Fills are the same in both brightnesses (5.2).
  Color get dangerFill => const Color(0xFFB3261E);
  Color get onDangerFill => const Color(0xFFFFFFFF);
  Color get warningFill => const Color(0xFFD98E04);
  Color get onWarningFill => const Color(0xFF1B1B1B);
  Color get successFill => const Color(0xFF1E7B3A);
  Color get onSuccessFill => const Color(0xFFFFFFFF);

  final Color danger, dangerContainer, onDangerContainer;
  final Color warning, warningContainer, onWarningContainer;
  final Color success, successContainer, onSuccessContainer;
  final Color info, infoContainer, onInfoContainer;
}

const _statusLight = _Status(
  danger: Color(0xFFB3261E),
  dangerContainer: Color(0xFFFBE4E2),
  onDangerContainer: Color(0xFF410E0B),
  warning: Color(0xFF8A5A00),
  warningContainer: Color(0xFFFFF1D6),
  onWarningContainer: Color(0xFF2E1F00),
  success: Color(0xFF1E7B3A),
  successContainer: Color(0xFFDFF3E4),
  onSuccessContainer: Color(0xFF0A2E16),
  info: Color(0xFF1F5FA8),
  infoContainer: Color(0xFFE1ECF8),
  onInfoContainer: Color(0xFF0B2545),
);

const _statusDark = _Status(
  danger: Color(0xFFF2B8B5),
  dangerContainer: Color(0xFF4A1714),
  onDangerContainer: Color(0xFFFFDAD6),
  warning: Color(0xFFFFC95C),
  warningContainer: Color(0xFF3D2C05),
  onWarningContainer: Color(0xFFFFE7B0),
  success: Color(0xFF7DD99A),
  successContainer: Color(0xFF12361E),
  onSuccessContainer: Color(0xFFC3F0CF),
  info: Color(0xFF9CC3F2),
  infoContainer: Color(0xFF14304F),
  onInfoContainer: Color(0xFFD6E6FA),
);

/// (light, dark) brand tokens per preset (5.3).
const _brand = <BhPreset, (_Brand, _Brand)>{
  BhPreset.teal: (
    _Brand(
      primary: Color(0xFF0F6E67),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFD3ECE8),
      onPrimaryContainer: Color(0xFF06302C),
      accent: Color(0xFF7B4B94),
      surface: Color(0xFFFBFAF6),
      surfaceVariant: Color(0xFFF1EFE8),
      onSurface: Color(0xFF1B1B1B),
      mutedText: Color(0xFF5B5F66),
      outline: Color(0xFF878C88),
      outlineVariant: Color(0xFFD9D6CC),
    ),
    _Brand(
      primary: Color(0xFF7FD1C8),
      onPrimary: Color(0xFF00302B),
      primaryContainer: Color(0xFF0E4A45),
      onPrimaryContainer: Color(0xFFC6EFEA),
      accent: Color(0xFFD2B3E3),
      surface: Color(0xFF121615),
      surfaceVariant: Color(0xFF1C2120),
      onSurface: Color(0xFFF2F1EC),
      mutedText: Color(0xFFB4B8BD),
      outline: Color(0xFF6F7774),
      outlineVariant: Color(0xFF3A403E),
    ),
  ),
  BhPreset.padma: (
    _Brand(
      primary: Color(0xFF3D6A1E),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFDCEBCB),
      onPrimaryContainer: Color(0xFF17300A),
      accent: Color(0xFF7B4B94),
      surface: Color(0xFFFAFAF5),
      surfaceVariant: Color(0xFFEEF0E6),
      onSurface: Color(0xFF1A1C17),
      mutedText: Color(0xFF5A5F55),
      outline: Color(0xFF868B80),
      outlineVariant: Color(0xFFD5D9CB),
    ),
    _Brand(
      primary: Color(0xFFA9D483),
      onPrimary: Color(0xFF1B3505),
      primaryContainer: Color(0xFF2C4D14),
      onPrimaryContainer: Color(0xFFD6EEC0),
      accent: Color(0xFFD2B3E3),
      surface: Color(0xFF131611),
      surfaceVariant: Color(0xFF1D211A),
      onSurface: Color(0xFFF1F2EA),
      mutedText: Color(0xFFB6BBAF),
      outline: Color(0xFF6F766A),
      outlineVariant: Color(0xFF3B4136),
    ),
  ),
  BhPreset.jamdani: (
    _Brand(
      primary: Color(0xFF33408F),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFDFE2F7),
      onPrimaryContainer: Color(0xFF141C4F),
      accent: Color(0xFF00796B),
      surface: Color(0xFFFAFAFC),
      surfaceVariant: Color(0xFFEEEFF5),
      onSurface: Color(0xFF1A1B21),
      mutedText: Color(0xFF5A5D6B),
      outline: Color(0xFF878A99),
      outlineVariant: Color(0xFFD6D8E3),
    ),
    _Brand(
      primary: Color(0xFFB7C0F5),
      onPrimary: Color(0xFF1A2366),
      primaryContainer: Color(0xFF2C3778),
      onPrimaryContainer: Color(0xFFDFE2FB),
      accent: Color(0xFF80CBC4),
      surface: Color(0xFF121318),
      surfaceVariant: Color(0xFF1C1D24),
      onSurface: Color(0xFFF1F1F6),
      mutedText: Color(0xFFB6B8C6),
      outline: Color(0xFF6F7283),
      outlineVariant: Color(0xFF3B3D4A),
    ),
  ),
  BhPreset.shapla: (
    _Brand(
      primary: Color(0xFF7E2E6F),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFF5DDEE),
      onPrimaryContainer: Color(0xFF3A0C32),
      accent: Color(0xFF0F6E67),
      surface: Color(0xFFFCFAF9),
      surfaceVariant: Color(0xFFF3EEEF),
      onSurface: Color(0xFF1E1A1D),
      mutedText: Color(0xFF62595F),
      outline: Color(0xFF8E858A),
      outlineVariant: Color(0xFFDDD3D8),
    ),
    _Brand(
      primary: Color(0xFFF0B0DF),
      onPrimary: Color(0xFF4A1340),
      primaryContainer: Color(0xFF622357),
      onPrimaryContainer: Color(0xFFFBDDF2),
      accent: Color(0xFF7FD1C8),
      surface: Color(0xFF171315),
      surfaceVariant: Color(0xFF221C1F),
      onSurface: Color(0xFFF5EFF2),
      mutedText: Color(0xFFBEB4BA),
      outline: Color(0xFF7A6F75),
      outlineVariant: Color(0xFF463C42),
    ),
  ),
  BhPreset.slate: (
    _Brand(
      primary: Color(0xFF2F5573),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFD8E5F0),
      onPrimaryContainer: Color(0xFF0D2638),
      accent: Color(0xFF7B4B94),
      surface: Color(0xFFF9FAFB),
      surfaceVariant: Color(0xFFECEFF2),
      onSurface: Color(0xFF191C1F),
      mutedText: Color(0xFF59616A),
      outline: Color(0xFF858D95),
      outlineVariant: Color(0xFFD3D9DF),
    ),
    _Brand(
      primary: Color(0xFF9EC4E4),
      onPrimary: Color(0xFF0F2E47),
      primaryContainer: Color(0xFF1F4260),
      onPrimaryContainer: Color(0xFFD2E5F6),
      accent: Color(0xFFD2B3E3),
      surface: Color(0xFF111417),
      surfaceVariant: Color(0xFF1B1F23),
      onSurface: Color(0xFFEFF2F5),
      mutedText: Color(0xFFB3BAC2),
      outline: Color(0xFF6C757E),
      outlineVariant: Color(0xFF39414A),
    ),
  ),
};
