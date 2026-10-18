/// The customer's review lines under a held transfer: "টাকা পাঠানো হয়নি, আপনার
/// কাছেই আছে।" plus "যাচাই চলছে।" or "যাচাই শেষ, টাকা আপনার কাছেই।". Only the
/// customer's own money and the progress of a review; never the payee's status,
/// ring or evidence.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../data/providers.dart';
import '../../../../data/repos/repos.dart';
import '../../logic/review_state.dart';

/// Renders the lines of a [ReviewState]; nothing for [ReviewState.none].
class ReviewLines extends StatelessWidget {
  const ReviewLines({required this.state, this.color, super.key});

  final ReviewState state;

  /// Text colour; `mutedText` by default (on a warning card pass its
  /// `onWarningContainer`).
  final Color? color;

  /// The lines of [state] in the app language, for a parent's semantics.
  static List<String> linesOf(AppLocalizations l10n, ReviewState state) =>
      switch (state) {
        ReviewState.none => const [],
        ReviewState.moneySafe => [l10n.reviewMoneySafe],
        ReviewState.inReview => [l10n.reviewMoneySafe, l10n.reviewInReview],
        ReviewState.finished => [l10n.reviewMoneySafe, l10n.reviewFinished],
      };

  @override
  Widget build(BuildContext context) {
    final lines = linesOf(context.l10n, state);
    if (lines.isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: color ?? context.palette.mutedText);
    return Column(
      key: const Key('review_lines'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, line) in lines.indexed)
          Text(line, key: Key('review_line_$i'), style: style),
      ],
    );
  }
}

/// [ReviewLines] for a ledger [row] held at [heldAt], with the newest case
/// this phone opened on the row's payee (from `CaseLinkRepo`).
class ReviewLinesForRow extends ConsumerWidget {
  const ReviewLinesForRow({
    required this.uid,
    required this.row,
    required this.heldAt,
    this.color,
    super.key,
  });

  final String uid;
  final LedgerTxn row;
  final DateTime heldAt;
  final Color? color;

  /// The state of [row]; also used by parents for their semantics label.
  static ReviewState stateOf(
    WidgetRef ref, {
    required String uid,
    required LedgerTxn row,
    required DateTime heldAt,
  }) => reviewStateFor(
    rowStatus: row.status,
    link: ref.watch(caseLinkForPayeeProvider((uid: uid, acctId: row.toAcct))),
    report: null,
    heldAt: heldAt,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) => ReviewLines(
    state: stateOf(ref, uid: uid, row: row, heldAt: heldAt),
    color: color,
  );
}
