import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/animated/skeleton.dart';

/// Three skeleton rows in the shape of the plan and product cards while the
/// store loads (never a spinner for content with a shape), one "লোড হচ্ছে"
/// semantics label on the group. Empty and failed states use the shared
/// `EmptyState`.
class FinanceLoading extends StatelessWidget {
  const FinanceLoading({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('finance_loading'),
    label: context.l10n.loadingList,
    child: const Padding(
      padding: EdgeInsets.all(BhSpace.m),
      child: Column(children: [SkeletonRow(), SkeletonRow(), SkeletonRow()]),
    ),
  );
}

/// A 6 dp progress bar, `primary` on `outlineVariant`, square ends.
/// [value] is clamped to 0..1.
class FinanceProgressBar extends StatelessWidget {
  const FinanceProgressBar({
    required this.value,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final double value;

  /// Defaults to `primary`.
  final Color? color;
  final String? semanticLabel;

  static const height = 6.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: ColoredBox(
            color: p.outlineVariant,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                key: const Key('finance_progress_fill'),
                widthFactor: value.clamp(0.0, 1.0),
                heightFactor: 1,
                child: ColoredBox(color: color ?? p.primary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `3.0` -> `3`, `6.5` -> `6.5` (ASCII; callers pass it through `context.digits`).
String percentLabel(double pct) =>
    pct == pct.roundToDouble() ? pct.round().toString() : pct.toString();
