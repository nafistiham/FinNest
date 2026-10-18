/// A held transfer waiting on the trusted contact:
/// 72 dp, `warningContainer` with a 4 dp stripe and the hourglass, the
/// amount and payee under the title. No trailing tag (the amber frame
/// and hourglass already say "held"), so the
/// title and the review line run the full width. Tap opens Apa with the
/// held score so the customer can ask what happens next.
///
/// [PendingSummaryCard] replaces the cards when two or more are held: one
/// card "২টি লেনদেন আটকে আছে", the newest card's amount line under it, and
/// "দেখুন ›" to History filtered to held rows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/l10n.dart';
import '../../../../app/router.dart' show Routes;
import '../../../../app/theme/theme.dart';
import '../../../../data/providers.dart';
import '../../../../data/repos/repos.dart';
import '../../../apa/logic/apa_held_score.dart';
import '../../../apa/ui/apa_sheet.dart';
import '../../../history/logic/history_providers.dart'
    show HistoryFilter, englishNameFor, payeeNamesEnProvider;
import '../../../safety/logic/review_state.dart';
import '../../../safety/ui/widgets/review_lines.dart';
import '../../logic/home_providers.dart';

class PendingCard extends ConsumerWidget {
  const PendingCard({required this.record, super.key});

  final InterventionRecord record;

  /// "৳ ৭,৯০০ · নতুন নম্বর": the held row's amount and payee in the app
  /// language (the same English-name lookup the ledger rows use).
  static String amountLine(
    BuildContext context,
    WidgetRef ref,
    InterventionRecord record,
  ) {
    final txn = ref
        .watch(txnByIdProvider((uid: record.uid, txnId: record.txnId)))
        .value;
    final acctId = ref.watch(currentUserProvider).value?.acctId ?? '';
    final namesEn = ref.watch(payeeNamesEnProvider);
    final nameBn = (txn?.counterpartyNameBn ?? '').trim();
    final nameEn = txn == null ? null : englishNameFor(txn, acctId, namesEn);
    final name = context.digits(
      !context.banglaDigits && (nameEn ?? '').isNotEmpty ? nameEn! : nameBn,
    );
    return [
      txn == null ? '—' : context.taka(txn.amountBdt),
      if (name.isNotEmpty) name,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final txn = ref
        .watch(txnByIdProvider((uid: record.uid, txnId: record.txnId)))
        .value;
    final subtitle = amountLine(context, ref, record);
    final title = l10n.pendingTrustedTitle;
    // The review lines only while the row is held.
    final review = txn == null
        ? ReviewState.none
        : ReviewLinesForRow.stateOf(
            ref,
            uid: record.uid,
            row: txn,
            heldAt: record.createdAt,
          );
    final reviewText = ReviewLines.linesOf(l10n, review).join(' ');
    return Semantics(
      button: true,
      label: [
        title,
        subtitle,
        if (reviewText.isNotEmpty) reviewText,
        l10n.statusHeld,
        l10n.askApa,
      ].join('. '),
      child: ExcludeSemantics(
        child: _HeldFrame(
          key: Key('pending_${record.id}'),
          onTap: () => ApaSheet.show(
            context,
            held: ref.read(apaHeldScoreProvider),
            screen: 'home',
          ),
          children: [
            // Whole, up to two lines (never "…trusted p…").
            Text(
              title,
              key: const Key('pending_title'),
              maxLines: 2,
              style: text.titleSmall?.copyWith(color: p.onWarningContainer),
            ),
            Text(
              subtitle,
              key: const Key('pending_subtitle'),
              maxLines: 2,
              style: text.bodySmall?.copyWith(color: p.onWarningContainer),
            ),
            ReviewLines(state: review, color: p.onWarningContainer),
          ],
        ),
      ),
    );
  }
}

/// Two or more held transfers as one card:
/// "২টি লেনদেন আটকে আছে", the newest held row's amount line, and "দেখুন ›"
/// to History filtered to held rows. [records] newest first or in any
/// order (the newest by `createdAt` gives the subtitle).
class PendingSummaryCard extends ConsumerWidget {
  const PendingSummaryCard({required this.records, super.key})
    : assert(records.length >= 2);

  final List<InterventionRecord> records;

  /// History with only the held rows.
  static final location = Uri(
    path: Routes.history,
    queryParameters: {'filter': HistoryFilter.held.id},
  ).toString();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final newest = records.reduce(
      (a, b) => b.createdAt.isAfter(a.createdAt) ? b : a,
    );
    final title = l10n.pendingSummaryTitle(
      records.length,
      context.digits('${records.length}'),
    );
    final subtitle = PendingCard.amountLine(context, ref, newest);
    final see = l10n.pendingSummarySee;
    return Semantics(
      button: true,
      label: [title, subtitle, see].join('. '),
      child: ExcludeSemantics(
        child: _HeldFrame(
          key: const Key('pending_summary'),
          onTap: () => context.push(location),
          trailing: Text(
            see,
            key: const Key('pending_summary_see'),
            style: text.labelLarge?.copyWith(color: p.onWarningContainer),
          ),
          children: [
            Text(
              title,
              key: const Key('pending_summary_title'),
              maxLines: 2,
              style: text.titleSmall?.copyWith(color: p.onWarningContainer),
            ),
            Text(
              subtitle,
              key: const Key('pending_summary_subtitle'),
              maxLines: 2,
              style: text.bodySmall?.copyWith(color: p.onWarningContainer),
            ),
          ],
        ),
      ),
    );
  }
}

/// The held card's frame: `warningContainer`, the 4 dp amber stripe, the
/// hourglass, then [children] at full width and an optional [trailing].
class _HeldFrame extends StatelessWidget {
  const _HeldFrame({
    required this.onTap,
    required this.children,
    this.trailing,
    super.key,
  });

  final VoidCallback onTap;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.warningContainer,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: BhSize.rowHeight),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: p.warningFill, width: BhSize.stripe),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            BhSpace.m - BhSize.stripe,
            12,
            BhSpace.m,
            12,
          ),
          child: Row(
            children: [
              Icon(Icons.hourglass_top, size: 24, color: p.warning),
              const SizedBox(width: BhSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: BhSpace.s),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
