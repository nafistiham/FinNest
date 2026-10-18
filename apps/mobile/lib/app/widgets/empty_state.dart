import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'bh_button.dart';

/// What to show when a list or screen has nothing (7.9). Copy always says
/// what to do next. [inline] is a 72 dp row inside a section; the full form
/// is centred, max 320 dp wide, with an outlined action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    this.inline = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    if (inline) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: BhSize.rowHeight),
        child: Row(
          children: [
            Icon(icon, size: 24, color: p.mutedText),
            const SizedBox(width: BhSpace.m),
            Expanded(
              child: Text(
                title,
                style: text.bodyMedium?.copyWith(color: p.mutedText),
              ),
            ),
            if (actionLabel != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.only(top: BhSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                color: p.surfaceVariant,
                alignment: Alignment.center,
                child: Icon(icon, size: 56, color: p.mutedText),
              ),
              const SizedBox(height: BhSpace.m),
              Text(
                title,
                textAlign: TextAlign.center,
                style: text.headlineSmall,
              ),
              if (body != null) ...[
                const SizedBox(height: BhSpace.s),
                Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: p.mutedText),
                ),
              ],
              if (actionLabel != null) ...[
                const SizedBox(height: BhSpace.l),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 200),
                  child: BhButton(
                    label: actionLabel!,
                    onPressed: onAction,
                    variant: BhButtonVariant.outlined,
                    fullWidth: false,
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
