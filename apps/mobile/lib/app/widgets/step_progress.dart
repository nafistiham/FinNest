import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';

/// 4 dp bar under a pay-flow app bar (7.14): [total] equal segments with
/// 2 dp gaps. Done segments are `primary`; the current segment's `primary`
/// fill grows over `normal` when the step opens, over an `outline` track;
/// upcoming segments are `outline`. Every track is at least 3:1 against
/// the surface in both brightnesses and every preset (the dark
/// `primaryContainer` / `outlineVariant` tracks were invisible on the demo
/// phone).
class StepProgress extends StatelessWidget {
  const StepProgress({required this.step, required this.total, super.key})
    : assert(step >= 1 && step <= total);

  /// 1-based current step.
  final int step;
  final int total;

  static const height = 4.0;

  /// Key of segment [i] (1-based), for layout tests.
  static Key segmentKey(int i) => Key('step_segment_$i');

  /// Key of the current segment's growing fill.
  static const fillKey = Key('step_segment_fill');

  /// The track colour of segment [i] when the current step is [step].
  static Color trackColor(BhPalette p, int i, int step) =>
      i < step ? p.primary : p.outline;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final motion = BhMotion.of(context);
    final l10n = context.l10n;
    return Semantics(
      label: l10n.stepOf(context.digits('$step'), context.digits('$total')),
      child: ExcludeSemantics(
        child: SizedBox(
          key: const Key('step_progress'),
          height: height,
          child: Row(
            children: [
              for (var i = 1; i <= total; i++) ...[
                if (i > 1) const SizedBox(width: BhSpace.xxs),
                Expanded(
                  child: ColoredBox(
                    key: segmentKey(i),
                    color: trackColor(p, i, step),
                    child: i == step
                        ? TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: motion.normal,
                            curve: BhCurves.enter,
                            builder: (_, t, _) => FractionallySizedBox(
                              alignment: AlignmentDirectional.centerStart,
                              widthFactor: t,
                              child: ColoredBox(key: fillKey, color: p.primary),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
