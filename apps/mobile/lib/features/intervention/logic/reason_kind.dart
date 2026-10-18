/// Reason routing: what kind of check a
/// server reason code asks for, so the PIN pad's step-up sheet and the
/// identity step-up policy can be chosen by the reason, not by one
/// hard-coded screen-share sheet. Pure Dart; codes mirror risk-mw
/// `app/rules.py` and `app/ato.py`.
library;

import 'package:bhorosha/data/contracts/contracts.dart';

/// In tie-break order: on equal weights the earlier kind leads.
enum ReasonKind {
  identity,
  coaching,
  mulePayee,
  newPayeeAmount,
  callActive,
  screenShare,
  simSwap,
  scam,
  appSafety,
  other;

  /// `ATO_BEHAVIOUR_MISMATCH` and its `_COLD_START` variant (`app/ato.py`
  /// `IDENTITY_CODES` + `COLD_START_SUFFIX`).
  static const identityCodes = <String>{
    'ATO_BEHAVIOUR_MISMATCH',
    'ATO_BEHAVIOUR_MISMATCH_COLD_START',
  };

  static const Map<String, ReasonKind> _byCode = {
    'ATO_BEHAVIOUR_MISMATCH': identity,
    'ATO_BEHAVIOUR_MISMATCH_COLD_START': identity,
    'COACHING_SUSPECTED': coaching,
    'COACHING_SUSPECTED_COLD_START': coaching,
    'DEST_MULE_RISK': mulePayee,
    'NEW_PAYEE_ABOVE_P95': newPayeeAmount,
    'CALL_ACTIVE_NON_CONTACT': callActive,
    'SCREEN_SHARE_ACTIVE': screenShare,
    'SIM_CHANGED_24H': simSwap,
    'SCAM_CONVERSATION': scam,
    'APP_SAFETY_BLOCK': appSafety,
    // The App Safety Check's CAUTION; it allows the payment and only
    // names the reason (risk-mw caps its weight below band high).
    'APP_SAFETY_CAUTION': appSafety,
  };

  /// The kind of [code]; [other] for anything unknown.
  static ReasonKind of(String code) => _byCode[code] ?? other;

  /// The kind of the highest-weight reason (ties: the earlier kind in the
  /// enum order); `null` when there are no reasons.
  static ReasonKind? leading(List<Reason> reasons) {
    ReasonKind? best;
    var bestWeight = double.negativeInfinity;
    for (final r in reasons) {
      final k = of(r.code);
      if (r.weight > bestWeight ||
          (r.weight == bestWeight && k.index < best!.index)) {
        best = k;
        bestWeight = r.weight;
      }
    }
    return best;
  }

  /// The `/v1/intervene` trigger this kind predicts when it leads (the
  /// server answers the generic script for both until request S4 lands);
  /// `null` keeps the client's existing trigger table.
  String? get trigger => switch (this) {
    identity => 'behaviour_mismatch',
    mulePayee => 'mule_payee',
    _ => null,
  };
}
