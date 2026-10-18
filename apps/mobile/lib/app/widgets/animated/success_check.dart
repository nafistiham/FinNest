/// Success confirmation: a circle stroke draws, then the check mark draws,
/// over [Motion.checkDraw] (480 ms), settling with a small overshoot
/// (scale 0.88 -> ~1.004 -> 1.0 on [MotionCurves.emphasis]).
/// `Haptics.success()` fires once, at the end of the draw, then [onDone].
///
/// [AmountConfirm] plays the check, then fades in the amount rolling up
/// from 0 ([RollingAmount]): "the check lands, then the amount confirms".
///
/// Only for a completed, good outcome. Never use it for held or blocked
/// money (that is not a celebration; use a static icon square, 6.2).
///
/// Reduce motion: the final frame at once; the haptic and [onDone] still
/// fire (after the first frame); the amount shows without a roll.
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

import '../../../core/haptics.dart';
import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';
import '../../theme/tokens.dart';
import 'expressive_text.dart';
import 'rolling_amount.dart';

class SuccessCheck extends StatefulWidget {
  const SuccessCheck({
    this.size = 72,
    this.color,
    this.onDone,
    this.semanticLabel,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  final double size;

  /// Stroke colour; defaults to the palette's `success` (brightness-aware).
  final Color? color;

  /// Called once when the draw completes.
  final VoidCallback? onDone;

  /// Spoken label (e.g. the result title); none by default, since the
  /// screen title usually says it.
  final String? semanticLabel;

  final Haptics haptics;

  @override
  State<SuccessCheck> createState() => _SuccessCheckState();
}

class _SuccessCheckState extends State<SuccessCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && !_jumping) _finish();
    });
  bool _started = false;
  bool _jumping = false;
  bool _finished = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final m = Motion.of(context);
    if (m.reduced) {
      // Setting the value fires the status listener synchronously, inside
      // build; finish after the frame instead.
      _jumping = true;
      _c.value = 1;
      _jumping = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finish();
      });
    } else {
      _c.duration = m.checkDraw;
      _c.forward();
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    unawaited(widget.haptics.success());
    widget.onDone?.call();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.palette.success;
    final painted = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final scale = 0.88 + 0.12 * MotionCurves.emphasis.transform(t);
        return Transform.scale(
          scale: scale,
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: SuccessCheckPainter(
              circle: MotionCurves.enter.transform(
                const Interval(0, 0.55).transform(t),
              ),
              check: MotionCurves.enter.transform(
                const Interval(0.4, 1).transform(t),
              ),
              color: color,
            ),
          ),
        );
      },
    );
    return Semantics(
      label: widget.semanticLabel,
      image: widget.semanticLabel != null,
      excludeSemantics: true,
      child: SizedBox.square(dimension: widget.size, child: painted),
    );
  }
}

/// Paints [circle] (0..1) of the ring, from 12 o'clock clockwise, and
/// [check] (0..1) of the tick, both as round-capped strokes.
class SuccessCheckPainter extends CustomPainter {
  const SuccessCheckPainter({
    required this.circle,
    required this.check,
    required this.color,
  });

  final double circle;
  final double check;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = math.max(2.0, s * 0.075);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, s - stroke, s - stroke);
    if (circle > 0) {
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * circle, false, paint);
    }
    if (check > 0) {
      final tick = Path()
        ..moveTo(s * 0.29, s * 0.52)
        ..lineTo(s * 0.44, s * 0.67)
        ..lineTo(s * 0.72, s * 0.37);
      final out = Path();
      var remaining = check * _length(tick);
      for (final PathMetric pm in tick.computeMetrics()) {
        final take = math.min(remaining, pm.length);
        out.addPath(pm.extractPath(0, take), Offset.zero);
        remaining -= take;
        if (remaining <= 0) break;
      }
      canvas.drawPath(out, paint);
    }
  }

  static double _length(Path p) =>
      p.computeMetrics().fold(0.0, (sum, m) => sum + m.length);

  @override
  bool shouldRepaint(SuccessCheckPainter old) =>
      old.circle != circle || old.check != check || old.color != color;
}

/// The check draws, then [amount] fades in and rolls up from 0. For the
/// "money sent" result: confirmation first, then the number.
class AmountConfirm extends StatefulWidget {
  const AmountConfirm({
    required this.amount,
    this.checkSize = 72,
    this.color,
    this.style,
    this.caption,
    this.onDone,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  final num amount;
  final double checkSize;

  /// Check colour; defaults to the palette's `success`.
  final Color? color;

  /// Amount style; defaults to [DisplayAmountStyle] at 44 sp.
  final TextStyle? style;

  /// Optional line under the amount (e.g. "এক লাখ টাকা").
  final Widget? caption;

  /// Called when the check has drawn (before the amount finishes rolling).
  final VoidCallback? onDone;
  final Haptics haptics;

  static const amountKey = Key('amount_confirm_amount');

  @override
  State<AmountConfirm> createState() => _AmountConfirmState();
}

class _AmountConfirmState extends State<AmountConfirm> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final m = Motion.of(context);
    final style = widget.style ?? DisplayAmountStyle(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SuccessCheck(
          size: widget.checkSize,
          color: widget.color,
          haptics: widget.haptics,
          onDone: () {
            if (mounted) setState(() => _checked = true);
            widget.onDone?.call();
          },
        ),
        const SizedBox(height: BhSpace.m),
        AnimatedOpacity(
          opacity: _checked ? 1 : 0,
          duration: m.reduced ? Motion.crossfade : m.enter,
          curve: MotionCurves.enter,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            // A new key on the check makes a fresh RollingAmount that rolls
            // from 0; before that an invisible one holds the final width.
            child: RollingAmount(
              widget.amount,
              key: _checked ? AmountConfirm.amountKey : null,
              from: _checked ? 0 : null,
              style: style,
            ),
          ),
        ),
        if (widget.caption != null) ...[
          const SizedBox(height: BhSpace.xs),
          AnimatedOpacity(
            opacity: _checked ? 1 : 0,
            duration: m.reduced ? Motion.crossfade : m.enter,
            child: widget.caption,
          ),
        ],
      ],
    );
  }
}
