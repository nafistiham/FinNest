/// One bubble of the Apa transcript (binding names).
library;

import 'package:bhorosha/features/apa/logic/apa_insights.dart';

/// A line said by the user or by Apa.
///
/// [path] records which path produced the line: `live` (Gemini Live audio),
/// `gemini` (Gemini text through Firebase AI Logic), `guide` (the offline
/// guide: quick actions, insights and the rule-based coach), `text` (the
/// `/v1/apa/turn` stub, last resort only) or `held` (the first line of a held
/// transaction, composed only from `ScoreResponse.reasons[]`; FR-3).
///
/// Both languages travel with the turn; the sheet shows the one that matches
/// the app language and reveals the other behind its toggle.
class ApaTurn {
  const ApaTurn({
    required this.speaker,
    required this.textBn,
    required this.path,
    this.textEn,
    this.tone,
    this.action = ApaAction.none,
    this.source,
  }) : assert(speaker == user || speaker == apa),
       assert(
         path == live ||
             path == text ||
             path == held ||
             path == gemini ||
             path == guide,
       );

  static const user = 'user';
  static const apa = 'apa';

  static const live = 'live';
  static const text = 'text';
  static const held = 'held';
  static const gemini = 'gemini';
  static const guide = 'guide';

  /// `'user'` or `'apa'`.
  final String speaker;
  final String textBn;
  final String? textEn;

  /// One of the path constants above.
  final String path;

  /// Colours the bubble (danger, caution, ok); `null` is the plain Apa fill.
  final ApaSeverity? tone;

  /// The button under the bubble; [ApaAction.none] shows none.
  final ApaAction action;

  /// Where the sentence came from, captioned under Apa's bubble (a trust
  /// cue); `null` shows no caption.
  final ApaSource? source;

  bool get isApa => speaker == apa;

  ApaTurn copyWith({String? textBn, String? textEn}) => ApaTurn(
    speaker: speaker,
    textBn: textBn ?? this.textBn,
    textEn: textEn ?? this.textEn,
    path: path,
    tone: tone,
    action: action,
    source: source,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaTurn &&
          speaker == other.speaker &&
          textBn == other.textBn &&
          textEn == other.textEn &&
          path == other.path &&
          tone == other.tone &&
          action == other.action &&
          source == other.source;

  @override
  int get hashCode =>
      Object.hash(speaker, textBn, textEn, path, tone, action, source);

  @override
  String toString() => 'ApaTurn($speaker/$path: $textBn)';
}
