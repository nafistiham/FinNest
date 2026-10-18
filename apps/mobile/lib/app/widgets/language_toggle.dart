import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../locale.dart';
import '../theme/theme.dart';

/// "বাংলা | English": a compact two-segment pill that switches the whole
/// app at once ([localeProvider]) and remembers the choice. Each segment
/// names its language in its own script, so a reader finds their own
/// language whatever is on screen.
///
/// The pill is [height] (32) dp tall and square-cornered: the selected
/// segment is filled `primary`, the other is transparent, and one 1 dp
/// `outline` hairline runs round both segments with one divider between
/// them; there is no second, outer box. The tap area is taller than the
/// pill: the whole control is [touchHeight] (48) dp tall, so it stays usable
/// in a 56 dp app bar without reading as a heavy button.
///
/// [compact] trims the side padding (app bars). [expanded] stretches each
/// segment to half the width (Settings).
class LanguageToggle extends ConsumerWidget {
  const LanguageToggle({
    this.compact = false,
    this.expanded = false,
    super.key,
  });

  final bool compact;
  final bool expanded;

  static const banglaKey = Key('language_bn');
  static const englishKey = Key('language_en');

  /// Painted height of the pill.
  static const height = 32.0;

  /// Tap height of the control (the pill sits centred inside it).
  static const touchHeight = 48.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final current = ref.watch(localeProvider).languageCode;
    final notifier = ref.read(localeProvider.notifier);
    Widget wrap(Widget child) => expanded ? Expanded(child: child) : child;
    return Semantics(
      container: true,
      label: l10n.languageToggleLabel,
      child: SizedBox(
        height: touchHeight,
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            wrap(
              _Segment(
                key: banglaKey,
                label: l10n.languageBangla,
                selected: current != 'en',
                compact: compact,
                expanded: expanded,
                first: true,
                onTap: () => notifier.set(LocaleNotifier.bangla),
              ),
            ),
            wrap(
              _Segment(
                key: englishKey,
                label: l10n.languageEnglish,
                selected: current == 'en',
                compact: compact,
                expanded: expanded,
                first: false,
                onTap: () => notifier.set(LocaleNotifier.english),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One segment: a [LanguageToggle.touchHeight]-tall ink well whose painted
/// part is the 32 dp pill half. The hairline is drawn per segment (the
/// second one skips its leading edge) so the two read as one outline.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.compact,
    required this.expanded,
    required this.first,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final bool compact;
  final bool expanded;
  final bool first;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = context.palette.outline;
    final ink = selected ? scheme.onPrimary : scheme.primary;
    final side = BorderSide(color: border);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: selected ? null : onTap,
            child: Center(
              child: Container(
                key: Key('language_segment_${first ? 'bn' : 'en'}'),
                height: LanguageToggle.height,
                width: expanded ? double.infinity : null,
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? BhSpace.s : BhSpace.m - BhSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : Colors.transparent,
                  border: Border(
                    top: side,
                    bottom: side,
                    left: first ? side : BorderSide.none,
                    right: side,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  maxLines: 1,
                  textScaler: MediaQuery.textScalerOf(context)
                      .clamp(maxScaleFactor: 1.15),
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: ink, height: 1.2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
