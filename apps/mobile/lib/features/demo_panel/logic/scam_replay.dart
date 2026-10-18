/// Replays the bundled scam script against `/v1/scam/turn`.
///
/// The server scores a transcript, not a single line, so every caller turn is
/// posted with the growing prefix of the conversation up to and including it
/// (capped at the last [ScamReplay.maxTurns] turns, the server's window). The
/// `pending_action` is always `send_money` with the amount about to be sent,
/// which is what makes the stub's "asks for the OTP/PIN" rule fire at 0.85.
library;

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';

class ScamReplay {
  ScamReplay(this._api);

  /// Longest transcript posted per turn (the contract's `turns` window).
  static const int maxTurns = 8;

  /// The only `pending_action` the demo panel replays for.
  static const String pendingAction = 'send_money';

  final RiskApi _api;

  /// One [ScamTurnResponse] per caller turn of [script], in order. The first
  /// [ApiFailure] is forwarded as a stream error and ends the replay; nothing
  /// else is caught.
  Stream<ScamTurnResponse> replay({
    required String sessionId,
    required List<Turn> script,
    required double amountBdt,
  }) async* {
    for (var i = 0; i < script.length; i++) {
      if (script[i].speaker != Turn.callerSpeaker) continue;
      final prefix = script.sublist(0, i + 1);
      final window = prefix.length > maxTurns
          ? prefix.sublist(prefix.length - maxTurns)
          : prefix;
      try {
        yield await _api.postScamTurn(
          ScamTurnRequest(
            sessionId: sessionId,
            turns: window,
            pendingAction: pendingAction,
            amountBdt: amountBdt,
          ),
        );
      } on ApiFailure catch (e, st) {
        yield* Stream<ScamTurnResponse>.error(e, st);
        return;
      }
    }
  }
}
