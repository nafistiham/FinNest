import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/ledger_repo.dart';

/// Status values of an [InterventionRecord].
abstract final class InterventionStatus {
  /// Overlay shown, no decision yet.
  static const open = 'open';

  /// Trusted-contact request created, waiting for the contact.
  static const pending = 'pending';
  static const approved = 'approved';
  static const declined = 'declined';
  static const expired = 'expired';
  static const cancelled = 'cancelled';

  /// The owner released the hold with a biometric step-up;
  /// the same wire value as the ledger row.
  static const releasedByStepUp = LedgerStatus.releasedByStepUp;

  /// The server answered `step_up` and the owner passed the fingerprint on
  /// the PIN pad (entry point A): a closed record that only
  /// carries the step-up, so `stepUp.decisionId` points at something. There
  /// was never a hold, so it is not [releasedByStepUp].
  static const stepUpPassed = 'step_up_passed';
}

/// One intervention shown to the user. The server's
/// copy is stored verbatim in both languages (FR-3); `script_en` is optional
/// on the doc (older records carry only `script_bn`).
class InterventionRecord {
  const InterventionRecord({
    required this.id,
    required this.uid,
    required this.txnId,
    required this.trigger,
    required this.scriptBn,
    this.scriptEn = '',
    required this.reasons,
    required this.actions,
    required this.status,
    required this.createdAt,
    this.requestId,
    this.expiresAt,
    this.contactUid,
    this.audioAssetId,
    this.stepUp,
    this.caseLink,
    this.simulated = false,
    this.signalSources,
    this.serverInterventionId,
  });

  /// Reads the `interventions/{id}` shape. Timestamps are ISO-8601 strings
  /// (Firestore implementations convert `Timestamp` before calling this).
  factory InterventionRecord.fromDoc(String id, Map<String, dynamic> doc) =>
      InterventionRecord(
        id: id,
        uid: readString(doc, 'uid', ''),
        txnId: readString(doc, 'txn_id', ''),
        trigger: readString(doc, 'trigger', ''),
        scriptBn: readString(doc, 'script_bn', ''),
        scriptEn: readString(doc, 'script_en', ''),
        reasons: readList(doc, 'reasons', objectItem(Reason.fromJson)),
        actions: readList(doc, 'actions', objectItem(ActionItem.fromJson)),
        status: readString(doc, 'status', InterventionStatus.open),
        createdAt: DateTime.parse(requireString(doc, 'created_at')),
        requestId: readStringOrNull(doc, 'request_id'),
        expiresAt: switch (readStringOrNull(doc, 'expires_at')) {
          null => null,
          final s => DateTime.parse(s),
        },
        contactUid: readStringOrNull(doc, 'contact_uid'),
        audioAssetId: readStringOrNull(doc, 'audio_asset_id'),
        stepUp: readObject<StepUpRecord?>(
          doc,
          'step_up',
          StepUpRecord.fromJson,
          null,
        ),
        caseLink: readObject<CaseLink?>(
          doc,
          'case_link',
          CaseLink.fromJson,
          null,
        ),
        simulated: readBool(doc, 'simulated', false),
        signalSources: readObject<SignalSources?>(
          doc,
          'signal_sources',
          SignalSources.fromJson,
          null,
        ),
        serverInterventionId: readStringOrNull(doc, 'server_intervention_id'),
      );

  final String id;
  final String uid;
  final String txnId;

  /// Trigger name as sent to `/v1/intervene` (`call_active`, `screen_share`,
  /// `new_payee`, ...).
  final String trigger;
  final String scriptBn;
  final String scriptEn;
  final List<Reason> reasons;
  final List<ActionItem> actions;
  final String status;
  final DateTime createdAt;

  /// Set after `POST /v1/actions/trusted-contact`.
  final String? requestId;
  final DateTime? expiresAt;
  final String? contactUid;

  /// The clip `/v1/intervene` served (`audio_asset_id`); the Result banner
  /// queues it when it differs from the predicted one.
  final String? audioAssetId;

  /// Set when the owner released this hold with a biometric step-up.
  final StepUpRecord? stepUp;

  /// The investigation this phone opened on the payee, if any.
  final CaseLink? caseLink;

  /// The behaviour sent was replayed or switched off by the demo panel
  /// (local only; the overlay shows the "সিমুলেটেড" tag).
  final bool simulated;

  /// The score's `signal_sources`, kept with the rest of the decision.
  final SignalSources? signalSources;

  /// The server's id for this intervention:
  /// `InterveneResponse.intervention_id`, else the hold's
  /// `actions[].params.intervention_id` from `/v1/risk/score`. [id] is this
  /// phone's own record id; the trusted-contact request and the step-up's
  /// `decision_id` name this one when it is known. Null on records written
  /// before it existed, or when the server named none.
  final String? serverInterventionId;

  /// The id the server knows this intervention by: [serverInterventionId],
  /// else this phone's [id] (which the server accepts unverified only in
  /// demo mode).
  String get idForServer => serverInterventionId ?? id;

  InterventionRecord copyWith({
    String? status,
    Object? requestId = unchanged,
    Object? expiresAt = unchanged,
    Object? contactUid = unchanged,
    String? scriptBn,
    String? scriptEn,
    List<ActionItem>? actions,
    Object? audioAssetId = unchanged,
    StepUpRecord? stepUp,
    CaseLink? caseLink,
    bool? simulated,
    SignalSources? signalSources,
    String? serverInterventionId,
  }) => InterventionRecord(
    id: id,
    uid: uid,
    txnId: txnId,
    trigger: trigger,
    scriptBn: scriptBn ?? this.scriptBn,
    scriptEn: scriptEn ?? this.scriptEn,
    reasons: reasons,
    actions: actions ?? this.actions,
    status: status ?? this.status,
    createdAt: createdAt,
    requestId: identical(requestId, unchanged)
        ? this.requestId
        : requestId as String?,
    expiresAt: identical(expiresAt, unchanged)
        ? this.expiresAt
        : expiresAt as DateTime?,
    contactUid: identical(contactUid, unchanged)
        ? this.contactUid
        : contactUid as String?,
    audioAssetId: identical(audioAssetId, unchanged)
        ? this.audioAssetId
        : audioAssetId as String?,
    stepUp: stepUp ?? this.stepUp,
    caseLink: caseLink ?? this.caseLink,
    simulated: simulated ?? this.simulated,
    signalSources: signalSources ?? this.signalSources,
    serverInterventionId: serverInterventionId ?? this.serverInterventionId,
  );

  Map<String, Object?> toDoc() => <String, Object?>{
    'uid': uid,
    'txn_id': txnId,
    'trigger': trigger,
    'script_bn': scriptBn,
    'script_en': scriptEn,
    'reasons': reasons.map((r) => r.toJson()).toList(),
    'actions': actions.map((a) => a.toJson()).toList(),
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'request_id': requestId,
    'expires_at': expiresAt?.toIso8601String(),
    'contact_uid': contactUid,
    'audio_asset_id': audioAssetId,
    // Written only when set (older documents keep their shape).
    if (stepUp != null) 'step_up': stepUp!.toJson(),
    if (caseLink != null) 'case_link': caseLink!.toJson(),
    if (simulated) 'simulated': true,
    if (signalSources != null) 'signal_sources': signalSources!.toJson(),
    if (serverInterventionId != null)
      'server_intervention_id': serverInterventionId,
  };

  /// [toDoc] without its null fields: what a merge write sends, so a stale
  /// copy of the record never erases a field another writer set (the
  /// trusted-contact `request_id`).
  Map<String, Object?> toMergeDoc() =>
      toDoc()..removeWhere((_, v) => v == null);

  /// This record written over [stored] with merge semantics: every field
  /// this copy carries wins, a field it leaves null keeps the stored value.
  InterventionRecord mergedOnto(InterventionRecord? stored) => stored == null
      ? this
      : InterventionRecord.fromDoc(id, <String, dynamic>{
          ...stored.toDoc(),
          ...toMergeDoc(),
        });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InterventionRecord &&
          id == other.id &&
          uid == other.uid &&
          txnId == other.txnId &&
          trigger == other.trigger &&
          scriptBn == other.scriptBn &&
          scriptEn == other.scriptEn &&
          listEq(reasons, other.reasons) &&
          listEq(actions, other.actions) &&
          status == other.status &&
          createdAt == other.createdAt &&
          requestId == other.requestId &&
          expiresAt == other.expiresAt &&
          contactUid == other.contactUid &&
          audioAssetId == other.audioAssetId &&
          stepUp == other.stepUp &&
          caseLink == other.caseLink &&
          simulated == other.simulated &&
          signalSources == other.signalSources &&
          serverInterventionId == other.serverInterventionId;

  @override
  int get hashCode => Object.hash(
    id,
    uid,
    txnId,
    trigger,
    scriptBn,
    scriptEn,
    hashList(reasons),
    hashList(actions),
    status,
    createdAt,
    requestId,
    expiresAt,
    contactUid,
    audioAssetId,
    stepUp,
    caseLink,
    simulated,
    signalSources,
    serverInterventionId,
  );

  @override
  String toString() => 'InterventionRecord($id $trigger $status)';
}

/// Interventions per user (Firestore collection or local list).
abstract class InterventionRepo {
  /// Newest first; emits the current list on subscribe, then every change.
  Stream<List<InterventionRecord>> watch(String uid);

  /// Writes [r] with merge semantics: the fields [r] carries replace the
  /// stored ones, the fields it leaves null (`request_id`, `contact_uid`,
  /// `step_up` ...) keep what is stored.
  Future<void> upsert(InterventionRecord r);

  /// [upsert] that completes only once the write has landed (for Firestore,
  /// the server acknowledged it) and throws when it was rejected. Used by
  /// the step-up release, which must not report a release that may not
  /// have happened. Callers bound the wait.
  Future<void> upsertAcked(InterventionRecord r);

  /// The stored record [id], or `null` when there is none (or it cannot be
  /// read now).
  Future<InterventionRecord?> byId(String id);

  /// Lookup for the `bhorosha://approve/{request_id}` deep link;
  /// `null` when the request was not created on this device.
  Future<InterventionRecord?> findByRequestId(String requestId);

  /// Drops this user's records (persona switch). Firestore implementations
  /// leave the collection alone.
  Future<void> reset(String uid);
}
