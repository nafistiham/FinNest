import 'package:flutter/material.dart';

import 'palette.dart';

/// Legacy colour constants (Teal trust, light). The palette lives in
/// `palette.dart` (`context.palette`); these stay for one release so call
/// sites migrate package by package. The status
/// constants remain for code that cannot reach a context (tests, painters);
/// the brand constants are deprecated and removed in package D.
abstract final class BhColors {
  @Deprecated('use context.palette.primary')
  static const primary = Color(0xFF0F6E67);
  @Deprecated('use context.palette.onPrimaryContainer')
  static const primaryDark = Color(0xFF0A4F4A);
  @Deprecated('use context.palette.primaryContainer')
  static const primarySoft = Color(0xFFD9ECEA);
  static const caution = Color(0xFFD98E04);
  static const cautionSoft = Color(0xFFFFF1D6);
  static const danger = Color(0xFFB3261E);
  static const dangerSoft = Color(0xFFFBE4E2);
  static const ok = Color(0xFF1E7B3A);
  static const okSoft = Color(0xFFDFF3E4);
  @Deprecated('use context.palette.surface')
  static const surface = Color(0xFFFBFAF6);
  @Deprecated('use context.palette.surfaceVariant')
  static const surfaceAlt = Color(0xFFF1EFE8);
  @Deprecated('use context.palette.onSurface')
  static const ink = Color(0xFF1B1B1B);
  @Deprecated('use context.palette.mutedText')
  static const muted = Color(0xFF5B5F66);
  @Deprecated('use context.palette.outlineVariant')
  static const line = Color(0xFFD9D6CC);
  static const onPrimary = Colors.white;

  /// Text and icons on any legacy `...Soft` fill (light in both
  /// brightnesses). New code uses the palette's `on...Container`.
  static const onSoft = Color(0xFF1B1B1B);

  /// Amber for text and icons on light fills and the light surface
  /// (5.7:1 on [surface], 5.3:1 on [cautionSoft]). [caution] itself is only
  /// 2.6:1 on the surface: use it for fills, borders and stripes, never text.
  static const cautionInk = Color(0xFF8A5A00);

  // Dark-theme surfaces and the status colours that read on them (all 9:1
  // or better on [surfaceDark] and [surfaceAltDark]). Feature code reaches
  // them through the `ColorScheme` accessors below, never directly.
  static const surfaceDark = Color(0xFF151716);
  static const surfaceAltDark = Color(0xFF1E2120);
  static const inkOnDark = Color(0xFFF2F1EC);
  static const mutedOnDark = Color(0xFFB4B8BD);
  static const primaryOnDark = Color(0xFF7FD1C8);
  static const dangerOnDark = Color(0xFFF2B8B5);
  static const okOnDark = Color(0xFF7DD99A);
  static const cautionOnDark = Color(0xFFFFC95C);
}

/// Status colours for text and icons drawn on the screen surface or a card,
/// picked by the theme's brightness: `Theme.of(context).colorScheme.dangerText`.
/// They return the palette's `danger / success / warning / mutedText`
/// (status colours are the same in every preset, so the brightness is
/// enough; muted text is the scheme's `onSurfaceVariant`).
extension BhStatusColors on ColorScheme {
  BhPalette get _status =>
      brightness == Brightness.dark ? _tealDark : BhPalette.tealLight;

  /// Hold, block, errors.
  Color get dangerText => _status.danger;

  /// Done, credits, safe.
  Color get okText => _status.success;

  /// Delay, step-up, pending.
  Color get cautionText => _status.warning;

  /// Secondary text and chrome icons (same as `textTheme.bodySmall`).
  Color get mutedText => onSurfaceVariant;
}

final _tealDark = BhPalette.of(BhPreset.teal, Brightness.dark);

abstract final class BhSpace {
  /// Hairline gaps (tag inner vertical).
  static const xxs = 2.0;
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 16.0;
  static const l = 24.0;
  static const xl = 32.0;

  /// Empty-state top padding.
  static const xxl = 48.0;
}

abstract final class BhSize {
  /// Minimum touch target (dp). Larger than Material's 48 on purpose: the
  /// users are often first-time smartphone owners.
  static const touch = 56.0;

  /// PIN pad keys (regular).
  static const key = 72.0;

  /// Amount numpad keys (regular).
  static const keyAmount = 64.0;

  /// Numpad keys on compact screens.
  static const keyCompact = 56.0;

  static const rowHeight = 72.0;
  static const rowHeightCompact = 64.0;
  static const appBar = 64.0;
  static const appBarCompact = 56.0;

  /// Bottom-bar button height (plus 8 top and 16 bottom padding).
  static const bottomBar = 56.0;

  /// Feature tile height (8 + 44 + 6 + two 14 sp lines + 8).
  static const tile = 100.0;
  static const avatar = 48.0;
  static const avatarSmall = 40.0;

  /// Leading status stripe on cards.
  static const stripe = 4.0;

  /// Screens shorter than this use the compact layout (4.1).
  static const compactBelowHeight = 700.0;
}

/// Legacy durations; new motion goes through `BhMotion.of(context)`.
abstract final class BhDuration {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 240);
}
