/// The text paths of the Apa sheet: Gemini when Firebase is
/// configured (`apa_gemini_service.dart`), the deterministic offline coach
/// otherwise and as Gemini's fallback, and the `/v1/apa/turn` stub only as
/// the last resort behind the coach.
library;

import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';

/// Anything that answers a typed question with one or more Apa turns.
///
/// May throw (`ApiFailure` on the stub path, anything from a fake); the
/// controller catches everything and shows a hint, never a crash.
abstract class ApaService {
  Future<List<ApaTurn>> ask(
    String text,
    ApaContext ctx,
    ApaContextSnapshot snapshot,
  );
}

/// Posts an [ApaTurnRequest] for [uid] and maps the reply to one `apa` turn
/// with path `text`. `reply_en` travels as [ApaTurn.textEn]; `tool_calls`
/// are not rendered. The server's answer is a fixed stub today, so this is
/// only ever reached behind [RuleBasedApaService].
class ApaTextService implements ApaService {
  ApaTextService(this._api, this.uid);

  final RiskApi _api;
  final String uid;

  @override
  Future<List<ApaTurn>> ask(
    String text,
    ApaContext ctx,
    ApaContextSnapshot snapshot,
  ) async {
    final response = await _api.postApaTurn(
      ApaTurnRequest(userId: uid, textBn: text, context: ctx),
    );
    return [
      ApaTurn(
        speaker: ApaTurn.apa,
        textBn: response.replyBn,
        textEn: response.replyEn.isEmpty ? null : response.replyEn,
        path: ApaTurn.text,
      ),
    ];
  }
}

/// The offline guide: keyword intents answered from the snapshot, the
/// server's texts and the guide content (path `guide`). Deterministic.
class RuleBasedApaService implements ApaService {
  const RuleBasedApaService(this.answers);

  final ApaAnswers answers;

  @override
  Future<List<ApaTurn>> ask(
    String text,
    ApaContext ctx,
    ApaContextSnapshot snapshot,
  ) async => answers.coach(text, snapshot);
}

/// [primary], and [secondary] when it throws or answers nothing.
class FallbackApaService implements ApaService {
  const FallbackApaService(this.primary, this.secondary);

  final ApaService primary;
  final ApaService secondary;

  @override
  Future<List<ApaTurn>> ask(
    String text,
    ApaContext ctx,
    ApaContextSnapshot snapshot,
  ) async {
    try {
      final turns = await primary.ask(text, ctx, snapshot);
      if (turns.isNotEmpty) return turns;
    } on Object {
      // fall through
    }
    return secondary.ask(text, ctx, snapshot);
  }
}
