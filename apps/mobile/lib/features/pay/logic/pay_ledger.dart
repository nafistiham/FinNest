/// The ledger row each pay kind writes, and the
/// small read models the pay screens need (balance, recent rows, recent
/// agents).
library;

import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pay_intent.dart';
import 'pay_rules.dart';

abstract final class PayLedger {
  /// `counterparty_name_bn` of the generic agent rows (as in the seed).
  static const cashOutName = 'এজেন্ট ক্যাশ আউট';
  static const cashInName = 'এজেন্ট ক্যাশ ইন';

  /// A DPS first instalment: the plan account (as `FinanceRepo` writes it)
  /// and the names on the PIN pad.
  static const dpsAccount = 'acct_bhorosha_dps';
  static const dpsName = 'ডিপিএস প্রথম কিস্তি';
  static const dpsNameEn = 'DPS first instalment';

  /// The row for [intent] by [user]. Cash out debits amount + fee; cash in
  /// credits the typed amount from the code's pseudo account.
  static LedgerTxn rowFor(
    PayIntent intent,
    UserProfile user, {
    required String txnId,
    required DateTime ts,
    required String status,
    String? interventionId,
    String? cashInCode,
  }) {
    final c = intent.counterparty;
    final kind = intent.kind;
    return LedgerTxn(
      txnId: txnId,
      ts: ts,
      type: kind.ledgerType,
      amountBdt: (kind == PayKind.cashIn ? intent.amountBdt : intent.debitBdt)
          .toDouble(),
      fromAcct: kind == PayKind.cashIn
          ? 'cashin_${cashInCode ?? txnId}'
          : user.acctId,
      toAcct: switch (kind) {
        PayKind.cashIn => user.acctId,
        PayKind.recharge => 'mob_${c?.subtitle ?? ''}',
        _ => c?.acctId ?? '',
      },
      channel: kind == PayKind.cashOut || kind == PayKind.cashIn
          ? 'agent'
          : 'app',
      status: status,
      counterpartyNameBn: nameFor(intent),
      interventionId: interventionId,
    );
  }

  /// What History shows as the row's title. Digits are stored as typed
  /// (ASCII); `TxnRow` renders them in the app language through
  /// `context.digits`, so a row written in Bangla still reads right after a
  /// switch to English. The operator keeps its Bangla name here (the seed
  /// vocabulary); `englishNameFor` maps it at render time.
  static String nameFor(PayIntent intent) {
    final c = intent.counterparty;
    return switch (intent.kind) {
      PayKind.send => c?.nameBn ?? '',
      PayKind.cashOut => cashOutName,
      PayKind.cashIn => cashInName,
      PayKind.recharge => [
        if (intent.operator != null) intent.operator!.nameBn,
        PayRules.groupPhone(c?.subtitle ?? ''),
      ].join(' · '),
      PayKind.bill => intent.bill?.biller.billNameBn ?? c?.nameBn ?? '',
      PayKind.dps => 'ডিপিএস জমা',
    };
  }

  /// The English form of [nameFor], for a `counterparty_name_en` column
  /// once the ledger row carries one.
  static String nameEnFor(PayIntent intent) {
    final c = intent.counterparty;
    return switch (intent.kind) {
      PayKind.send => c?.nameEn ?? c?.nameBn ?? '',
      PayKind.cashOut => 'Agent cash out',
      PayKind.cashIn => 'Agent cash in',
      PayKind.recharge => [
        if (intent.operator != null) intent.operator!.nameEn,
        PayRules.groupPhone(c?.subtitle ?? ''),
      ].join(' · '),
      PayKind.bill => intent.bill?.biller.billNameEn ?? c?.nameEn ?? '',
      PayKind.dps => 'DPS deposit',
    };
  }
}

/// The signed-in customer's balance, live.
final payBalanceProvider = StreamProvider.autoDispose<double>((ref) {
  final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
  if (uid == null) return const Stream.empty();
  return ref.watch(ledgerRepoProvider).watchBalance(uid);
});

/// The customer's recent rows (for "শেষ ১০ নভে." and recent agents).
final payRecentRowsProvider = StreamProvider.autoDispose<List<LedgerTxn>>((
  ref,
) {
  final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
  if (uid == null) return Stream.value(const <LedgerTxn>[]);
  return ref.watch(ledgerRepoProvider).watchRecent(uid, limit: 50);
});

/// Newest row to [acctId] (any status), or null.
DateTime? lastPaidTo(List<LedgerTxn> rows, String acctId) {
  for (final t in rows) {
    if (t.toAcct == acctId) return t.ts;
  }
  return null;
}

/// The two most recent agents the customer cashed out at, from the
/// `to_acct` of `cash_out` rows, newest first, distinct.
List<Counterparty> recentAgents(List<LedgerTxn> rows, String acctId) {
  final seen = <String>{};
  final out = <Counterparty>[];
  for (final t in rows) {
    if (t.type != 'cash_out' || !t.isDebitFor(acctId)) continue;
    if (!seen.add(t.toAcct)) continue;
    final masked = t.toAcct.startsWith('agent_')
        ? t.toAcct.substring('agent_'.length)
        : PayRules.agentMasked(t.toAcct);
    out.add(
      Counterparty(
        acctId: t.toAcct,
        nameBn: 'এজেন্ট',
        nameEn: 'Agent',
        subtitle: masked,
        avatar: const CounterpartyAvatar.icon(Icons.storefront_outlined),
      ),
    );
    if (out.length == 2) break;
  }
  return out;
}
