/// "[⛨] ফোনের নিরাপত্তা · ঝুঁকিপূর্ণ            [সিমুলেটেড]": the phone-safety
/// status line that heads Apa's card on Home and the verdict card on the Safety
/// screen. The verdict label is in the verdict's text colour; the "সিমুলেটেড"
/// tag is the last child of the row, so placed as the direct child of a card's
/// padded box its trailing edge is the card's 16 dp
/// padding line. Loading shows a breathing [StatusPulse] dot and
/// "যাচাই হচ্ছে…" (a re-check under a standing verdict adds a small
/// breathing dot after the verdict); once settled nothing moves. A failed
/// check without a standing verdict shows a refresh icon and "যাচাই করা
/// যায়নি" (the caller's [onTap] retries).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/animated/status_pulse.dart';
import '../../../../app/widgets/status_tag.dart';
import '../../../../data/contracts/contracts.dart';
import 'verdict_style.dart';

class SafetyStatusRow extends StatelessWidget {
  const SafetyStatusRow({
    this.verdict,
    this.checking = false,
    this.failed = false,
    this.simulated = false,
    this.onTap,
    this.large = false,
    this.showPrefix = true,
    super.key,
  });

  /// The verdict to show; `null` before any check (or after a failed one
  /// with no standing verdict).
  final SafetyVerdict? verdict;
  final bool checking;
  final bool failed;

  /// `simulated_verdict`: shows the "সিমুলেটেড" tag at the trailing edge.
  final bool simulated;
  final VoidCallback? onTap;

  /// The Safety screen header size (titleMedium, 28 dp icon).
  final bool large;

  /// "ফোনের নিরাপত্তা · " before the verdict; off where the app bar already
  /// says it (the Safety screen).
  final bool showPrefix;

  static const height = 40.0;
  static const tagKey = Key('safety_status_tag');
  static const labelKey = Key('safety_status_label');
  static const prefixKey = Key('safety_status_prefix');
  static const checkingKey = Key('safety_status_checking');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final style = verdict == null ? null : VerdictStyle.of(context, verdict!);
    final String label;
    final Color ink;
    final Widget leading;
    final iconSize = large ? 28.0 : 24.0;
    if (checking && style == null) {
      label = l10n.safetyChecking;
      ink = p.mutedText;
      leading = const StatusPulse(
        key: checkingKey,
        status: BhStatus.info,
        active: true,
        size: 12,
      );
    } else if (style == null) {
      label = failed ? l10n.safetyCheckFailedShort : l10n.safetyNotCheckedShort;
      ink = p.mutedText;
      leading = Icon(
        failed ? Icons.refresh : Icons.shield_outlined,
        size: iconSize,
        color: p.mutedText,
      );
    } else {
      label = style.label;
      ink = p.statusText(style.status);
      leading = Icon(style.icon, size: iconSize, color: ink);
    }
    final base = (large ? text.titleMedium : text.titleSmall)?.copyWith(
      color: p.onSurface,
    );
    final semantics = [
      l10n.safety,
      label,
      if (simulated) l10n.safetySimulatedTag,
      if (onTap != null) l10n.tapToOpen,
    ].join(', ');

    // When the verdict wraps (large text, 360 dp), the icon and the tag
    // stay on the first line (4.4 rule 3: the tag in the top-right corner).
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight =
        scaler.scale(base?.fontSize ?? 18) * (base?.height ?? 1.4);
    final firstLine = math.max(lineHeight, StatusTag.minHeight);
    final row = Padding(
      padding: EdgeInsets.symmetric(
        vertical: math.max(0, (height - firstLine) / 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: iconSize,
            height: firstLine,
            child: Center(child: leading),
          ),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: (firstLine - lineHeight) / 2),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (showPrefix) ...[
                    Text(l10n.safety, key: prefixKey, style: base),
                    Text(' · ', style: base),
                  ],
                  Text(
                    label,
                    key: labelKey,
                    style: base?.copyWith(color: ink),
                  ),
                  if (checking && style != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: BhSpace.s,
                      ),
                      child: StatusPulse(
                        key: checkingKey,
                        status: style.status,
                        active: true,
                        size: 8,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (simulated) ...[
            const SizedBox(width: BhSpace.s),
            SizedBox(
              height: firstLine,
              child: Center(
                child: StatusTag(
                  key: tagKey,
                  label: l10n.safetySimulatedTag,
                  status: BhStatus.info,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    // The verdict line cross-fades when it changes (6.2, `fast`); reduce
    // motion swaps it at once.
    final motion = BhMotion.of(context);
    return AnimatedSwitcher(
      duration: motion.fast,
      switchInCurve: BhCurves.release,
      switchOutCurve: BhCurves.exit,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [
          for (final w in previous) ExcludeSemantics(child: w),
          ?current,
        ],
      ),
      child: KeyedSubtree(
        key: ValueKey('$label|$simulated|$checking'),
        child: _wrap(semantics, row),
      ),
    );
  }

  Widget _wrap(String semantics, Widget row) {
    return Semantics(
      button: onTap != null,
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: onTap == null
            ? row
            : Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: const Key('safety_status_row_tap'),
                  onTap: onTap,
                  child: row,
                ),
              ),
      ),
    );
  }
}
