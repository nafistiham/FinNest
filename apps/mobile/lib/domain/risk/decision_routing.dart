/// Decision → UI container, and the score/intervene action merge
library;

import 'package:bhorosha/data/contracts/contracts.dart';

/// Where the intervention renders. Named by the plan; UI code that also
/// imports `package:flutter/widgets.dart` should import this file with
/// `show DecisionRouting` plus a prefix, or hide Flutter's `Container`.
enum Container { fullscreen, banner }

abstract final class DecisionRouting {
  /// `ActionLabels.biometricStepUp`: the client-only identity step-up.
  static const clientOnlyStepUp = 'biometric_step_up';

  /// The actions that all mean "the money stays with you for now": a hold,
  /// a new-payee delay, a PIN-reset freeze. `/v1/risk/score` sends one and
  /// `/v1/intervene` may send another (a hold and a 60-minute delay for the
  /// same transfer), and the app does the same thing for each: it keeps the
  /// hold and closes the overlay. Showing two of them side by side asked
  /// the customer to choose between two names for one outcome, so only the
  /// first survives the merge.
  static const moneyStaysFamily = {
    'hold_transaction',
    'delay_new_payee',
    'freeze_pin_reset',
  };

  /// The decision chooses the container; `InterveneResponse.ui` can only
  /// tighten it: `hold`/`block` → fullscreen; `delay`/`step_up` → banner
  /// unless the server says `ui == fullscreen`; `allow` → banner (unused).
  static Container containerFor(Decision d, UiMode? ui) => switch (d) {
    Decision.hold || Decision.block => Container.fullscreen,
    Decision.delay || Decision.stepUp =>
      ui == UiMode.fullscreen ? Container.fullscreen : Container.banner,
    Decision.allow => Container.banner,
  };

  /// Actions rendered = [fromScore] merged by `type` with [fromIntervene];
  /// the score's item wins on a type conflict, and the order is the score
  /// items (first occurrence of each type) followed by the intervene items
  /// whose type is new. The result is unmodifiable.
  ///
  /// A server-sent [clientOnlyStepUp] is dropped: the
  /// fingerprint release is the client's own item, added only when the
  /// step-up policy offers it; the server can never switch it on.
  static List<ActionItem> mergeActions(
    List<ActionItem> fromScore,
    List<ActionItem> fromIntervene,
  ) {
    final seen = <String>{};
    final out = <ActionItem>[];
    var moneyStays = false;
    for (final action in fromScore.followedBy(fromIntervene)) {
      if (action.type == clientOnlyStepUp) continue;
      if (moneyStaysFamily.contains(action.type)) {
        if (moneyStays) continue;
        moneyStays = true;
      }
      if (seen.add(action.type)) out.add(action);
    }
    return List<ActionItem>.unmodifiable(out);
  }
}
