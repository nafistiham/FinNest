/// The detail of one ledger row: `SheetHeader`, the
/// amount as the one big number with its kind above, then type, status,
/// time and a short reference suffix. A held row adds the server's stored
/// reasons (`text_bn/en` in the app language, never a code) as a bulleted
/// list, then the customer review lines.
///
/// A stopped send (held, blocked, cancelled) shows its amount in
/// `onSurface`, never the credit green, and a non-final status as its
/// [StatusTag] ("আটকে আছে" amber); the review line carries an info icon.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/dates.dart';
import '../../../../app/l10n.dart';
import '../../../../app/server_text.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/animated/sheet_reveal.dart';
import '../../../../app/widgets/digit_slots.dart';
import '../../../../app/widgets/sheet_header.dart';
import '../../../../app/widgets/status_tag.dart';
import '../../../../app/widgets/txn_row.dart';
import '../../../../data/providers.dart';
import '../../../../data/repos/repos.dart';
import '../../../safety/ui/widgets/review_lines.dart';
import '../../logic/history_providers.dart';

class TxnDetailSheet extends StatelessWidget {
  const TxnDetailSheet({
    required this.txn,
    required this.acctId,
    this.nameEn,
    this.fromName,
    super.key,
  });

  final LedgerTxn txn;
  final String acctId;

  /// The counterparty's English name (English mode).
  final String? nameEn;

  /// The viewer's name for the sender of a received transfer.
  final String? fromName;

  static Future<void> show(
    BuildContext context, {
    required LedgerTxn txn,
    required String acctId,
    String? nameEn,
    String? fromName,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => TxnDetailSheet(
      txn: txn,
      acctId: acctId,
      nameEn: nameEn,
      fromName: fromName,
    ),
  );

  /// The last six letters and digits of the row id, uppercased ASCII
  /// (never the whole id, never localised digits: it is a code).
  static String referenceSuffix(String txnId) => referenceCode(txnId);

  Widget _value(BuildContext context, String v) => Text(
    v,
    textAlign: TextAlign.end,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: context.palette.onSurface),
  );

  /// The status in words, final states included.
  static String statusLabel(AppLocalizations l10n, String status) =>
      TxnRow.tagFor(l10n, status)?.$1 ?? l10n.statusDone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final locale = Localizations.localeOf(context);
    final (title, _) = TxnRow.titleAndType(
      context,
      txn,
      acctId,
      nameEn: nameEn,
      fromName: fromName,
    );
    final credit = TxnRow.isCredit(txn, acctId);
    final type = txn.type == 'send_money' && txn.isCreditFor(acctId)
        ? l10n.txnTypeReceived
        : TxnRow.typeLabel(l10n, txn.type);
    final tag = TxnRow.tagFor(l10n, txn.status);
    final time =
        '${BhDates.longDate(txn.ts, locale)}, ${BhDates.time(txn.ts, locale)}';
    final rows = <(String, Widget)>[
      (l10n.historyDetailType, _value(context, type)),
      (
        l10n.historyDetailStatus,
        tag == null
            ? _value(context, statusLabel(l10n, txn.status))
            : Align(
                alignment: AlignmentDirectional.centerEnd,
                child: StatusTag(
                  key: const Key('txn_detail_status_tag'),
                  label: tag.$1,
                  status: tag.$2,
                ),
              ),
      ),
      (l10n.historyDetailTime, _value(context, time)),
      (l10n.resultReference, _value(context, referenceSuffix(txn.txnId))),
    ];
    final spoken = context.digits(groupLakh(txn.amountBdt));
    return SafeArea(
      top: false,
      // The sheet's content settles in after the sheet itself (6.2).
      child: SlideFadeIn(
        offset: 16,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(
                key: const Key('txn_detail_header'),
                title: title,
                icon: TxnRow.iconFor(txn.type),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  BhSpace.m,
                  BhSpace.l,
                  BhSpace.m,
                  BhSpace.m,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      type,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: p.mutedText),
                    ),
                    const SizedBox(height: BhSpace.s),
                    Center(
                      child: TakaSlots(
                        key: const Key('txn_detail_amount'),
                        amount: txn.amountBdt,
                        style: context.textRoles.amountHero.copyWith(
                          color: credit ? p.success : p.onSurface,
                        ),
                        signColor: p.mutedText,
                        gap: 6,
                        semanticsLabel: credit
                            ? l10n.txnSemCredit(spoken)
                            : l10n.txnSemDebit(spoken),
                      ),
                    ),
                    const SizedBox(height: BhSpace.l),
                    for (final (k, v) in rows)
                      Container(
                        constraints: const BoxConstraints(
                          minHeight: BhSize.touch,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: p.outlineVariant),
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              k,
                              style: text.bodyMedium?.copyWith(
                                color: p.mutedText,
                              ),
                            ),
                            const SizedBox(width: BhSpace.m),
                            Expanded(child: v),
                          ],
                        ),
                      ),
                    if (txn.status == LedgerStatus.held) ...[
                      HeldReasons(txn: txn),
                      HeldReviewLines(txn: txn),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The server's reasons stored with a held row's intervention, one bullet
/// each in the app language (FR-3: server copy only, no codes). Nothing
/// when the record has none.
class HeldReasons extends ConsumerWidget {
  const HeldReasons({required this.txn, super.key});

  final LedgerTxn txn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
    if (uid == null) return const SizedBox.shrink();
    final reasons =
        ref
            .watch(
              txnReasonsProvider((
                uid: uid,
                txnId: txn.txnId,
                interventionId: txn.interventionId,
              )),
            )
            .value ??
        const [];
    final lines = [
      for (final r in reasons)
        if (r.text(context).trim().isNotEmpty) r.text(context),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: p.onSurface);
    return Container(
      key: const Key('txn_detail_reasons'),
      padding: const EdgeInsets.only(top: BhSpace.s),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: BhSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(child: Text('•  ', style: style)),
                  Expanded(child: Text(line, style: style)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The customer review lines of a held row, under its
/// reasons: the money is still the customer's, and how far a review is.
class HeldReviewLines extends ConsumerWidget {
  const HeldReviewLines({required this.txn, super.key});

  final LedgerTxn txn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
    if (uid == null) return const SizedBox.shrink();
    final p = context.palette;
    return Padding(
      key: const Key('txn_detail_review'),
      padding: const EdgeInsets.only(top: BhSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: BhSpace.xxs),
            child: Icon(
              Icons.info_outline,
              key: const Key('txn_detail_review_icon'),
              size: 16,
              color: p.mutedText,
            ),
          ),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: ReviewLinesForRow(uid: uid, row: txn, heldAt: txn.ts),
          ),
        ],
      ),
    );
  }
}
