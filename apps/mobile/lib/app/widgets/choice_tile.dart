/// Selectable tiles (7.12): [ChoiceTile] (operator
/// chips, prepaid / postpaid, plan amounts and tenures, the demo panel's
/// 2 x 2 verdict grid, History filters) and [QuickAmountRow] (four equal
/// quick amounts in one row, never a scroller).
///
/// Selected = `primaryContainer` fill with a 2 dp `primary` border;
/// unselected = 1 dp `outline`. Fill and border change over `fast`; the
/// press is a [Pressable] (scale + shade, reduce motion: shade only).
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';
import 'animated/pressable.dart';

class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.height = 48,
    this.semanticLabel,
    this.tabular = false,
    this.scaleDown = false,
    super.key,
  });

  final String label;
  final bool selected;

  /// Null disables the tile.
  final VoidCallback? onTap;

  /// 48 dp chips; 56 dp for primary choices.
  final double height;

  /// Spoken label; defaults to [label].
  final String? semanticLabel;

  /// Tabular figures (amounts).
  final bool tabular;

  /// Shrink a long label to fit instead of ellipsising (amounts).
  final bool scaleDown;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: selected ? p.onPrimaryContainer : p.onSurface,
      fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
    );
    final Widget text = scaleDown
        ? FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1, style: style),
          )
        : Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: semanticLabel ?? label,
      child: AnimatedContainer(
        duration: BhMotion.of(context).fast,
        height: height,
        decoration: BoxDecoration(
          color: selected ? p.primaryContainer : Colors.transparent,
          border: Border.all(
            color: selected ? p.primary : p.outline,
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
        alignment: Alignment.center,
        child: text,
      ),
    );
  }
}

/// Four quick amounts in one row of equal chips with 8 dp gaps, never a
/// scroller, so the fourth is always visible. A chip is
/// selected exactly when the typed amount equals it; tapping replaces the
/// amount.
class QuickAmountRow extends StatelessWidget {
  const QuickAmountRow({
    required this.amounts,
    required this.selected,
    required this.onPick,
    this.height = BhSize.touch,
    super.key,
  });

  final List<int> amounts;
  final int selected;
  final ValueChanged<int> onPick;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('quick_amounts'),
      children: [
        for (final (i, a) in amounts.indexed) ...[
          if (i > 0) const SizedBox(width: BhSpace.s),
          Expanded(
            child: ChoiceTile(
              key: Key('quick_$a'),
              label: context.taka(a),
              selected: a == selected,
              height: height,
              tabular: true,
              scaleDown: true,
              onTap: () => onPick(a),
            ),
          ),
        ],
      ],
    );
  }
}
