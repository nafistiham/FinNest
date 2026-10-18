import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';

enum NumberGrouping {
  /// 5-6: ০১৭১২-৩৪৫৬৭৮.
  phone,

  /// 4-4-…: ১২৩৪ ৫৬৭৮.
  account,
}

/// Groups raw ASCII [digits] for display (no script conversion).
String groupNumber(String digits, NumberGrouping grouping) {
  switch (grouping) {
    case NumberGrouping.phone:
      if (digits.length <= 5) return digits;
      return '${digits.substring(0, 5)}-${digits.substring(5)}';
    case NumberGrouping.account:
      final out = StringBuffer();
      for (var i = 0; i < digits.length; i++) {
        if (i > 0 && i % 4 == 0) out.write(' ');
        out.write(digits[i]);
      }
      return out.toString();
  }
}

/// A phone or account number being typed (7.6): 32 sp bold, grouped,
/// digits in the active script, a 2 dp `primary` caret, a counter line
/// "৮/১১ সংখ্যা" and the danger colour when [invalid].
///
/// [NumberDisplay.grouped] takes text the caller already grouped (the pay
/// flows' `NumberEntryController`) with its own count and length.
class NumberDisplay extends StatelessWidget {
  const NumberDisplay({
    required this.digits,
    required this.maxDigits,
    this.grouping = NumberGrouping.phone,
    this.invalid = false,
    super.key,
  }) : grouped = null,
       count = null;

  const NumberDisplay.grouped({
    required String this.grouped,
    required int this.count,
    required int length,
    this.invalid = false,
    super.key,
  }) : digits = '',
       maxDigits = length,
       grouping = NumberGrouping.phone;

  /// ASCII digits typed so far.
  final String digits;
  final int maxDigits;
  final NumberGrouping grouping;
  final bool invalid;

  /// Pre-grouped ASCII text ([NumberDisplay.grouped]).
  final String? grouped;

  /// Digits typed ([NumberDisplay.grouped]).
  final int? count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shown = context.digits(grouped ?? groupNumber(digits, grouping));
    final n = count ?? digits.length;
    final counter = grouped != null
        ? context.l10n.numberCount(
            context.digits('$n'),
            context.digits('$maxDigits'),
          )
        : maxDigits == 11
        ? context.l10n.numberDigitsLeft(context.digits('$n'))
        : context.digits('$n/$maxDigits');
    return Semantics(
      liveRegion: true,
      label: '$shown, $counter',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    shown.isEmpty ? ' ' : shown,
                    key: const Key('number_display'),
                    maxLines: 1,
                    style: context.textRoles.numberEntry.copyWith(
                      color: invalid ? p.danger : p.onSurface,
                    ),
                  ),
                  Container(
                    width: 2,
                    height: 26,
                    margin: const EdgeInsetsDirectional.only(start: 2),
                    color: p.primary,
                  ),
                ],
              ),
            ),
            Text(
              counter,
              key: const Key('number_counter'),
              textScaler: TextScaler.noScaling,
              style: context.textRoles.pinDigitCounter.copyWith(
                color: p.mutedText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
