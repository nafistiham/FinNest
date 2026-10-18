import 'package:flutter/material.dart';

import '../l10n.dart';

/// A number with every Bangla digit centred in a fixed-width slot, so an
/// amount does not jump while it is typed or counted (SolaimanLipi has
/// no `tnum`, and ১ is narrow while ৪ is wide). Commas and
/// spaces keep their natural width. Latin digits use plain text with
/// tabular figures.
///
/// [text] is already formatted (`groupLakh`, active digits). Semantics come
/// from [semanticsLabel] on one node; the slots are excluded.
class DigitSlots extends StatelessWidget {
  const DigitSlots(
    this.text, {
    required this.style,
    this.semanticsLabel,
    super.key,
  });

  final String text;
  final TextStyle style;
  final String? semanticsLabel;

  static final Map<TextStyle, double> _slotCache = {};

  static bool isBanglaDigit(int rune) => rune >= 0x09E6 && rune <= 0x09EF;

  /// The widest advance among ০-৯ in [style] (measured once per style).
  static double slotWidth(TextStyle style, TextScaler scaler) {
    final key = style.copyWith(fontSize: scaler.scale(style.fontSize ?? 14));
    return _slotCache.putIfAbsent(key, () {
      var widest = 0.0;
      for (final d in '০১২৩৪৫৬৭৮৯'.characters) {
        final tp = TextPainter(
          text: TextSpan(text: d, style: key),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        if (tp.width > widest) widest = tp.width;
        tp.dispose();
      }
      return widest;
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = semanticsLabel ?? text;
    final hasBangla = text.runes.any(isBanglaDigit);
    if (!hasBangla) {
      return Text(
        text,
        semanticsLabel: label,
        maxLines: 1,
        softWrap: false,
        style: style.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }
    final scaler = MediaQuery.textScalerOf(context);
    final slot = slotWidth(style, scaler);
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            for (final ch in text.characters)
              if (ch.runes.length == 1 && isBanglaDigit(ch.runes.first))
                SizedBox(
                  width: slot,
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

/// "৳ ৫,০০০" as a row: the taka sign at [signScale] of the digit size in
/// [signColor], baseline-aligned, [gap] before the digit slots.
class TakaSlots extends StatelessWidget {
  const TakaSlots({
    required this.amount,
    required this.style,
    this.signColor,
    this.signScale = 0.6,
    this.gap = 4,
    this.prefix,
    this.semanticsLabel,
    this.hiddenDots = false,
    super.key,
  });

  final num amount;
  final TextStyle style;
  final Color? signColor;
  final double signScale;
  final double gap;

  /// Shown before the sign, e.g. "− " or "+ " in lists.
  final String? prefix;
  final String? semanticsLabel;

  /// Shows "• • • • •" instead of the digits (hidden balance).
  final bool hiddenDots;

  @override
  Widget build(BuildContext context) {
    final sign = style.copyWith(
      fontSize: (style.fontSize ?? 14) * signScale,
      color: signColor ?? style.color,
    );
    final grouped = context.digits(groupLakh(amount.abs()));
    return Semantics(
      label: semanticsLabel ?? context.taka(amount),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (prefix != null) Text(prefix!, style: style),
            Text('৳', style: sign),
            SizedBox(width: gap),
            if (hiddenDots)
              Text('• • • • •', style: style, maxLines: 1, softWrap: false)
            else
              DigitSlots(grouped, style: style),
          ],
        ),
      ),
    );
  }
}
