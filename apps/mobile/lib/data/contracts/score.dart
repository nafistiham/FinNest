/// `/v1/risk/score` request and response (contracts.py).
library;

import 'package:bhorosha/data/contracts/appsafety.dart';
import 'package:bhorosha/data/contracts/common.dart';

/// `class Txn(Strict)`.
class Txn {
  const Txn({
    required this.type,
    this.amountBdt = 0.0,
    this.toAccount,
    this.isNewPayee = false,
    this.txnId,
  });

  factory Txn.fromJson(Map<String, dynamic> json) => Txn(
    type: requireEnum(json, 'type', TxnType.fromWire),
    amountBdt: readDouble(json, 'amount_bdt', 0.0),
    toAccount: readStringOrNull(json, 'to_account'),
    isNewPayee: readBool(json, 'is_new_payee', false),
    txnId: readStringOrNull(json, 'txn_id'),
  );

  final TxnType type;
  final double amountBdt;
  final String? toAccount;
  final bool isNewPayee;

  /// Additive, max 64 chars: keys `transactions/{txnId}` on the
  /// server. Sent only with `AppEnv.riskMwSessionFields` (the deployed
  /// service forbids unknown keys) and then on `/v1/intervene` only, not on
  /// `/v1/risk/score`: the server's hold recorder merges `status`,
  /// `intervention_id` and `user_id` into that document, which is the app's
  /// own ledger row (same Firestore collection), and would re-point the
  /// row's `intervention_id` away from the local record.
  final String? txnId;

  /// Pass [unchanged] (the default) to keep a value; `null` clears [toAccount].
  Txn copyWith({
    TxnType? type,
    double? amountBdt,
    Object? toAccount = unchanged,
    bool? isNewPayee,
    Object? txnId = unchanged,
  }) => Txn(
    type: type ?? this.type,
    amountBdt: amountBdt ?? this.amountBdt,
    toAccount: identical(toAccount, unchanged)
        ? this.toAccount
        : toAccount as String?,
    isNewPayee: isNewPayee ?? this.isNewPayee,
    txnId: identical(txnId, unchanged) ? this.txnId : txnId as String?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type.wire,
    'amount_bdt': amountBdt,
    'to_account': toAccount,
    'is_new_payee': isNewPayee,
    // Omitted when null: the deployed service forbids extra keys
    // and does not know txn_id yet.
    'txn_id': ?txnId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Txn &&
          type == other.type &&
          amountBdt == other.amountBdt &&
          toAccount == other.toAccount &&
          isNewPayee == other.isNewPayee &&
          txnId == other.txnId;

  @override
  int get hashCode =>
      Object.hash(type, amountBdt, toAccount, isNewPayee, txnId);

  @override
  String toString() => 'Txn(${toJson()})';
}

/// `class DemoFlags(Strict)`: the only part of the demo state that is sent
/// to the server.
class DemoFlags {
  const DemoFlags({
    this.simSwap = false,
    this.callActive = false,
    this.screenShare = false,
    this.callerInContacts = false,
    this.appSafetyVerdict = SafetyVerdict.safe,
    this.inboundMuleScore = 0.0,
    this.scamScore = 0.0,
  });

  factory DemoFlags.fromJson(Map<String, dynamic> json) => DemoFlags(
    simSwap: readBool(json, 'sim_swap', false),
    callActive: readBool(json, 'call_active', false),
    screenShare: readBool(json, 'screen_share', false),
    callerInContacts: readBool(json, 'caller_in_contacts', false),
    appSafetyVerdict: readEnum(
      json,
      'app_safety_verdict',
      SafetyVerdict.fromWire,
      SafetyVerdict.safe,
    ),
    inboundMuleScore: readDouble(json, 'inbound_mule_score', 0.0),
    scamScore: readDouble(json, 'scam_score', 0.0),
  );

  final bool simSwap;
  final bool callActive;
  final bool screenShare;
  final bool callerInContacts;
  final SafetyVerdict appSafetyVerdict;
  final double inboundMuleScore;
  final double scamScore;

  DemoFlags copyWith({
    bool? simSwap,
    bool? callActive,
    bool? screenShare,
    bool? callerInContacts,
    SafetyVerdict? appSafetyVerdict,
    double? inboundMuleScore,
    double? scamScore,
  }) => DemoFlags(
    simSwap: simSwap ?? this.simSwap,
    callActive: callActive ?? this.callActive,
    screenShare: screenShare ?? this.screenShare,
    callerInContacts: callerInContacts ?? this.callerInContacts,
    appSafetyVerdict: appSafetyVerdict ?? this.appSafetyVerdict,
    inboundMuleScore: inboundMuleScore ?? this.inboundMuleScore,
    scamScore: scamScore ?? this.scamScore,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sim_swap': simSwap,
    'call_active': callActive,
    'screen_share': screenShare,
    'caller_in_contacts': callerInContacts,
    'app_safety_verdict': appSafetyVerdict.wire,
    'inbound_mule_score': inboundMuleScore,
    'scam_score': scamScore,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DemoFlags &&
          simSwap == other.simSwap &&
          callActive == other.callActive &&
          screenShare == other.screenShare &&
          callerInContacts == other.callerInContacts &&
          appSafetyVerdict == other.appSafetyVerdict &&
          inboundMuleScore == other.inboundMuleScore &&
          scamScore == other.scamScore;

  @override
  int get hashCode => Object.hash(
    simSwap,
    callActive,
    screenShare,
    callerInContacts,
    appSafetyVerdict,
    inboundMuleScore,
    scamScore,
  );

  @override
  String toString() => 'DemoFlags(${toJson()})';
}

/// `class AppSafetyFinding(Strict)`: one finding of the App Safety
/// Check as the score needs it.
class AppSafetyFinding {
  const AppSafetyFinding({
    required this.package,
    required this.signal,
    required this.severity,
    this.scope = Finding.scopeApp,
  });

  factory AppSafetyFinding.fromJson(Map<String, dynamic> json) =>
      AppSafetyFinding(
        package: requireString(json, 'package'),
        signal: requireString(json, 'signal'),
        severity: requireString(json, 'severity'),
        scope: readString(json, 'scope', Finding.scopeApp),
      );

  factory AppSafetyFinding.of(Finding f) => AppSafetyFinding(
    package: f.package,
    signal: f.signal,
    severity: f.severity,
    scope: f.scope,
  );

  final String package;
  final String signal;
  final String severity;
  final String scope;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'package': package,
    'signal': signal,
    'severity': severity,
    'scope': scope,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyFinding &&
          package == other.package &&
          signal == other.signal &&
          severity == other.severity &&
          scope == other.scope;

  @override
  int get hashCode => Object.hash(package, signal, severity, scope);
}

/// `class AppSafetyContext(Strict)`: the App Safety Check result the
/// phone holds when it asks for a score, sent as `ScoreRequest.app_safety`
/// so the decision does not depend on what the server instance remembers.
/// Built from the last `/v1/appsafety/check` answer ([fromResponse], source
/// `check`) or from the standing verdict ([fromLatest], source `latest`).
/// The server takes the stronger of its stored verdict, the demo flag and
/// this block: the phone can raise the verdict, never lower it.
class AppSafetyContext {
  const AppSafetyContext({
    required this.verdict,
    this.riskScore = 0.0,
    this.findings = const [],
    this.appsToUninstall = const [],
    this.recommendedAction = '',
    this.resolution = 'NONE',
    this.attestation = 'none',
    this.simulatedVerdict = false,
    this.modelVersion = '',
    this.checkId = '',
    this.checkedAt = '',
    this.validUntil = '',
    this.source = sourceCheck,
  });

  factory AppSafetyContext.fromJson(Map<String, dynamic> json) =>
      AppSafetyContext(
        verdict: requireEnum(json, 'verdict', SafetyVerdict.fromWire),
        riskScore: readDouble(json, 'risk_score', 0.0),
        findings: readList(
          json,
          'findings',
          objectItem(AppSafetyFinding.fromJson),
        ),
        appsToUninstall: readList(json, 'apps_to_uninstall', stringItem),
        recommendedAction: readString(json, 'recommended_action', ''),
        resolution: readString(json, 'resolution', 'NONE'),
        attestation: readString(json, 'attestation', 'none'),
        simulatedVerdict: readBool(json, 'simulated_verdict', false),
        modelVersion: readString(json, 'model_version', ''),
        checkId: readString(json, 'check_id', ''),
        checkedAt: readString(json, 'checked_at', ''),
        validUntil: readString(json, 'valid_until', ''),
        source: readString(json, 'source', sourceCheck),
      );

  /// The important data points of a fresh check.
  factory AppSafetyContext.fromResponse(AppSafetyResponse r) =>
      AppSafetyContext(
        verdict: r.verdict,
        riskScore: r.riskScore,
        findings: [for (final f in r.findings) AppSafetyFinding.of(f)],
        appsToUninstall: r.appsToUninstall,
        recommendedAction: r.recommendedAction,
        resolution: r.resolution,
        attestation: r.attestation,
        simulatedVerdict: r.simulatedVerdict,
        modelVersion: r.modelVersion,
        checkId: r.checkId,
        validUntil: r.validUntil,
      );

  /// The standing verdict when a fresh check could not be made. `null` when
  /// the server knows nothing for the uid.
  static AppSafetyContext? fromLatest(AppSafetyLatest l) => l.known
      ? AppSafetyContext(
          verdict: l.verdict,
          riskScore: l.riskScore,
          appsToUninstall: l.flaggedPackages,
          attestation: l.attestation,
          checkedAt: l.checkedAt,
          validUntil: l.validUntil,
          source: sourceLatest,
        )
      : null;

  static const String sourceCheck = 'check';
  static const String sourceLatest = 'latest';

  final SafetyVerdict verdict;
  final double riskScore;
  final List<AppSafetyFinding> findings;
  final List<String> appsToUninstall;
  final String recommendedAction;
  final String resolution;
  final String attestation;
  final bool simulatedVerdict;
  final String modelVersion;
  final String checkId;
  final String checkedAt;
  final String validUntil;
  final String source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'verdict': verdict.wire,
    'risk_score': riskScore,
    'findings': findings.map((f) => f.toJson()).toList(),
    'apps_to_uninstall': appsToUninstall,
    'recommended_action': recommendedAction,
    'resolution': resolution,
    'attestation': attestation,
    'simulated_verdict': simulatedVerdict,
    'model_version': modelVersion,
    'check_id': checkId,
    'checked_at': checkedAt,
    'valid_until': validUntil,
    'source': source,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyContext &&
          verdict == other.verdict &&
          riskScore == other.riskScore &&
          listEq(findings, other.findings) &&
          listEq(appsToUninstall, other.appsToUninstall) &&
          recommendedAction == other.recommendedAction &&
          resolution == other.resolution &&
          attestation == other.attestation &&
          simulatedVerdict == other.simulatedVerdict &&
          modelVersion == other.modelVersion &&
          checkId == other.checkId &&
          checkedAt == other.checkedAt &&
          validUntil == other.validUntil &&
          source == other.source;

  @override
  int get hashCode => Object.hash(
    verdict,
    riskScore,
    Object.hashAll(findings),
    Object.hashAll(appsToUninstall),
    recommendedAction,
    resolution,
    attestation,
    simulatedVerdict,
    modelVersion,
    checkId,
    checkedAt,
    validUntil,
    source,
  );

  @override
  String toString() => 'AppSafetyContext(${toJson()})';
}

/// `class ScoreRequest(Strict)`.
class ScoreRequest {
  const ScoreRequest({
    required this.userId,
    required this.sessionId,
    required this.txn,
    this.demoFlags = const DemoFlags(),
    this.appSafety,
  });

  factory ScoreRequest.fromJson(Map<String, dynamic> json) => ScoreRequest(
    userId: requireString(json, 'user_id'),
    sessionId: requireString(json, 'session_id'),
    txn: requireObject(json, 'txn', Txn.fromJson),
    demoFlags: readObject(
      json,
      'demo_flags',
      DemoFlags.fromJson,
      const DemoFlags(),
    ),
    appSafety: readObject<AppSafetyContext?>(
      json,
      'app_safety',
      AppSafetyContext.fromJson,
      null,
    ),
  );

  final String userId;
  final String sessionId;
  final Txn txn;
  final DemoFlags demoFlags;

  /// The App Safety Check result the phone holds. Left out of the
  /// wire when `null` (the deployed service forbids unknown keys, so
  /// [RiskFlow] sends it only with `RISK_MW_APP_SAFETY_IN_SCORE`).
  final AppSafetyContext? appSafety;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user_id': userId,
    'session_id': sessionId,
    'txn': txn.toJson(),
    'demo_flags': demoFlags.toJson(),
    'app_safety': ?appSafety?.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScoreRequest &&
          userId == other.userId &&
          sessionId == other.sessionId &&
          txn == other.txn &&
          demoFlags == other.demoFlags &&
          appSafety == other.appSafety;

  @override
  int get hashCode => Object.hash(userId, sessionId, txn, demoFlags, appSafety);

  @override
  String toString() => 'ScoreRequest(${toJson()})';
}

/// `class Reason(Strict)`: one explanation line; `text_bn` is the only risk
/// copy the UI may render (FR-3).
class Reason {
  const Reason({
    required this.code,
    required this.weight,
    required this.textBn,
    required this.textEn,
  });

  factory Reason.fromJson(Map<String, dynamic> json) => Reason(
    code: requireString(json, 'code'),
    weight: requireDouble(json, 'weight'),
    textBn: requireString(json, 'text_bn'),
    textEn: requireString(json, 'text_en'),
  );

  final String code;
  final double weight;
  final String textBn;
  final String textEn;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'code': code,
    'weight': weight,
    'text_bn': textBn,
    'text_en': textEn,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Reason &&
          code == other.code &&
          weight == other.weight &&
          textBn == other.textBn &&
          textEn == other.textEn;

  @override
  int get hashCode => Object.hash(code, weight, textBn, textEn);

  @override
  String toString() => 'Reason(${toJson()})';
}

/// `class Action(Strict)` in contracts.py, named `ActionItem` here to avoid
/// clashing with Flutter's `Action`.
///
/// [params] holds JSON primitives only (`int`, `double`, `String`, `bool`).
class ActionItem {
  const ActionItem({required this.type, this.params = const {}});

  factory ActionItem.fromJson(Map<String, dynamic> json) => ActionItem(
    type: requireString(json, 'type'),
    params: readPrimitiveMap(json, 'params'),
  );

  final String type;
  final Map<String, Object> params;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'params': Map<String, Object>.of(params),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionItem && type == other.type && mapEq(params, other.params);

  @override
  int get hashCode => Object.hash(type, hashMap(params));

  @override
  String toString() => 'ActionItem(${toJson()})';
}

/// `SignalSource` in contracts.py: where one live-risk input came from.
enum SignalSource {
  /// The phone measured it and posted it to `/v1/risk/signals`.
  device('device'),

  /// Only a demo flag (or a posted value listed in `simulated`) said so.
  demo('demo'),

  /// Off.
  none('none'),

  /// Anything the client does not know (a newer server value, a missing
  /// field). Never read as [none]: the step-up policy keeps the hold unless
  /// the server said `none`.
  unknown('unknown');

  const SignalSource(this.wire);
  final String wire;

  /// `device | demo | none`; any other value, or none at all, is [unknown].
  static SignalSource fromWire(Object? wire) {
    for (final v in values) {
      if (v != unknown && v.wire == wire) return v;
    }
    return unknown;
  }
}

/// `class SignalSources(Strict)` (additive): where each input of the
/// decision came from. `ScoreResponse.signalSources` is null when the
/// server did not send it, which the step-up policy treats as unknown.
class SignalSources {
  const SignalSources({
    this.callActive = SignalSource.none,
    this.simSwap = SignalSource.none,
    this.screenShare = SignalSource.none,
    this.callerInContacts = SignalSource.none,
  });

  factory SignalSources.fromJson(Map<String, dynamic> json) => SignalSources(
    callActive: SignalSource.fromWire(json['call_active']),
    simSwap: SignalSource.fromWire(json['sim_swap']),
    screenShare: SignalSource.fromWire(json['screen_share']),
    callerInContacts: SignalSource.fromWire(json['caller_in_contacts']),
  );

  final SignalSource callActive;
  final SignalSource simSwap;
  final SignalSource screenShare;
  final SignalSource callerInContacts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'call_active': callActive.wire,
    'sim_swap': simSwap.wire,
    'screen_share': screenShare.wire,
    'caller_in_contacts': callerInContacts.wire,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignalSources &&
          callActive == other.callActive &&
          simSwap == other.simSwap &&
          screenShare == other.screenShare &&
          callerInContacts == other.callerInContacts;

  @override
  int get hashCode =>
      Object.hash(callActive, simSwap, screenShare, callerInContacts);

  @override
  String toString() => 'SignalSources(${toJson()})';
}

/// `class ScoreResponse(Strict)`.
class ScoreResponse {
  const ScoreResponse({
    required this.decision,
    required this.riskScore,
    required this.band,
    required this.reasons,
    required this.actions,
    required this.modelVersion,
    this.signalSources,
    this.identitySource,
    this.payeeScoreBefore,
    this.payeeScoreWithThisTransfer,
    this.payeeMovedFeature,
    this.payeeScoreAsOf,
  });

  factory ScoreResponse.fromJson(Map<String, dynamic> json) => ScoreResponse(
    decision: requireEnum(json, 'decision', Decision.fromWire),
    riskScore: requireDouble(json, 'risk_score'),
    band: requireEnum(json, 'band', Band.fromWire),
    reasons: requireList(json, 'reasons', objectItem(Reason.fromJson)),
    actions: requireList(json, 'actions', objectItem(ActionItem.fromJson)),
    modelVersion: requireString(json, 'model_version'),
    signalSources: readObject<SignalSources?>(
      json,
      'signal_sources',
      SignalSources.fromJson,
      null,
    ),
    identitySource: readStringOrNull(json, 'identity_source'),
    payeeScoreBefore: readDoubleOrNull(json, 'payee_score_before'),
    payeeScoreWithThisTransfer: readDoubleOrNull(
      json,
      'payee_score_with_this_transfer',
    ),
    payeeMovedFeature: readStringOrNull(json, 'payee_moved_feature'),
    payeeScoreAsOf: readStringOrNull(json, 'payee_score_as_of'),
  );

  final Decision decision;
  final double riskScore;
  final Band band;
  final List<Reason> reasons;
  final List<ActionItem> actions;
  final String modelVersion;

  /// `signal_sources`; null when the server did not send it (unknown).
  final SignalSources? signalSources;

  /// Additive field: `verified` (a checked Firebase ID token) or `demo`
  /// (auth off, `user_id` taken at its word); null from older servers.
  final String? identitySource;

  /// Additive field (null when no known payee was screened): the payee's
  /// mule score on the evidence so far and with this transfer landed, the
  /// feature this transfer moved most and the server's scenario clock.
  final double? payeeScoreBefore;
  final double? payeeScoreWithThisTransfer;
  final String? payeeMovedFeature;
  final String? payeeScoreAsOf;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'decision': decision.wire,
    'risk_score': riskScore,
    'band': band.wire,
    'reasons': reasons.map((r) => r.toJson()).toList(),
    'actions': actions.map((a) => a.toJson()).toList(),
    'model_version': modelVersion,
    'signal_sources': signalSources?.toJson(),
    'identity_source': identitySource,
    'payee_score_before': payeeScoreBefore,
    'payee_score_with_this_transfer': payeeScoreWithThisTransfer,
    'payee_moved_feature': payeeMovedFeature,
    'payee_score_as_of': payeeScoreAsOf,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScoreResponse &&
          decision == other.decision &&
          riskScore == other.riskScore &&
          band == other.band &&
          listEq(reasons, other.reasons) &&
          listEq(actions, other.actions) &&
          modelVersion == other.modelVersion &&
          signalSources == other.signalSources &&
          identitySource == other.identitySource &&
          payeeScoreBefore == other.payeeScoreBefore &&
          payeeScoreWithThisTransfer == other.payeeScoreWithThisTransfer &&
          payeeMovedFeature == other.payeeMovedFeature &&
          payeeScoreAsOf == other.payeeScoreAsOf;

  @override
  int get hashCode => Object.hash(
    decision,
    riskScore,
    band,
    hashList(reasons),
    hashList(actions),
    modelVersion,
    signalSources,
    identitySource,
    payeeScoreBefore,
    payeeScoreWithThisTransfer,
    payeeMovedFeature,
    payeeScoreAsOf,
  );

  @override
  String toString() => 'ScoreResponse(${toJson()})';
}
