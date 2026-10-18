/// Labels and tones of the staff Fraud desk. Staff
/// screens may show masked ids; no customer screen imports this file.
library;

import 'package:flutter/widgets.dart' show Locale;

import '../../../app/dates.dart';
import '../../../app/l10n.dart';
import '../../../app/theme/palette.dart';
import '../../../data/contracts/contracts.dart';

/// "…1070" for `acct_01070`: the last four letters or digits of [id] behind
/// an ellipsis (the caller converts the digits to the app language).
String maskId(String id) {
  final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (clean.isEmpty) return '…';
  final tail = clean.length <= 4 ? clean : clean.substring(clean.length - 4);
  return '…$tail';
}

/// The ring role of a watch-list row; anything else reads "অন্যান্য".
String roleLabel(AppLocalizations l10n, String role) => switch (role) {
  'mule_L1' => l10n.fraudDeskRoleL1,
  'mule_L2' => l10n.fraudDeskRoleL2,
  'controller' => l10n.fraudDeskRoleController,
  'cashout_agent' => l10n.fraudDeskRoleCashout,
  'victim' => l10n.fraudDeskRoleVictim,
  _ => l10n.fraudDeskRoleOther,
};

/// A payee's watch-list status: suspected → warning, confirmed → danger,
/// cleared → success, anything else neutral.
({String label, BhStatus tone}) payeeStatusOf(
  AppLocalizations l10n,
  String status,
) => switch (status) {
  'suspected' => (label: l10n.fraudDeskStatusSuspected, tone: BhStatus.warning),
  'confirmed' => (label: l10n.fraudDeskStatusConfirmed, tone: BhStatus.danger),
  'cleared' => (label: l10n.fraudDeskStatusCleared, tone: BhStatus.success),
  _ => (label: l10n.fraudDeskStatusUnknown, tone: BhStatus.neutral),
};

/// A case's run status: queued/running are info (a wait, not a hold),
/// done success, degraded (delivered, citations not verified) warning,
/// failed and unknown neutral (red is for a block only).
({String label, BhStatus tone}) caseStatusOf(
  AppLocalizations l10n,
  CaseStatus status,
) => switch (status) {
  CaseStatus.queued => (label: l10n.czStatusQueued, tone: BhStatus.info),
  CaseStatus.running => (label: l10n.czStatusRunning, tone: BhStatus.info),
  CaseStatus.done => (label: l10n.czStatusDone, tone: BhStatus.success),
  CaseStatus.degraded => (label: l10n.czStatusDegraded, tone: BhStatus.warning),
  CaseStatus.failed => (label: l10n.czStatusFailed, tone: BhStatus.neutral),
  CaseStatus.unknown => (label: l10n.czStatusUnknown, tone: BhStatus.neutral),
};

/// The agent's recommendation; an unknown action goes to a reviewer.
String actionLabel(AppLocalizations l10n, CaseAction action) =>
    switch (action) {
      CaseAction.freeze => l10n.czActionFreeze,
      CaseAction.edd => l10n.czActionEdd,
      CaseAction.monitor => l10n.czActionMonitor,
      CaseAction.closeNoAction => l10n.czActionClose,
      CaseAction.pending => l10n.czActionPending,
      CaseAction.routeToRiskReviewer ||
      CaseAction.unknown => l10n.czActionReviewer,
    };

// --- Server text on staff screens -----------

/// Any ASCII or Bangla digit.
const _d = '[0-9০-৯]';

final _acctRe = RegExp(r'\bacct_[A-Za-z0-9]+');
final _txnRe = RegExp(r'\btxn_[A-Za-z0-9]+');
final _agentRe = RegExp(r'\b(?:[Aa]gent\s+)?(AG-\d+)\b');
final _dateTimeRe = RegExp(
  '($_d{4})-($_d{2})-($_d{2})(?:\\s*(?:at|T|তারিখে)\\s*|\\s+)'
  '($_d{2}):($_d{2})(?::$_d{2})?',
);
final _dateRe = RegExp('($_d{4})-($_d{2})-($_d{2})');
final _timeRe = RegExp('($_d{2}):($_d{2}):$_d{2}');

/// The display-side replacement table for rendered case summaries: the
/// design's own role word instead of the loanword (two spellings of one
/// word; the server text is otherwise kept as it is).
const victimWords = <String, String>{
  'ভিকটিম': 'ভুক্তভোগী',
  'ভিক্টিম': 'ভুক্তভোগী',
};

/// What a `txn_*` id in a summary becomes once the id itself moved to the
/// evidence list: "তালিকার লেনদেন(ের)" / "a listed transfer".
const _listedTxnBn = 'তালিকার লেনদেন';
const _listedTxnEn = 'a listed transfer';

String _digitsFor(bool bangla, String s) =>
    bangla ? bnDigits(s) : asciiDigits(s);

int _int(String s) => int.parse(asciiDigits(s));

/// "…1070" for `acct_01070` (the last four digits of a numbered id); for
/// a named id ("acct_rina") the trailing digits of its masked phone in
/// [phones] ("017XXXXX412" → "…412"), else "…••••". Never the name.
String maskAcct(
  String id, {
  required bool bangla,
  Map<String, String> phones = const {},
}) {
  final digits = asciiDigits(id).replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isNotEmpty) {
    final tail = digits.length <= 4
        ? digits
        : digits.substring(digits.length - 4);
    return '…${_digitsFor(bangla, tail)}';
  }
  final phone = RegExp(r'[0-9]+$')
      .firstMatch(asciiDigits(phones[id] ?? ''))
      ?.group(0);
  if (phone != null) {
    final tail = phone.length <= 4 ? phone : phone.substring(phone.length - 4);
    return '…${_digitsFor(bangla, tail)}';
  }
  return '…••••';
}

String _formatDates(String text, {required bool bangla, DateTime? now}) {
  final locale = Locale(bangla ? 'bn' : 'en');
  var out = text.replaceAllMapped(_dateTimeRe, (m) {
    final wall = DateTime.utc(
      _int(m[1]!),
      _int(m[2]!),
      _int(m[3]!),
      _int(m[4]!),
      _int(m[5]!),
    );
    return BhDates.wallDayTime(wall, locale, now: now);
  });
  out = out.replaceAllMapped(_dateRe, (m) {
    final wall = DateTime.utc(_int(m[1]!), _int(m[2]!), _int(m[3]!));
    return BhDates.wallDayTime(wall, locale, withTime: false, now: now);
  });
  return out.replaceAllMapped(
    _timeRe,
    (m) => _digitsFor(bangla, '${asciiDigits(m[1]!)}:${asciiDigits(m[2]!)}'),
  );
}

/// A case summary ready for the staff screen: every `acct_*`
/// masked ("…১০৭০", the victim included: [phones] gives a named account
/// its masked number), every `txn_*` id taken out of the prose (it is
/// listed with the evidence, see [citedTxnIds]), "YYYY-MM-DD HH:MM:SS"
/// times as "১০ নভেম্বর, ১৪:১৩", and "ভিকটিম" as "ভুক্তভোগী" ([victimWords]).
/// [bangla] is the language of [text] (it picks the digits and words).
String maskCaseText(
  String text, {
  required bool bangla,
  Map<String, String> phones = const {},
  DateTime? now,
}) {
  var out = text;
  for (final e in victimWords.entries) {
    out = out.replaceAll(e.key, e.value);
  }
  out = out.replaceAllMapped(
    _acctRe,
    (m) => maskAcct(m[0]!, bangla: bangla, phones: phones),
  );
  if (bangla) {
    out = out
        .replaceAllMapped(
          RegExp('${_txnRe.pattern}\\s*এর'),
          (_) => '$_listedTxnBnের',
        )
        .replaceAll(_txnRe, _listedTxnBn);
  } else {
    out = out.replaceAll(_txnRe, _listedTxnEn);
  }
  return _formatDates(out, bangla: bangla, now: now);
}

/// The `txn_*` ids named in [texts], first mention first, each once.
List<String> citedTxnIds(Iterable<String> texts) => [
  ...{
    for (final t in texts)
      for (final m in _txnRe.allMatches(t)) m[0]!,
  },
];

/// A watch-list fact for the staff row: `acct_*` and `txn_*`
/// ids masked to "…NNNN" in the app's digits, agent codes kept and named
/// ("এজেন্ট AG-0014" in Bangla). The fact stays in the server's language
/// (English): no translation is invented.
String maskFactText(String text, {required bool bangla}) {
  var out = text.replaceAllMapped(
    _acctRe,
    (m) => maskAcct(m[0]!, bangla: bangla),
  );
  out = out.replaceAllMapped(_txnRe, (m) => maskAcct(m[0]!, bangla: bangla));
  if (bangla) {
    out = out.replaceAllMapped(_agentRe, (m) => 'এজেন্ট ${m[1]}');
  }
  return out;
}

/// The facts of [entry] that belong on its row: a fact naming
/// accounts is kept only when one of them is [entry]'s own; a fact naming
/// none is about the row. At most [max].
List<String> factsFor(PayeeRiskEntry entry, {int max = 2}) {
  bool mine(String f) {
    final ids = [for (final m in _acctRe.allMatches(f)) m[0]];
    return ids.isEmpty || ids.contains(entry.acctId);
  }

  return entry.facts.where(mine).take(max).toList();
}
