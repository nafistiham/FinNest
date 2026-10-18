import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/persona.dart';

/// Status values of a [LedgerTxn].
abstract final class LedgerStatus {
  /// Seeded history entries.
  static const ok = 'ok';

  /// Completed in this session (debits reduce the balance).
  static const done = 'done';
  static const held = 'held';
  static const blocked = 'blocked';
  static const released = 'released';
  static const cancelled = 'cancelled';

  /// Cash in waiting for the agent to confirm. Never
  /// moves the balance; [LedgerRepo.confirmCashIn] turns it into [done].
  static const requested = 'requested';

  /// A server hold the owner released on this phone with a strong
  /// biometric. Moves the balance like [done]; the
  /// row carries the [StepUpRecord].
  static const releasedByStepUp = 'released_by_step_up';

  static const all = <String>{
    ok,
    done,
    held,
    blocked,
    released,
    cancelled,
    requested,
    releasedByStepUp,
  };

  /// Statuses of a session row whose money left (or arrived): they move the
  /// balance.
  static bool movesMoney(String status) =>
      status == done || status == releasedByStepUp;
}

/// The audit trail of an identity step-up: how and when the
/// owner confirmed, which decision it answered and what the server said.
/// Stored on the ledger row and the intervention record as `step_up`.
class StepUpRecord {
  const StepUpRecord({
    required this.method,
    required this.at,
    required this.decisionId,
    required this.serverDecision,
    this.reasonCodes = const [],
  });

  factory StepUpRecord.fromJson(Map<String, dynamic> json) => StepUpRecord(
    method: readString(json, 'method', biometric),
    at: DateTime.parse(requireString(json, 'at')),
    decisionId: readString(json, 'decision_id', ''),
    serverDecision: readString(json, 'server_decision', ''),
    reasonCodes: readList(json, 'reason_codes', stringItem),
  );

  static const biometric = 'biometric';

  final String method;
  final DateTime at;

  /// The server's intervention id for the hold when it named one
  /// (`InterventionRecord.serverInterventionId`), else this phone's record
  /// id.
  final String decisionId;

  /// `hold` (a released hold) or `step_up` (the server asked for it).
  final String serverDecision;
  final List<String> reasonCodes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': method,
    'at': at.toUtc().toIso8601String(),
    'decision_id': decisionId,
    'server_decision': serverDecision,
    'reason_codes': List<String>.of(reasonCodes),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StepUpRecord &&
          method == other.method &&
          at.isAtSameMomentAs(other.at) &&
          decisionId == other.decisionId &&
          serverDecision == other.serverDecision &&
          listEq(reasonCodes, other.reasonCodes);

  @override
  int get hashCode => Object.hash(
    method,
    at.microsecondsSinceEpoch,
    decisionId,
    serverDecision,
    hashList(reasonCodes),
  );

  @override
  String toString() => 'StepUpRecord($method $serverDecision $decisionId)';
}

/// The fields [LedgerRepo.patch] may change on an existing row; `null`
/// leaves a field as it is.
class LedgerPatch {
  const LedgerPatch({this.status, this.stepUp, this.caseLink});

  final String? status;
  final StepUpRecord? stepUp;
  final CaseLink? caseLink;

  /// The Firestore `update` map (only the set fields).
  Map<String, Object?> toUpdate() => <String, Object?>{
    'status': ?status,
    if (stepUp != null) 'step_up': stepUp!.toJson(),
    if (caseLink != null) 'case_link': caseLink!.toJson(),
  };

  LedgerTxn applyTo(LedgerTxn t) =>
      t.copyWith(status: status, stepUp: stepUp, caseLink: caseLink);
}

/// A saved or new payee of the send-money screen.
class Payee {
  const Payee({
    required this.acctId,
    required this.nameBn,
    this.nameEn = '',
    this.phoneMasked = '',
    this.isSaved = true,
  });

  factory Payee.fromJson(Map<String, dynamic> json) => Payee(
    acctId: requireString(json, 'acct_id'),
    nameBn: requireString(json, 'name_bn'),
    nameEn: readString(json, 'name_en', ''),
    phoneMasked: readString(json, 'phone_masked', ''),
    isSaved: readBool(json, 'is_saved', true),
  );

  final String acctId;
  final String nameBn;
  final String nameEn;
  final String phoneMasked;
  final bool isSaved;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'acct_id': acctId,
    'name_bn': nameBn,
    'name_en': nameEn,
    'phone_masked': phoneMasked,
    'is_saved': isSaved,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Payee &&
          acctId == other.acctId &&
          nameBn == other.nameBn &&
          nameEn == other.nameEn &&
          phoneMasked == other.phoneMasked &&
          isSaved == other.isSaved;

  @override
  int get hashCode => Object.hash(acctId, nameBn, nameEn, phoneMasked, isSaved);

  @override
  String toString() => 'Payee($acctId, $nameEn)';
}

/// One row of the customer's history. Mirrors `transactions/{txnId}` plus the
/// client-only `counterparty_name_bn` and `intervention_id`.
///
/// [type] is the seed vocabulary (`send_money`, `cash_out`, `cash_in`,
/// `salary`, ...), not the three-value [TxnType] of the risk contracts.
class LedgerTxn {
  const LedgerTxn({
    required this.txnId,
    required this.ts,
    required this.type,
    required this.amountBdt,
    required this.fromAcct,
    required this.toAcct,
    this.channel = 'app',
    this.status = LedgerStatus.ok,
    this.counterpartyNameBn,
    this.interventionId,
    this.stepUp,
    this.caseLink,
    this.warningShown,
    this.warningChoice,
    this.simulated = false,
  });

  factory LedgerTxn.fromJson(Map<String, dynamic> json) => LedgerTxn(
    txnId: requireString(json, 'txn_id'),
    ts: DateTime.parse(requireString(json, 'ts')),
    type: requireString(json, 'type'),
    amountBdt: requireDouble(json, 'amount_bdt'),
    fromAcct: readString(json, 'from_acct', ''),
    toAcct: readString(json, 'to_acct', ''),
    channel: readString(json, 'channel', 'app'),
    status: readString(json, 'status', LedgerStatus.ok),
    counterpartyNameBn: readStringOrNull(json, 'counterparty_name_bn'),
    interventionId: readStringOrNull(json, 'intervention_id'),
    stepUp: readObject<StepUpRecord?>(
      json,
      'step_up',
      StepUpRecord.fromJson,
      null,
    ),
    caseLink: readObject<CaseLink?>(json, 'case_link', CaseLink.fromJson, null),
    warningShown: readStringOrNull(json, 'warning_shown'),
    warningChoice: readStringOrNull(json, 'warning_choice'),
    simulated: readBool(json, 'simulated', false),
  );

  final String txnId;
  final DateTime ts;
  final String type;
  final double amountBdt;
  final String fromAcct;
  final String toAcct;
  final String channel;
  final String status;
  final String? counterpartyNameBn;
  final String? interventionId;

  /// Set when the owner confirmed this transfer with a biometric step-up.
  final StepUpRecord? stepUp;

  /// The investigation this phone opened on the payee, if any.
  final CaseLink? caseLink;

  /// The pre-PIN warning the amount step showed (`unfamiliar_payee`) and
  /// what the customer did after it (`continued`), copied from the intent.
  final String? warningShown;
  final String? warningChoice;

  /// The behaviour sent with this transfer was replayed or switched off by
  /// the demo panel (local only; the server is not told).
  final bool simulated;

  /// True when money leaves [acctId].
  bool isDebitFor(String acctId) => fromAcct == acctId;

  /// True when money arrives at [acctId] (and does not also leave it).
  bool isCreditFor(String acctId) => toAcct == acctId && fromAcct != acctId;

  /// Whether the stored [counterpartyNameBn] was written for the viewer
  /// [acctId]. A transfer written on a phone stores the sender's name for
  /// the payee ("মা" on Rina's send), so on the receiving side it is not
  /// the viewer's name; seeded rows ([LedgerStatus.ok]) are per persona and
  /// are.
  bool nameIsForViewer(String acctId) =>
      !(type == 'send_money' &&
          isCreditFor(acctId) &&
          status != LedgerStatus.ok);

  /// A send stopped before any money moved (held, blocked or cancelled):
  /// never a credit on screen, never a "+".
  bool get isStopped =>
      status == LedgerStatus.held ||
      status == LedgerStatus.blocked ||
      status == LedgerStatus.cancelled;

  /// A cash in still waiting for the agent.
  bool get isRequestedCashIn =>
      type == 'cash_in' && status == LedgerStatus.requested;

  LedgerTxn copyWith({
    String? status,
    Object? interventionId = unchanged,
    String? counterpartyNameBn,
    DateTime? ts,
    StepUpRecord? stepUp,
    CaseLink? caseLink,
    Object? warningShown = unchanged,
    Object? warningChoice = unchanged,
    bool? simulated,
  }) => LedgerTxn(
    txnId: txnId,
    ts: ts ?? this.ts,
    type: type,
    amountBdt: amountBdt,
    fromAcct: fromAcct,
    toAcct: toAcct,
    channel: channel,
    status: status ?? this.status,
    counterpartyNameBn: counterpartyNameBn ?? this.counterpartyNameBn,
    interventionId: identical(interventionId, unchanged)
        ? this.interventionId
        : interventionId as String?,
    stepUp: stepUp ?? this.stepUp,
    caseLink: caseLink ?? this.caseLink,
    warningShown: identical(warningShown, unchanged)
        ? this.warningShown
        : warningShown as String?,
    warningChoice: identical(warningChoice, unchanged)
        ? this.warningChoice
        : warningChoice as String?,
    simulated: simulated ?? this.simulated,
  );

  /// The stored shape. The step-up, case-link and warning fields are written
  /// only when set, so a row without them keeps its old document shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'txn_id': txnId,
    'ts': ts.toIso8601String(),
    'type': type,
    'amount_bdt': amountBdt,
    'from_acct': fromAcct,
    'to_acct': toAcct,
    'channel': channel,
    'status': status,
    'counterparty_name_bn': counterpartyNameBn,
    'intervention_id': interventionId,
    if (stepUp != null) 'step_up': stepUp!.toJson(),
    if (caseLink != null) 'case_link': caseLink!.toJson(),
    'warning_shown': ?warningShown,
    'warning_choice': ?warningChoice,
    if (simulated) 'simulated': true,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LedgerTxn &&
          txnId == other.txnId &&
          ts == other.ts &&
          type == other.type &&
          amountBdt == other.amountBdt &&
          fromAcct == other.fromAcct &&
          toAcct == other.toAcct &&
          channel == other.channel &&
          status == other.status &&
          counterpartyNameBn == other.counterpartyNameBn &&
          interventionId == other.interventionId &&
          stepUp == other.stepUp &&
          caseLink == other.caseLink &&
          warningShown == other.warningShown &&
          warningChoice == other.warningChoice &&
          simulated == other.simulated;

  @override
  int get hashCode => Object.hash(
    txnId,
    ts,
    type,
    amountBdt,
    fromAcct,
    toAcct,
    channel,
    status,
    counterpartyNameBn,
    interventionId,
    stepUp,
    caseLink,
    warningShown,
    warningChoice,
    simulated,
  );

  @override
  String toString() => 'LedgerTxn($txnId $type $amountBdt $status)';
}

/// Transaction history and balance per user.
abstract class LedgerRepo {
  /// Newest first; emits the current list on subscribe, then every change.
  Stream<List<LedgerTxn>> watchRecent(String uid, {int limit = 8});

  /// Seeded balance minus `done` debits plus `done` credits created in this
  /// session (a confirmed cash in raises it).
  Stream<double> watchBalance(String uid);

  /// Stores [t] (with the status it carries) at the top of the history.
  Future<LedgerTxn> create(String uid, LedgerTxn t);

  /// Updates the status of an existing row (see [LedgerStatus]).
  Future<void> setStatus(String txnId, String status);

  /// Updates the set fields of [patch] on an existing row
  /// (Firestore rules allow updates). The default only carries the
  /// status; both shipped repos override it with every field.
  Future<void> patch(String txnId, LedgerPatch patch) async {
    final status = patch.status;
    if (status != null) await setStatus(txnId, status);
  }

  List<Payee> savedPayees(Persona p);

  /// The agent confirmed the cash in [txnId]: a `requested` `cash_in` row
  /// becomes `done` and raises the balance. Any other row is left alone.
  /// The demo panel calls this ("এজেন্ট ক্যাশ ইন
  /// নিশ্চিত করলেন").
  Future<void> confirmCashIn(String txnId);

  /// The newest cash in still waiting for the agent, or null.
  Future<LedgerTxn?> newestRequestedCashIn(String uid) async {
    final rows = await watchRecent(uid, limit: 50).first;
    for (final t in rows) {
      if (t.isRequestedCashIn) return t;
    }
    return null;
  }

  /// Codes older than [ttl] that the agent never confirmed become
  /// `cancelled` (Home calls this on load). Returns how many flipped.
  Future<int> expireCashIns(
    String uid, {
    required DateTime now,
    Duration ttl = const Duration(minutes: 15),
  }) async {
    final rows = await watchRecent(uid, limit: 50).first;
    var n = 0;
    for (final t in rows) {
      if (t.isRequestedCashIn && now.difference(t.ts) >= ttl) {
        await setStatus(t.txnId, LedgerStatus.cancelled);
        n++;
      }
    }
    return n;
  }

  /// Drops in-session rows and restores the seeded history (persona
  /// switch). Firestore implementations leave the collection alone.
  Future<void> reset(String uid);
}
