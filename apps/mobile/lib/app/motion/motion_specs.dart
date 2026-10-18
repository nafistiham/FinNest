/// Motion names for the animated component library
/// (`lib/app/widgets/animated`).
///
/// There is one motion token source: `lib/app/theme/motion.dart`
/// ([BhMotion], [BhCurves]). This file only gives the
/// library its own names for them ([Motion] is [BhMotion], [MotionCurves] is
/// [BhCurves]) and holds [StaggeredReveal]. Tune a timing in motion.dart and
/// every screen and component follows.
///
/// Money motion is calm and low amplitude: a short preparation beat before a
/// balance shows, deliberate 240-400 ms easing, no bounce on hold or block.
/// Everything goes through [Motion.of], which returns zero durations when the
/// system asks for reduced motion (`MediaQuery.disableAnimationsOf`).
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

export '../theme/motion.dart' show BhCurves, BhMotion;

/// The component library's name for [BhCurves].
typedef MotionCurves = BhCurves;

/// The component library's name for [BhMotion].
typedef Motion = BhMotion;

/// Runs [start] once the enclosing route has finished entering, so a
/// first-paint animation is not hidden under the page transition (a 240 ms
/// reveal that starts with a 450 ms push is over before the page is fully
/// on screen). The decision waits for the end of the current frame: at a
/// route's first build the transition can still report itself settled
/// before the navigator has started it. Immediate (next frame) when there
/// is no route or it is already settled. Callers check `mounted` inside
/// [start].
void afterRouteEntrance(BuildContext context, VoidCallback start) {
  final anim = ModalRoute.of(context)?.animation;
  if (anim == null) {
    start();
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!anim.isAnimating) {
      start();
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        anim.removeStatusListener(listener);
        start();
      }
    };
    anim.addStatusListener(listener);
  });
}

/// Children fade in and rise [offset] dp one after another, [Motion.stagger]
/// apart, each over [Motion.enter]. One-shot: plays on first build only;
/// later rebuilds (new children, new parent state) show them settled.
/// Only the first [maxStaggered] children are staggered; the rest arrive
/// with the last one, so a long list never waits. An empty `SizedBox`
/// spacer takes no beat of its own, so spacing a column does not slow its
/// cascade. The run starts after the enclosing route has entered
/// ([afterRouteEntrance]) plus [delay], so a page's reveal is seen, not
/// buried under the push transition.
///
/// Reduce motion: children render at once, no fade, no movement.
class StaggeredReveal extends StatefulWidget {
  const StaggeredReveal({
    required this.children,
    this.offset = 8,
    this.maxStaggered = 5,
    this.delay = Duration.zero,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.mainAxisSize = MainAxisSize.min,
    super.key,
  });

  final List<Widget> children;

  /// Rise distance in dp.
  final double offset;

  /// How many children get their own beat.
  final int maxStaggered;

  /// Extra wait before the first child moves (after the route entrance),
  /// e.g. a nested cascade that follows its parent's.
  final Duration delay;

  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisSize mainAxisSize;

  @override
  State<StaggeredReveal> createState() => _StaggeredRevealState();
}

class _StaggeredRevealState extends State<StaggeredReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  bool _started = false;

  static bool _isSpacer(Widget w) => w is SizedBox && w.child == null;

  /// Beat of each child: spacers share the beat of the child after them.
  /// Computed per build: the children can change while the run is still on
  /// (a pending card arriving on Home).
  List<int> _beatsFor(List<Widget> children) {
    final beats = <int>[];
    var next = 0;
    for (final w in children) {
      beats.add(math.min(next, widget.maxStaggered - 1));
      if (!_isSpacer(w)) next++;
    }
    return beats;
  }

  int get _beats => math.max(
    1,
    math.min(
      widget.children.where((w) => !_isSpacer(w)).length,
      widget.maxStaggered,
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final m = Motion.of(context);
    if (m.reduced) {
      _c.value = 1;
      return;
    }
    _c.duration = widget.delay + m.enter + m.stagger * (_beats - 1);
    afterRouteEntrance(context, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _c.duration?.inMicroseconds ?? 0;
    if (total == 0) {
      // Reduce motion: decided once, before the first frame, so the
      // subtree shape never changes afterwards.
      return Column(
        crossAxisAlignment: widget.crossAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        children: widget.children,
      );
    }
    const m = Motion.standard;
    final enter = m.enter.inMicroseconds / total;
    final step = m.stagger.inMicroseconds / total;
    final delay = widget.delay.inMicroseconds / total;
    final beatOf = _beatsFor(widget.children);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Column(
        crossAxisAlignment: widget.crossAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            _rise(_progress(beatOf[i], delay, step, enter), widget.children[i]),
        ],
      ),
    );
  }

  double _progress(int beat, double delay, double step, double enter) {
    final start = delay + step * beat;
    final end = math.min(1.0, start + enter);
    final t = Interval(start, end).transform(_c.value);
    return MotionCurves.enter.transform(t);
  }

  Widget _rise(double t, Widget child) => Opacity(
    opacity: t,
    child: Transform.translate(
      offset: Offset(0, widget.offset * (1 - t)),
      child: child,
    ),
  );
}
