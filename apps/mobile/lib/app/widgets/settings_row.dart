import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../theme/theme.dart';
import 'animated/pressable.dart';

enum _SettingsRowKind { nav, action, control }

/// Rows of the Settings screen (7.12):
/// - [SettingsRow.nav]: icon well, title, optional subtitle, chevron.
/// - [SettingsRow.action]: the same without the chevron; [destructive] uses
///   `danger` for icon and title (log out).
/// - [SettingsRow.control]: a title above a full-width control (segmented
///   button, swatch grid).
class SettingsRow extends StatelessWidget {
  const SettingsRow.nav({
    required IconData this.icon,
    required this.title,
    required VoidCallback this.onTap,
    this.subtitle,
    super.key,
  }) : _kind = _SettingsRowKind.nav,
       destructive = false,
       child = null;

  const SettingsRow.action({
    required IconData this.icon,
    required this.title,
    required VoidCallback this.onTap,
    this.destructive = false,
    this.subtitle,
    super.key,
  }) : _kind = _SettingsRowKind.action,
       child = null;

  const SettingsRow.control({
    required this.title,
    required Widget this.child,
    super.key,
  }) : _kind = _SettingsRowKind.control,
       icon = null,
       onTap = null,
       subtitle = null,
       destructive = false;

  final _SettingsRowKind _kind;
  final IconData? icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool destructive;
  final Widget? child;

  static const minHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    if (_kind == _SettingsRowKind.control) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: BhSpace.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: text.bodyMedium),
            const SizedBox(height: BhSpace.s),
            child!,
          ],
        ),
      );
    }
    final ink = destructive ? p.danger : p.onSurface;
    return Pressable(
      onTap: onTap,
      semanticLabel: subtitle == null ? title : '$title, $subtitle',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: minHeight),
        child: Row(
          children: [
            Container(
              width: BhSize.avatarSmall,
              height: BhSize.avatarSmall,
              color: p.surfaceVariant,
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 24,
                color: destructive ? p.danger : p.onSurface,
              ),
            ),
            const SizedBox(width: BhSpace.m),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleSmall?.copyWith(color: ink)),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: text.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (_kind == _SettingsRowKind.nav)
              Icon(Icons.chevron_right, size: 24, color: p.mutedText),
          ],
        ),
      ),
    );
  }
}

/// One option of a [BhSegmented].
class BhSegment<T> {
  const BhSegment({required this.value, required this.label, this.key});

  final T value;
  final String label;
  final Key? key;
}

/// A 56 dp square segmented control (7.12): selected fill `primary` /
/// `onPrimary`, unselected 1 dp `outline`, no check icon, each segment
/// expanded, labels `labelMedium`. Fires `Haptics.key()` on a change.
class BhSegmented<T> extends StatelessWidget {
  const BhSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  final List<BhSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final Haptics haptics;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Container(
      foregroundDecoration: BoxDecoration(border: Border.all(color: p.outline)),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0)
              Container(width: 1, height: BhSize.touch, color: p.outline),
            Expanded(child: _segment(segments[i], p, text)),
          ],
        ],
      ),
    );
  }

  Widget _segment(BhSegment<T> s, BhPalette p, TextTheme text) {
    final isSelected = s.value == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      inMutuallyExclusiveGroup: true,
      label: s.label,
      child: ExcludeSemantics(
        child: Material(
          key: s.key,
          color: isSelected ? p.primary : Colors.transparent,
          child: InkWell(
            onTap: isSelected
                ? null
                : () {
                    haptics.key();
                    onChanged(s.value);
                  },
            child: Container(
              height: BhSize.touch,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
              // labelMedium; one step down (labelSmall) when that does not
              // fit the segment; only then an ellipsis.
              child: LayoutBuilder(
                builder: (context, box) {
                  final colour = isSelected ? p.onPrimary : p.onSurface;
                  final big = text.labelMedium?.copyWith(color: colour);
                  final small = text.labelSmall?.copyWith(color: colour);
                  final painter = TextPainter(
                    text: TextSpan(text: s.label, style: big),
                    maxLines: 1,
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout(maxWidth: box.maxWidth);
                  final fits = !painter.didExceedMaxLines;
                  painter.dispose();
                  return Text(
                    s.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: fits ? big : small,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
