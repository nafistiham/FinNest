/// Press feedback for tiles, rows and buttons: the child scales to 0.97 and
/// takes a slight shade while held (80 ms in, 160 ms out), with no ink
/// ripple. A quick tap still shows one full press so the user sees it land.
///
/// Keyboard and semantics safe: focusable, Enter / Space activate it (via
/// `ActivateIntent`), a 2 dp `primary` outline shows the keyboard focus,
/// and it is one `button` node: [semanticLabel] when given (the child's own
/// semantics are then excluded), else the child's merged text.
///
/// Reduce motion: no scale; the shade appears and clears instantly.
library;

import 'package:flutter/widgets.dart';

import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';

class Pressable extends StatefulWidget {
  const Pressable({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.scale = 0.97,
    this.shade = true,
    this.focusNode,
    this.autofocus = false,
    this.selected,
    super.key,
  });

  final Widget child;

  /// Null disables the press (no scale, semantics `enabled: false`).
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  /// Pressed scale (0.97 for tiles and buttons).
  final double scale;

  /// Whether a slight `onSurface` shade is laid over the child while held.
  final bool shade;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Selection state for semantics (a chip or a persona row); null = not a
  /// selectable control.
  final bool? selected;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  bool _held = false;
  bool _focused = false;

  // Cached: a tap can be cancelled while the element is being torn down,
  // when looking up MediaQuery is no longer allowed.
  Motion _m = Motion.standard;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _m = Motion.of(context);
  }

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _down() {
    if (!_enabled) return;
    _held = true;
    _c.animateTo(1, duration: _m.pressDown, curve: MotionCurves.press);
  }

  void _up() {
    _held = false;
    final m = _m;
    if (_c.value < 1 && _c.isAnimating) {
      // A quick tap: finish the press so it is visible, then release.
      _c
          .animateTo(1, duration: m.pressDown, curve: MotionCurves.press)
          .whenCompleteOrCancel(() {
            if (mounted && !_held) _release();
          });
    } else {
      _release();
    }
  }

  void _release() =>
      _c.animateTo(0, duration: _m.pressUp, curve: MotionCurves.release);

  void _activate() {
    if (widget.onTap == null) return;
    _down();
    _up();
    widget.onTap!();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final reduced = _m.reduced;
    final shade = p.onSurface.withValues(alpha: p.isDark ? 0.10 : 0.06);
    return MergeSemantics(
      child: FocusableActionDetector(
        enabled: widget.onTap != null,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: Semantics(
          container: true,
          button: true,
          enabled: _enabled,
          selected: widget.selected,
          label: widget.semanticLabel,
          // With a label, the label is the whole announcement; without one
          // the child's text merges into this button node.
          excludeSemantics: widget.semanticLabel != null,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: GestureDetector(
            excludeFromSemantics: true,
            behavior: HitTestBehavior.opaque,
            onTapDown: widget.onTap == null ? null : (_) => _down(),
            onTapUp: widget.onTap == null ? null : (_) => _up(),
            onTapCancel: _up,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: AnimatedBuilder(
              animation: _c,
              child: widget.child,
              builder: (context, child) => Transform.scale(
                scale: reduced ? 1 : 1 - (1 - widget.scale) * _c.value,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    color: widget.shade
                        ? shade.withValues(alpha: shade.a * _c.value)
                        : null,
                    border: _focused
                        ? Border.all(color: p.primary, width: 2)
                        : null,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
