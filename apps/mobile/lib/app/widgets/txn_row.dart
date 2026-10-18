import 'package:flutter/material.dart';

import '../../data/repos/ledger_repo.dart';
import '../dates.dart';
import '../l10n.dart';
import '../theme/theme.dart';
import 'animated/pressable.dart';
import 'digit_slots.dart';
import 'status_tag.dart';

/// One ledger row (7.3): a 48 dp leading icon tile,
/// then two baseline rows: title + amount, subtitle + status tag. The
/// trailing column never shrinks; the title ellipsises. Tags only for
/// non-final states (held, blocked, requested, cancelled, released); `ok` /
/// `done` show none. No row shows the same words twice: when the
/// counterparty is the generic type name, the title becomes "এজেন্ট · masked
/// number" (or the type label) and the subtitle drops the type. `payment`
/// rows read "বিল / পেমেন্ট", `dps_deposit` rows "ডিপিএস জমা".
///
/// The leading tile is an icon per type for every row (send, cash out, cash
/// in, recharge, bill, salary, DPS), never a letter, so the list reads as one
/// system; credits use the success container. In English the counterparty
/// shows [nameEn] when the caller knows it (`payeeNamesEnProvider`,
/// `englishNameFor`), and the stored name's digits always follow the app
/// language through `context.digits`. The row is one [Pressable] target
/// when [onTap] is set.
///
/// A received transfer is titled by its
/// sender: [fromName] (the viewer's own name for the sender, from the saved
/// payees), else the stored name when it was written for the viewer, else
/// the sender's masked number; its type reads "টাকা এসেছে", never "টাকা
/// পাঠানো". A stopped send (held, blocked, cancelled) is never a credit: no
/// green, no "+".
class TxnRow extends StatelessWidget {
  const TxnRow({
    required this.txn,
    required this.acctId,
    this.onTap,
    this.dense = false,
    this.now,
    this.nameEn,
    this.fromName,
    super.key,
  });

  final LedgerTxn txn;

  /// The viewer's name for the sender of a received transfer, in the app
  /// language (`senderNameFor`); null when unknown.
  final String? fromName;

  /// The counterparty's English name, shown in English mode.
  final String? nameEn;

  /// The customer's account: decides debit or credit.
  final String acctId;
  final VoidCallback? onTap;

  /// 64 dp instead of 72.
  final bool dense;

  /// Injectable clock for the date label (tests).
  final DateTime? now;

  static const _minus = '− ';
  static const _plus = '+ ';

  /// Ledger `type` of a DPS instalment (`finance_repo.dart`).
  static const dpsType = 'dps_deposit';

  static IconData iconFor(String type) => switch (type) {
    'send_money' => Icons.send_outlined,
    'cash_out' => Icons.south,
    'cash_in' => Icons.north,
    'recharge' => Icons.phone_android,
    'payment' => Icons.receipt_long,
    'salary' => Icons.work_outline,
    dpsType => Icons.savings_outlined,
    _ => Icons.swap_horiz,
  };

  static String typeLabel(AppLocalizations l10n, String type) => switch (type) {
    'send_money' => l10n.txnTypeSendMoney,
    'cash_in' => l10n.txnTypeCashIn,
    'cash_out' => l10n.txnTypeCashOut,
    'salary' => l10n.txnTypeSalary,
    'payment' => l10n.txnTypeBill,
    'recharge' => l10n.txnTypeRecharge,
    dpsType => l10n.txnTypeDps,
    _ => l10n.txnTypeOther,
  };

  /// The tag for [status], or null for final states.
  static (String, BhStatus)? tagFor(AppLocalizations l10n, String status) =>
      switch (status) {
        LedgerStatus.held => (l10n.statusHeld, BhStatus.warning),
        LedgerStatus.blocked => (l10n.statusBlocked, BhStatus.danger),
        'requested' => (l10n.statusRequested, BhStatus.warning),
        LedgerStatus.cancelled => (l10n.statusCancelled, BhStatus.neutral),
        LedgerStatus.released => (l10n.statusReleased, BhStatus.neutral),
        _ => null,
      };

  /// "০১৭XX-XXX০২৭" for an agent account (`AG-0027` keeps its last three
  /// digits; `agent_01712345678` is masked), else null.
  static String? maskedAgent(String acct) {
    final ag = RegExp(r'^AG-(\d+)$').firstMatch(acct);
    if (ag != null) {
      final d = ag.group(1)!.padLeft(3, '0');
      return '017XX-XXX${d.substring(d.length - 3)}';
    }
    final full = RegExp(r'^agent_(\d{11})$').firstMatch(acct);
    if (full != null) {
      final d = full.group(1)!;
      return '${d.substring(0, 3)}XX-XXX${d.substring(8)}';
    }
    return null;
  }

  /// Money arrived at [acctId] on row [t] (a stopped send never counts).
  static bool isCredit(LedgerTxn t, String acctId) =>
      t.isCreditFor(acctId) && !t.isStopped;

  /// "01712-XXX678" for a typed-number account (`acct_01712345678`),
  /// "…1070" for a short numbered one; null when the id has no number.
  static String? maskedNumber(String acct) {
    final d = acct.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 11) return '${d.substring(0, 3)}XX-XXX${d.substring(8)}';
    if (d.length >= 4) return '…${d.substring(d.length - 4)}';
    return null;
  }

  /// (title, subtitle-type-or-null) following the no-repeat rule.
  static (String, String?) titleAndType(
    BuildContext context,
    LedgerTxn txn,
    String acctId, {
    String? nameEn,
    String? fromName,
  }) {
    final l10n = context.l10n;
    final english = !context.banglaDigits;
    final forViewer = txn.nameIsForViewer(acctId);
    final nameBn = forViewer ? (txn.counterpartyNameBn ?? '').trim() : '';
    final en = forViewer ? (nameEn ?? '').trim() : '';
    if (txn.type == 'send_money' && txn.isCreditFor(acctId)) {
      // A received transfer: titled by its sender, typed "টাকা এসেছে".
      final received = l10n.txnTypeReceived;
      final from = (fromName ?? '').trim();
      final stored = english && en.isNotEmpty ? en : nameBn;
      final masked = maskedNumber(txn.fromAcct);
      final title = from.isNotEmpty
          ? from
          : stored.isNotEmpty
          ? stored
          : masked ?? '';
      return title.isEmpty
          ? (received, null)
          : (context.digits(title), received);
    }
    final type = typeLabel(l10n, txn.type);
    final other = txn.isDebitFor(acctId) ? txn.toAcct : txn.fromAcct;
    final agentGeneric =
        (txn.type == 'cash_out' || txn.type == 'cash_in') &&
        nameBn.startsWith('এজেন্ট');
    // Stored names keep whatever digits they were written with; the row
    // shows them in the app's digits (a new-number send in English reads
    // "01712-345678", not "০১৭১২-৩৪৫৬৭৮").
    final name = context.digits(english && en.isNotEmpty ? en : nameBn);
    if (name.isNotEmpty && !agentGeneric) {
      // "গার্মেন্টস বেতন" already says "বেতন": the subtitle drops the type.
      return (name, name.contains(type) ? null : type);
    }
    final agent = maskedAgent(other);
    if (agent != null) {
      return ('${l10n.agentLabel} · ${context.digits(agent)}', type);
    }
    return (type, null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final locale = Localizations.maybeLocaleOf(context) ?? const Locale('bn');
    final credit = isCredit(txn, acctId);
    final debit = !credit;
    final (title, type) = titleAndType(
      context,
      txn,
      acctId,
      nameEn: nameEn,
      fromName: fromName,
    );
    final date = BhDates.rowLabel(txn.ts, locale, now: now);
    // A transfer released by the phone's biometric check says so instead of
    // the type: a final state, so no tag.
    final subtitle = txn.status == LedgerStatus.releasedByStepUp
        ? '${l10n.stepUpHistorySubtitle} · $date'
        : type == null
        ? date
        : '$type · $date';
    final tag = tagFor(l10n, txn.status);
    final person = txn.type == 'send_money';
    final amountStyle = text.titleSmall!.copyWith(
      color: debit ? p.onSurface : p.success,
    );
    final spoken = [
      title,
      ?type,
      date,
      '${context.takaSpoken(txn.amountBdt)} ${debit ? l10n.txnSent : l10n.txnReceived}',
      if (tag != null) tag.$1,
    ].join(', ');

    // Credits green, sends in the brand container, everything else neutral:
    // the same tile shape with a type icon for every row.
    final leadingBg = !debit
        ? p.successContainer
        : person
        ? p.primaryContainer
        : p.surfaceVariant;
    final leadingFg = !debit
        ? p.onSuccessContainer
        : person
        ? p.onPrimaryContainer
        : p.mutedText;
    final leading = Container(
      key: const Key('txn_row_icon'),
      width: BhSize.avatar,
      height: BhSize.avatar,
      color: leadingBg,
      alignment: Alignment.center,
      child: Icon(iconFor(txn.type), size: 24, color: leadingFg),
    );

    final Widget row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: dense ? BhSize.rowHeightCompact : BhSize.rowHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: BhSpace.m,
          vertical: 12,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: BhSpace.m),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: text.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: BhSpace.s),
                      TakaSlots(
                        amount: txn.amountBdt,
                        // A stopped incoming send moved nothing: no sign.
                        prefix: credit
                            ? _plus
                            : txn.isStopped && !txn.isDebitFor(acctId)
                            ? null
                            : _minus,
                        style: amountStyle,
                        signScale: 1,
                        gap: 4,
                      ),
                    ],
                  ),
                  const SizedBox(height: BhSpace.xxs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      // The tag keeps its intrinsic width; beside it the
                      // subtitle wraps to a second line rather than cut
                      // the time ("টাকা পাঠানো · আজ, ভোর …" on a held row).
                      Expanded(
                        child: Text(
                          subtitle,
                          key: const Key('txn_row_subtitle'),
                          style: text.bodySmall,
                          maxLines: tag == null ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (tag != null) ...[
                        const SizedBox(width: BhSpace.s),
                        StatusTag(label: tag.$1, status: tag.$2),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) {
      return Semantics(
        label: spoken,
        child: ExcludeSemantics(child: row),
      );
    }
    return Pressable(onTap: onTap, semanticLabel: spoken, child: row);
  }
}
