/// The assistant's square glyph: one widget for every place she appears
/// (Home insight card, Apa sheet header, intervention overlay and banner).
/// A square tile in the palette's `primary` with the [FnaMonogram]
/// (`apaInitial`, "FNA"; no photographs of people, 9.6), so it follows the
/// preset and the brightness; a rebrand swaps the content here, once.
///
/// [ring]: a 2 dp `accent` ring marks that she is speaking. When [ring]
/// turns on, the ring breathes three times (opacity 1.0 -> 0.4 -> 1.0,
/// [BhMotion.pulse] each), then stays solid: present, never an alarm loop.
/// Reduce motion keeps it solid.
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';

class BrandGlyph extends StatefulWidget {
  const BrandGlyph({this.size = 32, this.ring = false, super.key});

  /// Edge length in dp (32 in rows and headers, 48 on the overlay).
  final double size;

  /// Speaking ring.
  final bool ring;

  /// How many times the ring breathes when it turns on.
  static const breaths = 3;

  @override
  State<BrandGlyph> createState() => _BrandGlyphState();
}

class _BrandGlyphState extends State<BrandGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(BrandGlyph old) {
    super.didUpdateWidget(old);
    if (old.ring != widget.ring) _sync();
  }

  void _sync() {
    final m = BhMotion.of(context);
    if (!widget.ring || m.reduced) {
      _c
        ..stop()
        ..value = 0;
      return;
    }
    if (!_c.isAnimating) {
      _c
        ..duration = BhMotion.standard.pulse
        ..repeat(
          reverse: true,
          count: BrandGlyph.breaths * 2,
        ).whenCompleteOrCancel(() {
          if (mounted) _c.value = 0;
        });
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
    final size = widget.size;
    final glyph = FnaMonogram(size: size, color: p.onPrimary);
    return Semantics(
      label: context.l10n.apaSheetTitle,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) => Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: p.primary,
              border: widget.ring
                  ? Border.all(
                      color: p.accent.withValues(
                        alpha: 1 - 0.6 * BhCurves.pulse.transform(_c.value),
                      ),
                      width: 2,
                    )
                  : null,
            ),
            alignment: Alignment.center,
            child: child,
          ),
          child: glyph,
        ),
      ),
    );
  }
}

/// The assistant's monogram (`apaInitial`, "FNA") fitted inside a [size] dp
/// square with a 15 % inset: bold, tight, never scaled by the text size.
class FnaMonogram extends StatelessWidget {
  const FnaMonogram({required this.size, required this.color, super.key});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size * 0.7,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        context.l10n.apaInitial,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: BhType.family,
          fontSize: size * 0.4,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: color,
          height: 1.0,
        ),
      ),
    ),
  );
}
