/// The Apa sheet (US-3): the security hub. Transcript, four
/// quick actions (phone safety, why money was held, the scam check, the five
/// rules), a text field answered by Gemini or the offline guide, and
/// hold-to-talk. With `AppEnv.fnaVoiceAgent` the chat shows a large
/// "Talk" button instead, "Hear it" on every answer, the call summary card,
/// and voice mode ([FnaVoiceView]) in place of the chat body. Opened as a modal bottom sheet by [ApaSheet.show] and
/// hosted full-screen by `ApaScreen` for the `/apa` route.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/ui/apa_actions.dart';
import 'package:bhorosha/features/apa/ui/fna_voice_view.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_tile.dart';
import 'package:bhorosha/features/apa/ui/widgets/fna_call_summary_card.dart';
import 'package:bhorosha/features/apa/ui/widgets/fna_talk_button.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ApaSheet {
  const ApaSheet._();

  /// Height of the hold-to-talk button (dp).
  static const holdButtonHeight = 72.0;

  /// Below this screen height the sheet takes the full height.
  static const fullHeightBelow = 720.0;

  /// Opens the sheet for [screen], seeded with the held [ScoreResponse] (its
  /// `reasons[].text_bn` become the first bubble) and an optional [insight]
  /// (the Home card's) followed by [others] (the card's "more" list), then
  /// runs [then] (e.g. the scam check) inside it.
  /// Resolves when the sheet is dismissed; audio and the Live session are
  /// stopped on the way out. The light haptic of the 6.3 map fires here, so
  /// every entry point (bar, card, pending card, overlay) feels the same.
  static Future<void> show(
    BuildContext context, {
    ScoreResponse? held,
    required String screen,
    ApaInsight? insight,
    ApaAction? then,
    List<ApaInsight> others = const [],
    Haptics haptics = const SystemHaptics(),
  }) async {
    final container = ProviderScope.containerOf(context);
    final controller = container.read(apaControllerProvider.notifier);
    // One sheet at a time per controller: a second tap while one is opening
    // or open is ignored, so two sheets never share (and silence) one
    // controller.
    if (!controller.markSheetOpen()) return;
    try {
      unawaited(haptics.light());
      // Never let preparation keep the sheet from opening: after 4 s the
      // sheet opens with whatever is ready (device test, 2026-10-18).
      await controller
          .openFor(held: held, screen: screen, insight: insight, others: others)
          .timeout(const Duration(seconds: 4), onTimeout: () {});
      if (then != null) await controller.runAction(then);
      if (!context.mounted) return;
      final height = MediaQuery.sizeOf(context).height;
      controller.markSheetShown();
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: double.infinity),
        builder: (_) => FractionallySizedBox(
          heightFactor: height < fullHeightBelow ? 1.0 : 0.92,
          child: const ApaSheetBody(),
        ),
      );
      await controller.close();
    } finally {
      controller.markSheetClosed();
    }
  }
}

/// The sheet content. Expects `ApaController.openFor` to have run.
class ApaSheetBody extends ConsumerStatefulWidget {
  const ApaSheetBody({this.showClose = true, super.key});

  /// The 56 dp close button in the header; off where an app bar already has
  /// a back button (the `/apa` route).
  final bool showClose;

  @override
  ConsumerState<ApaSheetBody> createState() => _ApaSheetBodyState();
}

class _ApaSheetBodyState extends ConsumerState<ApaSheetBody> {
  final _input = TextEditingController();

  /// The transcript opens at offset 0, the first insight's top right under
  /// the header (opening scrolled to the end hid it behind the header on
  /// the phone); new turns after that scroll to the newest.
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  bool _showEnglish = false;

  /// "About the last call" was tapped with no flagged call.
  bool _noCallShown = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  ApaController get _controller => ref.read(apaControllerProvider.notifier);

  /// Leaves voice mode (when open) and puts the cursor in the text field
  /// once the chat body is back.
  Future<void> _typeInstead() async {
    if (ref.read(apaControllerProvider).inVoice) await _controller.endVoice();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  /// "About the last call": FNA reads the card when there is one, otherwise
  /// the chat says no call was caught yet.
  void _summary() {
    if (ref.read(apaControllerProvider).callSummary == null) {
      setState(() => _noCallShown = true);
      return;
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _controller.hearCallSummary();
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    _input.clear();
    ref.read(apaControllerProvider.notifier).sendText(text);
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    final motion = BhMotion.of(context);
    final end = _scroll.position.maxScrollExtent;
    if (motion.reduced) {
      _scroll.jumpTo(end);
    } else {
      _scroll.animateTo(end, duration: motion.normal, curve: BhCurves.enter);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(apaControllerProvider.select((s) => s.turns.length), (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    });
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final fna = ref.watch(fnaVoiceAgentEnabledProvider);
    final header = _Header(
      key: const Key('apa_sheet_header'),
      path: ref.watch(apaControllerProvider.select((s) => s.path)),
      showEnglish: _showEnglish,
      onToggleEnglish: (v) => setState(() => _showEnglish = v),
      onClose: widget.showClose ? () => Navigator.of(context).maybePop() : null,
    );
    // Voice mode changes state many times a second (captions, phases): the
    // sheet watches only what its own part shows there, the voice view
    // watches the rest field by field.
    if (fna && ref.watch(apaControllerProvider.select((s) => s.inVoice))) {
      final busy = ref.watch(apaControllerProvider.select((s) => s.busy));
      final hasCall = ref.watch(
        apaControllerProvider.select((s) => s.callSummary != null),
      );
      return Column(
        children: [
          header,
          Expanded(
            child: FnaVoiceView(
              onTypeInstead: _typeInstead,
              chips: _QuickActions(
                enabled: !busy,
                compact: true,
                onSummary: hasCall ? _controller.hearCallSummary : null,
              ),
            ),
          ),
        ],
      );
    }
    final state = ref.watch(apaControllerProvider);
    final summary = fna ? state.callSummary : null;
    final hasCard = summary != null;
    final fallback = fna ? state.voiceFallback : null;
    // Under the flag the fallback strip explains voice problems; the old
    // hint would say the same thing twice.
    final error = fallback != null && state.error != ApaHint.textFailed
        ? null
        : state.error;

    return LayoutBuilder(
      builder: (context, box) => Column(
        children: [
          header,
          Expanded(
            child: state.turns.isEmpty && !hasCard
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(BhSpace.l),
                      child: Text(
                        l10n.apaEmptyTranscript,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: BhSpace.m,
                      vertical: BhSpace.s,
                    ),
                    itemCount: state.turns.length + (hasCard ? 1 : 0),
                    // 8 dp between bubbles of one speaker, 16 between speakers
                    // and under the call summary card.
                    separatorBuilder: (_, j) {
                      final i = hasCard ? j - 1 : j;
                      return SizedBox(
                        height:
                            i >= 0 &&
                                state.turns[i].isApa == state.turns[i + 1].isApa
                            ? BhSpace.s
                            : BhSpace.m,
                      );
                    },
                    itemBuilder: (_, j) {
                      if (hasCard && j == 0) {
                        return FnaCallSummaryCard(
                          summary: summary,
                          nextTime: ref.watch(fnaCallSummaryNextTimeProvider),
                          hearing: state.hearingSummary,
                          onHear: _controller.hearCallSummary,
                          onCallHelpline: () => runApaActionInSheet(
                            context,
                            ref,
                            ApaAction.callHelpline,
                            inModal: widget.showClose,
                          ),
                        );
                      }
                      final i = hasCard ? j - 1 : j;
                      final turn = state.turns[i];
                      return _Bubble(
                        key: Key('apa_bubble_$i'),
                        turn: turn,
                        showOther: _showEnglish,
                        hearing: fna && identical(state.hearingTurn, turn),
                        onHear: fna && turn.isApa
                            ? () => _controller.hearIt(turn)
                            : null,
                        onAction: (a) => runApaActionInSheet(
                          context,
                          ref,
                          a,
                          inModal: widget.showClose,
                        ),
                      );
                    },
                  ),
          ),
          ..._extras(fna, box.maxHeight * _extrasShare, [
            if (state.busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: BhSpace.s),
                    Text(l10n.apaThinking, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            if (error != null)
              _Hint(
                text: _hintText(l10n, error),
                onDismiss: ref
                    .read(apaControllerProvider.notifier)
                    .dismissError,
              ),
            if (fallback != null) FnaFallbackStrip(reason: fallback),
            if (fna && _noCallShown && !hasCard)
              _NoCallStrip(
                onCheck: () {
                  setState(() => _noCallShown = false);
                  _controller.startScamCheck();
                },
                onDismiss: () => setState(() => _noCallShown = false),
              ),
            _QuickActions(
              enabled: !state.busy,
              // 2 x 2 tiles until the first question, then one row so the
              // transcript keeps the room.
              compact: state.turns.any((t) => !t.isApa),
              onSummary: fna ? _summary : null,
            ),
            if (state.scamCheck)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  BhSpace.m,
                  BhSpace.s,
                  BhSpace.m,
                  0,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.phone_in_talk_outlined,
                      color: context.palette.warning,
                    ),
                    const SizedBox(width: BhSpace.s),
                    Expanded(
                      child: Text(
                        l10n.apaQuickCodeAsked,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: context.palette.warning,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('apa_scam_cancel'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(BhSize.touch, BhSize.touch),
                      ),
                      onPressed: ref
                          .read(apaControllerProvider.notifier)
                          .cancelScamCheck,
                      child: Text(l10n.apaScamCancel),
                    ),
                  ],
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              BhSpace.m,
              BhSpace.s,
              BhSpace.m,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _send,
                    enabled: !state.busy,
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      hintText: state.scamCheck
                          ? l10n.apaScamInputHint
                          : l10n.apaTypeHint,
                    ),
                  ),
                ),
                const SizedBox(width: BhSpace.s),
                // Icon-only 56 dp tonal square; the word is its tooltip and
                // TalkBack label (the old icon-over-word overlapped).
                SizedBox(
                  width: BhSize.touch,
                  height: BhSize.touch,
                  child: Semantics(
                    button: true,
                    label: l10n.apaSend,
                    child: ExcludeSemantics(
                      child: Tooltip(
                        message: l10n.apaSend,
                        child: FilledButton.tonal(
                          key: const Key('apa_send'),
                          style: FilledButton.styleFrom(
                            shape: const RoundedRectangleBorder(),
                            minimumSize: const Size(BhSize.touch, BhSize.touch),
                            padding: EdgeInsets.zero,
                          ),
                          onPressed: state.busy
                              ? null
                              : () => _send(_input.text),
                          child: const Icon(Icons.send, size: 24),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The sheet runs under the gesture bar: below the 16 dp gutter add
          // the view's bottom safe inset (at least 8 dp) so the hold-to-talk
          // button never sits on the handle.
          Padding(
            key: const Key('apa_sheet_bottom_controls'),
            padding: EdgeInsets.fromLTRB(
              BhSpace.m,
              BhSpace.m,
              BhSpace.m,
              BhSpace.m +
                  math.max(MediaQuery.viewPaddingOf(context).bottom, BhSpace.s),
            ),
            child: fna
                ? FnaTalkButton(onTypeInstead: _typeInstead)
                : _HoldToTalkButton(
                    listening: state.listening,
                    liveAvailable: state.liveAvailable,
                  ),
          ),
        ],
      ),
    );
  }

  /// Share of the sheet height the strips and chips between the transcript
  /// and the text field may take under the flag.
  static const _extrasShare = 0.4;

  /// Under the flag the strips and chips scroll inside at most [maxHeight],
  /// so at large text the transcript and the text field always keep room.
  /// Flag off: the children as before.
  static List<Widget> _extras(
    bool bound,
    double maxHeight,
    List<Widget> children,
  ) {
    if (!bound || children.isEmpty || !maxHeight.isFinite) return children;
    return [
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          key: const Key('fna_chat_extras'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ];
  }

  static String _hintText(AppLocalizations l10n, String code) => switch (code) {
    ApaHint.liveUnavailable => l10n.apaLiveUnavailable,
    ApaHint.micDenied => l10n.apaMicDenied,
    ApaHint.textFailed => l10n.apaTextFailed,
    ApaHint.liveFailed => l10n.apaLiveFailed,
    _ => l10n.apaLiveUnavailable,
  };
}

/// The sheet header (11.4): row 1 (56 dp) is the
/// assistant's tile, "ফিননেস্ট সহকারী" with the role as a caption under it
/// (neither ever ellipsised) and a labelled 56 dp close button; row 2 carries
/// the live/text path pill on the left and the English toggle on the right,
/// both 36 dp square pills in the language toggle's style; then a 1 dp
/// divider. The header sits above the transcript, never over it.
class _Header extends StatelessWidget {
  const _Header({
    required this.path,
    super.key,
    required this.showEnglish,
    required this.onToggleEnglish,
    required this.onClose,
  });

  final String path;
  final bool showEnglish;
  final ValueChanged<bool> onToggleEnglish;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final live = path == ApaTurn.live;
    final gemini = path == ApaTurn.gemini;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final close = onClose;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: BhSize.touch),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              start: BhSpace.m,
              end: BhSpace.xs,
            ),
            child: Row(
              children: [
                const ApaTile(size: 32),
                const SizedBox(width: BhSpace.s),
                // The name, and the role as a smaller caption under it:
                // both whole, never ellipsised (the old one-line
                // "name · role" was cut beside "✕ বন্ধ").
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // One line, whole: scaled down a little rather
                        // than cut when a narrow phone meets a long name.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            l10n.apaSheetTitle,
                            maxLines: 1,
                            key: const Key('apa_sheet_title'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: p.onSurface,
                              height: 1.3,
                            ),
                          ),
                        ),
                        Text(
                          l10n.apaRoleCaption,
                          key: const Key('apa_sheet_role'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: p.mutedText,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (close != null)
                  TextButton.icon(
                    key: const Key('apa_close'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(BhSize.touch, BhSize.touch),
                      foregroundColor: p.primary,
                    ),
                    onPressed: close,
                    icon: const Icon(Icons.close, size: 24),
                    label: Text(l10n.close),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            BhSpace.m,
            0,
            BhSpace.m,
            BhSpace.xs,
          ),
          // A Wrap: at 360 dp in a large text size the chip and the toggle
          // may not fit side by side, and neither may be cut.
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: BhSpace.s,
            runSpacing: BhSpace.xs,
            children: [
              _Pill(
                key: const Key('apa_path_chip'),
                icon: live
                    ? Icons.graphic_eq
                    : (gemini
                          ? Icons.auto_awesome_outlined
                          : Icons.menu_book_outlined),
                label: live
                    ? l10n.apaPathLive
                    : (gemini ? l10n.apaPathGemini : l10n.apaPathGuide),
                fill: live ? p.successContainer : Colors.transparent,
                ink: live ? p.onSuccessContainer : p.onSurface,
              ),
              // In English the lines are already English; server lines
              // without an English text fall back to Bangla on their own.
              if (!english)
                _Pill(
                  key: const Key('apa_english_toggle'),
                  label: l10n.apaEnglishToggle,
                  fill: showEnglish ? p.primary : Colors.transparent,
                  ink: showEnglish ? p.onPrimary : p.primary,
                  selected: showEnglish,
                  onTap: () => onToggleEnglish(!showEnglish),
                ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: p.outlineVariant),
      ],
    );
  }
}

/// A 36 dp square pill in the language toggle's style (1 dp `outline`
/// hairline, `labelSmall`, selected = filled): the path status (no [onTap])
/// and the "other script" toggle (48 dp tap height).
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.fill,
    required this.ink,
    this.icon,
    this.selected = false,
    this.onTap,
    super.key,
  });

  static const height = 36.0;
  static const touchHeight = 48.0;

  final String label;
  final IconData? icon;
  final Color fill;
  final Color ink;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pill = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: BhSpace.m - BhSpace.xs),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: p.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: ink),
            const SizedBox(width: BhSpace.xs),
          ],
          Text(
            label,
            maxLines: 1,
            textScaler: MediaQuery.textScalerOf(context)
                .clamp(maxScaleFactor: 1.15),
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: ink, height: 1.2),
          ),
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) {
      return Semantics(
        label: label,
        child: ExcludeSemantics(child: pill),
      );
    }
    return Semantics(
      button: true,
      toggled: selected,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: tap,
            child: SizedBox(
              height: touchHeight,
              child: Center(widthFactor: 1, child: pill),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.turn,
    required this.showOther,
    required this.onAction,
    this.hearing = false,
    this.onHear,
    super.key,
  });

  final ApaTurn turn;

  /// This answer's "Hear it" is playing.
  final bool hearing;

  /// "Hear it" under an FNA answer; `null` hides it (flag off, own bubbles).
  final VoidCallback? onHear;

  /// Bangla app: also show the English line (the sheet's toggle).
  final bool showOther;
  final ValueChanged<ApaAction> onAction;

  /// Fill, stripe and text of an Apa bubble: the status container (dark
  /// tint in dark mode) for held and danger/caution lines, otherwise
  /// `surfaceVariant`.
  static (Color fill, Color? stripe, Color ink) _colours(
    BhPalette p,
    ApaTurn turn,
  ) {
    if (turn.path == ApaTurn.held) {
      return (p.warningContainer, p.warningFill, p.onWarningContainer);
    }
    return switch (turn.tone) {
      ApaSeverity.danger => (
        p.dangerContainer,
        p.dangerFill,
        p.onDangerContainer,
      ),
      ApaSeverity.caution => (
        p.warningContainer,
        p.warningFill,
        p.onWarningContainer,
      ),
      ApaSeverity.ok => (p.surfaceVariant, p.successFill, p.onSurface),
      ApaSeverity.info || null => (p.surfaceVariant, null, p.onSurface),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final l10n = context.l10n;
    final apa = turn.isApa;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final en = turn.textEn ?? '';
    // Server and guide lines alike: the app language's text, the other as
    // the fallback when one is empty.
    final main = pickServerText(
      Localizations.localeOf(context),
      turn.textBn,
      en,
    );
    final other = !english && showOther && en.isNotEmpty && en != main
        ? en
        : null;
    final (fill, stripe, apaInk) = _colours(p, turn);
    final background = apa ? fill : p.primaryContainer;
    final ink = apa ? apaInk : p.onPrimaryContainer;
    final action = turn.action;
    final source = apa ? turn.source : null;
    final hear = onHear;
    return Semantics(
      label: apa ? l10n.apaSheetTitle : l10n.apaYou,
      child: Align(
        alignment: apa ? Alignment.centerLeft : Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.85,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: BhSpace.m,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: background,
                  border: apa && stripe != null
                      ? Border(left: BorderSide(color: stripe, width: 4))
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      main,
                      style: theme.textTheme.bodyLarge?.copyWith(color: ink),
                    ),
                    if (other != null) ...[
                      const SizedBox(height: BhSpace.xs),
                      Text(
                        other,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ink.withValues(alpha: 0.8),
                          fontFamily: null,
                        ),
                      ),
                    ],
                    if (apa && action != ApaAction.none) ...[
                      const SizedBox(height: BhSpace.s),
                      OutlinedButton.icon(
                        key: Key('apa_bubble_action_${action.name}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.primary,
                          side: BorderSide(color: p.primary),
                          backgroundColor: p.surface,
                          minimumSize: const Size(BhSize.touch, BhSize.touch),
                        ),
                        onPressed: () => onAction(action),
                        icon: Icon(_actionIcon(action)),
                        label: Text(apaActionLabel(l10n, action)),
                      ),
                    ],
                  ],
                ),
              ),
              if (source != null)
                Padding(
                  padding: const EdgeInsets.only(top: BhSpace.xs),
                  child: Text(
                    apaSourceLabel(l10n, source),
                    key: Key('apa_source_${source.name}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: p.mutedText,
                    ),
                  ),
                ),
              if (hear != null)
                // TalkBack hears which answer the button reads, not a row of
                // identical "Hear it" buttons.
                Semantics(
                  container: true,
                  button: true,
                  label: hearing
                      ? l10n.fnaHearStopLabel(fnaHearPreview(main))
                      : l10n.fnaHearItLabel(fnaHearPreview(main)),
                  excludeSemantics: true,
                  child: TextButton.icon(
                    key: Key(hearing ? 'fna_hear_stop' : 'fna_hear'),
                    style: TextButton.styleFrom(
                      foregroundColor: p.primary,
                      minimumSize: const Size(BhSize.touch, BhSize.touch),
                      padding: const EdgeInsets.symmetric(
                        horizontal: BhSpace.s,
                      ),
                    ),
                    onPressed: hear,
                    icon: Icon(
                      hearing ? Icons.stop : Icons.volume_up_outlined,
                      size: 24,
                    ),
                    label: Text(hearing ? l10n.fnaHearStop : l10n.fnaHearIt),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The start of an answer for the "Hear it" TalkBack label: at most
/// [max] characters, cut at a word where possible, with an ellipsis.
String fnaHearPreview(String text, {int max = 40}) {
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length <= max) return t;
  final cut = t.substring(0, max);
  final space = cut.lastIndexOf(' ');
  return '${(space > max ~/ 2 ? cut.substring(0, space) : cut).trimRight()}…';
}

/// The provenance caption under an Apa bubble.
String apaSourceLabel(AppLocalizations l, ApaSource s) => switch (s) {
  ApaSource.server => l.apaSourceServer,
  ApaSource.phone => l.apaSourcePhone,
  ApaSource.signal => l.apaSourceSignal,
  ApaSource.scam => l.apaSourceScam,
  ApaSource.rules => l.apaSourceRules,
  ApaSource.ai => l.apaSourceAi,
};

IconData _actionIcon(ApaAction a) => switch (a) {
  ApaAction.openSafety => Icons.shield_outlined,
  ApaAction.openApaScamCheck => Icons.phone_in_talk_outlined,
  ApaAction.openApproveOrHeld => Icons.hourglass_top,
  ApaAction.learnRules => Icons.checklist,
  ApaAction.callHelpline => Icons.call,
  ApaAction.none => Icons.chat_bubble_outline,
};

class _Hint extends StatelessWidget {
  const _Hint({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    return Container(
      key: const Key('apa_hint'),
      margin: const EdgeInsets.fromLTRB(BhSpace.m, BhSpace.s, BhSpace.m, 0),
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.s,
        BhSpace.xs,
        BhSpace.s,
      ),
      color: p.warningContainer,
      child: Row(
        children: [
          Icon(Icons.info_outline, color: p.onWarningContainer),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: p.onWarningContainer,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: p.onWarningContainer,
              minimumSize: const Size(BhSize.touch, BhSize.touch),
            ),
            onPressed: onDismiss,
            child: Text(context.l10n.close),
          ),
        ],
      ),
    );
  }
}

/// "About the last call" with no flagged call yet: the empty line
/// and a button that starts the caller's-words check.
class _NoCallStrip extends StatelessWidget {
  const _NoCallStrip({required this.onCheck, required this.onDismiss});

  final VoidCallback onCheck;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final ink = p.onInfoContainer;
    return Container(
      key: const Key('fna_no_call'),
      margin: const EdgeInsets.fromLTRB(BhSpace.m, BhSpace.s, BhSpace.m, 0),
      padding: const EdgeInsets.all(BhSpace.s),
      color: p.infoContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: ink),
              const SizedBox(width: BhSpace.s),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.fnaNoCallYet,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: ink),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: BhSpace.s,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: ink,
                  minimumSize: const Size(BhSize.touch, BhSize.touch),
                ),
                onPressed: onDismiss,
                child: Text(l10n.close),
              ),
              TextButton.icon(
                key: const Key('fna_no_call_check'),
                style: TextButton.styleFrom(
                  foregroundColor: ink,
                  minimumSize: const Size(BhSize.touch, BhSize.touch),
                ),
                onPressed: onCheck,
                icon: const Icon(Icons.phone_in_talk_outlined),
                label: Text(l10n.apaQuickCodeAsked),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The four quick actions of the security hub. Outlined buttons rather than
/// Material chips so each one meets the 56 dp touch target from the theme.
class _QuickActions extends ConsumerWidget {
  const _QuickActions({
    required this.enabled,
    required this.compact,
    this.onSummary,
  });

  final bool enabled;
  final bool compact;

  /// "About the last call" as a fifth action; `null` hides it.
  final VoidCallback? onSummary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final controller = ref.read(apaControllerProvider.notifier);
    final actions = <(String, IconData, String, Future<void> Function())>[
      (
        'apa_quick_phone',
        Icons.shield_outlined,
        l10n.apaQuickPhoneSafe,
        controller.askPhoneSafe,
      ),
      (
        'apa_quick_held',
        Icons.hourglass_top,
        l10n.apaQuickWhyHeld,
        controller.askWhyHeld,
      ),
      (
        'apa_quick_code',
        Icons.phone_in_talk_outlined,
        l10n.apaQuickCodeAsked,
        controller.startScamCheck,
      ),
      (
        'apa_quick_rules',
        Icons.checklist,
        l10n.apaQuickRules,
        controller.showRules,
      ),
      if (onSummary case final summary?)
        (
          'apa_quick_summary',
          Icons.summarize_outlined,
          l10n.fnaQuickSummary,
          () async => summary(),
        ),
    ];
    Widget button((String, IconData, String, Future<void> Function()) a) {
      final (key, icon, label, run) = a;
      return OutlinedButton.icon(
        key: Key(key),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(BhSize.touch, BhSize.touch),
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.s),
        ),
        onPressed: enabled ? run : null,
        icon: Icon(icon),
        label: Text(label, maxLines: 2),
      );
    }

    final Widget body;
    if (compact) {
      body = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(BhSpace.m, BhSpace.s, BhSpace.m, 0),
        child: Row(
          children: [
            for (final (i, a) in actions.indexed) ...[
              if (i > 0) const SizedBox(width: BhSpace.s),
              button(a),
            ],
          ],
        ),
      );
    } else {
      Widget row(int from) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: button(actions[from])),
          const SizedBox(width: BhSpace.s),
          Expanded(child: button(actions[from + 1])),
        ],
      );
      body = Padding(
        padding: const EdgeInsets.fromLTRB(BhSpace.m, BhSpace.s, BhSpace.m, 0),
        child: Column(
          children: [
            IntrinsicHeight(child: row(0)),
            const SizedBox(height: BhSpace.s),
            IntrinsicHeight(child: row(2)),
            if (actions.length > 4) ...[
              const SizedBox(height: BhSpace.s),
              SizedBox(width: double.infinity, child: button(actions[4])),
            ],
          ],
        ),
      );
    }
    return Semantics(
      container: true,
      label: l10n.apaQuickActionsLabel,
      child: body,
    );
  }
}

class _HoldToTalkButton extends ConsumerWidget {
  const _HoldToTalkButton({
    required this.listening,
    required this.liveAvailable,
  });

  final bool listening;
  final bool liveAvailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final motion = BhMotion.of(context);
    final controller = ref.read(apaControllerProvider.notifier);

    // Red is reserved for hold and block: listening stays primary and shows
    // a pulsing ring instead.
    final Color background;
    final Color foreground;
    if (liveAvailable || listening) {
      background = p.primary;
      foreground = p.onPrimary;
    } else {
      background = p.surfaceVariant;
      foreground = p.mutedText;
    }

    final button = AnimatedContainer(
      duration: motion.fast,
      height: ApaSheet.holdButtonHeight,
      decoration: BoxDecoration(
        color: background,
        border: liveAvailable || listening
            ? null
            : Border.all(color: p.outline, width: 2),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            listening
                ? Icons.graphic_eq
                : (liveAvailable ? Icons.mic : Icons.mic_off_outlined),
            color: foreground,
            size: 32,
          ),
          const SizedBox(width: BhSpace.m),
          Flexible(
            child: Text(
              listening ? l10n.apaListening : l10n.apaHoldToTalk,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: liveAvailable,
      label: listening ? l10n.apaListening : l10n.apaHoldToTalk,
      child: GestureDetector(
        key: const Key('apa_hold_to_talk'),
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) => controller.holdStart(),
        onLongPressEnd: (_) => controller.holdEnd(),
        onLongPressCancel: controller.holdEnd,
        // A short tap on a disabled button still explains why (hint).
        onTap: liveAvailable ? null : controller.holdStart,
        child: listening && !motion.reduced
            ? _PulseRing(color: p.accent, child: button)
            : button,
      ),
    );
  }
}

/// Two rings breathing out from the button while Apa listens (6.2:
/// `pulse`, 1.0 to 1.15 scale, 40 % to 0 % opacity). Only built while
/// listening and never with reduce motion.
class _PulseRing extends StatefulWidget {
  const _PulseRing({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: BhMotion.standard.pulse,
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        Widget ring(double phase) {
          final t = BhCurves.pulse.transform((_c.value + phase) % 1.0);
          return Positioned.fill(
            child: IgnorePointer(
              child: Transform.scale(
                scaleX: 1 + 0.04 * t,
                scaleY: 1 + 0.15 * t,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: widget.color.withValues(alpha: 0.4 * (1 - t)),
                      width: 3,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [child!, ring(0), ring(0.5)],
        );
      },
    );
  }
}
