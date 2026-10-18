/// Ripple-free press feedback for 72 dp numpad keys:
/// the key background tints from [KeyFeedback.color] (default
/// `surfaceVariant`) to `primaryContainer` at 60 % over it, and the key
/// scales to 0.96, both in [Motion.keyTint] (120 ms), and back.
///
/// Visual only: it listens to raw pointers ([Listener], translucent) and
/// never joins the gesture arena, so the Numpad's own tap and raw-pointer
/// callbacks (the PIN pad's behaviour capture) keep working untouched.
/// Wrap the key's content, keep the key's own `InkWell` / `GestureDetector`
/// inside with `splashFactory: NoSplash.splashFactory`. [pressed] lets the
/// owner drive it (keyboard input, tests).
///
/// Reduce motion: the fill changes instantly, no scale.
library;

import 'package:flutter/widgets.dart';

import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';

class KeyFeedback extends StatefulWidget {
  const KeyFeedback({
    required this.child,
    this.color,
    this.pressedColor,
    this.pressed,
    this.enabled = true,
    this.scale = 0.96,
    super.key,
  });

  final Widget child;

  /// Resting fill; defaults to the palette's `surfaceVariant`.
  final Color? color;

  /// Pressed fill; defaults to `primaryContainer` at 60 % over [color].
  final Color? pressedColor;

  /// Non-null = the owner decides the pressed state.
  final bool? pressed;

  final bool enabled;
  final double scale;

  @override
  State<KeyFeedback> createState() => _KeyFeedbackState();
}

class _KeyFeedbackState extends State<KeyFeedback>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.pressed != null) _set(widget.pressed!);
  }

  @override
  void didUpdateWidget(KeyFeedback old) {
    super.didUpdateWidget(old);
    if (widget.pressed != null && widget.pressed != old.pressed) {
      _set(widget.pressed!);
    }
  }

  void _set(bool down) {
    final m = Motion.of(context);
    _c.animateTo(
      down && widget.enabled ? 1 : 0,
      duration: m.keyTint,
      curve: down ? MotionCurves.press : MotionCurves.release,
    );
  }

  void _pointer(bool down) {
    if (widget.pressed == null) _set(down);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = widget.color ?? p.surfaceVariant;
    final pressed =
        widget.pressedColor ??
        Color.alphaBlend(p.primaryContainer.withValues(alpha: 0.6), base);
    final reduced = Motion.of(context).reduced;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _pointer(true),
      onPointerUp: (_) => _pointer(false),
      onPointerCancel: (_) => _pointer(false),
      child: AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => Transform.scale(
          scale: reduced ? 1 : 1 - (1 - widget.scale) * _c.value,
          child: ColoredBox(
            color: Color.lerp(base, pressed, _c.value)!,
            child: child,
          ),
        ),
      ),
    );
  }
}
