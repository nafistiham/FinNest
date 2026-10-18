import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/apa/logic/apa_held_score.dart';
import '../../features/apa/logic/apa_insights.dart';
import '../../features/apa/logic/apa_insights_provider.dart';
import '../../features/apa/ui/apa_sheet.dart';
import '../../features/apa/voice/fna_providers.dart';
import '../l10n.dart';
import '../theme/theme.dart';

/// The bottom bar: 56 dp content + 8 top + 16 bottom +
/// the system inset, on `surface`. Either the screen's one primary action
/// with a 56 dp square Apa button beside it, or ([BhBottomBar.apa]) the
/// full-width [ApaBar] alone (Home, recipient steps, History).
///
/// Use as `Scaffold.bottomNavigationBar`; the bar handles its own padding
/// and the system inset. [showTopBorder] draws the 1 dp `outlineVariant`
/// line (fades in over `fast`); the screen sets it while content scrolls
/// under the bar.
class BhBottomBar extends StatelessWidget {
  const BhBottomBar({
    required Widget this.primary,
    required this.apaScreen,
    this.secondary,
    this.hint,
    this.footer,
    this.showTopBorder = false,
    this.apaThen,
    super.key,
  }) : apaStyle = null;

  /// Only the full-width Apa bar.
  const BhBottomBar.apa({
    required this.apaScreen,
    ApaBarStyle style = ApaBarStyle.primary,
    this.showTopBorder = false,
    super.key,
  }) : primary = null,
       secondary = null,
       hint = null,
       footer = null,
       apaThen = null,
       apaStyle = style;

  /// The 56 dp primary button (a `BhButton`).
  final Widget? primary;

  /// Optional second button stacked above the primary row (8 dp gap).
  final Widget? secondary;

  /// `ApaContext.screen` for turns asked from this screen.
  final String apaScreen;

  /// Legacy line under the primary row. New screens put the reason in the
  /// disabled primary's label instead (2.2).
  final String? hint;

  /// Optional widget under the primary row, e.g. Login's "log in with
  /// password" text button.
  final Widget? footer;

  final bool showTopBorder;

  /// Set by [BhBottomBar.apa].
  final ApaBarStyle? apaStyle;

  /// What the Apa square runs once the sheet is open (Login: the rules).
  final ApaAction? apaThen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final motion = BhMotion.of(context);
    final Widget content = primary == null
        ? ApaBar(screen: apaScreen, style: apaStyle ?? ApaBarStyle.primary)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (secondary != null) ...[
                secondary!,
                const SizedBox(height: BhSpace.s),
              ],
              // The square stretches to the primary's height, so a two-line
              // label (the biometric login) never leaves it shorter.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: primary!),
                    const SizedBox(width: BhSpace.s),
                    ApaSquareButton(screen: apaScreen, then: apaThen),
                  ],
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: BhSpace.xs),
                Text(
                  hint!,
                  key: const Key('bottom_bar_hint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (footer != null) ...[
                const SizedBox(height: BhSpace.xs),
                footer!,
              ],
            ],
          );
    return Material(
      color: p.surface,
      child: AnimatedContainer(
        duration: motion.fast,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: showTopBorder
                  ? p.outlineVariant
                  : p.outlineVariant.withValues(alpha: 0),
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              BhSpace.m,
              BhSpace.s,
              BhSpace.m,
              BhSpace.m,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

enum ApaBarStyle {
  /// Home: `primaryContainer` fill.
  primary,

  /// Pay step 1, History: 1 dp `outline` border, transparent fill.
  secondary,
}

/// Opens the Apa sheet from [screen], seeded with the held score and the
/// current top insight.
Future<void> openApaFrom(BuildContext context, WidgetRef ref, String screen) {
  // ApaSheet.show fires the light haptic itself.
  final insights = ref.read(apaInsightsProvider);
  return ApaSheet.show(
    context,
    held: ref.read(apaHeldScoreProvider),
    screen: screen,
    insight: insights.isEmpty ? null : insights.first,
    others: insights.length > 1 ? insights.sublist(1) : const [],
  );
}

/// The full-width 56 dp "এফএনএ-কে জিজ্ঞাসা করুন" bar (7.11) with a mic
/// icon; a chat bubble with `AppEnv.fnaVoiceAgent`, since it opens the chat
/// first. While the top insight needs attention (`ApaSeverity.danger` or
/// `caution`) the semantics label adds "নতুন সতর্কতা আছে"; the bar itself
/// stays plain (no trailing status dot: the security card
/// above already carries the colour).
class ApaBar extends ConsumerWidget {
  const ApaBar({
    required this.screen,
    this.style = ApaBarStyle.primary,
    super.key,
  });

  final String screen;
  final ApaBarStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final l10n = context.l10n;
    final alert = ref.watch(
      apaInsightsProvider.select(
        (l) => switch (l.firstOrNull?.severity) {
          ApaSeverity.danger || ApaSeverity.caution => true,
          _ => false,
        },
      ),
    );
    final chat = ref.watch(fnaVoiceAgentEnabledProvider);
    final filled = style == ApaBarStyle.primary;
    final ink = filled ? p.onPrimaryContainer : p.primary;
    return Semantics(
      button: true,
      label: alert ? '${l10n.apaAsk}, ${l10n.apaNewAlert}' : l10n.apaAsk,
      child: ExcludeSemantics(
        child: Material(
          key: Key('apa_bar_$screen'),
          color: filled ? p.primaryContainer : Colors.transparent,
          shape: filled
              ? const RoundedRectangleBorder()
              : RoundedRectangleBorder(side: BorderSide(color: p.outline)),
          child: InkWell(
            onTap: () => openApaFrom(context, ref, screen),
            child: SizedBox(
              height: BhSize.touch,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      chat ? Icons.chat_bubble_outline : Icons.mic_none,
                      key: Key(chat ? 'apa_bar_icon_chat' : 'apa_bar_icon_mic'),
                      size: 24,
                      color: ink,
                    ),
                    const SizedBox(width: BhSpace.s),
                    Flexible(
                      child: Text(
                        l10n.apaAsk,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(color: ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 56 dp square button with the mic-voice icon above "এফএনএ" (7.11), fill
/// `primaryContainer`; opens the Apa sheet seeded with the last score. At
/// least 56 dp tall; in a stretched row it matches the primary beside it.
class ApaSquareButton extends ConsumerWidget {
  const ApaSquareButton({required this.screen, this.then, super.key});

  final String screen;

  /// Run inside the sheet once it is open (e.g. `ApaAction.learnRules`).
  final ApaAction? then;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: l10n.askApa,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: BhSize.touch,
            maxWidth: BhSize.touch,
            minHeight: BhSize.touch,
          ),
          child: Material(
            key: Key('apa_button_$screen'),
            color: p.primaryContainer,
            child: InkWell(
              onTap: () => ApaSheet.show(
                context,
                held: ref.read(apaHeldScoreProvider),
                screen: screen,
                then: then,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.record_voice_over_outlined,
                    color: p.onPrimaryContainer,
                    size: 24,
                  ),
                  // "এফএনএ" is wider than the 56 dp square: one line,
                  // scaled down only as far as it needs (a mark, not body).
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        l10n.apa,
                        maxLines: 1,
                        textScaler: TextScaler.noScaling,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: p.onPrimaryContainer,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
