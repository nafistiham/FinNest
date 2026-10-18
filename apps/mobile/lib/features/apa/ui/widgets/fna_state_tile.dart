/// The FNA tile of voice mode: one square shape per
/// on-screen state, never only a colour. Square corners everywhere; reduced
/// motion shows still frames.
library;

import 'dart:math' as math;

import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_tile.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The six states the voice view shows for the eleven session phases.
enum FnaVisual { connecting, listening, thinking, speaking, paused, problem }

/// Maps a session phase to what the screen shows.
FnaVisual fnaVisualOf(FnaPhase phase) => switch (phase) {
  FnaPhase.idle ||
  FnaPhase.micPermission ||
  FnaPhase.connecting ||
  FnaPhase.reconnecting => FnaVisual.connecting,
  FnaPhase.listening => FnaVisual.listening,
  FnaPhase.thinking => FnaVisual.thinking,
  FnaPhase.speaking => FnaVisual.speaking,
  FnaPhase.paused => FnaVisual.paused,
  FnaPhase.textFallback ||
  FnaPhase.offline ||
  FnaPhase.ended => FnaVisual.problem,
};

class FnaStateTile extends StatelessWidget {
  const FnaStateTile({
    required this.visual,
    required this.level,
    this.size = regular,
    super.key,
  });

  /// Edge length at normal text sizes (dp).
  static const regular = 96.0;

  /// Edge length at large text sizes (dp).
  static const compact = 72.0;

  final FnaVisual visual;

  /// Microphone level 0..1 (listening only). A listenable, so the level
  /// rebuilds only the bars, never the screen around them.
  final ValueListenable<double> level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final reduced = BhMotion.of(context).reduced;
    final glyph = BrandGlyph(size: size * 0.75);
    final Widget child = switch (visual) {
      FnaVisual.connecting => _Outline(
        key: const Key('fna_shape_connecting'),
        color: p.primary,
        shimmer: true,
        animate: !reduced,
        child: glyph,
      ),
      FnaVisual.listening => _LevelBars(
        key: const Key('fna_shape_listening'),
        level: level,
        size: size,
        animate: !reduced,
      ),
      FnaVisual.thinking => _Dots(
        key: const Key('fna_shape_thinking'),
        size: size,
        animate: !reduced,
      ),
      FnaVisual.speaking => _Outline(
        key: const Key('fna_shape_speaking'),
        color: p.accent,
        shimmer: false,
        animate: !reduced,
        child: glyph,
      ),
      FnaVisual.paused => Stack(
        key: const Key('fna_shape_paused'),
        alignment: Alignment.center,
        children: [
          glyph,
          Align(
            alignment: Alignment.bottomRight,
            child: ColoredBox(
              color: p.surface,
              child: Icon(Icons.pause, size: size * 0.3, color: p.onSurface),
            ),
          ),
        ],
      ),
      FnaVisual.problem => ColoredBox(
        key: const Key('fna_shape_problem'),
        color: p.surfaceVariant,
        child: Center(
          child: Icon(
            Icons.info_outline,
            size: size * 0.45,
            color: p.mutedText,
          ),
        ),
      ),
    };
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Center(child: child),
      ),
    );
  }
}

/// A square outline around [child]: a highlight that travels round the edge
/// ([shimmer], connecting) or an edge that breathes (speaking).
class _Outline extends StatefulWidget {
  const _Outline({
    required this.color,
    required this.shimmer,
    required this.animate,
    required this.child,
    super.key,
  });

  final Color color;
  final bool shimmer;
  final bool animate;
  final Widget child;

  @override
  State<_Outline> createState() => _OutlineState();
}

class _OutlineState extends State<_Outline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.shimmer
        ? BhMotion.standard.shimmer
        : BhMotion.standard.breathe,
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Outline old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) _sync();
  }

  void _sync() {
    if (widget.animate) {
      _c.repeat(reverse: !widget.shimmer);
    } else {
      _c
        ..stop()
        ..value = widget.shimmer ? 0 : 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: Padding(padding: const EdgeInsets.all(6), child: widget.child),
    builder: (_, child) => CustomPaint(
      foregroundPainter: _OutlinePainter(
        color: widget.color,
        t: _c.value,
        shimmer: widget.shimmer,
      ),
      child: child,
    ),
  );
}

class _OutlinePainter extends CustomPainter {
  const _OutlinePainter({
    required this.color,
    required this.t,
    required this.shimmer,
  });

  final Color color;
  final double t;
  final bool shimmer;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.miter;
    if (shimmer) {
      paint.shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0.15),
          color,
          color.withValues(alpha: 0.15),
        ],
        stops: const [0.0, 0.12, 0.3],
        transform: GradientRotation(2 * math.pi * t),
      ).createShader(rect);
    } else {
      // Breathes between 40 % and full opacity.
      paint.color = color.withValues(alpha: 0.4 + 0.6 * t);
    }
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_OutlinePainter old) =>
      old.t != t || old.color != color || old.shimmer != shimmer;
}

/// Five square-cornered bars that follow the microphone level; the outer
/// bars move less, so silence is a row of small squares. Only the bars
/// listen to the level.
class _LevelBars extends StatelessWidget {
  const _LevelBars({
    required this.level,
    required this.size,
    required this.animate,
    super.key,
  });

  static const _weights = [0.45, 0.75, 1.0, 0.75, 0.45];

  final ValueListenable<double> level;
  final double size;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bar = size / 9;
    final maxHeight = size * 0.7;
    return ColoredBox(
      color: p.primaryContainer,
      child: SizedBox.square(
        dimension: size,
        child: ValueListenableBuilder<double>(
          valueListenable: level,
          builder: (_, value, _) {
            final l = value.clamp(0.0, 1.0);
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final (i, w) in _weights.indexed) ...[
                  if (i > 0) SizedBox(width: bar * 0.6),
                  AnimatedContainer(
                    key: Key('fna_level_bar_$i'),
                    duration: animate ? BhMotion.standard.press : Duration.zero,
                    width: bar,
                    height: bar + (maxHeight - bar) * l * w,
                    color: p.primary,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Three square dots that light up in turn.
class _Dots extends StatefulWidget {
  const _Dots({required this.size, required this.animate, super.key});

  final double size;
  final bool animate;

  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: BhMotion.standard.pulse,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(_Dots old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) _c.repeat();
    if (!widget.animate) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dot = widget.size / 7;
    return ColoredBox(
      color: p.primaryContainer,
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: dot * 0.8),
                SizedBox.square(
                  dimension: dot,
                  child: ColoredBox(
                    color: p.primary.withValues(
                      alpha: widget.animate
                          ? (((_c.value * 3).floor() % 3) == i ? 1.0 : 0.35)
                          : 1.0,
                    ),
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
