import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/router.dart';
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/bangla_numpad.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/recipient_row.dart' show ConfirmSummary;
import '../../../app/widgets/step_progress.dart';
import '../../../core/audio/apa_audio.dart';
import '../../../core/haptics.dart';
import '../../../core/ids.dart';
import '../../../core/log.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/native/bhorosha_native.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../../domain/behaviour/behaviour_mode.dart';
import '../../../domain/behaviour/behaviour_sample.dart';
import '../../../domain/behaviour/feature_extractor.dart';
import '../../../domain/behaviour/feature_names.dart';
import '../../../domain/behaviour/pin_pad_recorder.dart';
import '../../../domain/risk/decision_routing.dart' as routing;
import '../../../domain/risk/trigger.dart';
import '../../apa/ui/apa_sheet.dart';
import '../../approve/logic/trusted_contact_flow.dart';
import '../../finance/logic/finance_providers.dart';
import '../../intervention/logic/action_labels.dart';
import '../../intervention/logic/reason_kind.dart';
import '../../intervention/logic/step_up_policy.dart';
import '../../intervention/ui/intervention_overlay.dart';
import '../../intervention/ui/intervention_style.dart';
import '../../login/logic/biometric_auth.dart';
import '../../pay/logic/pay_controller.dart';
import '../../pay/logic/pay_ledger.dart';
import '../../pay/logic/pay_paths.dart';
import '../../pay/logic/pay_rules.dart';
import '../../pay/ui/widgets/pay_format.dart';
import '../../result/ui/result_screen.dart' show ResultScreen;
import '../../safety/logic/safety_controller.dart';
import '../../send_money/logic/risk_flow.dart' show RiskFlow;
import '../../send_money/logic/risk_outcome.dart';
import '../../send_money/logic/risk_providers.dart';
import '../logic/pending_hold.dart';
import '../logic/pin_attempts.dart';

const _tag = 'pin_pad';

/// The PIN pad, step 3 of every pay kind but cash in. The confirmation shows
/// one big number: the kind line ("মা-কে পাঠাচ্ছেন"), the amount, the fee total
/// for cash out and the amount in words. FLAG_SECURE on while mounted
/// (`PayStartScreen`, underneath, owns turning it off when `/pay` is left),
/// obscured touches dropped for a second, four dots, the shared Bangla numpad
/// feeding a `PinPadRecorder` with physical-pixel positions. On the fourth
/// digit the pad locks and "যাচাই হচ্ছে…" shows in the same frame; the PIN is
/// checked against the bundled SHA-256 and discarded. Wrong PIN: heavy haptic,
/// shake, cleared dots, a Bangla line, 30 s pause after the third. Right PIN:
/// features (built for every kind) → send and cash out:
/// `RiskFlow.scoreTransfer` → route by outcome; recharge and bill: a local
/// allow after 600 ms of "যাচাই হচ্ছে…" (no risk call), ledger `done`.
///
/// No Apa FAB here (it would sit over the digit grid). Digits never reach a
/// `Text`, a log line or the feature vector.
class PinPadScreen extends ConsumerStatefulWidget {
  const PinPadScreen({
    this.kind = PayKind.send,
    this.haptics = const SystemHaptics(),
    this.lockout = const Duration(seconds: 30),
    this.obscuredBlock = const Duration(seconds: 1),
    super.key,
  });

  final PayKind kind;
  final Haptics haptics;

  /// Pause after [maxAttempts] wrong PINs (never a lockout).
  final Duration lockout;

  /// How long input is ignored after an `ObscuredTouchEvent`.
  final Duration obscuredBlock;

  static const pinLength = 4;
  static const maxAttempts = 3;

  /// Longest the flow waits on one store write before moving on; the write
  /// itself carries on in the background.
  static const writeBudget = pinWriteBudget;

  /// Bodies shorter than this use the compact layout (56 dp keys).
  static const compactBelow = 560.0;

  /// The behaviour vector of the last right PIN, any kind (tests read it:
  /// recharge and bill build it but never post it).
  @visibleForTesting
  static List<double>? lastFeatures;

  @override
  ConsumerState<PinPadScreen> createState() => _PinPadScreenState();
}

class _PinPadScreenState extends ConsumerState<PinPadScreen>
    with TickerProviderStateMixin {
  // The digits live only here, as a private buffer, until verified.
  final StringBuffer _pin = StringBuffer();
  final PinPadRecorder _recorder = PinPadRecorder();

  bool _verifying = false;
  bool _wrong = false;

  /// The PIN could not be checked (hash unavailable): say so, never silently
  /// clear the dots.
  bool _checkFailed = false;
  int _lockSecondsLeft = 0;
  Timer? _lockTimer;
  bool _obscured = false;
  Timer? _obscuredTimer;
  StreamSubscription<NativeEvent>? _events;
  late final AnimationController _shake;

  /// Verifying: the dots fill in sequence, 150 ms apart, looping.
  late final AnimationController _sweep;
  late final BhoroshaNative _native;

  /// The behaviour features of the last right PIN (built for every kind).
  List<double>? _features;

  bool get _inputEnabled => !_verifying && _lockSecondsLeft == 0 && !_obscured;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: BhMotion.standard.shake,
    );
    _sweep = AnimationController(
      vsync: this,
      // Verifying: the dots fill in sequence, `fast` apart (6.2).
      duration: BhMotion.standard.fast * PinPadScreen.pinLength,
    );
    // Kept in a field: dispose() may not touch ref.
    _native = ref.read(nativeProvider);
    unawaited(_native.setSecure(AppEnv.secureScreensEnabled));
    _events = _native.events.listen((e) {
      if (e is ObscuredTouchEvent) _onObscured();
    });
    // A pause started on an earlier pad is still running: back and Next
    // build a new pad, but the wrong-PIN count and pause live per user.
    final attempts = ref.read(pinAttemptsProvider.notifier);
    final left = attempts.of(_uid).secondsLeft(ref.read(clockProvider).now());
    if (left > 0) {
      _startLockout(left, initial: true);
    } else {
      attempts.endPause(_uid);
    }
  }

  /// Key of the wrong-PIN counter: the signed-in user ('' while none).
  String get _uid => ref.read(currentUserProvider).value?.uid ?? '';

  @override
  void dispose() {
    _lockTimer?.cancel();
    _obscuredTimer?.cancel();
    _events?.cancel();
    _shake.dispose();
    _sweep.dispose();
    // No setSecure(false): PayStartScreen sits under this route, owns
    // FLAG_SECURE for /pay/* and re-arms it on didPopNext; turning it off
    // here would leave the flow unprotected after a pop back (FR-5).
    _pin.clear();
    super.dispose();
  }

  // ------------------------------------------------------------- recording

  double get _dpr => MediaQuery.devicePixelRatioOf(context);

  void _keyDown(
    int keyIndex,
    Offset position,
    double pressure,
    double size,
    int tMs,
  ) {
    if (!_inputEnabled || !_isDigitKey(keyIndex)) return;
    _recorder.keyDown(
      keyIndex,
      Point2(position.dx * _dpr, position.dy * _dpr),
      pressure,
      tMs,
      size: size,
    );
  }

  void _keyUp(int keyIndex, int tMs) {
    if (!_isDigitKey(keyIndex)) return;
    _recorder.keyUp(keyIndex, tMs);
  }

  /// Only digit keys are presses. Backspace is recorded once, as a
  /// correction, by [_backspace]; its raw down/up must not also count as a
  /// keystroke (it would shift the hold and flight slots).
  static bool _isDigitKey(int keyIndex) =>
      keyIndex >= 0 && keyIndex < BanglaNumpad.backspaceIndex;

  void _onObscured() {
    if (!mounted) return;
    Log.w(_tag, 'obscured touch, input paused');
    _obscuredTimer?.cancel();
    setState(() => _obscured = true);
    _obscuredTimer = Timer(widget.obscuredBlock, () {
      if (mounted) setState(() => _obscured = false);
    });
  }

  // ------------------------------------------------------------- PIN entry

  void _digit(int d) {
    if (!_inputEnabled || _pin.length >= PinPadScreen.pinLength) return;
    unawaited(widget.haptics.key());
    _pin.write(d);
    if (_pin.length == PinPadScreen.pinLength) {
      // Lock and show the verifying state in this very frame.
      setState(() {
        _verifying = true;
        _wrong = false;
        _checkFailed = false;
      });
      _startSweep();
      // The hash check and the risk flow start on the next turn so the
      // frame above paints first.
      unawaited(Future<void>.microtask(_verify));
    } else {
      setState(() {
        _wrong = false;
        _checkFailed = false;
      });
    }
  }

  void _backspace() {
    if (!_inputEnabled || _pin.isEmpty) return;
    final s = _pin.toString();
    _pin
      ..clear()
      ..write(s.substring(0, s.length - 1));
    _recorder.backspace(DateTime.now().millisecondsSinceEpoch);
    setState(() {});
  }

  void _startSweep() {
    if (!MediaQuery.disableAnimationsOf(context)) unawaited(_sweep.repeat());
  }

  void _stopSweep() {
    _sweep
      ..stop()
      ..value = 0;
  }

  Future<void> _verify() async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      Log.w(_tag, 'no user on the PIN pad');
      if (mounted) _go(Routes.login);
      return;
    }
    final String hash;
    try {
      hash = (await ref.read(demoAssetsProvider).persona(user.persona))
          .pinSha256;
    } on Object catch (e) {
      Log.e(_tag, 'pin hash unavailable', e);
      _pin.clear();
      _recorder.reset();
      if (mounted) {
        _stopSweep();
        setState(() {
          _verifying = false;
          _checkFailed = true;
        });
      }
      return;
    }
    final ok = PinCheck.matches(_pin.toString(), hash);
    _pin.clear();
    if (!mounted) return;
    if (!ok) {
      await _wrongPin();
      return;
    }
    ref.read(pinAttemptsProvider.notifier).clear(_uid);
    await _score(user);
  }

  Future<void> _wrongPin() async {
    final paused = ref
        .read(pinAttemptsProvider.notifier)
        .recordWrong(
          _uid,
          max: PinPadScreen.maxAttempts,
          pause: widget.lockout,
          now: ref.read(clockProvider).now(),
        );
    _recorder.reset();
    unawaited(widget.haptics.error());
    _stopSweep();
    setState(() {
      _verifying = false;
      _wrong = true;
    });
    if (!MediaQuery.disableAnimationsOf(context)) {
      unawaited(_shake.forward(from: 0));
    }
    if (paused) _startLockout(widget.lockout.inSeconds);
  }

  /// Counts [seconds] down on screen; at zero the per-user pause ends.
  /// [initial]: called from `initState`, where `setState` is not allowed.
  void _startLockout(int seconds, {bool initial = false}) {
    _lockTimer?.cancel();
    if (initial) {
      _lockSecondsLeft = seconds;
    } else {
      setState(() => _lockSecondsLeft = seconds);
    }
    final uid = _uid;
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(
        () => _lockSecondsLeft = (_lockSecondsLeft - 1).clamp(0, 1 << 20),
      );
      if (_lockSecondsLeft == 0) {
        t.cancel();
        ref.read(pinAttemptsProvider.notifier).endPause(uid);
      }
    });
  }

  /// StepUp: back to a clean pad in the same session.
  void _resetPad() {
    _pin.clear();
    _recorder.reset();
    _stopSweep();
    setState(() {
      _verifying = false;
      _wrong = false;
    });
  }

  // ------------------------------------------------------------- scoring

  /// Scores the attempt. Any throw that escapes the flow (a callback, the
  /// feature extractor, a store) ends on the "cannot verify now" result with
  /// its retry, never on a pad stuck at "যাচাই হচ্ছে…".
  Future<void> _score(UserProfile user) async {
    try {
      await _scoreUnguarded(user);
    } on Object catch (e, st) {
      Log.e(_tag, 'scoring failed unexpectedly', e, st);
      if (!mounted) return;
      _stopSweep();
      setState(() => _verifying = false);
      final intent = ref.read(payControllerProvider);
      _go(
        PayPaths.result(
          widget.kind,
          state: 'unavailable',
          amount: intent.amountBdt,
        ),
      );
    }
  }

  Future<void> _scoreUnguarded(UserProfile user) async {
    final intent = ref.read(payControllerProvider);
    final pay = ref.read(payControllerProvider.notifier);
    final counterparty = intent.counterparty;
    if (intent.kind != widget.kind ||
        counterparty == null ||
        !intent.canProceed) {
      Log.w(
        _tag,
        'PIN confirmed without a counterparty or amount: kind '
        '${intent.kind.slug} (pad ${widget.kind.slug}), payee '
        '${counterparty == null ? 'none' : 'set'}, amount ${intent.amountBdt}',
      );
      if (mounted) _go(PayPaths.start(widget.kind));
      return;
    }
    final features = _features = PinPadScreen.lastFeatures =
        FeatureExtractor.build(
          BehaviourSample(
            keys: _recorder.keys,
            strokes: pay.swipeStrokes,
            imu: pay.imuWindow.all,
          ),
        );
    if (intent.kind == PayKind.dps) {
      await _openDps(user, intent);
      return;
    }
    if (!intent.kind.scored) {
      await _localAllow(user, intent);
      return;
    }
    final demo = ref.read(demoStateProvider).value ?? DemoState.initial;
    final mode = ref.read(behaviourModeProvider);
    // Everything the hold path writes through is captured before the first
    // await: the overlay can be dismissed (and this screen disposed) before
    // /v1/intervene answers, and the held row and record must still land.
    final pending = PendingHold(
      user: user,
      intent: intent,
      clock: ref.read(clockProvider),
      ledger: ref.read(ledgerRepoProvider),
      interventions: ref.read(interventionRepoProvider),
      cooldown: ref.read(cooldownProvider),
      lastScore: ref.read(lastScoreProvider.notifier),
      mode: mode,
    );
    // Cash out is a transfer to the agent's wallet (a real scam vector), so
    // it is scored as one: the wire has no cash-out type. txn_id is this
    // attempt's ledger row; RiskFlow sends it on /v1/intervene only.
    final txn = Txn(
      type: TxnType.sendMoney,
      amountBdt: intent.debitBdt.toDouble(),
      toAccount: counterparty.acctId,
      isNewPayee: intent.isNewPayee,
      txnId: pending.txnId,
    );
    // Read alongside the score (the step-up policy needs it the moment a
    // hold opens the overlay); not ready in time counts as no biometric.
    unawaited(
      ref
          .read(biometricAuthProvider)
          .strength()
          .then((s) => pending.strength = s)
          .catchError((Object e) {
            Log.w(_tag, 'biometric strength unavailable', e);
            return BiometricStrength.unsupported;
          }),
    );

    final outcome = await ref
        .read(riskFlowProvider)
        .scoreTransfer(
          user: user,
          sessionId: intent.sessionId,
          txn: txn,
          features: features,
          demo: demo,
          lastVerdict: ref.read(lastSafetyVerdictProvider),
          appSafety: ref.read(appSafetyContextProvider),
          onHoldPredicted: (trigger, asset, score) =>
              _onHoldPredicted(pending, user, trigger, asset, score),
          mode: mode,
          onFlags: (flags) => pending.callActiveLocal = flags.callActive,
        );

    final score = switch (outcome) {
      Allowed(:final score) ||
      Blocked(:final score) ||
      StepUpRequired(:final score) => score,
      Intervened(:final score) => score,
      Unavailable() => null,
    };
    if (score != null) pending.lastScore.state = score;

    if (outcome is Intervened) {
      // Written whether or not this screen is still up (the user may have
      // dismissed the overlay already): script_bn and the merged actions are
      // patched onto the record opened in onHoldPredicted.
      pending.intervene.complete(outcome.intervene);
      await pending.finishHold(outcome);
    }
    if (!mounted) return;

    final kind = widget.kind;
    final amount = intent.amountBdt;
    switch (outcome) {
      case Allowed():
        await pending.createTxn(LedgerStatus.done);
        if (!mounted) return;
        _go(
          PayPaths.result(
            kind,
            state: 'done',
            amount: amount,
            txn: pending.txnId,
          ),
        );
      case Intervened():
        if (pending.overlayOpened) {
          // The overlay is already up (opened in onHoldPredicted); it will
          // render script_bn and queue the served clip itself.
          return;
        }
        if (outcome.container == routing.Container.fullscreen) {
          // A delay the server tightened to fullscreen: the predicted clip
          // already played from onHoldPredicted, so speak is false here.
          _openOverlay(
            user,
            pending,
            outcome.score,
            outcome.trigger,
            outcome.predictedAsset,
            speak: false,
          );
        } else {
          _go(
            PayPaths.result(
              kind,
              state: 'held',
              amount: amount,
              txn: pending.txnId,
              banner: true,
              intervention: pending.recordId,
            ),
          );
        }
      case StepUpRequired():
        await _showStepUpSheet(user, pending, outcome.score);
      case Blocked():
        await pending.createTxn(LedgerStatus.blocked);
        unawaited(widget.haptics.error());
        if (!mounted) return;
        _openBlockedOverlay(
          outcome.score,
          pending,
          pending.clock.nowMs(),
          user: user,
          sessionId: intent.sessionId,
          txn: txn,
        );
      case Unavailable():
        // Cannot verify now: the money does not move.
        _go(PayPaths.result(kind, state: 'unavailable', amount: amount));
    }
    assert(features.length == FeatureNames.count);
  }

  /// Recharge and bill: no risk call. The pad keeps the verifying rhythm for
  /// [PayRules.localAllowDelay], then the `done` row is written.
  Future<void> _localAllow(UserProfile user, PayIntent intent) async {
    final clock = ref.read(clockProvider);
    final ledger = ref.read(ledgerRepoProvider);
    final txnId = newId('txn');
    await Future<void>.delayed(PayRules.localAllowDelay);
    await boundedWrite(
      () => ledger.create(
        user.uid,
        PayLedger.rowFor(
          intent,
          user,
          txnId: txnId,
          ts: clock.now(),
          status: LedgerStatus.done,
        ),
      ),
      'ledger write (done)',
    );
    if (!mounted) return;
    _go(
      PayPaths.result(
        widget.kind,
        state: 'done',
        amount: intent.amountBdt,
        txn: txnId,
      ),
    );
  }

  /// DPS, a local allow: the right PIN opens the plan through
  /// `FinanceRepo.openDps`, which writes the first instalment's ledger row
  /// itself. A failed write is "unavailable" (money never moves silently).
  Future<void> _openDps(UserProfile user, PayIntent intent) async {
    await Future<void>.delayed(PayRules.localAllowDelay);
    final months = intent.dpsTenureMonths ?? 0;
    try {
      final plan = await ref
          .read(financeRepoProvider)
          .openDps(
            user.uid,
            monthlyBdt: intent.amountBdt,
            tenureMonths: months,
          );
      Log.i(_tag, 'DPS ${plan.id} opened after the PIN');
    } on Object catch (e) {
      Log.w(_tag, 'DPS open failed', e);
      if (!mounted) return;
      setState(() => _verifying = false);
      _go(
        PayPaths.result(
          widget.kind,
          state: 'unavailable',
          amount: intent.amountBdt,
        ),
      );
      return;
    }
    if (!mounted) return;
    _go(PayPaths.result(widget.kind, state: 'done', amount: intent.amountBdt));
  }

  /// The overlay's "what is held" block: the amount and the counterparty.
  HeldSummary _summary(PayIntent intent) {
    final c = intent.counterparty;
    return HeldSummary(
      amountBdt: intent.debitBdt,
      name: c == null ? '' : context.counterpartyName(c),
      number: c == null ? '' : context.counterpartyNumber(c),
    );
  }

  /// Fires before `/v1/intervene` is awaited. The held ledger row and the
  /// open intervention record are written first (they must survive an early
  /// dismiss), then, for a `hold` (always fullscreen), the overlay opens with
  /// the reasons and the predicted clip (speak follows the cooldown, as
  /// `RiskFlow` decided it a moment ago). A `delay` renders as a banner by
  /// default, so only the clip starts here.
  void _onHoldPredicted(
    PendingHold pending,
    UserProfile user,
    String trigger,
    String asset,
    ScoreResponse score,
  ) {
    pending.scoreArrivedAtMs = pending.clock.nowMs();
    pending.lastScore.state = score;
    pending.startHold(trigger, score);
    final speak = pending.cooldown.shouldSpeak(trigger);
    if (!mounted) return;
    if (score.decision == Decision.hold) {
      _openOverlay(user, pending, score, trigger, asset, speak: speak);
    } else if (speak && Localizations.localeOf(context).languageCode != 'en') {
      // The bundled clips are Bangla; the English UI hears the served lines
      // in English from the banner instead.
      unawaited(
        ref.read(apaAudioProvider).playForScript(assetId: asset, scriptBn: ''),
      );
    }
  }

  void _openOverlay(
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
    String trigger,
    String asset, {
    required bool speak,
  }) {
    pending.overlayOpened = true;
    final amount = pending.intent.amountBdt;
    final held = PayPaths.result(
      widget.kind,
      state: 'held',
      amount: amount,
      txn: pending.txnId,
    );
    // Entry point B: a behaviour-only hold the owner may
    // release with a strong biometric. Offered when the overlay opens and
    // decided again at the tap.
    final decision = _stepUpPolicy(user, pending, score);
    final offer =
        score.decision == Decision.hold &&
        (decision.offered ||
            decision == const StepUpKeep(StepUpBlock.attemptsExhausted));
    if (decision == const StepUpKeep(StepUpBlock.attemptsExhausted)) {
      pending.stepUpExhausted.value = true;
    }
    unawaited(
      InterventionOverlay.show(
        context,
        held: _summary(pending.intent),
        score: score,
        trigger: trigger,
        predictedAsset: asset,
        intervene: pending.intervene.future,
        // mergeActions drops a server-sent biometric_step_up; the only one
        // shown is the client's own, when the policy offers it.
        actions: (r) => [
          ...routing.DecisionRouting.mergeActions(
            score.actions,
            r?.actions ?? const [],
          ),
          if (offer) const ActionItem(type: ActionLabels.biometricStepUp),
        ],
        speak: speak,
        scoreArrivedAtMs: pending.scoreArrivedAtMs,
        onDismiss: () => _afterOverlayPops(() => _go(held)),
        onAction: (a) => _onOverlayAction(a, user, pending, score, held),
        trustedSent: pending.trustedSent,
        stepUpFailed: pending.stepUpFailed,
        stepUpExhausted: pending.stepUpExhausted,
        stepUpClosed: pending.stepUpClosed,
        simulatedTag: _simulatedTag(pending.mode),
        review: (uid: user.uid, txnId: pending.txnId),
      ),
    );
  }

  /// The step-up policy for this attempt now: the same
  /// inputs at both entry points, at the overlay's open and at every tap.
  StepUpDecision _stepUpPolicy(
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
  ) => stepUpFor(
    score: score,
    callActiveLocal: pending.callActiveLocal,
    amountBdt: pending.intent.debitBdt.toDouble(),
    personaP95: PayRules.p95For(user.uid),
    strength: pending.strength,
    mode: pending.mode,
    attempts: ref.read(stepUpAttemptsProvider),
  );

  /// The phone's biometric strength; unreadable counts as none.
  Future<BiometricStrength> _strength() async {
    try {
      return await ref.read(biometricAuthProvider).strength();
    } on Object catch (e) {
      Log.w(_tag, 'biometric strength unavailable', e);
      return BiometricStrength.unsupported;
    }
  }

  /// The overlay's short "সিমুলেটেড: …" tag for a replayed or switched-off
  /// behaviour.
  String? _simulatedTag(BehaviourMode mode) => switch (mode) {
    BehaviourMode.live => null,
    BehaviourMode.off => context.l10n.simulatedTagOff,
    BehaviourMode.replayStranger => context.l10n.simulatedTagStranger,
    BehaviourMode.replayTapPattern => context.l10n.simulatedTagTapPattern,
    BehaviourMode.replayShaking => context.l10n.simulatedTagShaking,
    BehaviourMode.replayCoached => context.l10n.simulatedTagCoached,
  };

  /// `block`: the same fullscreen overlay (danger style from the decision)
  /// with the score's reasons and actions; there is no `/v1/intervene` for a
  /// block, so nothing further arrives. Dismiss (or any action but Apa) opens
  /// the safety findings with the blocked header.
  void _openBlockedOverlay(
    ScoreResponse score,
    PendingHold pending,
    int arrivedAtMs, {
    required UserProfile user,
    required String sessionId,
    required Txn txn,
  }) {
    // An App Safety block is explained by FNA, in words the
    // server writes from what the check found; other blocks keep the reasons.
    final flow = ref.read(riskFlowProvider);
    final appSafety = score.reasons.any(
      (r) => r.code == RiskFlow.appSafetyBlockCode,
    );
    final trigger = appSafety
        ? Triggers.appSafety
        : score.reasons.isEmpty
        ? Decision.block.wire
        : score.reasons.first.code.toLowerCase();
    // Decided before explainBlock arms the window, as for a hold.
    final speak = appSafety && flow.cooldown.shouldSpeak(trigger);
    final explained = appSafety
        ? flow.explainBlock(
            user: user,
            sessionId: sessionId,
            txn: txn,
            score: score,
          )
        : Future<InterveneResponse?>.value();
    void toSafety() => _go('${Routes.safety}?block=1');
    unawaited(
      InterventionOverlay.show(
        context,
        held: _summary(pending.intent),
        score: score,
        trigger: trigger,
        predictedAsset: Triggers.predictedAsset(trigger),
        intervene: explained,
        // A block's own actions only: the answer's hold actions never apply.
        actions: (_) =>
            routing.DecisionRouting.mergeActions(score.actions, const []),
        speak: speak,
        scoreArrivedAtMs: arrivedAtMs,
        simulatedTag: _simulatedTag(pending.mode),
        onDismiss: () => _afterOverlayPops(toSafety),
        onAction: (a) async {
          if (a.type == ActionLabels.askApa) {
            await ApaSheet.show(context, held: score, screen: 'intervention');
            return;
          }
          final nav = Navigator.of(context);
          if (nav.canPop()) nav.pop();
          _afterOverlayPops(toSafety);
        },
      ),
    );
  }

  /// The overlay pops itself right after `onDismiss` returns; navigating
  /// after that pop keeps go_router's page stack consistent.
  void _afterOverlayPops(VoidCallback go) {
    unawaited(
      Future<void>.microtask(() {
        if (mounted) go();
      }),
    );
  }

  Future<void> _onOverlayAction(
    ActionItem a,
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
    String heldResult,
  ) async {
    final l10n = context.l10n;
    switch (a.type) {
      case ActionLabels.trustedContactCheck:
        if (pending.trustedSent.value) return;
        try {
          await pending.record.future;
          final flow = ref.read(trustedContactFlowProvider);
          // Through the record queue: a step-up release behind it sees the
          // request and refuses. Marks it sent, which
          // swaps the button for the green "sent" line and drops the
          // step-up.
          final updated = await pending.requestTrusted(
            (record) => flow.request(
              record: record,
              contactUid: user.trustedContactUid,
            ),
          );
          // The request id is for the demo panel and the log, not the user.
          Log.i(_tag, 'trusted contact request ${updated.requestId}');
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.trustedRequestSent),
              duration: const Duration(seconds: 6),
            ),
          );
        } on Object catch (e) {
          Log.w(_tag, 'trusted contact request failed', e);
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l10n.trustedRequestFailed)));
        }
      case ActionLabels.askApa:
        await ApaSheet.show(context, held: score, screen: 'intervention');
      case ActionLabels.biometricStepUp:
        await _releaseByStepUp(user, pending, score);
      default:
        // hold / freeze / delay / block / unknown: acknowledge and move on.
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
        _afterOverlayPops(() => _go(heldResult));
    }
  }

  /// One fingerprint prompt; every prompt counts towards the session's
  /// [maxStepUpAttempts].
  Future<BiometricOutcome> _promptBiometric() {
    ref.read(stepUpAttemptsProvider.notifier).record();
    return ref
        .read(biometricAuthProvider)
        .authenticate(reason: context.l10n.stepUpBiometricReason);
  }

  StepUpRecord _stepUpRecord(PendingHold pending, ScoreResponse score) =>
      StepUpRecord(
        method: StepUpRecord.biometric,
        at: pending.clock.now(),
        // The server's intervention id when known, else this
        // phone's record id.
        decisionId: pending.serverInterventionId ?? pending.recordId,
        serverDecision: score.decision.wire,
        reasonCodes: [for (final r in score.reasons) r.code],
      );

  /// Entry point B: the overlay's "আঙুলের ছাপ দিয়ে নিশ্চিত করুন". The
  /// policy is decided again at the tap: the record must
  /// still be open, the trusted contact not asked, and the session's three
  /// prompts not used up (cancels count). A pass releases the hold on this
  /// phone (ledger and record `released_by_step_up`, both with the step-up
  /// record) and shows the result only when both writes landed;
  /// otherwise the overlay stays with the failed line. A failure is
  /// terminal (the sensor is locked) and leaves the trusted contact as the
  /// way on; a cancel changes nothing but the count.
  Future<void> _releaseByStepUp(
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
  ) async {
    if (!pending.stepUpOpen) {
      pending.stepUpClosed.value = true;
      return;
    }
    final decision = _stepUpPolicy(user, pending, score);
    if (decision case StepUpKeep(:final reason)) {
      Log.i(_tag, 'step-up kept at the tap: ${reason.name}');
      if (reason == StepUpBlock.attemptsExhausted) {
        pending.stepUpExhausted.value = true;
      } else {
        pending.stepUpClosed.value = true;
      }
      return;
    }
    final outcome = await _promptBiometric();
    switch (outcome) {
      case BiometricPassed():
        final released = await pending.release(_stepUpRecord(pending, score));
        if (!released) {
          // Refused (the trusted contact was asked meanwhile) or a write
          // did not land: never the "sent" result.
          if (pending.stepUpOpen) pending.stepUpFailed.value = true;
          return;
        }
        if (!mounted) return;
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
        final result = PayPaths.result(
          widget.kind,
          state: ResultScreen.releasedByStepUp,
          amount: pending.intent.amountBdt,
          txn: pending.txnId,
        );
        _afterOverlayPops(() => _go(result));
      case BiometricCancelled():
        if (ref.read(stepUpAttemptsProvider) >= maxStepUpAttempts) {
          pending.stepUpExhausted.value = true;
        }
      case BiometricFailed() || BiometricUnavailable():
        Log.i(_tag, 'step-up not passed: ${outcome.runtimeType}');
        pending.stepUpFailed.value = true;
    }
  }

  /// Entry point A, the server's `step_up`: any
  /// screen-share reason (or no reason) → stop sharing and retry (as
  /// before); the fingerprint sheet only when the step-up policy offers it
  /// with the overlay's inputs (identity reasons only, no call, amount at
  /// most the p95, a strong biometric, live behaviour, attempts left);
  /// anything else → the server's reasons and a retry.
  Future<void> _showStepUpSheet(
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
  ) async {
    // The pad under the sheet goes back to its clean state right away (no
    // spinner behind the sheet); the user re-enters the PIN after "retry".
    _resetPad();
    final screenShare =
        score.reasons.isEmpty ||
        score.reasons.any(
          (r) => ReasonKind.of(r.code) == ReasonKind.screenShare,
        );
    if (screenShare) return _showScreenShareSheet();
    pending.strength = await _strength();
    if (!mounted) return;
    final decision = _stepUpPolicy(user, pending, score);
    if (decision.offered) return _showIdentitySheet(user, pending, score);
    Log.i(_tag, 'step-up sheet without the fingerprint: $decision');
    return _showGenericStepUpSheet(score);
  }

  Future<void> _showScreenShareSheet() async {
    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(
          BhSpace.l,
          BhSpace.s,
          BhSpace.l,
          BhSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.screen_share_outlined,
                  color: Theme.of(sheet).colorScheme.cautionText,
                  size: 32,
                ),
                const SizedBox(width: BhSpace.m),
                Expanded(
                  child: Text(
                    l10n.stepUpTitle,
                    key: const Key('step_up_title'),
                    style: Theme.of(sheet).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: BhSpace.m),
            Text(l10n.stepUpBody, style: Theme.of(sheet).textTheme.bodyLarge),
            const SizedBox(height: BhSpace.l),
            BhButton(
              key: const Key('step_up_retry'),
              label: l10n.stepUpRetry,
              icon: Icons.refresh,
              onPressed: () => Navigator.of(sheet).pop(),
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet's title row and the server's reasons (FR-3: the why is the
  /// server's text only).
  List<Widget> _sheetHeader(BuildContext sheet, ScoreResponse score) {
    final theme = Theme.of(sheet);
    final p = sheet.palette;
    return [
      Row(
        children: [
          Icon(Icons.verified_user_outlined, color: p.warning, size: 32),
          const SizedBox(width: BhSpace.m),
          Expanded(
            child: Text(
              sheet.l10n.stepUpConfirmTitle,
              key: const Key('step_up_title'),
              style: theme.textTheme.titleLarge,
            ),
          ),
        ],
      ),
      const SizedBox(height: BhSpace.m),
      for (final r in uniqueReasons(sheet, score.reasons))
        Padding(
          padding: const EdgeInsets.only(bottom: BhSpace.s),
          child: ReasonLine(
            text: r.text(sheet),
            color: p.warningFill,
            style: theme.textTheme.bodyLarge,
          ),
        ),
    ];
  }

  Future<void> _showGenericStepUpSheet(ScoreResponse score) async {
    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            BhSpace.l,
            BhSpace.s,
            BhSpace.l,
            BhSpace.l,
          ),
          child: Column(
            key: const Key('step_up_generic'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._sheetHeader(sheet, score),
              const SizedBox(height: BhSpace.m),
              BhButton(
                key: const Key('step_up_retry'),
                label: l10n.stepUpRetry,
                icon: Icons.refresh,
                onPressed: () => Navigator.of(sheet).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "একবার নিশ্চিত করুন": the server's reason, "আমিই পাঠাচ্ছি", the
  /// outlined fingerprint button, "আপনজনের মত নিন" and "বাতিল". A pass sends
  /// the money (ledger `done` with the step-up record); a failure is
  /// terminal and keeps the trusted contact; a cancelled prompt changes
  /// nothing.
  Future<void> _showIdentitySheet(
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
  ) async {
    final l10n = context.l10n;
    var failed = false;
    var exhausted = ref.read(stepUpAttemptsProvider) >= maxStepUpAttempts;
    var busy = false;
    final choice = await showModalBottomSheet<_StepUpChoice>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              BhSpace.l,
              BhSpace.s,
              BhSpace.l,
              BhSpace.l,
            ),
            child: Column(
              key: const Key('step_up_identity'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._sheetHeader(sheet, score),
                const SizedBox(height: BhSpace.m),
                const StepUpChromeLine(),
                const SizedBox(height: BhSpace.xs),
                if (exhausted)
                  const StepUpFailedLine(exhausted: true)
                else if (failed)
                  const StepUpFailedLine()
                else
                  ActionButton(
                    action: const ActionItem(
                      type: ActionLabels.biometricStepUp,
                    ),
                    busy: busy,
                    outlined: true,
                    onPressed: () async {
                      if (busy) return;
                      // Decided again at the tap.
                      final decision = _stepUpPolicy(user, pending, score);
                      if (decision case StepUpKeep(:final reason)) {
                        Log.i(_tag, 'step-up kept at the tap: ${reason.name}');
                        setSheet(() {
                          if (reason == StepUpBlock.attemptsExhausted) {
                            exhausted = true;
                          } else {
                            failed = true;
                          }
                        });
                        return;
                      }
                      setSheet(() => busy = true);
                      final outcome = await _promptBiometric();
                      if (!sheet.mounted) return;
                      switch (outcome) {
                        case BiometricPassed():
                          Navigator.of(sheet).pop(_StepUpChoice.passed);
                        case BiometricCancelled():
                          setSheet(() {
                            busy = false;
                            exhausted =
                                ref.read(stepUpAttemptsProvider) >=
                                maxStepUpAttempts;
                          });
                        case BiometricFailed() || BiometricUnavailable():
                          Log.i(
                            _tag,
                            'step-up not passed: ${outcome.runtimeType}',
                          );
                          setSheet(() {
                            busy = false;
                            failed = true;
                          });
                      }
                    },
                  ),
                const SizedBox(height: BhSpace.s),
                BhButton(
                  key: const Key('step_up_ask_trusted'),
                  label: l10n.stepUpAskTrusted,
                  icon: Icons.people_outline,
                  variant: BhButtonVariant.outlined,
                  onPressed: busy
                      ? null
                      : () => Navigator.of(sheet).pop(_StepUpChoice.trusted),
                ),
                const SizedBox(height: BhSpace.xs),
                SizedBox(
                  height: BhSize.touch,
                  child: TextButton(
                    key: const Key('step_up_cancel'),
                    onPressed: busy ? null : () => Navigator.of(sheet).pop(),
                    child: Text(l10n.stepUpCancel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _StepUpChoice.passed:
        // A closed `step_up_passed` record carries the step-up, so its
        // decisionId points at something; then the row.
        await pending.recordStepUpPassed(
          ReasonKind.identity.trigger!,
          score,
          _stepUpRecord(pending, score),
        );
        if (!mounted) return;
        _go(
          PayPaths.result(
            widget.kind,
            state: ResultScreen.done,
            amount: pending.intent.amountBdt,
            txn: pending.txnId,
          ),
        );
      case _StepUpChoice.trusted:
        await _askTrustedAfterStepUp(user, pending, score);
      case null:
        // "বাতিল": the pad is already back to a clean state.
        break;
    }
  }

  /// "আপনজনের মত নিন" from the identity sheet: the transfer is held (row
  /// and record, as for a server hold) and the trusted contact is asked.
  Future<void> _askTrustedAfterStepUp(
    UserProfile user,
    PendingHold pending,
    ScoreResponse score,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    pending.startHold(ReasonKind.identity.trigger!, score);
    var sent = false;
    try {
      final flow = ref.read(trustedContactFlowProvider);
      final updated = await pending.requestTrusted(
        (record) =>
            flow.request(record: record, contactUid: user.trustedContactUid),
      );
      Log.i(_tag, 'trusted contact request ${updated.requestId}');
      sent = true;
    } on Object catch (e) {
      Log.w(_tag, 'trusted contact request failed', e);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          sent ? l10n.trustedRequestSent : l10n.trustedRequestFailed,
        ),
      ),
    );
    if (!mounted) return;
    _go(
      PayPaths.result(
        widget.kind,
        state: ResultScreen.held,
        amount: pending.intent.amountBdt,
        txn: pending.txnId,
        intervention: pending.recordId,
      ),
    );
  }

  void _go(String location) {
    unawaited(ref.read(payControllerProvider.notifier).stopImu());
    context.go(location);
  }

  void _back() => context.go(PayPaths.beforePin(widget.kind));

  /// The line above the amount, per kind (2.3).
  String _kindLine(BuildContext context, PayIntent intent) {
    final l10n = context.l10n;
    final c = intent.counterparty;
    if (c == null) return '';
    return switch (intent.kind) {
      PayKind.send => l10n.pinSendingTo(context.counterpartyName(c)),
      PayKind.cashOut => l10n.pinCashOutTo(context.counterpartyNumber(c)),
      PayKind.recharge => l10n.pinRechargeLine(
        context.counterpartyNumber(c),
        intent.operator == null ? '' : context.operatorName(intent.operator!),
      ),
      PayKind.bill =>
        intent.bill == null
            ? context.counterpartyName(c)
            : context.billName(intent.bill!.biller),
      PayKind.cashIn => '',
      PayKind.dps => context.dpsPlanLine(intent),
    };
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final theme = Theme.of(context);
    final intent = ref.watch(payControllerProvider);
    final count = _pin.length;
    final shortScreen =
        MediaQuery.sizeOf(context).height < BhSize.compactBelowHeight;

    final String? line;
    final Color lineColor;
    if (_lockSecondsLeft > 0) {
      line = l10n.pinLocked(context.digits('$_lockSecondsLeft'));
      lineColor = p.danger;
    } else if (_obscured) {
      line = l10n.pinObscured;
      lineColor = p.warning;
    } else if (_verifying) {
      line = l10n.pinVerifying;
      lineColor = p.mutedText;
    } else if (_wrong) {
      line = l10n.pinWrong;
      lineColor = p.danger;
    } else if (_checkFailed) {
      line = l10n.pinCheckUnavailable;
      lineColor = p.danger;
    } else {
      line = null;
      lineColor = p.mutedText;
    }
    final amount = intent.amountBdt;

    // While verifying, system back must not pop the pad out from under the
    // risk flow (the overlay, a route of its own, handles its own back).
    // Otherwise back is one step back: the amount step (or the bill card).
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_verifying) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: shortScreen ? BhSize.appBarCompact : BhSize.appBar,
          title: Text(l10n.pinTitle),
          leading: BackButton(onPressed: _verifying ? null : _back),
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, box) {
              final compact = box.maxHeight < PinPadScreen.compactBelow;
              return Column(
                children: [
                  const StepProgress(step: 3, total: 3),
                  Expanded(
                    child: ClipRect(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: box.maxWidth - 2 * BhSpace.m,
                            ),
                            child: ConfirmSummary(
                              compact: compact,
                              kindLine: _kindLine(context, intent),
                              amountText: context.taka(amount),
                              feeLine: intent.feeBdt > 0
                                  ? l10n.pinTotalWithFee(
                                      context.taka(intent.debitBdt),
                                    )
                                  : null,
                              words: amount >= 1000
                                  ? context.takaWords(amount)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _shake,
                    builder: (_, child) {
                      final t = _shake.value;
                      final dx = t == 0 || t == 1
                          ? 0.0
                          : 12 * (1 - t) * _sinWave(t);
                      return Transform.translate(
                        offset: Offset(dx, 0),
                        child: child,
                      );
                    },
                    child: _Dots(
                      key: Key(_verifying ? 'pin_verifying' : 'pin_dots'),
                      count: count,
                      total: PinPadScreen.pinLength,
                      error: _wrong,
                      sweep: _verifying ? _sweep : null,
                      semantics: _verifying
                          ? l10n.pinVerifying
                          : l10n.pinDigitsEntered(context.digits('$count')),
                    ),
                  ),
                  const SizedBox(height: BhSpace.m),
                  SizedBox(
                    height: compact ? 40 : 48,
                    child: line == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: BhSpace.m,
                            ),
                            child: Text(
                              line,
                              key: const Key('pin_line'),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: lineColor,
                                height: 1.2,
                              ),
                            ),
                          ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(bottom: compact ? 12 : 16),
                    child: Numpad(
                      enabled: _inputEnabled,
                      keyHeight: compact ? BhSize.keyCompact : BhSize.key,
                      gap: compact ? BhSpace.xs : BhSpace.s,
                      onDigit: _digit,
                      onBackspace: _backspace,
                      onKeyDown: _keyDown,
                      onKeyUp: _keyUp,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Three oscillations over the shake, damped by the caller.
  static double _sinWave(double t) => math.sin(t * 2 * math.pi * 3);

  /// The vector of this pad's last right PIN.
  List<double>? get features => _features;
}

/// What the identity step-up sheet closed with (`null`: "বাতিল").
enum _StepUpChoice { passed, trusted }

/// Four 20 dp squares, 16 dp apart. While verifying ([sweep] set) they fill
/// in sequence, 150 ms apart, looping, instead of swapping the row for
/// something else (no layout jump).
class _Dots extends StatelessWidget {
  const _Dots({
    required this.count,
    required this.total,
    required this.error,
    required this.semantics,
    this.sweep,
    super.key,
  });

  final int count;
  final int total;
  final bool error;
  final String semantics;
  final Animation<double>? sweep;

  static const size = 20.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final motion = BhMotion.of(context);
    final color = error ? p.danger : p.primary;
    Widget row(int filled) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: BhSpace.m),
          AnimatedContainer(
            duration: motion.fast,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: i < filled ? color : Colors.transparent,
              border: Border.all(color: color, width: 2),
            ),
          ),
        ],
      ],
    );
    final s = sweep;
    return Semantics(
      label: semantics,
      liveRegion: s != null,
      child: ExcludeSemantics(
        child: s == null
            ? row(count)
            : AnimatedBuilder(
                animation: s,
                // Reduce motion (no repeat): all four filled, static.
                builder: (_, _) =>
                    row(s.isAnimating ? (s.value * total).floor() + 1 : total),
              ),
      ),
    );
  }
}
