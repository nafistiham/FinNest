/// Riverpod wiring of the hidden demo panel.
///
/// [DemoPanelController] is the only writer of the simulated world: flags,
/// persona, forced verdict and the scam replay all go through it, so the
/// merged signal stream and the next `/v1/risk/score` call see the same
/// `DemoState`. A persona switch resets every per-user handle (session id,
/// ledger, interventions, cooldowns, last score, evidence quote) so nothing
/// leaks between Rina and Rahima.
library;

import 'dart:async';
import 'dart:io';

import 'package:bhorosha/app/appearance.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/demo_panel/logic/scam_replay.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:bhorosha/features/session/logic/session_reset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wire names of the four boolean demo flags, as [DemoPanelController.toggle]
/// accepts them.
abstract final class DemoFlagNames {
  static const simSwap = 'sim_swap';
  static const callActive = 'call_active';
  static const screenShare = 'screen_share';
  static const callerInContacts = 'caller_in_contacts';
  static const all = <String>[
    simSwap,
    callActive,
    screenShare,
    callerInContacts,
  ];
}

/// Values of `DemoState.integrityScenario`: which Play Integrity demo token
/// the app presents on the next `/v1/appsafety/check`. `null` is a clean,
/// attested device.
abstract final class IntegrityScenarios {
  /// Screen controlled by another app → BLOCK, call the bank.
  static const screenControlled = 'UNKNOWN_CONTROLLING';

  /// Modified app binary → BLOCK, reinstall.
  static const moddedApp = 'UNRECOGNIZED_VERSION';

  /// Emulator → CAUTION.
  static const emulator = 'MEETS_VIRTUAL_INTEGRITY';

  /// Token without the request hash bound to it.
  static const unbound = 'unbound';

  /// Every selectable value, `null` (clean) first.
  static const all = <String?>[
    null,
    screenControlled,
    moddedApp,
    emulator,
    unbound,
  ];
}

class DemoPanelState {
  const DemoPanelState({
    this.demo = DemoState.initial,
    this.replaying = false,
    this.replayLog = const [],
    this.error,
    this.lastServerMs,
    this.healthy,
  });

  /// The signed-in user's simulated world, mirrored from `demoStateProvider`.
  final DemoState demo;

  /// A scam replay is in flight; the replay and preset buttons are disabled.
  final bool replaying;

  /// Every `/v1/scam/turn` answer of this session, oldest first.
  final List<ScamTurnResponse> replayLog;

  /// Log-safe description of the last failure, or `null`.
  final String? error;

  /// `X-Processing-Time-Ms` of the most recent response.
  final int? lastServerMs;

  /// Result of the last health check; `null` before the first one.
  final bool? healthy;

  /// The last replay answer, whose `rolling_score` the progress bar shows.
  ScamTurnResponse? get lastReplay => replayLog.isEmpty ? null : replayLog.last;

  /// Pass [unchanged] (the default) to keep a nullable value; `null` clears it.
  DemoPanelState copyWith({
    DemoState? demo,
    bool? replaying,
    List<ScamTurnResponse>? replayLog,
    Object? error = unchanged,
    Object? lastServerMs = unchanged,
    Object? healthy = unchanged,
  }) => DemoPanelState(
    demo: demo ?? this.demo,
    replaying: replaying ?? this.replaying,
    replayLog: replayLog ?? this.replayLog,
    error: identical(error, unchanged) ? this.error : error as String?,
    lastServerMs: identical(lastServerMs, unchanged)
        ? this.lastServerMs
        : lastServerMs as int?,
    healthy: identical(healthy, unchanged) ? this.healthy : healthy as bool?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DemoPanelState &&
          demo == other.demo &&
          replaying == other.replaying &&
          listEq(replayLog, other.replayLog) &&
          error == other.error &&
          lastServerMs == other.lastServerMs &&
          healthy == other.healthy;

  @override
  int get hashCode => Object.hash(
    demo,
    replaying,
    hashList(replayLog),
    error,
    lastServerMs,
    healthy,
  );

  @override
  String toString() =>
      'DemoPanelState($demo, replaying=$replaying, log=${replayLog.length}, '
      'error=$error, serverMs=$lastServerMs, healthy=$healthy)';
}

class DemoPanelController extends Notifier<DemoPanelState> {
  static const _tag = 'demo_panel';

  /// Amount the scam replay pretends is about to be sent (Rina's p95).
  static const double replayAmountBdt = 5000;

  /// The clip the "preview Apa audio" button plays.
  static const String previewAssetId = 'apa_hold_call_active';

  /// A dynamic line with no bundled clip, so the preview exercises the
  /// Gemini voice (or whichever source answers) on the device.
  static const String previewGeminiTextBn =
      'আমি ফিননেস্ট সহকারী বলছি। এই কণ্ঠটি সার্ভারের লেখা থেকে এখনই তৈরি হলো।';
  static const String previewGeminiTextEn =
      "This is your FinNest Assistant. This voice was made just now from the server's text.";

  @override
  DemoPanelState build() {
    // Listen rather than watch: a demo-state emission must not rebuild the
    // notifier and drop the replay log, the health dot and the error line.
    ref.listen(demoStateProvider, (_, next) {
      final demo = next.value;
      if (demo != null) state = state.copyWith(demo: demo);
    });
    return DemoPanelState(
      demo: ref.read(demoStateProvider).value ?? DemoState.initial,
    );
  }

  // --- Who we write for ------------------------------------------------------

  /// The signed-in uid; while signed out (panel opened from Login) the
  /// default persona, so flags set before login land on Rina's document.
  String get _uid =>
      ref.read(authRepoProvider).current?.uid ??
      state.demo.persona?.uid ??
      Persona.rina.uid;

  Future<void> _write(DemoState next, {String? uid}) async {
    // Optimistic: the switches flip at once even while signed out, when
    // `demoStateProvider` is pinned to `DemoState.initial`.
    state = state.copyWith(demo: next, error: null);
    // The write is bounded: a story must never wait on a slow network for
    // the sync (the state above is already applied locally).
    try {
      await ref
          .read(demoStateRepoProvider)
          .write(uid ?? _uid, next)
          .timeout(writeBudget);
    } on Object catch (e) {
      Log.w(_tag, 'demo state write not confirmed', e);
    }
  }

  /// How long a demo-state write may take before the panel moves on.
  static const writeBudget = Duration(milliseconds: 1500);

  // --- Flags -----------------------------------------------------------------

  /// Flips one of [DemoFlagNames.all]; throws [ArgumentError] for anything else.
  Future<void> toggle(String flag) =>
      setFlag(flag, !_flagValue(state.demo, flag));

  /// Sets one of [DemoFlagNames.all] to [on].
  Future<void> setFlag(String flag, bool on) {
    final d = state.demo;
    final next = switch (flag) {
      DemoFlagNames.simSwap => d.copyWith(simSwap: on),
      DemoFlagNames.callActive => d.copyWith(callActive: on),
      DemoFlagNames.screenShare => d.copyWith(screenShare: on),
      DemoFlagNames.callerInContacts => d.copyWith(callerInContacts: on),
      _ => throw ArgumentError.value(flag, 'flag', 'unknown demo flag'),
    };
    return _write(next);
  }

  static bool _flagValue(DemoState d, String flag) => switch (flag) {
    DemoFlagNames.simSwap => d.simSwap,
    DemoFlagNames.callActive => d.callActive,
    DemoFlagNames.screenShare => d.screenShare,
    DemoFlagNames.callerInContacts => d.callerInContacts,
    _ => throw ArgumentError.value(flag, 'flag', 'unknown demo flag'),
  };

  /// `null` means "use the server's verdict".
  Future<void> setForcedVerdict(SafetyVerdict? verdict) =>
      _write(state.demo.copyWith(forcedSafetyVerdict: verdict));

  /// One of [IntegrityScenarios.all]; `null` clears it (clean device).
  Future<void> setIntegrityScenario(String? scenario) =>
      _write(state.demo.copyWith(integrityScenario: scenario));

  /// Runs `/v1/appsafety/check` again with the current demo state so the
  /// badge reflects a freshly chosen integrity scenario or forced verdict.
  Future<void> rerunSafetyCheck() =>
      ref.read(safetyControllerProvider.notifier).refresh();

  // --- Persona ---------------------------------------------------------------

  /// Signs out, demo-logs-in [p] and resets every per-user handle of the
  /// previous persona.
  Future<void> setPersona(Persona p) async {
    final auth = ref.read(authRepoProvider);
    final previous = auth.current?.uid;
    // The coached story's call belongs to the previous persona.
    _storyCallOn = false;
    try {
      await auth.signOut();
      await auth.demoLogin(p);
      if (!ref.mounted) return;
      await resetSessionState(ref.read, previousUid: previous);
      if (!ref.mounted) return;
      // The reset dropped the previous persona's verdict; check again
      // for the new one so the badge and demo_flags are this persona's.
      unawaited(ref.read(safetyControllerProvider.notifier).refresh());
      state = state.copyWith(replayLog: const [], error: null);
      Log.i(_tag, 'persona switched to ${p.uid}');
    } on Object catch (e) {
      Log.w(_tag, 'persona switch failed', e);
      if (!ref.mounted) return;
      state = state.copyWith(error: 'persona switch failed: ${e.runtimeType}');
    }
  }

  // --- Scam replay -----------------------------------------------------------

  /// Posts the bundled script turn by turn, appends each answer to
  /// [DemoPanelState.replayLog], then stores the last `rolling_score` as
  /// `scam_score` and the last `evidence_quote` for `/v1/intervene`.
  Future<void> replayScam() async {
    if (state.replaying) return;
    state = state.copyWith(replaying: true, error: null);
    // The persona this replay is for, fixed before any await: a persona
    // switch mid-replay must not land the score on the new persona.
    final uid = _uid;
    final api = ref.read(riskApiProvider);
    ScamTurnResponse? last;
    try {
      final script = await ref.read(demoAssetsProvider).scamScript();
      final sessionId = ref.read(sessionRepoProvider).sessionId;
      final replay = ScamReplay(api).replay(
        sessionId: sessionId,
        script: script,
        amountBdt: replayAmountBdt,
      );
      await for (final response in replay) {
        if (!ref.mounted) return;
        last = response;
        state = state.copyWith(
          replayLog: [...state.replayLog, response],
          lastServerMs: api.lastServerTimingMs,
        );
      }
    } on ApiFailure catch (e) {
      Log.w(_tag, 'scam replay stopped', e);
      if (!ref.mounted) return;
      state = state.copyWith(error: e.toString());
    } on Object catch (e) {
      Log.w(_tag, 'scam replay failed', e);
      if (!ref.mounted) return;
      state = state.copyWith(error: 'replay failed: ${e.runtimeType}');
    } finally {
      if (ref.mounted) state = state.copyWith(replaying: false);
    }
    if (last == null || !ref.mounted) return;
    if (_uid != uid) {
      Log.w(_tag, 'persona changed during the replay; result dropped');
      return;
    }
    ref.read(lastEvidenceQuoteProvider.notifier).state = last.evidenceQuote;
    // The FNA call summary card shows the same flagged call.
    if (!ApaAnswers.isBenign(last)) {
      ref.read(lastCallSummaryProvider.notifier).state =
          FnaCallSummary.fromScamTurn(last, DateTime.now());
    }
    await _write(state.demo.copyWith(scamScore: last.rollingScore), uid: uid);
  }

  /// The one-tap recording setup: call active on, then the scam replay.
  /// Yields `hold` / `SCAM_CONVERSATION` / `call_active` on the next score.
  Future<void> videoPreset() async {
    await setFlag(DemoFlagNames.callActive, true);
    await replayScam();
  }

  // --- Health ----------------------------------------------------------------

  Future<void> checkHealth() async {
    final api = ref.read(riskApiProvider);
    final ok = await api.health();
    if (!ref.mounted) return;
    state = state.copyWith(healthy: ok, lastServerMs: api.lastServerTimingMs);
  }

  // --- Cash in ---------------------------------------------------------------

  /// "এজেন্ট ক্যাশ ইন নিশ্চিত করলেন": the newest cash in
  /// still waiting for the agent turns `done` and raises the balance.
  /// Returns that row, or null when nothing waits (or on a failure, which
  /// also sets [DemoPanelState.error]).
  Future<LedgerTxn?> confirmCashIn() async {
    final uid = ref.read(authRepoProvider).current?.uid;
    if (uid == null) return null;
    final ledger = ref.read(ledgerRepoProvider);
    try {
      final row = await ledger.newestRequestedCashIn(uid);
      if (row == null) return null;
      await ledger.confirmCashIn(row.txnId);
      Log.i(_tag, 'cash in ${row.txnId} confirmed');
      return row;
    } on Object catch (e) {
      Log.w(_tag, 'confirm cash in failed', e);
      if (ref.mounted) {
        state = state.copyWith(error: 'confirm cash in: ${e.runtimeType}');
      }
      return null;
    }
  }

  // --- Behaviour ------------------------------------------------

  /// The session-scoped behaviour mode (never synced, see `behaviourModeProvider`).
  void setBehaviourMode(BehaviourMode mode) =>
      ref.read(behaviourModeProvider.notifier).set(mode);

  /// "নথিভুক্ত করা হচ্ছে": capture each live PIN entry's vector.
  void setEnrolling(bool on) =>
      ref.read(behaviourEnrollingProvider.notifier).set(on);

  /// The persona whose enrolment the panel shows and exports.
  String get enrolmentPersona => _uid;

  /// "ফাইলে লিখুন": the JSONL file, or `null` on a failure (also sets
  /// [DemoPanelState.error]).
  Future<File?> exportEnrolment() async {
    try {
      final file = await ref
          .read(enrolmentStoreProvider)
          .exportJsonl(enrolmentPersona);
      return file;
    } on Object catch (e) {
      Log.w(_tag, 'enrolment export failed', e);
      if (ref.mounted) {
        state = state.copyWith(error: 'enrolment export: ${e.runtimeType}');
      }
      return null;
    }
  }

  /// "মুছুন": drops this persona's enrolment rows.
  Future<void> clearEnrolment() =>
      ref.read(enrolmentStoreProvider).clear(enrolmentPersona);

  // --- Stories -------------------------------------------

  /// The account of the ring's first-level mule the story pre-selects.
  static const suspectPayeeAcct = 'acct_01070';

  /// "প্রাপক সন্দেহভাজন": a clean phone (every flag off, verdict and
  /// integrity automatic, no scam score) and the behaviour signal off, so
  /// only the payee can hold the transfer. The UI then opens the send flow
  /// with [suspectPayeeAcct].
  Future<void> storySuspectPayee() async {
    setBehaviourMode(BehaviourMode.off);
    // Every flag goes off below, the coached story's call included.
    _storyCallOn = false;
    await _write(
      state.demo.copyWith(
        simSwap: false,
        callActive: false,
        screenShare: false,
        callerInContacts: false,
        forcedSafetyVerdict: null,
        integrityScenario: null,
        scamScore: 0,
        // The live service screens the payee with the transfer
        // and holds on `demo_flags.inbound_mule_score > mule_hold_threshold`
        // (0.80); the ring's L1 account alone scored 0.03 to 0.40 on
        // 2026-10-17, so the story carries the flag and the server words the
        // reason from the payee's own evidence.
        inboundMuleScore: suspectPayeeMuleScore,
      ),
    );
  }

  /// `demo_flags.inbound_mule_score` the suspect-payee story sets; above the
  /// server's `mule_hold_threshold` (0.80).
  static const suspectPayeeMuleScore = 0.9;

  /// "অন্য কেউ ফোন চালাচ্ছে": a stranger's touch on the next transfer.
  Future<void> storyStranger() => _behaviourStory(BehaviourMode.replayStranger);

  /// "ট্যাপের ধরন বদলে গেছে": only the tap pattern differs from the owner's.
  Future<void> storyTapPattern() =>
      _behaviourStory(BehaviourMode.replayTapPattern);

  /// "হাত কাঁপছে": only the grip and the shake differ from the owner's.
  Future<void> storyShaking() => _behaviourStory(BehaviourMode.replayShaking);

  /// "কেউ বলে দিচ্ছে": the owner's hand with a coached tempo, and the call
  /// switched on: the server holds on coaching only while a call is active
  /// (`app/ato.py`; without a call it is a step-up). The call goes off again
  /// when another story runs or the panel is reset.
  Future<void> storyCoached() async {
    setBehaviourMode(BehaviourMode.replayCoached);
    _storyCallOn = true;
    await setFlag(DemoFlagNames.callActive, true);
  }

  /// The coached story switched the call on and nothing has switched it
  /// off since; the next story (or a reset) does.
  bool _storyCallOn = false;

  Future<void> _behaviourStory(BehaviourMode mode) async {
    setBehaviourMode(mode);
    await _endCoachedCall();
    // The suspect-payee story's mule flag must not hold a behaviour story.
    if (state.demo.inboundMuleScore != 0) {
      await _write(state.demo.copyWith(inboundMuleScore: 0));
    }
  }

  /// Switches off the call the coached story switched on, if it did.
  Future<void> _endCoachedCall() async {
    if (!_storyCallOn) return;
    _storyCallOn = false;
    if (state.demo.callActive) await setFlag(DemoFlagNames.callActive, false);
  }

  // --- Resets ----------------------------------------------------------------

  /// Clears every armed audio cooldown so a video retake replays Apa.
  void resetCooldown() => ref.read(cooldownProvider).reset();

  /// Restores [DemoState.initial] for the current user (flags, persona
  /// field, forced verdict, scam score and integrity scenario), clears the
  /// risk session (cooldowns, last score, evidence) and the replay log, and
  /// puts the appearance back to its defaults (Teal, system mode, normal
  /// text) so a presenter always starts from the same screen.
  Future<void> resetAll() async {
    // DemoState.initial has the call off, the coached story's included.
    _storyCallOn = false;
    state = state.copyWith(
      demo: DemoState.initial,
      replayLog: const [],
      error: null,
    );
    ref.read(riskSessionProvider.notifier).reset();
    ref.read(lastEvidenceQuoteProvider.notifier).state = null;
    await ref.read(demoStateRepoProvider).reset(_uid);
    try {
      await resetAppearance(ref.read);
    } on Object catch (e) {
      // Appearance is a convenience here; the demo reset already happened.
      Log.w(_tag, 'appearance reset failed', e);
    }
  }
}

final demoPanelControllerProvider =
    NotifierProvider<DemoPanelController, DemoPanelState>(
      DemoPanelController.new,
    );

/// How many enrolment rows persona [persona] has (the "আচরণ" counter).
final enrolmentCountProvider = StreamProvider.autoDispose.family<int, String>(
  (ref, persona) => ref.watch(enrolmentStoreProvider).watchCount(persona),
);
