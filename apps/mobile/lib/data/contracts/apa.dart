/// `/v1/apa/turn` request and response (contracts.py).
library;

import 'package:bhorosha/data/contracts/common.dart';

/// `class ApaContext(Strict)`: what Apa knows about the screen and last risk.
class ApaContext {
  const ApaContext({this.lastRisk, this.screen});

  factory ApaContext.fromJson(Map<String, dynamic> json) => ApaContext(
    lastRisk: readDoubleOrNull(json, 'last_risk'),
    screen: readStringOrNull(json, 'screen'),
  );

  final double? lastRisk;
  final String? screen;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'last_risk': lastRisk,
    'screen': screen,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaContext &&
          lastRisk == other.lastRisk &&
          screen == other.screen;

  @override
  int get hashCode => Object.hash(lastRisk, screen);

  @override
  String toString() => 'ApaContext(${toJson()})';
}

/// `class ApaTurnRequest(Strict)`.
class ApaTurnRequest {
  const ApaTurnRequest({
    required this.userId,
    required this.textBn,
    this.context = const ApaContext(),
  });

  factory ApaTurnRequest.fromJson(Map<String, dynamic> json) => ApaTurnRequest(
    userId: requireString(json, 'user_id'),
    textBn: requireString(json, 'text_bn'),
    context: readObject(
      json,
      'context',
      ApaContext.fromJson,
      const ApaContext(),
    ),
  );

  final String userId;
  final String textBn;
  final ApaContext context;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user_id': userId,
    'text_bn': textBn,
    'context': context.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaTurnRequest &&
          userId == other.userId &&
          textBn == other.textBn &&
          context == other.context;

  @override
  int get hashCode => Object.hash(userId, textBn, context);

  @override
  String toString() => 'ApaTurnRequest(${toJson()})';
}

/// `class ApaTurnResponse(Strict)`.
class ApaTurnResponse {
  const ApaTurnResponse({
    required this.replyBn,
    required this.replyEn,
    required this.toolCalls,
  });

  factory ApaTurnResponse.fromJson(Map<String, dynamic> json) =>
      ApaTurnResponse(
        replyBn: requireString(json, 'reply_bn'),
        replyEn: requireString(json, 'reply_en'),
        toolCalls: requireList(json, 'tool_calls', stringItem),
      );

  final String replyBn;
  final String replyEn;
  final List<String> toolCalls;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'reply_bn': replyBn,
    'reply_en': replyEn,
    'tool_calls': List<String>.of(toolCalls),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaTurnResponse &&
          replyBn == other.replyBn &&
          replyEn == other.replyEn &&
          listEq(toolCalls, other.toolCalls);

  @override
  int get hashCode => Object.hash(replyBn, replyEn, hashList(toolCalls));

  @override
  String toString() => 'ApaTurnResponse(${toJson()})';
}
