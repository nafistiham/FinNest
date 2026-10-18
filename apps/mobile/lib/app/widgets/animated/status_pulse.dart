/// A status dot for the safety badge and the "checking" state.
///
/// While [active] (a check is running) the dot breathes: opacity 1.0 ->
/// 0.35 -> 1.0 once every [Motion.breathe] (1.6 s, easeInOut), with a faint
/// halo. When the result settles ([active] false) it eases to a solid dot
/// and stops; a settled BLOCK or HOLD never pulses (no alarm, no
/// celebration).
///
/// The colour is the status text colour of the palette
/// (`palette.statusText`, brightness-aware: dark mode gets the light tints).
///
/// Reduce motion: a solid dot, no breathing, no halo.
library;

import 'package:flutter/widgets.dart';

import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';

class StatusPulse extends StatefulWidget {
  const StatusPulse({
    required this.status,
    this.active = false,
    this.size = 10,
    this.shape = BoxShape.circle,
    this.semanticLabel,
    super.key,
  });

  final BhStatus status;

  /// True while checking; false once the verdict is in.
  final bool active;

  /// Dot diameter in dp; the widget reserves twice this for the halo.
  final double size;

  final BoxShape shape;

  /// E.g. "যাচাই হচ্ছে"; none by default (the row text says it).
  final String? semanticLabel;

  @override
  State<StatusPulse> createState() => _StatusPulseState();
}

class _StatusPulseState extends State<StatusPulse>
    with SingleTickerProviderStateMixin {
  // value 1 = full opacity (settled), 0 = the dimmest point of a breath.
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StatusPulse old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    final m = Motion.of(context);
    if (m.reduced) {
      _c
        ..stop()
        ..value = 1;
    } else if (widget.active) {
      if (!_c.isAnimating) {
        _c.duration = m.breathe ~/ 2;
        _c.repeat(reverse: true);
      }
    } else {
      _c.animateTo(1, duration: m.exit, curve: MotionCurves.release);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.palette.statusText(widget.status);
    final s = widget.size;
    final reduced = Motion.of(context).reduced;
    final dot = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = MotionCurves.pulse.transform(_c.value);
        final opacity = 0.35 + 0.65 * t;
        final halo = widget.active && !reduced ? (1 - t) : 0.0;
        return SizedBox.square(
          dimension: s * 2,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (halo > 0)
                Container(
                  width: s * (1.2 + 0.8 * halo),
                  height: s * (1.2 + 0.8 * halo),
                  decoration: BoxDecoration(
                    shape: widget.shape,
                    color: color.withValues(alpha: 0.18 * halo),
                  ),
                ),
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: widget.shape,
                  color: color.withValues(alpha: opacity),
                ),
              ),
            ],
          ),
        );
      },
    );
    return widget.semanticLabel == null
        ? ExcludeSemantics(child: dot)
        : Semantics(label: widget.semanticLabel, liveRegion: true, child: dot);
  }
}
