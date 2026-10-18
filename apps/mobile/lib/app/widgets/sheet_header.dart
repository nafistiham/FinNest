import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';

/// Header of every bottom sheet (7.10): a 56 dp row with an optional 24 dp
/// icon (or [leading]), the title in `headlineSmall` (one line, ellipsis) and
/// a labelled close button; an optional second row ([bottom], at least 48 dp) for
/// chips or toggles, so the first row never overflows at 360 dp; then a
/// 1 dp divider. The drag handle comes from the theme.
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    required this.title,
    this.icon,
    this.leading,
    this.bottom,
    this.onClose,
    super.key,
  });

  final String title;
  final IconData? icon;

  /// Replaces [icon] (e.g. the Apa tile).
  final Widget? leading;

  /// The optional 48 dp second row.
  final Widget? bottom;

  /// Defaults to `Navigator.maybePop`.
  final VoidCallback? onClose;

  static const closeKey = Key('sheet_close');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final lead =
        leading ??
        (icon == null ? null : Icon(icon, size: 24, color: p.onSurface));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: BhSize.touch,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              start: BhSpace.m,
              end: BhSpace.xs,
            ),
            child: Row(
              children: [
                if (lead != null) ...[lead, const SizedBox(width: BhSpace.s)],
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: text.headlineSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                TextButton.icon(
                  key: closeKey,
                  onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, size: 24),
                  label: Text(context.l10n.close),
                ),
              ],
            ),
          ),
        ),
        if (bottom != null)
          // At least 48 dp; a second row that wraps to two lines grows
          // rather than clips.
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: bottom,
          ),
        Divider(height: 1, thickness: 1, color: p.outlineVariant),
      ],
    );
  }
}
