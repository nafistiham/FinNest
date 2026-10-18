import 'package:flutter/material.dart';

import '../theme/theme.dart';

enum BhButtonVariant { primary, outlined, danger }

/// The one button of the app: 56 dp tall at least, full width by default so
/// it fills the thumb zone, square corners from the theme, and a loading
/// state that keeps the label's width while the spinner shows (no layout
/// jump under a thumb).
class BhButton extends StatelessWidget {
  const BhButton({
    required this.label,
    required this.onPressed,
    this.variant = BhButtonVariant.primary,
    this.icon,
    this.fullWidth = true,
    this.loading = false,
    this.semanticsLabel,
    super.key,
  });

  final String label;

  /// `null` renders the disabled state.
  final VoidCallback? onPressed;
  final BhButtonVariant variant;
  final IconData? icon;
  final bool fullWidth;

  /// Shows a spinner in place of the icon and disables the button.
  final bool loading;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = context.palette;
    final enabled = onPressed != null && !loading;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        else if (icon != null)
          Icon(icon, size: 26),
        if (loading || icon != null) const SizedBox(width: BhSpace.s),
        Flexible(child: Text(label, textAlign: TextAlign.center, maxLines: 2)),
      ],
    );

    final Widget button = switch (variant) {
      BhButtonVariant.primary => FilledButton(
        onPressed: enabled ? onPressed : null,
        child: child,
      ),
      BhButtonVariant.danger => FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          backgroundColor: p.dangerFill,
          foregroundColor: p.onDangerFill,
          disabledBackgroundColor: p.dangerFill.withValues(alpha: 0.4),
        ),
        child: child,
      ),
      BhButtonVariant.outlined => OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(foregroundColor: scheme.primary),
        child: child,
      ),
    };

    return Semantics(
      label: semanticsLabel,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: BhSize.touch,
          minWidth: fullWidth ? double.infinity : BhSize.touch,
        ),
        child: button,
      ),
    );
  }
}
