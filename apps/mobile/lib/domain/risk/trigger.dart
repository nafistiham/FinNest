/// Client-chosen intervention trigger and the bundled clip it predicts
///
/// The server maps the trigger string to a script in
/// `app/routers/intervene.py` `SCRIPTS` and does not validate it; anything
/// it does not know falls back to `apa_generic_caution`. The tables here
/// mirror `SCRIPTS` and the reason codes of `app/rules.py`.
library;

import 'package:bhorosha/data/contracts/contracts.dart';

abstract final class Triggers {
  static const String callActive = 'call_active';
  static const String screenShare = 'screen_share';
  static const String newPayeeHighAmount = 'new_payee_high_amount';

  /// Behaviour: the server has no script for these yet, so the
  /// generic clip plays; the trigger still names the reason in the record.
  static const String behaviourMismatch = 'behaviour_mismatch';
  static const String coaching = 'coaching';
  static const String simSwap = 'sim_swap';
  static const String scamConversation = 'scam_conversation';
  static const String destMuleRisk = 'dest_mule_risk';
  static const String appSafety = 'app_safety';
  static const String generic = 'generic';

  /// `intervene.py` asset ids.
  static const String assetHoldCallActive = 'apa_hold_call_active';
  static const String assetHoldScreenShare = 'apa_hold_screen_share';
  static const String assetDelayNewPayee = 'apa_delay_new_payee';
  static const String assetGenericCaution = 'apa_generic_caution';

  /// `rules.py` reason code → trigger.
  static const Map<String, String> _byReasonCode = {
    'SIM_CHANGED_24H': simSwap,
    'SCAM_CONVERSATION': scamConversation,
    'DEST_MULE_RISK': destMuleRisk,
    'APP_SAFETY_BLOCK': appSafety,
    'APP_SAFETY_CAUTION': appSafety,
    'CALL_ACTIVE_NON_CONTACT': callActive,
    'SCREEN_SHARE_ACTIVE': screenShare,
    'NEW_PAYEE_ABOVE_P95': newPayeeHighAmount,
    'ATO_BEHAVIOUR_MISMATCH': behaviourMismatch,
    'ATO_BEHAVIOUR_MISMATCH_COLD_START': behaviourMismatch,
    'COACHING_SUSPECTED': coaching,
  };

  /// Trigger → predicted `audio_asset_id`.
  static const Map<String, String> _assetByTrigger = {
    callActive: assetHoldCallActive,
    screenShare: assetHoldScreenShare,
    newPayeeHighAmount: assetDelayNewPayee,
  };

  /// Picks the trigger for a `hold`, `delay` or `step_up` decision.
  ///
  /// Precedence: `hold && flags.callActive` → [callActive];
  /// `stepUp && flags.screenShare` → [screenShare];
  /// `delay` with a `NEW_PAYEE_ABOVE_P95` reason → [newPayeeHighAmount];
  /// otherwise the highest-weight reason code mapped through the `rules.py`
  /// table (unknown codes are lower-cased); no reasons → [generic].
  /// On equal weights the earlier reason wins (server evaluation order).
  static String choose({
    required Decision decision,
    required DemoFlags flags,
    required List<Reason> reasons,
  }) {
    if (decision == Decision.hold && flags.callActive) return callActive;
    if (decision == Decision.stepUp && flags.screenShare) return screenShare;
    if (decision == Decision.delay &&
        reasons.any((r) => r.code == 'NEW_PAYEE_ABOVE_P95')) {
      return newPayeeHighAmount;
    }
    if (reasons.isEmpty) return generic;
    final top = reasons.reduce((a, b) => b.weight > a.weight ? b : a);
    return _byReasonCode[top.code] ?? top.code.toLowerCase();
  }

  /// The bundled clip to start before `/v1/intervene` answers; the three
  /// named triggers map to their asset, everything else to the generic one.
  static String predictedAsset(String trigger) =>
      _assetByTrigger[trigger] ?? assetGenericCaution;
}
