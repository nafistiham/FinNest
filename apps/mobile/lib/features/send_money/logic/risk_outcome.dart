/// What `RiskFlow.scoreTransfer` resolves to.
///
/// The PIN screen switches exhaustively over [RiskOutcome]; nothing else
/// crosses out of the risk flow. [Unavailable] is the "cannot verify now"
/// path: the money must not move.
library;

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/domain/risk/decision_routing.dart';

sealed class RiskOutcome {
  const RiskOutcome();
}

/// `decision == allow`: ledger `done`, green confirmation.
final class Allowed extends RiskOutcome {
  const Allowed(this.score);
  final ScoreResponse score;
}

/// Common shape of [Held] and [Delayed]: the trigger the client chose, the
/// clip it predicted (already playing when [intervene] arrives), the server's
/// intervention (null when `/v1/intervene` failed) and whether audio should
/// play at all ([speak] is false inside the cooldown window).
sealed class Intervened extends RiskOutcome {
  const Intervened({
    required this.score,
    required this.trigger,
    required this.predictedAsset,
    required this.intervene,
    required this.speak,
  });

  final ScoreResponse score;
  final String trigger;
  final String predictedAsset;
  final InterveneResponse? intervene;
  final bool speak;

  /// Score actions merged by type with the intervene actions (score wins).
  List<ActionItem> get actions => DecisionRouting.mergeActions(
    score.actions,
    intervene?.actions ?? const [],
  );

  /// Fullscreen for a hold; banner for a delay unless the server tightened it.
  Container get container =>
      DecisionRouting.containerFor(score.decision, intervene?.ui);
}

/// `decision == hold`: fullscreen overlay, ledger `held`.
final class Held extends Intervened {
  const Held({
    required super.score,
    required super.trigger,
    required super.predictedAsset,
    required super.intervene,
    required super.speak,
  });
}

/// `decision == delay`: banner card, ledger `held` with `delay_new_payee`.
final class Delayed extends Intervened {
  const Delayed({
    required super.score,
    required super.trigger,
    required super.predictedAsset,
    required super.intervene,
    required super.speak,
  });
}

/// `decision == step_up`: stop screen share, re-confirm PIN, score again.
final class StepUpRequired extends RiskOutcome {
  const StepUpRequired(this.score);
  final ScoreResponse score;
}

/// `decision == block`: fullscreen overlay, ledger `blocked`, safety findings.
final class Blocked extends RiskOutcome {
  const Blocked(this.score);
  final ScoreResponse score;
}

/// `/v1/risk/score` failed or timed out: show "cannot verify now", no allow.
final class Unavailable extends RiskOutcome {
  const Unavailable(this.failure);
  final ApiFailure failure;
}
