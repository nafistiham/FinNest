/// History: the full ledger of the signed-in user,
/// the type filters and the grouping by day. Pure helpers plus one stream.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dates.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../pay/logic/billers.dart';
import '../../pay/logic/pay_intent.dart';

/// How many rows History asks the ledger for.
const historyLimit = 500;

/// Every row of [uid], newest first.
final historyTxnsProvider = StreamProvider.autoDispose
    .family<List<LedgerTxn>, String>(
      (ref, uid) =>
          ref.watch(ledgerRepoProvider).watchRecent(uid, limit: historyLimit),
    );

/// The server's reasons stored with the intervention behind the row
/// [key].txnId of user [key].uid (the record named by the row's
/// `intervention_id`, else the one written for that `txn_id`); empty when
/// there is none. History's held-row detail lists their `text_bn/en`.
final txnReasonsProvider = StreamProvider.autoDispose
    .family<List<Reason>, ({String uid, String txnId, String? interventionId})>(
      (ref, key) => ref.watch(interventionRepoProvider).watch(key.uid).map((
        records,
      ) {
        final r =
            records
                .where(
                  (r) =>
                      key.interventionId != null && r.id == key.interventionId,
                )
                .firstOrNull ??
            records.where((r) => r.txnId == key.txnId).firstOrNull;
        return r?.reasons ?? const <Reason>[];
      }),
    );

/// The filter chips, in display order. [id] is the `?filter=` value.
enum HistoryFilter {
  all('all'),
  sent('sent'),
  cashOut('cashout'),
  cashIn('cashin'),
  recharge('recharge'),
  bill('bill'),
  received('received'),

  /// Held transfers only: Home's "দেখুন ›" on the held summary card.
  held('held');

  const HistoryFilter(this.id);

  final String id;

  static HistoryFilter parse(String? id) =>
      values.where((f) => f.id == id).firstOrNull ?? all;

  /// Whether row [t] of account [acctId] belongs under this chip.
  bool matches(LedgerTxn t, String acctId) => switch (this) {
    all => true,
    sent => t.type == 'send_money' && t.isDebitFor(acctId),
    cashOut => t.type == 'cash_out',
    cashIn => t.type == 'cash_in',
    recharge => t.type == 'recharge',
    bill => t.type == 'payment',
    received => t.toAcct == acctId && !t.isDebitFor(acctId),
    held => t.status == LedgerStatus.held,
  };
}

/// One day of History: its header ("আজ", "গতকাল", "১০ নভেম্বর") and rows.
class HistoryDay {
  const HistoryDay({required this.header, required this.rows});

  final String header;
  final List<LedgerTxn> rows;
}

/// [rows] (any order) grouped by Dhaka calendar day, newest day first and
/// newest row first inside a day.
List<HistoryDay> groupByDay(
  List<LedgerTxn> rows,
  Locale locale, {
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final sorted = [...rows]..sort((a, b) => b.ts.compareTo(a.ts));
  final out = <HistoryDay>[];
  DateTime? currentDay;
  var current = <LedgerTxn>[];
  for (final t in sorted) {
    final d = BhDates.dhaka(t.ts);
    final day = DateTime.utc(d.year, d.month, d.day);
    if (day != currentDay) {
      if (current.isNotEmpty) {
        out.add(
          HistoryDay(
            header: BhDates.dayHeader(current.first.ts, locale, now: n),
            rows: current,
          ),
        );
      }
      currentDay = day;
      current = [];
    }
    current.add(t);
  }
  if (current.isNotEmpty) {
    out.add(
      HistoryDay(
        header: BhDates.dayHeader(current.first.ts, locale, now: n),
        rows: current,
      ),
    );
  }
  return out;
}

/// English forms of the fixed seed counterparty names
/// (`assets/demo/personas.json`, `finance_repo.dart`). Names are data, not
/// ARB copy: the seed carries only the Bangla name, so the English one is
/// looked up here at render time.
const seedNamesEn = <String, String>{
  'নতুন নম্বর': 'New number',
  'গার্মেন্টস বেতন': 'Garment wages',
  'ডিপিএস জমা': 'DPS deposit',
};

/// English names of the signed-in persona's counterparties, keyed by account
/// id and by Bangla name: the saved payees, the fixed seed names
/// ([seedNamesEn]), the mobile operators (recharge rows store
/// `operator · number`) and the billers' bill names once the catalogue
/// has loaded. A ledger row carries only the Bangla name, so this is how
/// "মা" reads "Mother" and "ডেসকো বিদ্যুৎ বিল" reads "DESCO electricity
/// bill" in English mode.
final payeeNamesEnProvider = Provider.autoDispose<Map<String, String>>((ref) {
  final persona = ref.watch(
    currentUserProvider.select((u) => u.value?.persona),
  );
  final billers = ref.watch(billersProvider).value ?? const <Biller>[];
  return {
    ...seedNamesEn,
    for (final op in Operator.values) op.nameBn: op.nameEn,
    for (final b in billers)
      if (b.billNameEn.isNotEmpty) b.billNameBn: b.billNameEn,
    if (persona != null)
      for (final p in ref.watch(ledgerRepoProvider).savedPayees(persona))
        if (p.nameEn.isNotEmpty) ...{p.acctId: p.nameEn, p.nameBn: p.nameEn},
  };
});

/// Bangla names of the signed-in persona's saved payees by account id
/// ("acct_rahima" → "মা" for Rina, "acct_rina" → "রিনা" for Rahima): the
/// viewer's own name for the sender of a received transfer.
final payeeNamesBnProvider = Provider.autoDispose<Map<String, String>>((ref) {
  final persona = ref.watch(
    currentUserProvider.select((u) => u.value?.persona),
  );
  if (persona == null) return const {};
  return {
    for (final p in ref.watch(ledgerRepoProvider).savedPayees(persona))
      if (p.nameBn.isNotEmpty) p.acctId: p.nameBn,
  };
});

/// The viewer's name for the sender of a received transfer [t] (the saved
/// payee by account, English when [english] and known), else null.
String? senderNameFor(
  LedgerTxn t,
  String acctId, {
  required Map<String, String> namesBn,
  required Map<String, String> namesEn,
  required bool english,
}) {
  if (t.type != 'send_money' || !t.isCreditFor(acctId)) return null;
  final bn = namesBn[t.fromAcct];
  return english ? namesEn[t.fromAcct] ?? bn : bn;
}

/// The English name of row [t]'s counterparty from [names], or null when
/// none is known (the row then shows its Bangla name, digits converted).
///
/// Recharge rows are stored as `operator Bangla name · number`; the
/// operator part is translated and the number kept, so the row reads
/// "Operator A · 01712-345678".
String? englishNameFor(LedgerTxn t, String acctId, Map<String, String> names) {
  if (names.isEmpty) return null;
  final other = t.isDebitFor(acctId) ? t.toAcct : t.fromAcct;
  final bn = t.nameIsForViewer(acctId)
      ? (t.counterpartyNameBn ?? '').trim()
      : '';
  final direct = names[other] ?? (bn.isEmpty ? null : names[bn]);
  if (direct != null) return direct;
  if (t.type == 'recharge' && bn.contains(' · ')) {
    final parts = bn.split(' · ');
    final op = names[parts.first.trim()];
    if (op != null) return [op, ...parts.skip(1)].join(' · ');
  }
  return null;
}
