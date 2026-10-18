import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';

/// The FinNest mark (nest, shield, coins), generated from the FinNest logo by
/// `tool/make_brand_assets.py`.
const brandMarkAsset = 'assets/brand/finnest_logo.png';

/// The logo lockup: the mark above the two-tone "FinNest" wordmark ("Fin" in
/// [BhPalette.brandLeaf], "Nest" in [BhPalette.brandNavy]). When the mark
/// cannot load (missing asset, decode error) only the wordmark shows; the
/// wordmark is text, so the brand never disappears. TalkBack reads the
/// localised app name (ফিননেস্ট / FinNest), not the two halves.
class BrandLockup extends StatelessWidget {
  const BrandLockup({
    this.markSize = 88,
    this.asset = brandMarkAsset,
    this.wordmarkKey,
    super.key,
  });

  final double markSize;

  /// Injectable so the fallback is testable.
  final String asset;

  /// Key on the wordmark `Text` (Login uses `login_logo`).
  final Key? wordmarkKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.appName,
      header: true,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Image.asset(
              asset,
              key: const Key('brand_mark'),
              width: markSize,
              height: markSize,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) =>
                  const SizedBox.shrink(key: Key('brand_mark_fallback')),
            ),
            BrandWordmark(key: wordmarkKey),
          ],
        ),
      ),
    );
  }
}

/// "FinNest" in the logo's two tones, at `displaySmall` bold.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final base = Theme.of(context).textTheme.displaySmall
        ?.copyWith(fontWeight: FontWeight.w700);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(
            text: l10n.wordmarkFin,
            style: TextStyle(color: p.brandLeaf),
          ),
          TextSpan(
            text: l10n.wordmarkNest,
            style: TextStyle(color: p.brandNavy),
          ),
        ],
      ),
      maxLines: 1,
    );
  }
}
