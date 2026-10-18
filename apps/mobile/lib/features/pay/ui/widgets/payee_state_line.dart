/// The send-money amount step's two-state payee line:
/// chrome from the ARB only, no score and no server call before the PIN.
library;

import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';

/// "সেভ করা প্রাপক" (muted) for a saved payee; for any other the info
/// line "নতুন বা অচেনা প্রাপক। পাঠানোর আগে একবার ভাবুন।" with an
/// `info_outline` icon. Info, never amber: amber is for holds.
class PayeeStateLine extends StatelessWidget {
  const PayeeStateLine({required this.saved, super.key});

  final bool saved;

  static const iconSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodySmall;
    if (saved) {
      return Text(
        l10n.payeeSavedLine,
        key: const Key('payee_state_saved'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: p.mutedText),
      );
    }
    return Row(
      key: const Key('payee_state_unfamiliar'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(Icons.info_outline, size: iconSize, color: p.info),
        ),
        const SizedBox(width: BhSpace.xs),
        Flexible(
          child: Text(
            l10n.payeeUnfamiliarLine,
            style: style?.copyWith(color: p.info),
          ),
        ),
      ],
    );
  }
}
