/// Expressive typography for big numbers (Wise-style display figures).
///
/// - [DisplayAmountStyle]: heavy, tight-leading amount style for the active
///   locale and palette (`DisplayAmountStyle(context)` is a `TextStyle`).
/// - [DigitSlotMetrics]: the fixed slot every digit sits in, measured once
///   per style from the widest digit of the active script. SolaimanLipi has
///   no tabular figures (১ is narrow, ৪ is wide), so Bangla amounts would
///   jitter as they change without it.
/// - [TabularBangla]: static text with every digit in its slot.
///
/// Nothing here animates, so there is no reduce-motion path.
library;

import 'package:flutter/widgets.dart';

import '../../l10n.dart';
import '../../theme/palette.dart';
import '../../theme/typography.dart';

/// The display amount style: heavy weight, tight line height, near-black
/// ink (the palette's `onSurface`).
///
/// Bangla: SolaimanLipi 700 (the only bold it has), line height 0.95,
/// letter spacing 0 (tracking breaks the joins). Latin: Roboto 800, line
/// height 0.9, tracking -2 % of the size, tabular figures. The tight leading
/// is only for digit runs;
/// never use it for reading text. `leadingDistribution: even` keeps the
/// glyphs centred in the tight box.
class DisplayAmountStyle extends TextStyle {
  DisplayAmountStyle(BuildContext context, {double size = 44, Color? color})
    : this._(
        Localizations.maybeLocaleOf(context),
        size,
        color ?? context.palette.onSurface,
      );

  /// The display face: Baloo Da 2 (variable, Bangla and Latin digits in one
  /// file) at its heaviest weight, so an amount reads as the one bold
  /// object on the screen. The script's text face is the fallback for any
  /// glyph it lacks.
  static const family = 'BalooDa2';
  static const weight = 800.0;

  DisplayAmountStyle._(Locale? locale, double size, Color color)
    : super(
        fontFamily: family,
        fontFamilyFallback: [
          ?BhType.familyFor(locale),
          ...BhType.fallbackFor(locale),
        ],
        fontSize: size,
        fontWeight: FontWeight.w800,
        fontVariations: const [FontVariation.weight(weight)],
        height: _bangla(locale) ? 0.95 : 0.9,
        letterSpacing: _bangla(locale) ? 0 : -size * 0.01,
        leadingDistribution: TextLeadingDistribution.even,
        color: color,
        fontFeatures: _bangla(locale)
            ? null
            : const [FontFeature.tabularFigures()],
      );

  static bool _bangla(Locale? locale) => locale?.languageCode != 'en';
}

/// Width and height of one digit slot for a style and text scale.
@immutable
class DigitSlotMetrics {
  const DigitSlotMetrics(this.width, this.height);

  /// The widest advance among the ten digits of the script.
  final double width;

  /// The laid-out line height of one digit.
  final double height;

  static const bnDigitChars = '০১২৩৪৫৬৭৮৯';
  static const enDigitChars = '0123456789';

  static final Map<(TextStyle, double, bool), DigitSlotMetrics> _cache = {};

  /// Measured once per (style, scaled size, script) and cached.
  static DigitSlotMetrics of(
    TextStyle style,
    TextScaler scaler, {
    required bool bangla,
  }) {
    final size = scaler.scale(style.fontSize ?? 14);
    return _cache.putIfAbsent((style, size, bangla), () {
      var w = 0.0;
      var h = 0.0;
      for (final d in (bangla ? bnDigitChars : enDigitChars).characters) {
        final tp = TextPainter(
          text: TextSpan(text: d, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        if (tp.width > w) w = tp.width;
        if (tp.height > h) h = tp.height;
        tp.dispose();
      }
      return DigitSlotMetrics(w, h);
    });
  }

  /// Whether [rune] is a digit in either script.
  static bool isDigit(int rune) =>
      (rune >= 0x30 && rune <= 0x39) || (rune >= 0x09E6 && rune <= 0x09EF);
}

/// [text] with every digit (Bangla or Latin) centred in a fixed slot, so a
/// changing number keeps its width. Other characters (commas, spaces, ৳)
/// keep their natural width. One semantics node with [semanticsLabel]
/// (default: [text]); the slots are excluded.
class TabularBangla extends StatelessWidget {
  const TabularBangla(
    this.text, {
    required this.style,
    this.semanticsLabel,
    super.key,
  });

  /// Already formatted (`context.digits(groupLakh(n))`, `context.taka(n)`).
  final String text;
  final TextStyle style;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final bangla =
        text.runes.any((r) => r >= 0x09E6 && r <= 0x09EF) ||
        context.banglaDigits;
    final slot = DigitSlotMetrics.of(
      style,
      MediaQuery.textScalerOf(context),
      bangla: bangla,
    );
    return Semantics(
      label: semanticsLabel ?? text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            for (final ch in text.characters)
              if (ch.runes.length == 1 &&
                  DigitSlotMetrics.isDigit(ch.runes.first))
                SizedBox(
                  width: slot.width,
                  child: Text(
                    ch,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    style: style,
                  ),
                )
              else
                Text(ch, maxLines: 1, softWrap: false, style: style),
          ],
        ),
      ),
    );
  }
}
