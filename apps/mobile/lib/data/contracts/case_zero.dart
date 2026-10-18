/// Case Zero investigator contracts: `POST /v1/investigate`,
/// `GET /v1/investigations/{case_id}` (risk-mw) and the watch-list
/// `GET /api/payee-risk` (the Case Zero service itself).
///
/// Readers are strict on the keys the app needs and ignore unknown keys
/// (the payee list carries `as_of`, for one). Payee `facts`, the ring and
/// the evidence are staff-only: never shown to a customer.
library;

import 'package:bhorosha/data/contracts/common.dart';

/// `class InvestigateResponse(Strict)`.
class InvestigateResponse {
  const InvestigateResponse({required this.caseId, required this.streamUrl});

  factory InvestigateResponse.fromJson(Map<String, dynamic> json) =>
      InvestigateResponse(
        caseId: requireString(json, 'case_id'),
        streamUrl: requireString(json, 'stream_url'),
      );

  final String caseId;

  /// SSE stream of the run, relative to the risk-mw root.
  final String streamUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'case_id': caseId,
    'stream_url': streamUrl,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InvestigateResponse &&
          caseId == other.caseId &&
          streamUrl == other.streamUrl;

  @override
  int get hashCode => Object.hash(caseId, streamUrl);

  @override
  String toString() => 'InvestigateResponse(${toJson()})';
}

/// `CaseReport.status`. A value the app does not know reads as [unknown]
/// instead of failing the whole report.
enum CaseStatus {
  queued('queued'),
  running('running'),
  done('done'),

  /// Delivered, but it failed Case Zero's citation check after the
  /// retry (`validation_errors`, `limitations`). Terminal like [done].
  degraded('degraded'),
  failed('failed'),
  unknown('unknown');

  const CaseStatus(this.wire);
  final String wire;

  /// `true` once the case will not change any more.
  bool get isTerminal => this == done || this == degraded || this == failed;

  static CaseStatus fromWire(String wire) {
    for (final value in values) {
      if (value != unknown && value.wire == wire) return value;
    }
    return unknown;
  }
}

/// `CaseReport.recommended_action`, a plain string on the server. Unknown
/// values read as [unknown]; the raw string stays on the report.
enum CaseAction {
  freeze('freeze'),
  edd('edd'),
  monitor('monitor'),
  closeNoAction('close_no_action'),
  pending('pending'),
  routeToRiskReviewer('route_to_risk_reviewer'),
  unknown('unknown');

  const CaseAction(this.wire);
  final String wire;

  static CaseAction fromWire(String wire) {
    for (final value in values) {
      if (value != unknown && value.wire == wire) return value;
    }
    return unknown;
  }
}

/// `class Evidence(Strict)`: one claim backed by a ledger row.
class CaseEvidence {
  const CaseEvidence({required this.rowId, required this.claim});

  factory CaseEvidence.fromJson(Map<String, dynamic> json) => CaseEvidence(
    rowId: requireString(json, 'row_id'),
    claim: requireString(json, 'claim'),
  );

  final String rowId;
  final String claim;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'row_id': rowId,
    'claim': claim,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaseEvidence && rowId == other.rowId && claim == other.claim;

  @override
  int get hashCode => Object.hash(rowId, claim);

  @override
  String toString() => 'CaseEvidence(${toJson()})';
}

/// `class CaseReport(Strict)`.
class CaseReport {
  const CaseReport({
    required this.caseId,
    required this.acctId,
    required this.status,
    required this.summaryEn,
    required this.summaryBn,
    required this.evidence,
    required this.ring,
    required this.confidence,
    required this.recommendedAction,
    required this.modelVersion,
  });

  factory CaseReport.fromJson(Map<String, dynamic> json) => CaseReport(
    caseId: requireString(json, 'case_id'),
    acctId: requireString(json, 'acct_id'),
    status: requireEnum(json, 'status', CaseStatus.fromWire),
    summaryEn: requireString(json, 'summary_en'),
    summaryBn: requireString(json, 'summary_bn'),
    evidence: requireList(json, 'evidence', objectItem(CaseEvidence.fromJson)),
    ring: requireList(json, 'ring', stringItem),
    confidence: requireDouble(json, 'confidence'),
    recommendedAction: requireString(json, 'recommended_action'),
    modelVersion: requireString(json, 'model_version'),
  );

  final String caseId;
  final String acctId;
  final CaseStatus status;
  final String summaryEn;
  final String summaryBn;
  final List<CaseEvidence> evidence;

  /// Account ids of the suspected ring, seed first.
  final List<String> ring;

  /// 0..1.
  final double confidence;

  /// The server's string, kept verbatim; [action] is its parsed form.
  final String recommendedAction;
  final String modelVersion;

  CaseAction get action => CaseAction.fromWire(recommendedAction);

  /// Model version of the scripted answer risk-mw serves when the live
  /// investigator is busy or over budget.
  static const stubFallbackVersion = 'stub-fallback';

  /// `true` when this report is the scripted stand-in, not a live run: it
  /// never counts as a finished review for the customer.
  bool get isStubFallback => modelVersion == stubFallbackVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'case_id': caseId,
    'acct_id': acctId,
    'status': status.wire,
    'summary_en': summaryEn,
    'summary_bn': summaryBn,
    'evidence': [for (final e in evidence) e.toJson()],
    'ring': List<String>.of(ring),
    'confidence': confidence,
    'recommended_action': recommendedAction,
    'model_version': modelVersion,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaseReport &&
          caseId == other.caseId &&
          acctId == other.acctId &&
          status == other.status &&
          summaryEn == other.summaryEn &&
          summaryBn == other.summaryBn &&
          listEq(evidence, other.evidence) &&
          listEq(ring, other.ring) &&
          confidence == other.confidence &&
          recommendedAction == other.recommendedAction &&
          modelVersion == other.modelVersion;

  @override
  int get hashCode => Object.hash(
    caseId,
    acctId,
    status,
    summaryEn,
    summaryBn,
    hashList(evidence),
    hashList(ring),
    confidence,
    recommendedAction,
    modelVersion,
  );

  @override
  String toString() => 'CaseReport(${toJson()})';
}

/// One row of the Case Zero watch-list (`payee-risk/1`).
class PayeeRiskEntry {
  const PayeeRiskEntry({
    required this.acctId,
    required this.status,
    this.caseId,
    this.role = '',
    this.modelScore = 0.0,
    this.analystApproved = false,
    this.facts = const [],
  });

  factory PayeeRiskEntry.fromJson(Map<String, dynamic> json) => PayeeRiskEntry(
    acctId: requireString(json, 'acct_id'),
    status: requireString(json, 'status'),
    caseId: readStringOrNull(json, 'case_id'),
    role: readString(json, 'role', ''),
    modelScore: readDouble(json, 'model_score', 0.0),
    analystApproved: readBool(json, 'analyst_approved', false),
    facts: readList(json, 'facts', stringItem),
  );

  final String acctId;

  /// `suspected`, `confirmed` or `cleared` (kept as the server's string).
  final String status;

  /// The investigation that listed this payee, when there is one.
  final String? caseId;

  /// e.g. `mule_L2`.
  final String role;
  final double modelScore;
  final bool analystApproved;

  /// Staff-only one-line facts; never shown to a customer.
  final List<String> facts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'acct_id': acctId,
    'status': status,
    'case_id': caseId,
    'role': role,
    'model_score': modelScore,
    'analyst_approved': analystApproved,
    'facts': List<String>.of(facts),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PayeeRiskEntry &&
          acctId == other.acctId &&
          status == other.status &&
          caseId == other.caseId &&
          role == other.role &&
          modelScore == other.modelScore &&
          analystApproved == other.analystApproved &&
          listEq(facts, other.facts);

  @override
  int get hashCode => Object.hash(
    acctId,
    status,
    caseId,
    role,
    modelScore,
    analystApproved,
    hashList(facts),
  );

  @override
  String toString() => 'PayeeRiskEntry(${toJson()})';
}

/// `GET /api/payee-risk` on the Case Zero service.
class PayeeRisk {
  const PayeeRisk({
    required this.version,
    required this.generatedAt,
    this.payees = const [],
  });

  factory PayeeRisk.fromJson(Map<String, dynamic> json) => PayeeRisk(
    version: requireString(json, 'version'),
    generatedAt: requireString(json, 'generated_at'),
    payees: readList(json, 'payees', objectItem(PayeeRiskEntry.fromJson)),
  );

  /// `payee-risk/1`.
  final String version;

  /// ISO-8601 with offset, as the server wrote it.
  final String generatedAt;
  final List<PayeeRiskEntry> payees;

  /// The listed entry for [acctId], or `null`.
  PayeeRiskEntry? entryFor(String acctId) {
    for (final p in payees) {
      if (p.acctId == acctId) return p;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'generated_at': generatedAt,
    'payees': [for (final p in payees) p.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PayeeRisk &&
          version == other.version &&
          generatedAt == other.generatedAt &&
          listEq(payees, other.payees);

  @override
  int get hashCode => Object.hash(version, generatedAt, hashList(payees));

  @override
  String toString() => 'PayeeRisk(${toJson()})';
}
