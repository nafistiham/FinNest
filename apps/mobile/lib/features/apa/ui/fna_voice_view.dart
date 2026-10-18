/// FNA voice mode: shown in place of the chat body
/// while `ApaState.inVoice`. A permanent PIN strip, the FNA tile in one square
/// shape per state, a state label announced as a live region, both captions,
/// the hidden-number warning, one row of topic chips and the controls.
library;

import 'dart:async';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/ui/widgets/fna_state_tile.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FnaVoiceView extends ConsumerStatefulWidget {
  const FnaVoiceView({required this.onTypeInstead, this.chips, super.key});

  /// Text scale from which the tile shrinks to 72 dp and the chips hide while
  /// FNA listens.
  static const largeText = 1.3;

  /// "Type instead": the host ends voice mode and focuses its text field.
  final VoidCallback onTypeInstead;

  /// One row of topic chips (the chat's quick actions), or `null`.
  final Widget? chips;

  @override
  ConsumerState<FnaVoiceView> createState() => _FnaVoiceViewState();
}

class _FnaVoiceViewState extends ConsumerState<FnaVoiceView> {
  late final ApaController _controller = ref.read(
    apaControllerProvider.notifier,
  );
  late final AppLifecycleListener _lifecycle;

  /// The app is hidden or paused (not just inactive).
  bool _appHidden = false;

  /// Another in-app route (a screen, a dialog) covers voice mode: the view
  /// stays mounted, so the mic must close as when the app is hidden.
  bool _routeCovered = false;

  /// What the controller was last told ([_syncHidden]).
  bool _hiddenSent = false;

  /// The hidden-number warning stays up this long after it appears, even
  /// when the next caption clears `secretBlocked`.
  static const warningHold = Duration(seconds: 5);
  Timer? _warningTimer;
  bool _warningHeld = false;

  @override
  void initState() {
    super.initState();
    // `hidden` and `paused` close the microphone; `inactive` (a system
    // dialog, the notification shade) does not. Back on screen after a
    // hide, the controller may open it again.
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        switch (s) {
          case AppLifecycleState.hidden || AppLifecycleState.paused:
            _appHidden = true;
          case AppLifecycleState.resumed:
            _appHidden = false;
          case AppLifecycleState.inactive || AppLifecycleState.detached:
            return;
        }
        _syncHidden();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rebuilt when a route is pushed over this one or popped off it.
    final covered = ModalRoute.isCurrentOf(context) == false;
    if (covered == _routeCovered) return;
    _routeCovered = covered;
    // Not during the build: the controller may change its state.
    scheduleMicrotask(_syncHidden);
  }

  /// Tells the controller once per change: hidden when the app is in the
  /// background or another route covers voice mode. Back in view, voice
  /// mode stays paused until the customer resumes it.
  void _syncHidden() {
    final hidden = _appHidden || _routeCovered;
    if (hidden == _hiddenSent) return;
    _hiddenSent = hidden;
    if (hidden) {
      _controller.onAppHidden();
    } else {
      _controller.onAppVisible();
    }
  }

  @override
  void dispose() {
    _warningTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _holdWarning() {
    _warningTimer?.cancel();
    setState(() => _warningHeld = true);
    _warningTimer = Timer(warningHold, () {
      if (mounted) setState(() => _warningHeld = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(apaControllerProvider.select((s) => s.secretBlocked), (
      was,
      now,
    ) {
      if (now && was != true) {
        HapticFeedback.heavyImpact();
        _holdWarning();
      }
    });
    // Only the fields this view shows: captions rebuild on their own
    // ([FnaCaptions]) and the microphone level only moves the bars.
    final phase =
        ref.watch(apaControllerProvider.select((s) => s.voicePhase)) ??
        FnaPhase.connecting;
    final fallback = ref.watch(
      apaControllerProvider.select((s) => s.voiceFallback),
    );
    final secretBlocked = ref.watch(
      apaControllerProvider.select((s) => s.secretBlocked),
    );
    final visual = fnaVisualOf(phase);
    final l10n = context.l10n;
    final largeText =
        MediaQuery.textScalerOf(context).scale(10) / 10 >=
        FnaVoiceView.largeText;
    final chips = widget.chips;
    final showChips =
        chips != null && !(largeText && visual == FnaVisual.listening);

    return Column(
      key: const Key('fna_voice_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Strip(
          key: const Key('fna_pin_strip'),
          icon: Icons.shield_outlined,
          text: l10n.fnaPinStrip,
          warning: false,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: BhSpace.m,
              vertical: BhSpace.l,
            ),
            child: Column(
              children: [
                _TileButton(
                  visual: visual,
                  level: _controller.micLevel,
                  size: largeText ? FnaStateTile.compact : FnaStateTile.regular,
                  onResume: visual == FnaVisual.paused
                      ? _controller.resumeVoice
                      : null,
                ),
                const SizedBox(height: BhSpace.m),
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Text(
                    _label(l10n, phase, fallback),
                    key: const Key('fna_state_label'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: BhSpace.l),
                const FnaCaptions(),
                if (secretBlocked || _warningHeld) ...[
                  const SizedBox(height: BhSpace.m),
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: _Strip(
                      key: const Key('fna_secret_blocked'),
                      icon: Icons.visibility_off_outlined,
                      text: l10n.fnaNumberHidden,
                      warning: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showChips) chips,
        _Controls(
          visual: visual,
          onStop: _controller.stopSpeaking,
          onPause: _controller.pauseVoice,
          onResume: _controller.resumeVoice,
          onTypeInstead: widget.onTypeInstead,
          onEnd: _controller.endVoice,
        ),
      ],
    );
  }

  static String _label(
    AppLocalizations l,
    FnaPhase phase,
    FnaFallbackReason? fallback,
  ) => switch (fnaVisualOf(phase)) {
    FnaVisual.connecting => l.fnaStateConnecting,
    FnaVisual.listening => l.fnaStateListening,
    FnaVisual.thinking => l.fnaStateThinking,
    FnaVisual.speaking => l.fnaStateSpeaking,
    FnaVisual.paused => l.fnaStatePaused,
    FnaVisual.problem =>
      phase == FnaPhase.offline || fallback == FnaFallbackReason.offline
          ? l.fnaOffline
          : l.fnaVoiceDown,
  };
}

/// The tile; while paused it is the "tap to talk" target (also the turn
/// start in tap-to-talk mode, where the controller pauses after each
/// answer).
class _TileButton extends StatelessWidget {
  const _TileButton({
    required this.visual,
    required this.level,
    required this.size,
    required this.onResume,
  });

  final FnaVisual visual;
  final ValueListenable<double> level;
  final double size;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final tile = FnaStateTile(visual: visual, level: level, size: size);
    final resume = onResume;
    if (resume == null) return tile;
    return Semantics(
      button: true,
      label: context.l10n.fnaResume,
      child: InkWell(
        key: const Key('fna_tile_resume'),
        onTap: resume,
        child: tile,
      ),
    );
  }
}

/// The customer's caption (2 lines, muted) above FNA's (3 lines). Both
/// `bodyLarge` and scaled with the text size. A long FNA caption opens in
/// full with a tap on it or on "Show all". Watches only the two captions.
class FnaCaptions extends ConsumerStatefulWidget {
  const FnaCaptions({super.key});

  /// Builds so far; tests check the microphone level never rebuilds this.
  @visibleForTesting
  static int debugBuilds = 0;

  static const userLines = 2;
  static const fnaLines = 3;

  @override
  ConsumerState<FnaCaptions> createState() => _FnaCaptionsState();
}

class _FnaCaptionsState extends ConsumerState<FnaCaptions> {
  bool _expanded = false;
  String _shownFna = '';

  @override
  Widget build(BuildContext context) {
    FnaCaptions.debugBuilds++;
    final user = ref.watch(apaControllerProvider.select((s) => s.userCaption));
    final fna = ref.watch(apaControllerProvider.select((s) => s.modelCaption));
    // A new answer opens folded again.
    if (fna != _shownFna) {
      _shownFna = fna;
      _expanded = false;
    }
    final theme = Theme.of(context);
    final p = context.palette;
    final l10n = context.l10n;
    final fnaStyle = theme.textTheme.bodyLarge?.copyWith(color: p.onSurface);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (user.isNotEmpty)
          Semantics(
            label: l10n.apaYou,
            child: Text(
              user,
              key: const Key('fna_caption_user'),
              maxLines: FnaCaptions.userLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(color: p.mutedText),
            ),
          ),
        if (user.isNotEmpty && fna.isNotEmpty)
          const SizedBox(height: BhSpace.s),
        if (fna.isNotEmpty)
          LayoutBuilder(
            builder: (context, box) {
              final painter = TextPainter(
                text: TextSpan(text: fna, style: fnaStyle),
                maxLines: FnaCaptions.fnaLines,
                textAlign: TextAlign.center,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: box.maxWidth);
              final long = painter.didExceedMaxLines;
              painter.dispose();
              final text = Text(
                fna,
                key: const Key('fna_caption_fna'),
                maxLines: _expanded ? null : FnaCaptions.fnaLines,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: fnaStyle,
              );
              if (!long) {
                return Semantics(label: l10n.apaSheetTitle, child: text);
              }
              void toggle() => setState(() => _expanded = !_expanded);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    label: l10n.apaSheetTitle,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: toggle,
                      child: text,
                    ),
                  ),
                  Center(
                    child: TextButton(
                      key: const Key('fna_caption_toggle'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(BhSize.touch, BhSize.touch),
                      ),
                      onPressed: toggle,
                      child: Text(
                        _expanded ? l10n.fnaShowLess : l10n.fnaShowAll,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// A full-width square strip: the info container for the PIN rule, the
/// warning (amber) container for the hidden number.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.icon,
    required this.text,
    required this.warning,
    super.key,
  });

  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fill = warning ? p.warningContainer : p.infoContainer;
    final ink = warning ? p.onWarningContainer : p.onInfoContainer;
    return Container(
      color: fill,
      padding: const EdgeInsets.symmetric(
        horizontal: BhSpace.m,
        vertical: BhSpace.s,
      ),
      child: Row(
        children: [
          Icon(icon, color: ink),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stop (only while FNA speaks), Pause or Resume, Type instead, End: icon
/// over the word, at least 56 dp.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.visual,
    required this.onStop,
    required this.onPause,
    required this.onResume,
    required this.onTypeInstead,
    required this.onEnd,
  });

  final FnaVisual visual;
  final VoidCallback onStop;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onTypeInstead;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final paused = visual == FnaVisual.paused;
    final canPause =
        visual == FnaVisual.listening ||
        visual == FnaVisual.thinking ||
        visual == FnaVisual.speaking;
    return Semantics(
      container: true,
      label: l10n.fnaVoiceControls,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          BhSpace.m,
          BhSpace.s,
          BhSpace.m,
          BhSpace.m + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (visual == FnaVisual.speaking) ...[
                Expanded(
                  child: _ControlButton(
                    key: const Key('fna_stop'),
                    icon: Icons.stop,
                    label: l10n.fnaStop,
                    onTap: onStop,
                    filled: true,
                  ),
                ),
                const SizedBox(width: BhSpace.s),
              ],
              Expanded(
                child: paused
                    ? _ControlButton(
                        key: const Key('fna_resume'),
                        icon: Icons.play_arrow,
                        label: l10n.fnaResume,
                        onTap: onResume,
                        filled: true,
                      )
                    : _ControlButton(
                        key: const Key('fna_pause'),
                        icon: Icons.pause,
                        label: l10n.fnaPause,
                        onTap: canPause ? onPause : null,
                      ),
              ),
              const SizedBox(width: BhSpace.s),
              Expanded(
                child: _ControlButton(
                  key: const Key('fna_type_instead'),
                  icon: Icons.keyboard_outlined,
                  label: l10n.fnaTypeInstead,
                  onTap: onTypeInstead,
                ),
              ),
              const SizedBox(width: BhSpace.s),
              Expanded(
                child: _ControlButton(
                  key: const Key('fna_end'),
                  icon: Icons.close,
                  label: l10n.fnaEnd,
                  onTap: onEnd,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 24),
        const SizedBox(height: BhSpace.xxs),
        Text(label, maxLines: 2, textAlign: TextAlign.center),
      ],
    );
    const style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(BhSize.touch, BhSize.touch)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: BhSpace.xs, vertical: BhSpace.s),
      ),
    );
    return filled
        ? FilledButton(style: style, onPressed: onTap, child: content)
        : OutlinedButton(style: style, onPressed: onTap, child: content);
  }
}
