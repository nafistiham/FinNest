import 'package:flutter/material.dart';

import '../motion/motion_specs.dart';
import '../theme/theme.dart';
import 'animated/pressable.dart';

/// One feature on the Home grid (7.1): a 44 dp icon well in
/// `primaryContainer` above a label of at most two lines (never
/// ellipsised: shorten the ARB instead), fill `surfaceVariant`.
///
/// Centring: the well, the gap and the label form one block. The block
/// is centred in the tile, with equal space above and below. This is true
/// for a one-line label and for a two-line label. The tile height does not
/// change with the label: it is [heightFor] the text scale, which is
/// `BhSize.tile` (100 dp) at the default text size.
/// The label follows the app's text size up to 1.15x ([maxTextScale]); the
/// tile grows with it ([heightFor]), so "বড়" reaches Home's main
/// actions without a three-line label.
///
/// Pressed ([Pressable]): the tile scales to 0.97 with a slight shade, the
/// fill tints toward `primaryContainer` and the well scales to 0.94 (`press`
/// in, `release` out). [badge] ("নতুন") sits in the top-right corner on
/// `accent`. Reduce motion: fill only.
/// The colour family of a tile's icon well: a calm category cue so
/// nine tiles do not read as nine identical squares. Container tokens only;
/// red is never used here (red means a block).
enum FeatureTone { primary, success, warning, info, neutral }

class FeatureTile extends StatefulWidget {
  const FeatureTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
    this.height,
    this.tone = FeatureTone.primary,
    super.key,
  });

  /// The well's colour family.
  final FeatureTone tone;

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? badge;

  /// Tile height; [FeatureGrid] passes its own. Null = [heightFor] the
  /// current text scale.
  final double? height;

  /// The icon well (for layout tests).
  static const wellKey = ValueKey('feature_tile_well');

  /// Icon well: 44 dp square, 24 dp glyph.
  static const wellSize = 44.0;
  static const iconSize = 24.0;

  /// Space between the well and the label.
  static const gap = 6.0;

  /// Vertical padding in the tile height rhythm ([heightFor]).
  static const padding = 8.0;

  /// Label size and line height: two lines take 33.6 dp at scale 1, kept in
  /// a whole-dp [labelBox] so the tile is exactly 100 dp.
  static const labelSize = 14.0;
  static const labelHeight = 1.2;
  static const labelBox = 34.0;

  /// The label scales with the app text size up to this factor.
  static const maxTextScale = 1.15;

  /// The height of two label lines at [scale] (used by [heightFor]).
  static double labelBoxFor(double scale) => labelBox * scale;

  /// The tile height at [scale] (100 dp at 1.0).
  static double heightFor(double scale) =>
      padding + wellSize + gap + labelBoxFor(scale) + padding;

  /// The clamped text scale factor of [context] for the label.
  static double scaleOf(BuildContext context) =>
      MediaQuery.textScalerOf(context)
          .clamp(maxScaleFactor: maxTextScale)
          .scale(labelSize) /
      labelSize;

  @override
  State<FeatureTile> createState() => _FeatureTileState();
}

class _FeatureTileState extends State<FeatureTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final motion = BhMotion.of(context);
    final text = Theme.of(context).textTheme;
    final scale = FeatureTile.scaleOf(context);
    final height = widget.height ?? FeatureTile.heightFor(scale);
    final fill = _pressed
        ? Color.alphaBlend(
            p.primaryContainer.withValues(alpha: 0.4),
            p.surfaceVariant,
          )
        : p.surfaceVariant;
    // The well: the strong tone colour at 18% over the surface, with the
    // icon in the strong colour. The pale container tokens are too close to
    // each other to tell apart on a device.
    final toneColor = switch (widget.tone) {
      FeatureTone.primary => p.primary,
      FeatureTone.success => p.success,
      FeatureTone.warning => p.warning,
      FeatureTone.info => p.info,
      FeatureTone.neutral => null,
    };
    final (wellFill, wellIcon) = toneColor == null
        ? (p.outlineVariant, p.mutedText)
        : (
            Color.alphaBlend(toneColor.withValues(alpha: 0.18), p.surface),
            toneColor,
          );
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: Pressable(
        onTap: widget.onTap,
        semanticLabel: widget.badge == null
            ? widget.label
            : '${widget.label}, ${widget.badge}',
        child: AnimatedContainer(
          duration: _pressed ? motion.press : motion.release,
          height: height,
          // A hairline edge gives the grid structure in light mode, where
          // surfaceVariant is close to the page.
          color: fill,
          // Drawn on top, so the edge takes no layout space (the 100 dp
          // rhythm stays exact).
          foregroundDecoration: BoxDecoration(
            border: Border.all(color: p.outlineVariant),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.s),
                child: Column(
                  // Well + gap + the label's real height, centred as one
                  // block: equal space above and below.
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AnimatedScale(
                      scale: _pressed && !motion.reduced ? 0.94 : 1,
                      duration: _pressed ? motion.press : motion.release,
                      child: Container(
                        key: FeatureTile.wellKey,
                        width: FeatureTile.wellSize,
                        height: FeatureTile.wellSize,
                        color: wellFill,
                        alignment: Alignment.center,
                        child: Icon(
                          widget.icon,
                          size: FeatureTile.iconSize,
                          color: wellIcon,
                        ),
                      ),
                    ),
                    const SizedBox(height: FeatureTile.gap),
                    Text(
                      widget.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      textScaler: TextScaler.linear(scale),
                      style: text.labelMedium?.copyWith(
                        color: p.onSurface,
                        fontSize: FeatureTile.labelSize,
                        height: FeatureTile.labelHeight,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.badge != null)
                PositionedDirectional(
                  top: 0,
                  end: 0,
                  child: Container(
                    color: p.accent,
                    padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
                    child: Text(
                      widget.badge!,
                      style: text.labelSmall?.copyWith(color: p.surface),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 3-column Home grid (7.1): 8 dp gaps both ways, every tile the same
/// height ([tileHeight], else [FeatureTile.heightFor] the current text
/// scale: 100 dp at 1.0) whatever the width, equal columns. Not scrollable
/// (it lives in Home's scroll view). The rows rise in one after another on
/// first build ([StaggeredReveal], 40 ms apart); reduce motion shows them at
/// once.
class FeatureGrid extends StatelessWidget {
  const FeatureGrid({
    required this.children,
    this.tileHeight,
    this.revealDelay = Duration.zero,
    super.key,
  });

  final List<FeatureTile> children;
  final double? tileHeight;

  /// Wait before the first row rises (Home: after its own cascade).
  final Duration revealDelay;

  static const columns = 3;

  @override
  Widget build(BuildContext context) {
    final height =
        tileHeight ?? FeatureTile.heightFor(FeatureTile.scaleOf(context));
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final row = <Widget>[];
      for (var j = 0; j < columns; j++) {
        if (j > 0) row.add(const SizedBox(width: BhSpace.s));
        final k = i + j;
        row.add(
          Expanded(
            child: k < children.length
                ? _sized(children[k], height)
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : BhSpace.s),
          child: SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: row,
            ),
          ),
        ),
      );
    }
    return StaggeredReveal(delay: revealDelay, children: rows);
  }

  Widget _sized(FeatureTile t, double height) => t.height == height
      ? t
      : FeatureTile(
          key: t.key,
          icon: t.icon,
          label: t.label,
          onTap: t.onTap,
          badge: t.badge,
          height: height,
          tone: t.tone,
        );
}
