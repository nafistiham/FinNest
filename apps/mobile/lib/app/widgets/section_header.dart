import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 40 dp section title with an optional trailing text action ("সব দেখুন ›")
/// whose 56 dp hit area overflows the header symmetrically (7.8). Callers
/// put the 24 dp section gap above; the header carries the 8 dp below.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: BhSpace.s),
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: text.titleMedium?.copyWith(color: p.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (actionLabel != null)
              IntrinsicWidth(
                child: OverflowBox(
                  maxHeight: BhSize.touch,

                  child: TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(BhSize.touch, BhSize.touch),
                      padding: const EdgeInsets.symmetric(
                        horizontal: BhSpace.s,
                      ),
                      foregroundColor: p.primary,
                      textStyle: text.labelMedium,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(actionLabel!),
                        const Icon(Icons.chevron_right, size: 16),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
