/// Entrances for bottom sheets and overlays.
///
/// - [SheetHandleReveal]: the sheet's drag handle grows from the centre
///   (0 -> 32 dp) and fades in over [Motion.enter], a beat after the sheet
///   itself; square-cornered, `outline` colour, decorative.
/// - [SlideFadeIn]: content slides up [SlideFadeIn.offset] dp and fades in
///   over [Motion.overlay] (280 ms), optionally over a fading [scrim].
///   Default curve: a gentle easeOutBack-lite settle for friendly sheets.
///   `firm: true` for hold / block overlays: decisive deceleration, no
///   overshoot, nothing that reads as playful.
///
/// The content is hit-testable from the first frame (6.2: overlay action
/// buttons must be tappable the moment they show). Both are one-shot.
///
/// Reduce motion: shown at once (no slide, no fade, scrim at full).
library;

import 'package:flutter/widgets.dart';

import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';
import '../../theme/tokens.dart';

class SheetHandleReveal extends StatelessWidget {
  const SheetHandleReveal({
    this.width = 32,
    this.thickness = 4,
    this.color,
    super.key,
  });

  final double width;
  final double thickness;

  /// Defaults to the palette's `outline`.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final m = Motion.of(context);
    final c = color ?? context.palette.outline;
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BhSpace.s),
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: m.reduced ? 1 : 0, end: 1),
            duration: m.enter + m.stagger,
            curve: const Interval(0.15, 1, curve: MotionCurves.enter),
            builder: (context, t, _) => Opacity(
              opacity: t,
              child: SizedBox(
                width: width * (0.2 + 0.8 * t),
                height: thickness,
                child: ColoredBox(color: c),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SlideFadeIn extends StatefulWidget {
  const SlideFadeIn({
    required this.child,
    this.offset = 32,
    this.firm = false,
    this.scrim,
    this.alignment = Alignment.bottomCenter,
    this.delay = Duration.zero,
    this.duration,
    super.key,
  });

  final Widget child;

  /// Rise distance in dp.
  final double offset;

  /// Hold / block: firm curve, no overshoot.
  final bool firm;

  /// When set, the widget fills its parent: [scrim] fades in behind and the
  /// child is placed at [alignment].
  final Color? scrim;
  final Alignment alignment;

  /// Wait before starting (e.g. after the scrim, or a stagger).
  final Duration delay;

  /// Defaults to [Motion.overlay].
  final Duration? duration;

  @override
  State<SlideFadeIn> createState() => _SlideFadeInState();
}

class _SlideFadeInState extends State<SlideFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  bool _started = false;
  double _delayFrac = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final m = Motion.of(context);
    final d = widget.duration ?? m.overlay;
    if (m.reduced || d == Duration.zero) {
      _c.value = 1;
      return;
    }
    final total = d + widget.delay;
    _delayFrac = widget.delay.inMicroseconds / total.inMicroseconds;
    _c
      ..duration = total
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = widget.firm ? MotionCurves.firm : MotionCurves.emphasis;
    final content = AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final raw = Interval(_delayFrac, 1).transform(_c.value);
        final t = curve.transform(raw);
        return Opacity(
          opacity: Curves.easeOut.transform(raw),
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - t)),
            child: child,
          ),
        );
      },
    );
    final scrim = widget.scrim;
    if (scrim == null) return content;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) => ColoredBox(
            // The scrim leads: full by the time the content is half in.
            color: scrim.withValues(
              alpha:
                  scrim.a *
                  MotionCurves.enter.transform((_c.value * 2).clamp(0.0, 1.0)),
            ),
          ),
        ),
        Align(alignment: widget.alignment, child: content),
      ],
    );
  }
}
