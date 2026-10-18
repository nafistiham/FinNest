import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Small square tag: fill `<status>Container`, text
/// `on<Status>Container`, 1 dp border in the status colour at 60 %, 28 dp
/// min height, never wraps. Replaces `BhTag` and `FinanceTag`.
///
/// Placement: a tag that belongs to a card header goes at the end of a
/// `Row(children: [Expanded(child: title), SizedBox(width: 8), tag])` that is
/// the direct child of the card's padded box, so its trailing edge is the
/// card's 16 dp padding line (see [StatusTag.header]).
class StatusTag extends StatelessWidget {
  const StatusTag({required this.label, required this.status, super.key});

  final String label;
  final BhStatus status;

  static const minHeight = 28.0;

  /// A card header row with [title] and the tag pinned to the trailing edge,
  /// baseline-aligned with the title.
  static Widget header({required Widget title, StatusTag? tag, Key? key}) =>
      Row(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: title),
          if (tag != null) ...[const SizedBox(width: BhSpace.s), tag],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final border = status == BhStatus.neutral
        ? p.outline
        : p.statusText(status).withValues(alpha: 0.6);
    return Container(
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: BhSpace.s,
        vertical: BhSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: p.statusContainer(status),
        border: Border.all(color: border),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: p.onStatusContainer(status),
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}
