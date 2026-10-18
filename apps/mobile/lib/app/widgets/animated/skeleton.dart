/// Loading placeholders: square-cornered `surfaceVariant` blocks with a
/// soft highlight band sweeping left to right, linearly, every
/// [Motion.shimmer] (1.2 s). Never a spinner for content that has a shape.
///
/// - [Skeleton]: one block (a line of text, an amount, a card).
/// - [SkeletonRow]: a 72 dp list row (leading square + two lines).
///
/// Excluded from semantics unless [Skeleton.semanticLabel] is given (put
/// one label, e.g. "লোড হচ্ছে", on the group, not on every block).
///
/// Reduce motion: a static `surfaceVariant` block, no sweep.
library;

import 'package:flutter/widgets.dart';

import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';
import '../../theme/tokens.dart';

class Skeleton extends StatefulWidget {
  const Skeleton({this.width, this.height = 16, this.semanticLabel, super.key});

  /// The Home balance placeholder: 160 x 44.
  const Skeleton.amount({this.semanticLabel, super.key})
    : width = 160,
      height = 44;

  /// Null = as wide as the parent allows.
  final double? width;
  final double height;
  final String? semanticLabel;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final m = Motion.of(context);
    if (m.reduced) {
      _c
        ..stop()
        ..value = 0;
    } else if (!_c.isAnimating) {
      _c
        ..duration = m.shimmer
        ..repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = p.surfaceVariant;
    final highlight = Color.alphaBlend(
      p.onSurface.withValues(alpha: p.isDark ? 0.08 : 0.06),
      base,
    );
    final reduced = Motion.of(context).reduced;
    final block = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (reduced) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: ColoredBox(color: base),
          );
        }
        // The band centre travels from -1.5 to +1.5 (fully off both sides).
        final x = -1.5 + 3 * _c.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(x - 1, 0),
              end: Alignment(x + 1, 0),
              colors: [base, highlight, base],
            ),
          ),
        );
      },
    );
    return widget.semanticLabel == null
        ? ExcludeSemantics(child: block)
        : Semantics(label: widget.semanticLabel, child: block);
  }
}

/// A loading list row: 40 dp leading square, a title line at 60 % and a
/// subtitle line at 35 % of the row, 72 dp tall.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({this.height = BhSize.rowHeight, super.key});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: [
        const Skeleton(width: BhSize.avatarSmall, height: BhSize.avatarSmall),
        const SizedBox(width: BhSpace.m),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(width: c.maxWidth * 0.6, height: 16),
                const SizedBox(height: BhSpace.s),
                Skeleton(width: c.maxWidth * 0.35, height: 14),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
