/// Send money's payee helpers:
/// the demo map from typed numbers to the mule ring's account ids, the
/// "সাম্প্রতিক" group of unsaved recipients from the ledger, and the payee
/// line's warning record on the intent.
///
/// `assets/demo/payee_map.json` is demo only: three typed numbers reach the
/// ring `GET /v1/mule/demo-ring` serves. Every other number keeps today's
/// `acct_<digits>`.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repos/repos.dart';
import 'pay_controller.dart';
import 'pay_rules.dart';

/// Typed 11-digit numbers → account ids, loaded once from [path].
class PayeeMap {
  const PayeeMap(this._byNumber);

  static const path = 'assets/demo/payee_map.json';

  /// Before the asset has loaded (or when it fails): every number falls
  /// back to [fallbackFor].
  static const empty = PayeeMap(<String, String>{});

  final Map<String, String> _byNumber;

  /// Keys starting with `_` are comments.
  factory PayeeMap.parse(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    return PayeeMap(
      Map.unmodifiable({
        for (final e in root.entries)
          if (!e.key.startsWith('_') && e.value is String)
            e.key: e.value as String,
      }),
    );
  }

  static Future<PayeeMap> load([AssetBundle? bundle]) async =>
      PayeeMap.parse(await (bundle ?? rootBundle).loadString(path));

  /// The account id a typed number pays: the mapped ring id, else the
  /// app's long-standing `acct_<digits>`.
  String acctForTyped(String digits) =>
      _byNumber[digits] ?? fallbackFor(digits);

  /// What a typed number became before the map existed.
  static String fallbackFor(String digits) => 'acct_$digits';

  /// The typed number that maps to [acctId], or null.
  String? numberFor(String acctId) {
    for (final e in _byNumber.entries) {
      if (e.value == acctId) return e.key;
    }
    return null;
  }

  /// The masked display number of an account ("017XXXXX070", ASCII): the
  /// mapped number, or the 11 digits of an `acct_<digits>` id, masked to
  /// the first three and the last three; any other id keeps its last three
  /// digits after `017XXXXX` (as the seed masks agent tills).
  String maskedFor(String acctId) {
    final number =
        numberFor(acctId) ??
        switch (acctId.replaceFirst('acct_', '')) {
          final d when RegExp(r'^\d{11}$').hasMatch(d) => d,
          _ => null,
        };
    if (number != null) {
      return '${number.substring(0, 3)}XXXXX'
          '${number.substring(number.length - 3)}';
    }
    return PayRules.agentMasked(acctId);
  }
}

/// The bundled map. Tests override it with a parsed map.
final payeeMapProvider = FutureProvider<PayeeMap>((_) => PayeeMap.load());

/// The map for a synchronous lookup: [PayeeMap.empty] until it has loaded.
final payeeMapNowProvider = Provider<PayeeMap>(
  (ref) => ref.watch(payeeMapProvider).value ?? PayeeMap.empty,
);

/// How many rows the "সাম্প্রতিক" group shows.
const recentUnsavedMax = 3;

/// The "সাম্প্রতিক" group: [acctId]'s send rows (any status)
/// to an account that is not one of [saved], newest first, one row per
/// recipient, at most [recentUnsavedMax]. Each entry is the newest row to
/// that recipient.
List<LedgerTxn> recentUnsavedSends(
  List<LedgerTxn> rows,
  String acctId,
  Iterable<Payee> saved,
) {
  final savedIds = {for (final p in saved) p.acctId};
  final sorted = [...rows]..sort((a, b) => b.ts.compareTo(a.ts));
  final seen = <String>{};
  final out = <LedgerTxn>[];
  for (final t in sorted) {
    if (t.type != 'send_money' || !t.isDebitFor(acctId)) continue;
    if (t.toAcct.isEmpty || t.toAcct == acctId) continue;
    if (savedIds.contains(t.toAcct) || !seen.add(t.toAcct)) continue;
    out.add(t);
    if (out.length == recentUnsavedMax) break;
  }
  return out;
}

/// `warning_shown` / `warning_choice` values.
abstract final class PayeeWarning {
  static const unfamiliarPayee = 'unfamiliar_payee';
  static const continued = 'continued';
}

/// The amount step's record of the payee line. The intent is the
/// controller's state, so the write lives on the controller.
// own pay_controller.dart).
extension PayeeWarningX on PayController {
  /// Leaving the amount step by "পরের ধাপ": an unfamiliar payee records
  /// that the line was shown and the customer continued; a saved payee
  /// clears any earlier record (the customer went back and changed it).
  void recordPayeeLine({required bool unfamiliar}) => setPayeeWarning(
    shown: unfamiliar ? PayeeWarning.unfamiliarPayee : null,
    choice: unfamiliar ? PayeeWarning.continued : null,
  );
}
