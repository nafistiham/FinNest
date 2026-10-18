/// The hidden demo panel: a bottom
/// sheet the team opens by long-pressing the logo on Login or Home. It flips
/// the simulated world, switches persona, replays the scam script, confirms
/// a waiting cash in and resets cooldowns so the video can be retaken.
///
/// Layout: `SheetHeader` "ডেমো প্যানেল" with the status line (cloud, server
/// time in the active digits, health dot) as its second row; three groups
/// under `SectionHeader`s on `surfaceVariant` cards: দৃশ্য (video preset,
/// persona, forced verdict and phone check as 2-column `ChoiceTile` grids),
/// সংকেত (the four flags, wire name as a muted second line), কাজ (re-run,
/// replay, audio, cash in, resets). It also has গল্প (six one-tap stories,
/// each with its demo note) and আচরণ (the session-scoped behaviour mode as
/// a vertical radio group, the enrolment switch, counter, export and clear).
/// Never shown to a customer, but still readable: every label comes from the
/// ARB in the active language.
library;

import 'dart:async';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/router.dart' show Routes;
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/animated/sheet_reveal.dart';
import 'package:bhorosha/app/widgets/animated/status_pulse.dart';
import 'package:bhorosha/app/widgets/choice_tile.dart';
import 'package:bhorosha/app/widgets/demo_note.dart';
import 'package:bhorosha/app/widgets/section_header.dart';
import 'package:bhorosha/app/widgets/settings_row.dart';
import 'package:bhorosha/app/widgets/sheet_header.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/demo_panel/logic/demo_panel_controller.dart';
import 'package:bhorosha/features/intervention/logic/apa_voice.dart';
import 'package:bhorosha/features/intervention/logic/asset_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Opens the panel as a scrollable modal bottom sheet.
class DemoPanelSheet {
  const DemoPanelSheet._();

  static Future<void> show(BuildContext ctx) {
    unawaited(const SystemHaptics().light());
    return showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.4,
        maxChildSize: 0.96,
        builder: (_, controller) => DemoPanelBody(scrollController: controller),
      ),
    );
  }
}

/// Wraps [child] so a long press opens the demo panel. Login and Home wrap
/// their logo with it. With [enabled] false (a release build without
/// `--dart-define=DEMO_PANEL=true`, [AppEnv.demoPanel]) it is just [child]:
/// no gesture, no hint.
class DemoLongPressTarget extends StatelessWidget {
  const DemoLongPressTarget({
    required this.child,
    this.enabled = AppEnv.demoPanel,
    super.key,
  });

  final Widget child;

  /// Whether the long press opens the panel.
  final bool enabled;

  @override
  Widget build(BuildContext context) => !enabled
      ? child
      : Semantics(
          hint: context.l10n.demoPanel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => DemoPanelSheet.show(context),
            child: child,
          ),
        );
}

/// The panel content, shared by [DemoPanelSheet] and `DemoPanelScreen`.

class DemoPanelBody extends ConsumerStatefulWidget {
  const DemoPanelBody({
    this.scrollController,
    this.showTitle = true,
    this.haptics = const SystemHaptics(),
    this.navigate,
    super.key,
  });

  final Haptics haptics;

  /// Where a story goes next; `null` uses the app's router. Tests pass a
  /// recorder.
  final void Function(String location)? navigate;

  final ScrollController? scrollController;

  /// `false` when a Scaffold app bar already shows the title.
  final bool showTitle;

  // Keys for tests and the smoke tool.
  static const presetKey = Key('demo_video_preset');
  static const replayKey = Key('demo_replay_scam');
  static const previewAudioKey = Key('demo_preview_audio');
  static const previewGeminiKey = Key('demo_preview_gemini');
  static const resetCooldownKey = Key('demo_reset_cooldown');
  static const resetAllKey = Key('demo_reset_all');
  static const healthDotKey = Key('demo_health_dot');
  static const personaKey = Key('demo_persona');
  static const verdictKey = Key('demo_forced_verdict');
  static const integrityKey = Key('demo_integrity');
  static const rerunSafetyKey = Key('demo_rerun_safety');
  static const confirmCashInKey = Key('demo_confirm_cash_in');
  static Key switchKey(String flag) => Key('demo_switch_$flag');
  static const behaviourModeKey = Key('demo_behaviour_mode');
  static const enrolToggleKey = Key('demo_enrol_toggle');
  static const enrolCountKey = Key('demo_enrol_count');
  static const enrolExportKey = Key('demo_enrol_export');
  static const enrolClearKey = Key('demo_enrol_clear');
  static const storySuspectKey = Key('demo_story_suspect');
  static const storyStrangerKey = Key('demo_story_stranger');
  static const storyTapPatternKey = Key('demo_story_tap_pattern');
  static const storyShakingKey = Key('demo_story_shaking');
  static const storyCoachedKey = Key('demo_story_coached');
  static Key behaviourModeOptionKey(BehaviourMode m) =>
      Key('demo_behaviour_mode_${m.name}');
  static const storyInvestigationKey = Key('demo_story_investigation');

  /// The send flow with the recent `acct_01070` row pre-selected (the
  /// recipient step reads `payee`).
  static final suspectPayeeLocation = Uri(
    path: Routes.send,
    queryParameters: {'payee': DemoPanelController.suspectPayeeAcct},
  ).toString();

  @override
  ConsumerState<DemoPanelBody> createState() => _DemoPanelBodyState();
}

String _verdictLabel(AppLocalizations l10n, SafetyVerdict v) => switch (v) {
  SafetyVerdict.safe => l10n.safetyVerdictSafe,
  SafetyVerdict.caution => l10n.safetyVerdictCaution,
  SafetyVerdict.block => l10n.safetyVerdictBlock,
};

/// A readable label with the wire name after it in small muted text, e.g.
/// "নিরাপদ SAFE" or "সিম বদল sim_swap".
class WireLabel extends StatelessWidget {
  const WireLabel({required this.label, required this.wire, super.key});

  final String label;
  final String wire;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label),
          TextSpan(text: '  $wire', style: muted),
        ],
      ),
      maxLines: 1,
    );
  }
}

class _DemoPanelBodyState extends ConsumerState<DemoPanelBody> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(demoPanelControllerProvider.notifier).checkHealth();
    });
  }

  Future<void> _confirmCashIn() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final row = await ref
        .read(demoPanelControllerProvider.notifier)
        .confirmCashIn();
    if (!mounted) return;
    if (row != null) unawaited(widget.haptics.success());
    messenger?.showSnackBar(
      SnackBar(
        content: Text(row == null ? l10n.demoCashInNone : l10n.demoCashInDone),
      ),
    );
  }

  /// Closes the sheet (when the panel is one) and goes to [location].
  void _goTo(String location) {
    final navigate = widget.navigate;
    final router = navigate == null ? GoRouter.maybeOf(context) : null;
    if (ModalRoute.of(context) is PopupRoute) Navigator.of(context).pop();
    if (navigate != null) {
      navigate(location);
    } else {
      router?.go(location);
    }
  }

  /// The preview button whose line is playing, or null: it reads "চলছে…" with a
  /// stop until the audio finishes.
  Key? _playing;
  StreamSubscription<AudioEvent>? _audioSub;

  @override
  void dispose() {
    _audioSub?.cancel();
    super.dispose();
  }

  /// Speaks [u] through the voice stack from the preview button [key],
  /// names the source that played, and shows the playing state until the
  /// audio finishes (or the stop is pressed). A second tap stops it.
  Future<void> _preview(Key key, ApaUtterance u) async {
    final voice = ref.read(apaVoiceProvider);
    if (_playing != null) {
      setState(() => _playing = null);
      await voice.stop();
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    _audioSub ??= ref.read(apaAudioProvider).events.listen((e) {
      if (e is AudioFinished && mounted) setState(() => _playing = null);
    });
    setState(() => _playing = key);
    final source = await voice.speak(u);
    if (!mounted) return;
    if (source == ApaVoiceSource.none) setState(() => _playing = null);
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.voiceSourceNote(source.label(l10n)))),
    );
  }

  Widget _previewButton(Key key, IconData icon, String label, ApaUtterance u) {
    final l10n = context.l10n;
    final playing = _playing == key;
    return Semantics(
      label: playing
          ? '${l10n.demoPreviewPlaying} ${l10n.demoPreviewStop}'
          : null,
      child: _ActionButton(
        key: key,
        icon: playing ? Icons.stop : icon,
        label: playing ? l10n.demoPreviewPlaying : label,
        onPressed: _playing == null || playing
            ? () => unawaited(_preview(key, u))
            : null,
      ),
    );
  }

  Future<void> _storySuspect() async {
    await ref.read(demoPanelControllerProvider.notifier).storySuspectPayee();
    if (mounted) _goTo(DemoPanelBody.suspectPayeeLocation);
  }

  DemoPanelController get _ctl =>
      ref.read(demoPanelControllerProvider.notifier);

  void _storyStranger() => unawaited(_ctl.storyStranger());

  void _storyTapPattern() => unawaited(_ctl.storyTapPattern());

  void _storyShaking() => unawaited(_ctl.storyShaking());

  void _storyCoached() => unawaited(_ctl.storyCoached());

  void _storyInvestigation() => _goTo(Routes.fraudDesk);

  Future<void> _exportEnrolment() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final file = await ref
        .read(demoPanelControllerProvider.notifier)
        .exportEnrolment();
    if (!mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          file == null ? l10n.enrolExportFailed : l10n.enrolExported(file.path),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  Future<void> _clearEnrolment() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await ref.read(demoPanelControllerProvider.notifier).clearEnrolment();
    if (!mounted) return;
    messenger?.showSnackBar(SnackBar(content: Text(l10n.enrolCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(demoPanelControllerProvider);
    final ctl = ref.read(demoPanelControllerProvider.notifier);
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final demo = state.demo;
    final persona =
        ref.watch(currentUserProvider.select((u) => u.value?.persona)) ??
        demo.persona;
    final status = _StatusLine(state: state, onHealthTap: ctl.checkHealth);

    // Built in full (a short panel): every control exists for tests and
    // TalkBack, whatever the scroll position.
    final list = SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.s,
        BhSpace.m,
        BhSpace.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.showTitle) status,
          // দৃশ্য: the recording setup and who / what the world is.
          _Group(
            title: l10n.demoGroupScene,
            children: [
              // The short label on the button, what it sets as a caption
              // under it (the one-line "label · detail" was cut).
              _ActionButton(
                key: DemoPanelBody.presetKey,
                filled: true,
                icon: Icons.videocam,
                label: l10n.demoVideoPreset,
                onPressed: state.replaying ? null : ctl.videoPreset,
              ),
              Padding(
                padding: const EdgeInsets.only(top: BhSpace.xs),
                child: Text(
                  l10n.demoVideoPresetDetail,
                  key: const Key('demo_video_preset_detail'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.palette.mutedText),
                ),
              ),
              // The same ChoiceTile grid as the verdict below: one selected
              // style in the panel.
              _Labelled(
                label: l10n.demoPersona,
                child: _ChoiceGrid<Persona?>(
                  key: DemoPanelBody.personaKey,
                  selected: persona,
                  options: [
                    (Persona.rina, l10n.demoPersonaRina),
                    (Persona.rahima, l10n.demoPersonaRahima),
                  ],
                  onSelected: (v) {
                    if (v != null) ctl.setPersona(v);
                  },
                ),
              ),
              _Labelled(
                label: l10n.demoForcedVerdict,
                child: _ChoiceGrid<SafetyVerdict?>(
                  key: DemoPanelBody.verdictKey,
                  selected: demo.forcedSafetyVerdict,
                  options: [
                    (null, l10n.demoVerdictAuto),
                    for (final v in SafetyVerdict.values)
                      (v, _verdictLabel(l10n, v)),
                  ],
                  onSelected: ctl.setForcedVerdict,
                ),
              ),
              _Labelled(
                label: l10n.demoIntegrity,
                child: _ChoiceGrid<String?>(
                  key: DemoPanelBody.integrityKey,
                  selected: demo.integrityScenario,
                  options: [
                    (null, l10n.demoIntegrityClean),
                    (
                      IntegrityScenarios.screenControlled,
                      l10n.demoIntegrityScreenControlled,
                    ),
                    (IntegrityScenarios.moddedApp, l10n.demoIntegrityModded),
                    (IntegrityScenarios.emulator, l10n.demoIntegrityEmulator),
                    (IntegrityScenarios.unbound, l10n.demoIntegrityUnbound),
                  ],
                  onSelected: ctl.setIntegrityScenario,
                ),
              ),
            ],
          ),
          // গল্প: one tap sets up a story.
          _Group(
            title: l10n.storySection,
            children: [
              _Story(
                buttonKey: DemoPanelBody.storySuspectKey,
                icon: Icons.person_search_outlined,
                label: l10n.storySuspectPayee,
                note: l10n.storySuspectPayeeNote,
                onPressed: _storySuspect,
              ),
              _Story(
                buttonKey: DemoPanelBody.storyStrangerKey,
                icon: Icons.back_hand_outlined,
                label: l10n.storyStranger,
                note: l10n.storyStrangerNote,
                onPressed: _storyStranger,
              ),
              _Story(
                buttonKey: DemoPanelBody.storyTapPatternKey,
                icon: Icons.touch_app_outlined,
                label: l10n.storyTapPattern,
                note: l10n.storyTapPatternNote,
                onPressed: _storyTapPattern,
              ),
              _Story(
                buttonKey: DemoPanelBody.storyShakingKey,
                icon: Icons.vibration,
                label: l10n.storyShaking,
                note: l10n.storyShakingNote,
                onPressed: _storyShaking,
              ),
              _Story(
                buttonKey: DemoPanelBody.storyCoachedKey,
                icon: Icons.record_voice_over_outlined,
                label: l10n.storyCoached,
                note: l10n.storyCoachedNote,
                onPressed: _storyCoached,
              ),
              _Story(
                buttonKey: DemoPanelBody.storyInvestigationKey,
                icon: Icons.policy_outlined,
                label: l10n.storyInvestigation,
                note: l10n.storyInvestigationNote,
                onPressed: _storyInvestigation,
              ),
            ],
          ),
          // সংকেত: the four simulated phone signals.
          _Group(
            title: l10n.demoGroupSignals,
            gap: 0,
            children: [
              _FlagSwitch(
                flag: DemoFlagNames.simSwap,
                label: l10n.demoFlagSimSwap,
                value: demo.simSwap,
                onChanged: ctl.setFlag,
              ),
              _FlagSwitch(
                flag: DemoFlagNames.callActive,
                label: l10n.demoFlagCallActive,
                value: demo.callActive,
                onChanged: ctl.setFlag,
              ),
              _FlagSwitch(
                flag: DemoFlagNames.screenShare,
                label: l10n.demoFlagScreenShare,
                value: demo.screenShare,
                onChanged: ctl.setFlag,
              ),
              _FlagSwitch(
                flag: DemoFlagNames.callerInContacts,
                label: l10n.demoFlagCallerInContacts,
                value: demo.callerInContacts,
                onChanged: ctl.setFlag,
              ),
            ],
          ),
          // আচরণ: what the next transfer posts as behaviour, and enrolment.
          _BehaviourGroup(onExport: _exportEnrolment, onClear: _clearEnrolment),
          // কাজ: one-shot actions.
          _Group(
            title: l10n.demoGroupActions,
            children: [
              _ActionButton(
                key: DemoPanelBody.rerunSafetyKey,
                icon: Icons.security,
                label: l10n.demoRerunSafety,
                onPressed: ctl.rerunSafetyCheck,
              ),
              _ActionButton(
                key: DemoPanelBody.replayKey,
                icon: Icons.record_voice_over,
                busy: state.replaying,
                label: l10n.demoReplayScam,
                onPressed: state.replaying ? null : ctl.replayScam,
              ),
              _ReplaySummary(state: state),
              if (state.error != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.demoActionFailed,
                      key: const Key('demo_error'),
                      style: text.bodyMedium?.copyWith(
                        color: p.statusText(BhStatus.danger),
                      ),
                    ),
                    // The technical detail, for the team, small and muted.
                    Text(
                      state.error!,
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                  ],
                ),
              // Both previews go through the voice stack, so the snackbar
              // names the source that played (bundled clip, server, Gemini,
              // on-device).
              _previewButton(
                DemoPanelBody.previewAudioKey,
                Icons.volume_up,
                l10n.demoPreviewAudio,
                ApaUtterance(
                  textBn:
                      AssetCatalog.scripts[DemoPanelController
                          .previewAssetId] ??
                      '',
                  assetId: DemoPanelController.previewAssetId,
                ),
              ),
              _previewButton(
                DemoPanelBody.previewGeminiKey,
                Icons.record_voice_over_outlined,
                l10n.demoPreviewGeminiVoice,
                ApaUtterance(
                  textBn: DemoPanelController.previewGeminiTextBn,
                  textEn: DemoPanelController.previewGeminiTextEn,
                  english: Localizations.localeOf(context).languageCode == 'en',
                ),
              ),
              _ActionButton(
                key: DemoPanelBody.confirmCashInKey,
                icon: Icons.storefront_outlined,
                label: l10n.demoConfirmCashIn,
                onPressed: _confirmCashIn,
              ),
              _ActionButton(
                key: DemoPanelBody.resetCooldownKey,
                icon: Icons.timer_off,
                label: l10n.demoResetCooldown,
                onPressed: ctl.resetCooldown,
              ),
              _ActionButton(
                key: DemoPanelBody.resetAllKey,
                icon: Icons.restart_alt,
                label: l10n.demoResetAll,
                onPressed: ctl.resetAll,
              ),
            ],
          ),
        ],
      ),
    );

    if (!widget.showTitle) return list;
    return Column(
      children: [
        SheetHeader(title: l10n.demoPanel, icon: Icons.tune, bottom: status),
        Expanded(child: SlideFadeIn(offset: 16, child: list)),
      ],
    );
  }
}

/// A [SectionHeader] over a `surfaceVariant` card with 16 dp padding and
/// [gap] dp between its children (8.12).
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.gap = 12});

  final String title;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: BhSpace.m),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title),
        // A Material, not a ColoredBox: the switch tiles ink on it.
        Material(
          color: context.palette.surfaceVariant,
          child: Padding(
            padding: const EdgeInsets.all(BhSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, c) in children.indexed) ...[
                  if (i > 0) SizedBox(height: gap),
                  c,
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A control with its label above (`SettingsRow.control` style).
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SettingsRow.control(title: label, child: child);
}

/// A full-width 56 dp action: outlined, or filled for the one setup action.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Widget leading = busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon);
    final Widget label = Text(this.label, maxLines: 2);
    return SizedBox(
      height: BhSize.touch,
      child: filled
          ? FilledButton.icon(onPressed: onPressed, icon: leading, label: label)
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: leading,
              label: label,
            ),
    );
  }
}

/// Options as shared [ChoiceTile]s, two per row (8.12: more than three
/// options never squeeze into one segmented row, and a label never wraps
/// mid-word).
class _ChoiceGrid<T> extends StatelessWidget {
  const _ChoiceGrid({
    required this.selected,
    required this.options,
    required this.onSelected,
    super.key,
  });

  final T selected;
  final List<(T, String)> options;
  final void Function(T value) onSelected;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < options.length; i += 2) {
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : BhSpace.s),
          child: Row(
            children: [
              for (var j = i; j < i + 2; j++) ...[
                if (j > i) const SizedBox(width: BhSpace.s),
                Expanded(
                  child: j < options.length
                      ? ChoiceTile(
                          label: options[j].$2,
                          selected: options[j].$1 == selected,
                          height: BhSize.touch,
                          scaleDown: true,
                          onTap: () => onSelected(options[j].$1),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// Cloud status, health dot (tap to re-check) and last server timing: the
/// sheet header's second row, all from the ARB in the active digits.
class _StatusLine extends ConsumerWidget {
  const _StatusLine({required this.state, required this.onHealthTap});

  final DemoPanelState state;
  final VoidCallback onHealthTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: p.mutedText);
    final firebase = ref.watch(firebaseStatusProvider);
    final status = switch (state.healthy) {
      true => BhStatus.success,
      false => BhStatus.danger,
      null => BhStatus.neutral,
    };
    final ms = state.lastServerMs;
    final cloud = l10n.demoCloudStatus(switch (firebase) {
      FirebaseStatus.configured => l10n.demoCloudConfigured,
      FirebaseStatus.absent => l10n.demoCloudAbsent,
      FirebaseStatus.failed => l10n.demoCloudFailed,
    });
    final server = l10n.demoServerMsShort(
      ms == null ? '—' : context.digits('$ms'),
    );
    return Row(
      children: [
        // Wraps to a second line rather than cutting "মি.সে.".
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: cloud),
                const TextSpan(text: ' · '),
                TextSpan(text: server),
              ],
            ),
            key: const Key('demo_status_line'),
            maxLines: 2,
            style: style,
          ),
        ),
        // 56 dp target that overflows the 48 dp row symmetrically.
        SizedBox(
          width: BhSize.touch,
          height: 48,
          child: OverflowBox(
            maxHeight: BhSize.touch,
            child: Semantics(
              button: true,
              label: l10n.demoHealth,
              child: InkWell(
                key: DemoPanelBody.healthDotKey,
                onTap: onHealthTap,
                child: SizedBox.square(
                  dimension: BhSize.touch,
                  child: Center(child: StatusPulse(status: status, size: 12)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FlagSwitch extends StatelessWidget {
  const _FlagSwitch({
    required this.flag,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String flag;
  final String label;
  final bool value;
  final Future<void> Function(String flag, bool on) onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: BhSize.touch),
      child: SwitchListTile(
        key: DemoPanelBody.switchKey(flag),
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        // The wire name, for the team: small and muted under the label.
        subtitle: Text(
          flag,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: p.mutedText),
        ),
        value: value,
        onChanged: (on) => onChanged(flag, on),
      ),
    );
  }
}

/// Rolling-score bar, evidence quote and the per-turn log.
class _ReplaySummary extends StatelessWidget {
  const _ReplaySummary({required this.state});

  final DemoPanelState state;

  static String _urgency(AppLocalizations l10n, String wire) =>
      switch (wire.toLowerCase()) {
        'none' => l10n.demoUrgencyNone,
        'low' => l10n.safetySeverityLow,
        'medium' => l10n.safetySeverityMedium,
        'high' => l10n.safetySeverityHigh,
        _ => '—',
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final last = state.lastReplay;
    final score = last?.rollingScore ?? state.demo.scamScore;
    final quote = last?.evidenceQuote ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: score.clamp(0.0, 1.0),
          minHeight: 8,
          borderRadius: BorderRadius.zero,
          color: context.palette.statusText(
            score >= 0.7 ? BhStatus.danger : BhStatus.warning,
          ),
          backgroundColor: context.palette.outlineVariant,
        ),
        const SizedBox(height: BhSpace.xs),
        Text(
          l10n.demoScamScore(context.digits(score.toStringAsFixed(2))),
          key: const Key('demo_scam_score'),
          style: text.labelMedium,
        ),
        if (quote.isNotEmpty) ...[
          const SizedBox(height: BhSpace.s),
          Text(quote, style: text.bodyLarge),
        ],
        if (state.replayLog.isNotEmpty) ...[
          const SizedBox(height: BhSpace.s),
          for (final (i, r) in state.replayLog.indexed)
            WireLabel(
              label: l10n.demoReplayTurn(
                context.digits('${i + 1}'),
                context.digits(r.rollingScore.toStringAsFixed(2)),
                _urgency(l10n, r.urgency),
              ),
              wire: r.scamType,
            ),
        ],
      ],
    );
  }
}

/// One story: an outlined 56 dp button and its demo note.
class _Story extends StatelessWidget {
  const _Story({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.note,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final String note;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _ActionButton(
        key: buttonKey,
        icon: icon,
        label: label,
        onPressed: onPressed,
      ),
      const SizedBox(height: BhSpace.xs),
      DemoNote(note),
    ],
  );
}

String _modeLabel(AppLocalizations l10n, BehaviourMode m) => switch (m) {
  BehaviourMode.live => l10n.behaviourModeLive,
  BehaviourMode.off => l10n.behaviourModeOff,
  BehaviourMode.replayStranger => l10n.behaviourModeStranger,
  BehaviourMode.replayTapPattern => l10n.behaviourModeTapPattern,
  BehaviourMode.replayShaking => l10n.behaviourModeShaking,
  BehaviourMode.replayCoached => l10n.behaviourModeCoached,
};

/// One muted line under each mode: what the server will see.
String _modeHelp(AppLocalizations l10n, BehaviourMode m) => switch (m) {
  BehaviourMode.live => l10n.behaviourModeLiveHelp,
  BehaviourMode.off => l10n.behaviourModeOffHelp,
  BehaviourMode.replayStranger => l10n.behaviourModeStrangerHelp,
  BehaviourMode.replayTapPattern => l10n.behaviourModeTapPatternNote,
  BehaviourMode.replayShaking => l10n.behaviourModeShakingNote,
  BehaviourMode.replayCoached => l10n.behaviourModeCoachedNote,
};

/// "আচরণ": the behaviour mode (every [BehaviourMode]), the enrolment
/// switch with its note, the counter, export and clear. All session-scoped
/// except the rows themselves (kept on this phone).
class _BehaviourGroup extends ConsumerWidget {
  const _BehaviourGroup({required this.onExport, required this.onClear});

  final VoidCallback onExport;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final ctl = ref.read(demoPanelControllerProvider.notifier);
    final mode = ref.watch(behaviourModeProvider);
    final enrolling = ref.watch(behaviourEnrollingProvider);
    // Rebuilt on a persona switch: the counter follows the signed-in user.
    ref.watch(currentUserProvider.select((u) => u.value?.uid));
    final count =
        ref.watch(enrolmentCountProvider(ctl.enrolmentPersona)).value ?? 0;
    return _Group(
      title: l10n.behaviourModeSection,
      children: [
        _Labelled(
          label: l10n.behaviourModeLabel,
          // Six modes never fit one segmented row at 360 dp (8.12): a
          // vertical radio group, one 48 dp row each.
          child: RadioGroup<BehaviourMode>(
            key: DemoPanelBody.behaviourModeKey,
            groupValue: mode,
            onChanged: (m) {
              if (m != null) ctl.setBehaviourMode(m);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in BehaviourMode.values)
                  RadioListTile<BehaviourMode>(
                    key: DemoPanelBody.behaviourModeOptionKey(m),
                    value: m,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_modeLabel(l10n, m)),
                    // What the server will see, so the presenter can predict
                    // the answer.
                    subtitle: Text(
                      _modeHelp(l10n, m),
                      key: Key('demo_behaviour_help_${m.name}'),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: context.palette.mutedText),
                    ),
                  ),
              ],
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: BhSize.touch),
          child: SwitchListTile(
            key: DemoPanelBody.enrolToggleKey,
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.enrolToggle),
            value: enrolling,
            onChanged: ctl.setEnrolling,
          ),
        ),
        DemoNote(l10n.enrolHint),
        Text(
          l10n.enrolCount(context.digits('$count')),
          key: DemoPanelBody.enrolCountKey,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        _ActionButton(
          key: DemoPanelBody.enrolExportKey,
          icon: Icons.save_alt,
          label: l10n.enrolExport,
          onPressed: onExport,
        ),
        _ActionButton(
          key: DemoPanelBody.enrolClearKey,
          icon: Icons.delete_outline,
          label: l10n.enrolClear,
          onPressed: onClear,
        ),
      ],
    );
  }
}
