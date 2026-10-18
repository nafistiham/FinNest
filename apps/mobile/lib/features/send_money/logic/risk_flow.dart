/// Orchestration of the eleven-seconds path, steps 4 to 8:
/// native signals → merge → integrity → `/signals` →
/// `/score` → trigger prediction → `/intervene` → cooldown.
///
/// Pure Dart over the [RiskApi] and [BhoroshaNative] interfaces; the PIN
/// screen reads it through `riskFlowProvider`. Logs carry routes and
/// timings only, never bodies, tokens or features (Global Constraints).
library;

import 'dart:async';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/core/ids.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/domain/behaviour/behaviour_replay.dart';
import 'package:bhorosha/domain/behaviour/enrolment_store.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:bhorosha/domain/risk/trigger.dart';
import 'package:bhorosha/domain/signals/signal_merger.dart';
import 'package:bhorosha/features/send_money/logic/risk_outcome.dart';

/// Called as soon as a hold or delay is known, before `/v1/intervene` is
/// awaited, so the overlay can open and the predicted clip can start.
typedef HoldPredicted = void Function(
  String trigger,
  String predictedAsset,
  ScoreResponse score,
);

class RiskFlow {
  RiskFlow({
    required this.api,
    required this.native,
    required this.cooldown,
    required this.clock,
    required this.nonce,
    String? Function()? lastEvidenceQuote,
    this.enrolment,
    bool Function()? enrolling,
    this.signalsTimeout = const Duration(milliseconds: 1500),
    this.integrityTimeout = const Duration(milliseconds: 1500),
    this.sendSessionFields = AppEnv.riskMwSessionFields,
    this.sendAppSafety = AppEnv.riskMwAppSafetyInScore,
  }) : _lastEvidenceQuote = lastEvidenceQuote ?? _none,
       _enrolling = enrolling ?? _off;

  static const String _tag = 'risk_flow';

  /// Used when `/v1/intervene` fails (`intervene.py` `INTERVENE_COOLDOWN_S`).
  static const int defaultCooldownS = 300;

  final RiskApi api;
  final BhoroshaNative native;
  final Cooldown cooldown;
  final Clock clock;

  /// Fresh nonce per attempt for the integrity request hash.
  final String Function() nonce;

  /// Last `evidence_quote` of a scam replay, read at call time so the demo
  /// panel can set it after this object was built.
  final String? Function() _lastEvidenceQuote;

  /// The owner's enrolment rows: appended to while
  /// [_enrolling] says so in [BehaviourMode.live], read for the stranger
  /// replay. `null` disables both (the replay then perturbs the live vector).
  final EnrolmentStore? enrolment;

  /// The demo panel's "নথিভুক্ত করা হচ্ছে", read at call time.
  final bool Function() _enrolling;

  /// Outer budgets around the native bridge. The channel implementation has
  /// its own timeouts; these guard a bridge that does not.
  final Duration signalsTimeout;
  final Duration integrityTimeout;

  /// Send `session_id`, `intervention_id` and `txn.txn_id` on
  /// `/v1/intervene` ([AppEnv.riskMwSessionFields]); without it those keys
  /// are left out, since the deployed service forbids unknown keys.
  final bool sendSessionFields;

  /// Send `app_safety` on `/v1/risk/score`
  /// ([AppEnv.riskMwAppSafetyInScore]); without it the block is left out,
  /// since the deployed service forbids unknown keys.
  final bool sendAppSafety;

  static String? _none() => null;
  static bool _off() => false;

  /// Scores one transfer. Never throws: every failure is either tolerated
  /// (signals, intervene, native, the [onHoldPredicted] callback) or surfaced
  /// as [Unavailable]: an [ApiFailure] from `/score` as is, anything else
  /// that escapes (a merge, a model, a bug) as a [ContractFailure], so the
  /// money never moves on an error.
  Future<RiskOutcome> scoreTransfer({
    required UserProfile user,
    required String sessionId,
    required Txn txn,
    required List<double> features,
    required DemoState demo,
    SafetyVerdict? lastVerdict,
    AppSafetyContext? appSafety,
    HoldPredicted? onHoldPredicted,
    BehaviourMode mode = BehaviourMode.live,
    void Function(DemoFlags flags)? onFlags,
  }) async {
    try {
      return await _scoreTransfer(
        user: user,
        sessionId: sessionId,
        txn: txn,
        features: features,
        demo: demo,
        lastVerdict: lastVerdict,
        appSafety: appSafety,
        onHoldPredicted: onHoldPredicted,
        mode: mode,
        onFlags: onFlags,
      );
    } on Object catch (e, st) {
      Log.e(_tag, 'scoring failed unexpectedly', e, st);
      return Unavailable(ContractFailure('unexpected ${e.runtimeType}'));
    }
  }

  Future<RiskOutcome> _scoreTransfer({
    required UserProfile user,
    required String sessionId,
    required Txn txn,
    required List<double> features,
    required DemoState demo,
    required SafetyVerdict? lastVerdict,
    required AppSafetyContext? appSafety,
    required HoldPredicted? onHoldPredicted,
    required BehaviourMode mode,
    required void Function(DemoFlags flags)? onFlags,
  }) async {
    final startedMs = clock.nowMs();

    // 4. Device signals and the Play Integrity token, fetched concurrently:
    // the token depends only on the transfer, so its wait overlaps the
    // signals wait instead of adding to it (each still capped at 1.5 s). A
    // token is attached only if one is ready in time.
    final hash = sha256Hex(
      '${user.acctId}|${txn.toAccount ?? ''}|${txn.amountBdt}|${nonce()}',
    );
    final (nativeSignals, token) = await (
      _signals(),
      _integrityToken(hash),
    ).wait;
    final merged = SignalMerger.merge(nativeSignals.signals, demo);
    final flags = SignalMerger.flags(merged, demo, lastVerdict: lastVerdict);
    onFlags?.call(flags);

    // 5. Signals: failures are logged and tolerated. The behaviour block
    // follows the demo mode.
    final behaviour = await _behaviour(
      mode: mode,
      persona: user.persona.uid,
      sessionId: sessionId,
      features: features,
    );
    await _postSignals(
      SignalsRequest(
        sessionId: sessionId,
        device: nativeSignals.device,
        signals: merged,
        integrityToken: token,
        behaviour: behaviour,
        simulated: SignalMerger.simulatedNames(nativeSignals.signals, merged),
      ),
    );

    // 6. Score: a failure here is "cannot verify now", never an allow.
    final ScoreResponse score;
    try {
      score = await api.postScore(
        ScoreRequest(
          userId: user.uid,
          sessionId: sessionId,
          // Never txn_id here: the server's hold recorder would merge its
          // own status and intervention_id into transactions/{txn_id}, the
          // app's ledger row (see Txn.txnId).
          txn: txn.copyWith(txnId: null),
          demoFlags: flags,
          // The App Safety Check result this phone holds, so the
          // server's decision does not depend on its own memory of the check.
          appSafety: sendAppSafety ? appSafety : null,
        ),
      );
    } on ApiFailure catch (failure) {
      Log.w(_tag, '${RiskRoutes.score} failed', failure);
      return Unavailable(failure);
    } on Object catch (e, st) {
      Log.e(_tag, '${RiskRoutes.score} threw', e, st);
      return Unavailable(ContractFailure('score threw ${e.runtimeType}'));
    }
    Log.i(
      _tag,
      '${RiskRoutes.score} ${score.decision.wire} '
      'in ${clock.nowMs() - startedMs} ms',
    );

    // 7. Route by decision.
    return switch (score.decision) {
      Decision.allow => Allowed(score),
      Decision.block => Blocked(score),
      Decision.stepUp => StepUpRequired(score),
      Decision.hold || Decision.delay => await _intervene(
        user: user,
        sessionId: sessionId,
        txn: txn,
        flags: flags,
        score: score,
        onHoldPredicted: onHoldPredicted,
      ),
    };
  }

  /// FNA's words for a block. A block opens no hold, so
  /// [scoreTransfer] never calls `/v1/intervene` for it; an App Safety block
  /// asks here, with the `app_safety` trigger, and risk-mw writes the warning
  /// from what the App Safety Check found (its phone facts: never an app name).
  /// Any other block, or a failed call, is `null`: the score's reasons stand
  /// on the overlay. The cooldown is armed either way, like a hold's.
  Future<InterveneResponse?> explainBlock({
    required UserProfile user,
    required String sessionId,
    required Txn txn,
    required ScoreResponse score,
  }) async {
    if (!score.reasons.any((r) => r.code == appSafetyBlockCode)) return null;
    InterveneResponse? explained;
    try {
      explained = await api.postIntervene(
        InterveneRequest(
          userId: user.uid,
          trigger: Triggers.appSafety,
          txn: sendSessionFields ? txn : txn.copyWith(txnId: null),
          sessionId: sendSessionFields ? sessionId : null,
          interventionId: sendSessionFields
              ? interventionIdOf(score.actions)
              : null,
        ),
      );
    } on ApiFailure catch (failure) {
      Log.w(_tag, '${RiskRoutes.intervene} for a block failed', failure);
    } on Object catch (e, st) {
      Log.e(_tag, '${RiskRoutes.intervene} for a block threw', e, st);
    }
    cooldown.arm(Triggers.appSafety, explained?.cooldownS ?? defaultCooldownS);
    return explained;
  }

  /// risk-mw's reason code for an App Safety block (`app/rules.py`).
  static const appSafetyBlockCode = 'APP_SAFETY_BLOCK';

  Future<RiskOutcome> _intervene({
    required UserProfile user,
    required String sessionId,
    required Txn txn,
    required DemoFlags flags,
    required ScoreResponse score,
    required HoldPredicted? onHoldPredicted,
  }) async {
    final trigger = Triggers.choose(
      decision: score.decision,
      flags: flags,
      reasons: score.reasons,
    );
    final predictedAsset = Triggers.predictedAsset(trigger);

    // Decided before the callback so the clip the overlay starts now and the
    // `speak` the outcome reports agree (the window is armed only below).
    final speak = cooldown.shouldSpeak(trigger);
    try {
      onHoldPredicted?.call(trigger, predictedAsset, score);
    } on Object catch (e, st) {
      // The hold still stands: the caller routes the outcome below.
      Log.e(_tag, 'onHoldPredicted threw', e, st);
    }

    InterveneResponse? intervene;
    try {
      intervene = await api.postIntervene(
        InterveneRequest(
          userId: user.uid,
          trigger: trigger,
          txn: sendSessionFields ? txn : txn.copyWith(txnId: null),
          transcriptSnippet: _lastEvidenceQuote(),
          // Which call and which hold the warning is for; the
          // hold's id rides on the score's actions.
          sessionId: sendSessionFields ? sessionId : null,
          interventionId: sendSessionFields
              ? interventionIdOf(score.actions)
              : null,
        ),
      );
    } on ApiFailure catch (failure) {
      Log.w(_tag, '${RiskRoutes.intervene} failed', failure);
    } on Object catch (e, st) {
      // Treated as no response: the predicted clip and score reasons stand.
      Log.e(_tag, '${RiskRoutes.intervene} threw', e, st);
    }

    // 8. Cooldown: remember (trigger, until) from the server's cooldown_s.
    cooldown.arm(trigger, intervene?.cooldownS ?? defaultCooldownS);

    return score.decision == Decision.hold
        ? Held(
            score: score,
            trigger: trigger,
            predictedAsset: predictedAsset,
            intervene: intervene,
            speak: speak,
          )
        : Delayed(
            score: score,
            trigger: trigger,
            predictedAsset: predictedAsset,
            intervene: intervene,
            speak: speak,
          );
  }

  /// The `behaviour` block for [mode]: the measured vector (live, which is
  /// also appended to the enrolment while enrolling), none at all (off),
  /// or the owner's last enrolled row (the live vector when nothing is
  /// enrolled) with the replay mode's perturbation: a stranger's touch,
  /// another tap pattern, a shaking hand or a coached tempo. An enrolment
  /// failure is logged, never fatal.
  Future<Behaviour?> _behaviour({
    required BehaviourMode mode,
    required String persona,
    required String sessionId,
    required List<double> features,
  }) async {
    switch (mode) {
      case BehaviourMode.off:
        return null;
      case BehaviourMode.live:
        if (_enrolling() && features.length == FeatureNames.count) {
          try {
            await enrolment?.append(
              EnrolmentRow(
                // One row per PIN entry, unique within the login session.
                sessionId: '$sessionId-${clock.nowMs()}',
                ts: clock.now(),
                persona: persona,
                features: features,
              ),
            );
          } on Object catch (e) {
            Log.w(_tag, 'enrolment append failed', e);
          }
        }
        return Behaviour(features: features);
      case BehaviourMode.replayStranger ||
          BehaviourMode.replayTapPattern ||
          BehaviourMode.replayShaking ||
          BehaviourMode.replayCoached:
        var base = features;
        try {
          base = (await enrolment?.last(persona))?.features ?? features;
        } on Object catch (e) {
          Log.w(_tag, 'enrolment read failed, replaying the live vector', e);
        }
        if (base.length != FeatureNames.count) {
          return Behaviour(features: base);
        }
        return Behaviour(
          features: switch (mode) {
            BehaviourMode.replayTapPattern => BehaviourReplay.tapPattern(base),
            BehaviourMode.replayShaking => BehaviourReplay.shaking(base),
            BehaviourMode.replayCoached => BehaviourReplay.coached(base),
            _ => BehaviourReplay.stranger(base),
          },
        );
    }
  }

  /// `getSignals()` within [signalsTimeout], else the documented defaults.
  Future<NativeSignals> _signals() async {
    try {
      return await native.getSignals().timeout(signalsTimeout);
    } on TimeoutException {
      Log.w(_tag, 'getSignals exceeded ${signalsTimeout.inMilliseconds} ms');
    } on Object catch (e) {
      Log.w(_tag, 'getSignals failed', e);
    }
    return NativeSignals.defaults();
  }

  /// `getIntegrityToken()` within [integrityTimeout], else `null`.
  Future<String?> _integrityToken(String requestHash) async {
    try {
      return await native
          .getIntegrityToken(requestHash)
          .timeout(integrityTimeout);
    } on TimeoutException {
      Log.d(_tag, 'getIntegrityToken not ready, sending null');
    } on Object catch (e) {
      Log.w(_tag, 'getIntegrityToken failed', e);
    }
    return null;
  }

  Future<void> _postSignals(SignalsRequest request) async {
    try {
      await api.postSignals(request);
    } on Object catch (failure) {
      Log.w(_tag, '${RiskRoutes.signals} failed, continuing', failure);
    }
  }
}
