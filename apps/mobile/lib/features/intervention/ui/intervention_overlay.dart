import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n.dart';
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/sheet_reveal.dart';
import '../../../app/widgets/brand_glyph.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../core/audio/apa_audio.dart';
import '../../../core/haptics.dart';
import '../../../core/log.dart';
import '../../../data/contracts/common.dart';
import '../../../data/contracts/intervene.dart';
import '../../../data/contracts/score.dart';
import '../../../domain/risk/decision_routing.dart' show DecisionRouting;
import '../../home/logic/home_providers.dart' show txnByIdProvider;
import '../../safety/logic/review_state.dart';
import '../../safety/ui/widgets/review_lines.dart';
import '../logic/action_labels.dart';
import '../logic/apa_voice.dart';
import '../logic/asset_catalog.dart';
import '../logic/metrics_log.dart';
import '../logic/reason_kind.dart';
import 'intervention_style.dart';

const _tag = 'overlay';

/// The fullscreen hold/block screen (4).
///
/// Opens on the `ScoreResponse` alone: the reasons render and the predicted
/// clip is queued synchronously in `initState`, so it always plays before
/// anything `/v1/intervene` brings, even when that future is already resolved.
/// When it answers, the script in the app language (`script_bn`, or
/// `script_en` in English) appears above the reasons, with a toggle that
/// reveals the other language's line and, if the served `audio_asset_id`
/// differs from the predicted one, the served clip queues after it. If it
/// fails, the reasons stay. Every visible string is a server field or an ARB
/// label keyed by a type or decision (FR-3). System back equals the top-left
/// dismiss; neither clears the hold.
///
/// [onAction] may return a `Future`; for the trusted-contact action the
/// button stays busy until it completes, so a tap burst sends one request.
/// The same holds for the identity step-up
/// ([ActionLabels.biometricStepUp]), which the caller
/// adds to the actions only when the step-up policy offers it: it renders
/// outlined under the chrome line "আমিই পাঠাচ্ছি", just above the trusted
/// contact (which stays the filled primary), and turns into the
/// "যাচাই হয়নি" line once [stepUpFailed] is true, or the "তিনবার যাচাই
/// হয়নি" line once [stepUpExhausted] is. It is gone (chrome line and all)
/// once the trusted-contact request went out ([trustedSent]) or the record
/// is no longer open ([stepUpClosed]): the owner has handed the decision to
/// the trusted contact, and a release would erase that.
///
/// [review] (a held transfer) shows the customer's review lines under the
/// held summary; every hold or block
/// overlay shows at least "টাকা পাঠানো হয়নি, আপনার কাছেই আছে।" there, even
/// before the row is written.
///
/// One state per screen: a `block` decision, or a
/// leading app-safety reason, reads "আটকানো হয়েছে" over the amount, keeps
/// the decision title and offers "ঠিক আছে" (dismiss) as the primary instead
/// of the server's cancel/hold/trusted-contact actions; a `hold` keeps "আটকে
/// রাখা হয়েছে" and the server's actions. Reason bullets take their colour
/// from [ReasonKind]: danger only for an app-safety, scam, call or screen
/// share reason on a block, warning otherwise. An identity
/// reason without the biometric offer always keeps "আপনজনের মত নিন".
///
/// [simulatedTag] (the behaviour was replayed or switched off by the demo
/// panel) shows as a warning [StatusTag] under the amount line, e.g.
/// "সিমুলেটেড: অন্য কারও হাতের ধরন".
abstract final class InterventionOverlay {
  static Future<void> show(
    BuildContext context, {
    required ScoreResponse score,
    required String trigger,
    required String predictedAsset,
    required Future<InterveneResponse?> intervene,
    required List<ActionItem> Function(InterveneResponse?) actions,
    required FutureOr<void> Function(ActionItem) onAction,
    required VoidCallback onDismiss,
    required bool speak,
    required int scoreArrivedAtMs,
    ValueListenable<bool>? trustedSent,
    ValueListenable<bool>? stepUpFailed,
    ValueListenable<bool>? stepUpExhausted,
    ValueListenable<bool>? stepUpClosed,
    String? simulatedTag,
    HeldSummary? held,
    HeldReview? review,
    bool? english,
    Haptics haptics = const SystemHaptics(),
  }) {
    final isEnglish =
        english ?? Localizations.localeOf(context).languageCode == 'en';
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        settings: const RouteSettings(name: 'intervention'),
        builder: (_) => InterventionScreen(
          score: score,
          trigger: trigger,
          predictedAsset: predictedAsset,
          intervene: intervene,
          actions: actions,
          onAction: onAction,
          onDismiss: onDismiss,
          speak: speak,
          scoreArrivedAtMs: scoreArrivedAtMs,
          trustedSent: trustedSent,
          stepUpFailed: stepUpFailed,
          stepUpExhausted: stepUpExhausted,
          stepUpClosed: stepUpClosed,
          simulatedTag: simulatedTag,
          held: held,
          review: review,
          english: isEnglish,
          haptics: haptics,
        ),
      ),
    );
  }
}

/// What is being held, shown at the top of the overlay: the amount and the
/// counterparty. App chrome, not risk copy (FR-3 allows what, forbids why).
class HeldSummary {
  const HeldSummary({
    required this.amountBdt,
    required this.name,
    this.number = '',
  });

  final int amountBdt;

  /// Already in the app language and digits.
  final String name;
  final String number;
}

/// The ledger row behind a held overlay, for its review lines: persona
/// [uid], row [txnId]. The lines use the row's own time as the hold time.
typedef HeldReview = ({String uid, String txnId});

/// The route body; public so tests can pump it directly.
class InterventionScreen extends ConsumerStatefulWidget {
  const InterventionScreen({
    super.key,
    required this.score,
    required this.trigger,
    required this.predictedAsset,
    required this.intervene,
    required this.actions,
    required this.onAction,
    required this.onDismiss,
    required this.speak,
    required this.scoreArrivedAtMs,
    this.trustedSent,
    this.stepUpFailed,
    this.stepUpExhausted,
    this.stepUpClosed,
    this.simulatedTag,
    this.held,
    this.review,
    this.english = false,
    this.haptics = const SystemHaptics(),
  });

  /// The UI is English: the lines are spoken in English and the Bangla
  /// clips are skipped (the spoken line follows the app language, owner
  /// 2026-10-17).
  final bool english;

  final ScoreResponse score;
  final String trigger;
  final String predictedAsset;
  final Future<InterveneResponse?> intervene;
  final List<ActionItem> Function(InterveneResponse?) actions;

  /// Runs an action; a returned `Future` keeps the trusted-contact button
  /// busy until it completes.
  final FutureOr<void> Function(ActionItem) onAction;
  final VoidCallback onDismiss;
  final bool speak;
  final int scoreArrivedAtMs;

  /// Turns `true` once the trusted-contact request went out; the button is
  /// then replaced in place by [TrustedRequestSentLine].
  final ValueListenable<bool>? trustedSent;

  /// Turns `true` after a failed (terminal) fingerprint step-up: the
  /// step-up button is replaced in place by [StepUpFailedLine].
  final ValueListenable<bool>? stepUpFailed;

  /// Turns `true` once three prompts in this session did not pass: the
  /// step-up button is replaced by the exhausted line.
  final ValueListenable<bool>? stepUpExhausted;

  /// Turns `true` once the record is no longer open: the step-up is gone.
  final ValueListenable<bool>? stepUpClosed;

  /// The short tag of a replayed or switched-off behaviour signal
  /// ("সিমুলেটেড: …"); null shows none.
  final String? simulatedTag;

  /// The amount and payee being held; null shows no summary block.
  final HeldSummary? held;

  /// The held row whose review lines show under [held]; null shows none.
  final HeldReview? review;
  final Haptics haptics;

  /// Server actions shown as buttons; more collapse into "আরও উপায়" so the
  /// block never exceeds 4 x 56 + 3 x 8 + 32 dp.
  @override
  ConsumerState<InterventionScreen> createState() => _InterventionScreenState();
}

class _InterventionScreenState extends ConsumerState<InterventionScreen> {
  InterveneResponse? _served;
  bool _resolved = false;

  /// The toggle under the script: reveals `script_en` in Bangla, or
  /// `script_bn` when the app is already in English.
  bool _showOther = false;
  bool _dismissed = false;
  bool _latencyRecorded = false;

  /// The trusted-contact request went out and has not answered yet.
  bool _trustedBusy = false;

  /// The fingerprint prompt is up.
  bool _stepUpBusy = false;

  /// One state: a block (or an app-safety lead) is shown as blocked.
  bool get _blocked =>
      widget.score.decision == Decision.block ||
      ReasonKind.leading(widget.score.reasons) == ReasonKind.appSafety;

  /// The kinds whose bullet is red, and only on a block.
  static const _dangerKinds = {
    ReasonKind.appSafety,
    ReasonKind.scam,
    ReasonKind.callActive,
    ReasonKind.screenShare,
  };

  /// The bullet colour of reason [r]: never red on a hold.
  Color _bulletColor(BhPalette p, Reason r) => p.statusFill(
    _blocked && _dangerKinds.contains(ReasonKind.of(r.code))
        ? BhStatus.danger
        : BhStatus.warning,
  );

  /// The buttons for this state. A block offers "ঠিক আছে" first and drops
  /// what no longer applies (cancel, hold, trusted contact, step-up). A hold
  /// with an identity reason and no biometric offer keeps the trusted
  /// contact even when the server sent none.
  List<ActionItem> _actionsFor(List<ActionItem> served) {
    if (_blocked) {
      return [
        const ActionItem(type: ActionLabels.acknowledge),
        for (final a in served)
          if (!_stoppedByBlock.contains(a.type)) a,
      ];
    }
    final identity = widget.score.reasons.any(
      (r) => ReasonKind.of(r.code) == ReasonKind.identity,
    );
    final hasStepUp = served.any((a) => a.type == ActionLabels.biometricStepUp);
    final hasTrusted = served.any(
      (a) => a.type == ActionLabels.trustedContactCheck,
    );
    if (identity && !hasStepUp && !hasTrusted) {
      return [
        ...served,
        const ActionItem(type: ActionLabels.trustedContactCheck),
      ];
    }
    return served;
  }

  static const _stoppedByBlock = {
    ActionLabels.blockTransaction,
    ActionLabels.holdTransaction,
    ActionLabels.trustedContactCheck,
    ActionLabels.biometricStepUp,
    ActionLabels.acknowledge,
  };
  StreamSubscription<AudioEvent>? _audioSub;

  @override
  void initState() {
    super.initState();
    final audio = ref.read(apaAudioProvider);
    final metrics = ref.read(metricsLogProvider);

    // Subscribe before anything plays so the first start is never missed.
    if (widget.speak) {
      _audioSub = audio.events.listen((e) {
        if (e is AudioStarted && !_latencyRecorded) {
          _latencyRecorded = true;
          metrics.record(
            Metrics.holdToAudioMs,
            e.atMs - widget.scoreArrivedAtMs,
          );
        }
      });
      // Queued now, before `intervene.then` can run: the served clip can
      // never come first, however fast the server (or a resolved future) is.
      Log.d(
        _tag,
        'predicted clip "${widget.predictedAsset}" for trigger "${widget.trigger}"',
      );
      // The bundled clips are Bangla: in the English UI nothing plays until
      // the served lines are rendered in English.
      if (!widget.english) {
        unawaited(
          audio.playForScript(assetId: widget.predictedAsset, scriptBn: ''),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.haptics.warning());
    });

    widget.intervene.then(_onServed).catchError((Object e) {
      Log.w(_tag, 'intervene failed; keeping the score reasons', e);
      if (mounted) setState(() => _resolved = true);
    });
  }

  void _onServed(InterveneResponse? r) {
    if (!mounted) return;
    setState(() {
      _served = r;
      _resolved = true;
    });
    if (r == null || !widget.speak) return;
    // Everything served plays after the predicted clip, never instead of it:
    // ApaVoice queues on the same FIFO. Audio is always Bangla (there is no
    // English audio): in English the screen shows `script_en` while FNA
    // speaks `script_bn`.
    final voice = ref.read(apaVoiceProvider);
    if (r.lines.isNotEmpty) {
      // The warning written for this call, line by line: a bundled
      // clip, the server's clip or live audio, Gemini TTS, or the phone.
      for (final line in r.lines) {
        if (!widget.english &&
            AssetCatalog.idForScript(line.textBn) == widget.predictedAsset) {
          continue; // already playing
        }
        unawaited(
          voice.speak(
            ApaUtterance.fromLine(
              line,
              fallback: ApaFallback.none,
              english: widget.english,
            ),
          ),
        );
      }
      return;
    }
    final served = r.audioAssetId;
    if (served == null ||
        (!widget.english && served == widget.predictedAsset)) {
      return;
    }
    Log.d(
      _tag,
      'served asset "$served" differs from predicted; queued after it',
    );
    // An id the client has never seen still falls back to the sha256 index,
    // then the dynamic voices.
    unawaited(
      voice.speak(
        ApaUtterance(
          textBn: r.scriptBn,
          textEn: r.scriptEn,
          assetId: served,
          fallback: ApaFallback.none,
          english: widget.english,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    widget.onDismiss();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// Forwards [a]; the trusted-contact action is sent once per burst: the
  /// button is busy from the tap until the caller's future completes (or the
  /// request is marked sent).
  Future<void> _runAction(ActionItem a) async {
    if (a.type == ActionLabels.acknowledge) {
      _dismiss();
      return;
    }
    if (a.type == ActionLabels.biometricStepUp) {
      if (_stepUpBusy ||
          (widget.stepUpFailed?.value ?? false) ||
          (widget.stepUpExhausted?.value ?? false) ||
          (widget.stepUpClosed?.value ?? false) ||
          (widget.trustedSent?.value ?? false)) {
        return;
      }
      setState(() => _stepUpBusy = true);
      try {
        await widget.onAction(a);
      } finally {
        if (mounted) setState(() => _stepUpBusy = false);
      }
      return;
    }
    if (a.type != ActionLabels.trustedContactCheck) {
      await widget.onAction(a);
      return;
    }
    if (_trustedBusy || (widget.trustedSent?.value ?? false)) return;
    setState(() => _trustedBusy = true);
    try {
      await widget.onAction(a);
    } finally {
      if (mounted) setState(() => _trustedBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final style = InterventionStyle.of(
      context,
      _blocked ? Decision.block : widget.score.decision,
    );
    final actions = orderForThumbZone(_actionsFor(widget.actions(_served)));
    final simulated = widget.simulatedTag == null
        ? null
        : Align(
            child: Padding(
              padding: const EdgeInsets.only(top: BhSpace.s),
              child: StatusTag(
                key: const ValueKey('intervention_simulated'),
                label: widget.simulatedTag!,
                status: BhStatus.warning,
              ),
            ),
          );
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final served = _served;
    final held = widget.held;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _dismiss();
      },
      child: Scaffold(
        backgroundColor: p.surface,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Chrome: dismiss top-left (hard to reach on purpose).
              Container(
                key: const ValueKey('intervention_strip'),
                color: style.container,
                height: BhSize.touch,
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('intervention_dismiss'),
                  style: TextButton.styleFrom(
                    foregroundColor: style.onContainer,
                    minimumSize: const Size(BhSize.touch, BhSize.touch),
                  ),
                  onPressed: _dismiss,
                  icon: const Icon(Icons.close),
                  label: Text(l10n.interventionDismiss),
                ),
              ),
              Expanded(
                // Entrance (6.2): the content slides up 32 dp and fades in, firm
                // (no overshoot: a hold or block is never playful). The
                // action buttons below stay put and tappable from frame one.
                // The foot of the scroll area fades into the surface, so a
                // script longer than the space reads as "more below" rather
                // than as cut off.
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SlideFadeIn(
                        firm: true,
                        child: ListView(
                          padding: const EdgeInsets.all(BhSpace.m),
                          children: [
                            // 2. What is held.
                            if (held != null) ...[
                              Column(
                                key: const ValueKey('intervention_held'),
                                children: [
                                  Text(
                                    _blocked
                                        ? l10n.overlayBlockedLabel
                                        : l10n.overlayHeldLabel,
                                    key: const ValueKey(
                                      'intervention_held_label',
                                    ),
                                    style: text.labelMedium?.copyWith(
                                      color: style.text,
                                    ),
                                  ),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      context.taka(held.amountBdt),
                                      key: const ValueKey(
                                        'intervention_held_amount',
                                      ),
                                      maxLines: 1,
                                      style: context.textRoles.amountHero
                                          .copyWith(color: p.onSurface),
                                    ),
                                  ),
                                  Text(
                                    held.number.isEmpty
                                        ? held.name
                                        : l10n.overlayHeldTo(
                                            held.name,
                                            held.number,
                                          ),
                                    key: const ValueKey('intervention_held_to'),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyMedium?.copyWith(
                                      color: p.mutedText,
                                    ),
                                  ),
                                  _HeldReviewLines(review: widget.review),
                                  ?simulated,
                                ],
                              ),
                              const SizedBox(height: BhSpace.l),
                            ] else if (simulated != null) ...[
                              simulated,
                              const SizedBox(height: BhSpace.m),
                            ],
                            // 3. Apa and the decision title.
                            Row(
                              children: [
                                BrandGlyph(
                                  size: BhSize.avatar,
                                  ring: widget.speak,
                                ),
                                const SizedBox(width: BhSpace.m),
                                Expanded(
                                  child: Text(
                                    style.title,
                                    key: const ValueKey('intervention_title'),
                                    style: text.headlineMedium?.copyWith(
                                      color: style.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: BhSpace.l),
                            // 4. Apa's script (server copy).
                            if (served != null) ...[
                              Text(
                                served.script(context),
                                key: const ValueKey('intervention_script'),
                                style: context.textRoles.script.copyWith(
                                  color: p.onSurface,
                                ),
                              ),
                              // No toggle when the server sent only one language.
                              if (served.otherScript(context).trim().isNotEmpty)
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: TextButton(
                                    key: const ValueKey(
                                      'intervention_english_toggle',
                                    ),
                                    onPressed: () => setState(
                                      () => _showOther = !_showOther,
                                    ),
                                    child: Text(
                                      context.banglaDigits
                                          ? l10n.interventionEnglish
                                          : l10n.interventionShowBangla,
                                    ),
                                  ),
                                ),
                              if (_showOther &&
                                  served.otherScript(context).trim().isNotEmpty)
                                Text(
                                  served.otherScript(context),
                                  key: const ValueKey(
                                    'intervention_script_other',
                                  ),
                                  style: text.bodyMedium?.copyWith(
                                    color: p.mutedText,
                                  ),
                                ),
                              const SizedBox(height: BhSpace.l),
                            ] else if (!_resolved) ...[
                              Row(
                                children: [
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: BhSpace.m),
                                  Text(
                                    l10n.interventionWaiting,
                                    style: text.bodySmall?.copyWith(
                                      color: p.mutedText,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: BhSpace.l),
                            ],
                            // 5. The server's reasons.
                            for (final r in uniqueReasons(
                              context,
                              widget.score.reasons,
                            ))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: ReasonLine(
                                  key: ValueKey(
                                    'intervention_reason_${r.code}',
                                  ),
                                  text: r.text(context),
                                  color: _bulletColor(p, r),
                                  style: text.bodyLarge?.copyWith(
                                    color: p.onSurface,
                                  ),
                                ),
                              ),
                            const SizedBox(height: BhSpace.l),
                          ],
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: 0,
                      end: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          key: const ValueKey('intervention_scroll_fade'),
                          height: 28,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                p.surface.withValues(alpha: 0),
                                p.surface,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 6. Actions in the thumb zone, on the surface with a hairline:
              // server order, then ask Apa, and the protective
              // trusted-contact action lowest.
              DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surface,
                  border: Border(top: BorderSide(color: p.outlineVariant)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(BhSpace.m),
                  child: _ActionColumn(
                    actions: actions,
                    onAction: (a) => unawaited(_runAction(a)),
                    trustedSent: widget.trustedSent,
                    trustedBusy: _trustedBusy,
                    stepUpFailed: widget.stepUpFailed,
                    stepUpExhausted: widget.stepUpExhausted,
                    stepUpClosed: widget.stepUpClosed,
                    stepUpBusy: _stepUpBusy,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionColumn extends StatelessWidget {
  const _ActionColumn({
    required this.actions,
    required this.onAction,
    required this.trustedSent,
    this.trustedBusy = false,
    this.stepUpFailed,
    this.stepUpExhausted,
    this.stepUpClosed,
    this.stepUpBusy = false,
  });

  /// Already in thumb-zone order (trusted contact last).
  final List<ActionItem> actions;
  final void Function(ActionItem) onAction;
  final ValueListenable<bool>? trustedSent;

  /// The trusted-contact request is in flight: its button is disabled.
  final bool trustedBusy;
  final ValueListenable<bool>? stepUpFailed;
  final ValueListenable<bool>? stepUpExhausted;
  final ValueListenable<bool>? stepUpClosed;

  /// The fingerprint prompt is up: the step-up button is disabled.
  final bool stepUpBusy;

  static final ValueListenable<bool> _never = ValueNotifier(false);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      trustedSent ?? _never,
      stepUpFailed ?? _never,
      stepUpExhausted ?? _never,
      stepUpClosed ?? _never,
    ]),
    builder: (context, _) => _build(
      context,
      sent: trustedSent?.value ?? false,
      stepUpFailed: stepUpFailed?.value ?? false,
      stepUpExhausted: stepUpExhausted?.value ?? false,
      stepUpClosed: stepUpClosed?.value ?? false,
    ),
  );

  Widget _build(
    BuildContext context, {
    required bool sent,
    required bool stepUpFailed,
    required bool stepUpExhausted,
    required bool stepUpClosed,
  }) {
    final l10n = context.l10n;
    final p = context.palette;
    // One filled primary: the outcome the server already chose. The step-up
    // and the trusted contact are the two ways to get the money moving
    // again, both outlined; anything else the server sent waits behind
    // "আরও উপায়"; asking FNA is a text link. Six equal buttons asked a
    // first-time user to compare them; three choices with a hierarchy do
    // not.
    ActionItem? primary;
    ActionItem? stepUp;
    final trusted = <ActionItem>[];
    final rest = <ActionItem>[];
    for (final a in actions) {
      if (a.type == ActionLabels.biometricStepUp) {
        stepUp ??= a;
      } else if (a.type == ActionLabels.trustedContactCheck) {
        trusted.add(a);
      } else if (primary == null && ActionLabels.isPrimary(a.type)) {
        primary = a;
      } else if (DecisionRouting.moneyStaysFamily.contains(a.type)) {
        // A second name for the outcome the primary already states (a hold
        // beside a 60-minute delay): never shown, whoever built the list.
        continue;
      } else {
        rest.add(a);
      }
    }
    // Gone once the trusted contact was asked or the record closed.
    final stepUpOpen = stepUp != null && !sent && !stepUpClosed;
    final stepUpLive = stepUpOpen && !stepUpFailed && !stepUpExhausted;
    // While the fingerprint is on offer it is the one way through: the
    // trusted contact appears when it fails (the fail line names it), so
    // an identity hold asks one question, not two.
    final showTrusted = !stepUpLive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stepUpOpen) ...[
          const StepUpChromeLine(),
          const SizedBox(height: BhSpace.xs),
          if (stepUpExhausted)
            const StepUpFailedLine(exhausted: true)
          else if (stepUpFailed)
            const StepUpFailedLine()
          else
            ActionButton(
              action: stepUp,
              busy: stepUpBusy,
              outlined: true,
              onPressed: () => onAction(stepUp!),
            ),
          const SizedBox(height: BhSpace.m),
        ],
        if (rest.isNotEmpty) ...[
          SizedBox(
            height: BhSize.touch,
            child: OutlinedButton(
              key: const ValueKey('action_more'),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.onSurface,
                side: BorderSide(color: p.outline),
              ),
              onPressed: () => _showMore(context, rest),
              child: Text(l10n.overlayMoreActions),
            ),
          ),
          const SizedBox(height: BhSpace.s),
        ],
        if (showTrusted)
          for (final a in trusted) ...[
            if (sent)
              const TrustedRequestSentLine()
            else
              ActionButton(
                action: a,
                busy: trustedBusy,
                outlined: true,
                onPressed: () => onAction(a),
              ),
            const SizedBox(height: BhSpace.s),
          ],
        if (primary != null)
          ActionButton(action: primary, onPressed: () => onAction(primary!)),
        const SizedBox(height: BhSpace.xs),
        TextButton(
          key: const ValueKey('action_ask_apa'),
          style: TextButton.styleFrom(
            foregroundColor: p.primary,
            minimumSize: const Size(double.infinity, 48),
          ),
          onPressed: () =>
              onAction(const ActionItem(type: ActionLabels.askApa)),
          child: Text(l10n.askApa),
        ),
      ],
    );
  }

  Future<void> _showMore(BuildContext context, List<ActionItem> rest) =>
      showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(BhSpace.m),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in rest) ...[
                  ActionButton(
                    action: a,
                    onPressed: () {
                      Navigator.of(sheet).pop();
                      onAction(a);
                    },
                  ),
                  const SizedBox(height: BhSpace.s),
                ],
              ],
            ),
          ),
        ),
      );
}

/// The review lines under the held summary: the row's own
/// lines while it is held; at least the money line otherwise (no row yet,
/// or a blocked row, whose money also never left).
class _HeldReviewLines extends ConsumerWidget {
  const _HeldReviewLines({required this.review});

  final HeldReview? review;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = review;
    final row = r == null
        ? null
        : ref.watch(txnByIdProvider((uid: r.uid, txnId: r.txnId))).value;
    var state = ReviewState.moneySafe;
    if (r != null && row != null) {
      final own = ReviewLinesForRow.stateOf(
        ref,
        uid: r.uid,
        row: row,
        heldAt: row.ts,
      );
      if (own != ReviewState.none) state = own;
    }
    return Padding(
      key: const ValueKey('intervention_review'),
      padding: const EdgeInsets.only(top: BhSpace.s),
      child: ReviewLines(state: state),
    );
  }
}
