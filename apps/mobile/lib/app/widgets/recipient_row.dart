/// Counterparty rows and summaries shared by the pay flows, Login and the
/// finance screens (7.15): [CounterpartyTile],
/// [RecipientRow], [RecipientSummary], [ConfirmSummary].
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../../features/pay/logic/pay_intent.dart';
import '../../features/pay/ui/widgets/pay_format.dart';
import '../l10n.dart';
import '../theme/theme.dart';
import 'animated/pressable.dart';

/// 48 dp leading tile of a counterparty: a person's
/// initial on `primaryContainer`; an agent, biller or operator icon on
/// `surfaceVariant`.
class CounterpartyTile extends StatelessWidget {
  const CounterpartyTile({
    required this.counterparty,
    this.size = BhSize.avatar,
    super.key,
  });

  final Counterparty counterparty;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final avatar = counterparty.avatar;
    final name = context.counterpartyName(counterparty);
    final startsWithDigit =
        name.isNotEmpty && RegExp(r'^[0-9০-৯]').hasMatch(name);
    final IconData? icon = switch (avatar) {
      IconAvatar(:final icon) => icon,
      OperatorAvatar() => Icons.phone_android,
      InitialAvatar() => startsWithDigit ? Icons.dialpad : null,
    };
    if (icon != null) {
      return Container(
        width: size,
        height: size,
        color: p.surfaceVariant,
        alignment: Alignment.center,
        child: Icon(icon, size: 24, color: p.mutedText),
      );
    }
    final initial = name.characters.isEmpty ? '?' : name.characters.first;
    return Container(
      width: size,
      height: size,
      color: p.primaryContainer,
      alignment: Alignment.center,
      child: Text(
        initial,
        textScaler: TextScaler.noScaling,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(color: p.onPrimaryContainer, height: 1.0),
      ),
    );
  }
}

/// A 72 dp list row (4.3) for a [Counterparty]: 48 dp [CounterpartyTile],
/// title and subtitle, a trailing chevron (or [trailing]). With
/// [RecipientRow.action] an action row ("নতুন নম্বরে পাঠান") whose icon
/// sits in a `primaryContainer` well and whose title is `primary`.
/// [selected] draws the Login persona style (2 dp `primary` border on
/// `primaryContainer`). The whole row is one [Pressable] target.
class RecipientRow extends StatelessWidget {
  const RecipientRow({
    required Counterparty this.counterparty,
    required this.onTap,
    this.subtitle,
    this.subtitleOverride,
    this.selected = false,
    this.trailing,
    this.trailingChevron = true,
    super.key,
  }) : icon = null,
       title = null;

  const RecipientRow.action({
    required IconData this.icon,
    required String this.title,
    required this.onTap,
    this.subtitle,
    super.key,
  }) : counterparty = null,
       subtitleOverride = null,
       selected = false,
       trailing = null,
       trailingChevron = true;

  final Counterparty? counterparty;
  final IconData? icon;
  final String? title;

  /// Overrides the counterparty's number line
  /// ("০১৯XX-XXX৮৮১ · শেষ ১০ নভে.").
  final String? subtitle;

  /// Same as [subtitle] (older name).
  final String? subtitleOverride;
  final bool selected;

  /// Replaces the chevron.
  final Widget? trailing;
  final bool trailingChevron;

  /// Null disables the row.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final c = counterparty;
    final isAction = c == null;
    final titleText = isAction ? title! : context.counterpartyName(c);
    final sub =
        subtitle ??
        subtitleOverride ??
        (isAction ? null : context.counterpartyNumber(c));
    final leading = isAction
        ? Container(
            width: BhSize.avatar,
            height: BhSize.avatar,
            color: p.primaryContainer,
            alignment: Alignment.center,
            child: Icon(icon, size: 24, color: p.onPrimaryContainer),
          )
        : CounterpartyTile(counterparty: c);
    final Widget? end =
        trailing ??
        (trailingChevron
            ? Icon(Icons.chevron_right, size: 24, color: p.mutedText)
            : null);
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: [
        titleText,
        if (sub != null && sub.isNotEmpty) sub,
      ].join(', '),
      child: Container(
        constraints: const BoxConstraints(minHeight: BhSize.rowHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: BhSpace.m,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: selected ? p.primaryContainer : null,
          border: selected ? Border.all(color: p.primary, width: 2) : null,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: BhSpace.m),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(
                      color: isAction ? p.primary : p.onSurface,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                ],
              ),
            ),
            if (end != null) ...[const SizedBox(width: BhSpace.s), end],
          ],
        ),
      ),
    );
  }
}

/// The amount step's 72 dp recipient row with a trailing "বদলান" text
/// button that goes back to step 1 (7.15); [compact] folds it into one
/// 28 dp line "মা · ০১৯XX-XXX৮৮১ · বদলান".
class RecipientSummary extends StatelessWidget {
  const RecipientSummary({
    required this.counterparty,
    this.changeLabel,
    required this.onChange,
    this.compact = false,
    this.line,
    super.key,
  });

  final Counterparty counterparty;

  /// Defaults to "বদলান".
  final String? changeLabel;
  final VoidCallback onChange;
  final bool compact;

  /// Overrides the number line (recharge: number · operator).
  final String? line;

  static const compactHeight = 28.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final name = context.counterpartyName(counterparty);
    final number = line ?? context.counterpartyNumber(counterparty);
    final change = TextButton(
      key: const Key('recipient_change'),
      onPressed: onChange,
      style: TextButton.styleFrom(
        minimumSize: const Size(BhSize.touch, BhSize.touch),
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.s),
        foregroundColor: p.primary,
        textStyle: text.labelMedium,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(changeLabel ?? context.l10n.change),
    );
    if (compact) {
      return SizedBox(
        key: const Key('recipient_summary'),
        height: compactHeight,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                [name, if (number.isNotEmpty) number].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: p.mutedText),
              ),
            ),
            Text(' · ', style: text.bodySmall?.copyWith(color: p.mutedText)),
            OverflowBox(
              maxHeight: BhSize.touch,
              fit: OverflowBoxFit.deferToChild,
              child: change,
            ),
          ],
        ),
      );
    }
    return SizedBox(
      key: const Key('recipient_summary'),
      height: BhSize.rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
        child: Row(
          children: [
            CounterpartyTile(counterparty: counterparty),
            const SizedBox(width: BhSpace.m),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall,
                  ),
                  if (number.isNotEmpty)
                    Text(
                      number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                ],
              ),
            ),
            change,
          ],
        ),
      ),
    );
  }
}

/// The confirmation block (7.15): kind line (muted) → 8 → the amount, the
/// largest thing on screen → 8 → optional fee line, then the amount in
/// words for ৳ ১,০০০ and above (9.1). The amount is one `Text`, never
/// animated after first paint.
class ConfirmSummary extends StatelessWidget {
  const ConfirmSummary({
    required this.kindLine,
    this.amountBdt,
    this.amountText,
    this.feeLine,
    this.words,
    this.compact = false,
    super.key,
  }) : assert(amountBdt != null || amountText != null);

  final String kindLine;

  /// Whole taka; formatted with the active digits. Words are added for
  /// ৳ ১,০০০ and above unless [words] is given.
  final int? amountBdt;

  /// Already formatted ("৳ ৫,০০০"); wins over [amountBdt].
  final String? amountText;
  final String? feeLine;
  final String? words;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final roles = context.textRoles;
    final amount = amountText ?? context.taka(amountBdt!);
    final words =
        this.words ??
        (amountBdt != null && amountBdt! >= 1000
            ? context.takaWords(amountBdt!)
            : null);
    return Column(
      key: const Key('confirm_summary'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          kindLine,
          key: const Key('confirm_kind_line'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(color: p.mutedText),
        ),
        const SizedBox(height: BhSpace.s),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            amount,
            key: const Key('confirm_amount'),
            maxLines: 1,
            style: (compact ? roles.amountEntryCompact : roles.amountHero)
                .copyWith(color: p.onSurface),
          ),
        ),
        if (feeLine != null) ...[
          const SizedBox(height: BhSpace.xs),
          Text(
            feeLine!,
            key: const Key('confirm_fee_line'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: p.mutedText),
          ),
        ],
        if (words != null && !compact) ...[
          const SizedBox(height: BhSpace.xs),
          Text(
            words,
            key: const Key('confirm_words'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: p.mutedText),
          ),
        ],
      ],
    );
  }
}
