/// `/v1/scam/turn` request and response (contracts.py).
library;

import 'package:bhorosha/data/contracts/common.dart';

/// `class Turn(Strict)`: one line of a call transcript.
///
/// [speaker] is `caller` or `user` on the wire (see [callerSpeaker] and
/// [userSpeaker]); the plan keeps it as a string.
class Turn {
  const Turn({required this.speaker, required this.text, required this.ts});

  factory Turn.fromJson(Map<String, dynamic> json) => Turn(
    speaker: requireString(json, 'speaker'),
    text: requireString(json, 'text'),
    ts: requireDouble(json, 'ts'),
  );

  static const String callerSpeaker = 'caller';
  static const String userSpeaker = 'user';

  final String speaker;
  final String text;
  final double ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'speaker': speaker,
    'text': text,
    'ts': ts,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Turn &&
          speaker == other.speaker &&
          text == other.text &&
          ts == other.ts;

  @override
  int get hashCode => Object.hash(speaker, text, ts);

  @override
  String toString() => 'Turn(${toJson()})';
}

/// `class ScamTurnRequest(Strict)`; the server requires at least one turn.
class ScamTurnRequest {
  const ScamTurnRequest({
    required this.sessionId,
    required this.turns,
    this.pendingAction,
    this.amountBdt,
  });

  factory ScamTurnRequest.fromJson(Map<String, dynamic> json) =>
      ScamTurnRequest(
        sessionId: requireString(json, 'session_id'),
        turns: requireList(json, 'turns', objectItem(Turn.fromJson)),
        pendingAction: readStringOrNull(json, 'pending_action'),
        amountBdt: readDoubleOrNull(json, 'amount_bdt'),
      );

  final String sessionId;
  final List<Turn> turns;
  final String? pendingAction;
  final double? amountBdt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'session_id': sessionId,
    'turns': turns.map((t) => t.toJson()).toList(),
    'pending_action': pendingAction,
    'amount_bdt': amountBdt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScamTurnRequest &&
          sessionId == other.sessionId &&
          listEq(turns, other.turns) &&
          pendingAction == other.pendingAction &&
          amountBdt == other.amountBdt;

  @override
  int get hashCode =>
      Object.hash(sessionId, hashList(turns), pendingAction, amountBdt);

  @override
  String toString() => 'ScamTurnRequest(${toJson()})';
}

/// `class ScamTurnResponse(Strict)`.
///
/// [urgency] is `none|low|medium|high` and [requestedSecret] is
/// `none|otp|pin|password|other` on the wire; both are kept as strings.
/// `evidence_quote` is the only field the UI may render (FR-3).
class ScamTurnResponse {
  const ScamTurnResponse({
    required this.scamType,
    required this.urgency,
    required this.requestedSecret,
    required this.confidence,
    required this.evidenceQuote,
    required this.recommendedAction,
    required this.rollingScore,
  });

  factory ScamTurnResponse.fromJson(Map<String, dynamic> json) =>
      ScamTurnResponse(
        scamType: requireString(json, 'scam_type'),
        urgency: requireString(json, 'urgency'),
        requestedSecret: requireString(json, 'requested_secret'),
        confidence: requireDouble(json, 'confidence'),
        evidenceQuote: requireString(json, 'evidence_quote'),
        recommendedAction: requireString(json, 'recommended_action'),
        rollingScore: requireDouble(json, 'rolling_score'),
      );

  final String scamType;
  final String urgency;
  final String requestedSecret;
  final double confidence;
  final String evidenceQuote;
  final String recommendedAction;
  final double rollingScore;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scam_type': scamType,
    'urgency': urgency,
    'requested_secret': requestedSecret,
    'confidence': confidence,
    'evidence_quote': evidenceQuote,
    'recommended_action': recommendedAction,
    'rolling_score': rollingScore,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScamTurnResponse &&
          scamType == other.scamType &&
          urgency == other.urgency &&
          requestedSecret == other.requestedSecret &&
          confidence == other.confidence &&
          evidenceQuote == other.evidenceQuote &&
          recommendedAction == other.recommendedAction &&
          rollingScore == other.rollingScore;

  @override
  int get hashCode => Object.hash(
    scamType,
    urgency,
    requestedSecret,
    confidence,
    evidenceQuote,
    recommendedAction,
    rollingScore,
  );

  @override
  String toString() => 'ScamTurnResponse(${toJson()})';
}
