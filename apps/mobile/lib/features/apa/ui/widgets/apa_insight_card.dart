/// Home's one security card (11.3): the phone-safety
/// status row on top (verdict, and the "সিমুলেটেড" tag pinned to the card's
/// trailing padding line), then "আপা বলছে" and the single most important
/// thing Apa wants the customer to know right now (the top of
/// `apaInsightsProvider`) with its source and one action.
///
/// Tapping the status row opens `/safety` (or retries a failed check);
/// tapping Apa's part opens the Apa sheet with that insight as the first
/// bubble; the button runs the insight's action.
library;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bh_button.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/features/apa/logic/apa_held_score.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/ui/apa_actions.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_tile.dart';
import 'package:bhorosha/features/safety/logic/external_links.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_status_row.dart';
import 'package:bhorosha/features/safety/ui/widgets/verdict_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ApaInsightCard extends ConsumerWidget {
  const ApaInsightCard({
    super.key,
    this.screen = 'home',
    this.withoutHeld = false,
  });

  /// `ApaContext.screen` of the sheet this card opens.
  final String screen;

  /// Home's pending-intervention card is on screen and already says the
  /// money is held: skip `held_transfer` / `call_transfer` and show the next
  /// insight (the FNA sheet keeps them).
  final bool withoutHeld;

  /// Apa's tile beside "আপা বলছে"; the title, body and source are indented
  /// by the tile plus 8 dp.
  static const tileSize = 32.0;
  static const indent = tileSize + BhSpace.s;

  /// Lines of the body on Home; the whole text is the sheet's first bubble.
  static const bodyLines = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only what the card draws (top, the tip, the count), so a new list with
    // the same content does not rebuild the card (ApaInsight has `==`).
    final (top, tip, more) = ref.watch(
      apaCardInsightsProvider(withoutHeld).select(_cardFacts),
    );
    final checking = ref.watch(
      apaSnapshotProvider.select((s) => s.safetyChecking),
    );
    // Nothing urgent yet and the phone check is still running: wait for it
    // rather than say "not checked".
    final loading =
        checking &&
        (top == null ||
            top.severity == ApaSeverity.info ||
            top.severity == ApaSeverity.ok);
    final motion = BhMotion.of(context);
    final Widget child;
    if (loading) {
      child = const _LoadingCard(key: ValueKey('loading'));
    } else if (top == null) {
      child = _EmptyCard(key: const ValueKey('empty'), screen: screen);
    } else {
      child = _InsightCardBody(
        key: ValueKey(top.id),
        insight: top,
        tip: tip,
        more: more,
        screen: screen,
      );
    }
    // When the insight changes kind: a 150 ms cross-fade (instant with
    // reduce motion).
    return AnimatedSwitcher(
      duration: motion.fast,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      child: child,
    );
  }
}

/// The top insight, the tip shown under an all-clear, and how many other
/// danger/caution items the footer counts.
(ApaInsight?, ApaInsight?, int) _cardFacts(List<ApaInsight> insights) {
  final top = insights.firstOrNull;
  final tip = top != null && top.id == 'all_clear' && insights.length > 1
      ? insights[1]
      : null;
  final more = insights
      .skip(1)
      .where(
        (i) =>
            i.severity == ApaSeverity.danger ||
            i.severity == ApaSeverity.caution,
      )
      .length;
  return (top, tip, more);
}

Future<void> _openSheet(
  BuildContext context,
  WidgetRef ref,
  String screen, {
  ApaInsight? insight,
  ApaAction? then,
  bool others = false,
}) => ApaSheet.show(
  context,
  held: ref.read(apaHeldScoreProvider),
  screen: screen,
  insight: insight,
  then: then,
  others: others
      ? ref
            .read(apaInsightsProvider)
            .where((i) => i.id != insight?.id)
            .where(
              (i) =>
                  i.severity == ApaSeverity.danger ||
                  i.severity == ApaSeverity.caution,
            )
            .toList()
      : const [],
);

/// Colours of the card by insight severity: soft status container for
/// danger and caution (dark tints in dark mode), `surfaceVariant` otherwise.
({Color fill, Color stripe, Color title, Color body, BhStatus? status})
_colours(BhPalette p, ApaSeverity severity) {
  final status = switch (severity) {
    ApaSeverity.danger => BhStatus.danger,
    ApaSeverity.caution => BhStatus.warning,
    ApaSeverity.ok => BhStatus.success,
    ApaSeverity.info => BhStatus.info,
  };
  final loud =
      severity == ApaSeverity.danger || severity == ApaSeverity.caution;
  return (
    fill: loud ? p.statusContainer(status) : p.surfaceVariant,
    stripe: p.statusFill(status),
    title: loud ? p.statusText(status) : p.onSurface,
    body: loud ? p.onStatusContainer(status) : p.onSurface,
    status: loud ? status : null,
  );
}

/// The phone-safety status row, from the same state the insights use.
class _StatusRow extends ConsumerWidget {
  const _StatusRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Verdict and checking only: the row must not redraw on a balance tick.
    final (verdict, checking) = ref.watch(
      apaSnapshotProvider.select((s) => (s.verdict, s.safetyChecking)),
    );
    final safety = ref.watch(safetyControllerProvider);
    final failed = safety.hasError && !safety.isLoading;
    return SafetyStatusRow(
      key: const Key('apa_insight_status_row'),
      verdict: verdict,
      checking: checking,
      failed: failed,
      simulated: safety.value?.simulatedVerdict ?? false,
      onTap: failed && verdict == null
          ? () => ref.read(safetyControllerProvider.notifier).refresh()
          : () => apaNavigate(context, apaSafetyRoute, inModal: false),
    );
  }
}

/// Danger / caution header: "[shield-off] এফএনএ: বিপদ" (or "[⚠] এফএনএ:
/// সাবধান") in the status text colour, the "সিমুলেটেড" tag at the trailing
/// edge as on [SafetyStatusRow]. Same 40 dp height as the status row.
class _SeverityHeader extends ConsumerWidget {
  const _SeverityHeader({required this.severity});

  final ApaSeverity severity;

  static const iconSize = 24.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final danger = severity == ApaSeverity.danger;
    final status = danger ? BhStatus.danger : BhStatus.warning;
    final ink = p.statusText(status);
    final word = danger ? l10n.apaSeverityDanger : l10n.apaSeverityCaution;
    final simulated = ref.watch(
      safetyControllerProvider.select(
        (s) => s.value?.simulatedVerdict ?? false,
      ),
    );
    return ConstrainedBox(
      key: const Key('apa_insight_severity_header'),
      constraints: const BoxConstraints(minHeight: SafetyStatusRow.height),
      child: Row(
        children: [
          Icon(
            danger
                ? Icons.remove_moderator_outlined
                : Icons.warning_amber_rounded,
            key: const Key('apa_insight_header_icon'),
            size: iconSize,
            color: ink,
          ),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Text(
              l10n.apaHeaderSeverity(word),
              key: const Key('apa_insight_header_text'),
              style: text.titleSmall?.copyWith(color: ink),
            ),
          ),
          if (simulated) ...[
            const SizedBox(width: BhSpace.s),
            StatusTag(
              key: SafetyStatusRow.tagKey,
              label: l10n.safetySimulatedTag,
              status: BhStatus.info,
            ),
          ],
        ],
      ),
    );
  }
}

/// Under a danger / caution body: "ফোনের নিরাপত্তা: নিরাপদ · সিমুলেটেড" on one
/// line, muted, with the verdict colour on the verdict word only, so the
/// phone check stays visible without contradicting the header.
class _PhoneCaption extends ConsumerWidget {
  const _PhoneCaption();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final (verdict, checking) = ref.watch(
      apaSnapshotProvider.select((s) => (s.verdict, s.safetyChecking)),
    );
    final safety = ref.watch(safetyControllerProvider);
    final failed = safety.hasError && !safety.isLoading;
    final simulated = safety.value?.simulatedVerdict ?? false;
    final style = verdict == null ? null : VerdictStyle.of(context, verdict);
    final word =
        style?.label ??
        (checking
            ? l10n.safetyChecking
            : failed
            ? l10n.safetyCheckFailedShort
            : l10n.safetyNotCheckedShort);
    final ink = style == null ? p.mutedText : p.statusText(style.status);
    final base = text.bodySmall?.copyWith(color: p.mutedText);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: ApaInsightCard.indent,
        top: BhSpace.xxs,
      ),
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: '${l10n.safetyCaptionPrefix} '),
            TextSpan(
              text: word,
              style: base?.copyWith(color: ink),
            ),
            if (simulated) TextSpan(text: ' · ${l10n.safetySimulatedTag}'),
          ],
        ),
        key: const Key('apa_insight_phone_caption'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// The card frame: fill, 4 dp leading stripe, 16 dp padding (the stripe
/// sits inside the leading padding, so the content's left and right edges
/// are both 16 dp in).
class _Frame extends StatelessWidget {
  const _Frame({
    required this.fill,
    required this.stripe,
    required this.children,
    this.materialKey,
    this.compact = false,
    this.severity,
  });

  final Color fill;
  final Color stripe;
  final List<Widget> children;
  final Key? materialKey;

  /// Calm and caution states: tighter vertical padding so the feature grid
  /// stays on the first screen at 412 x 915.
  final bool compact;

  /// The top insight's severity: danger and caution lead the header with
  /// it ([_SeverityHeader]) instead of the phone-safety row, which would
  /// otherwise say "নিরাপদ" in green on a red card.
  final ApaSeverity? severity;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final loud =
        severity == ApaSeverity.danger || severity == ApaSeverity.caution;
    return Material(
      key: materialKey,
      color: fill,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: stripe, width: BhSize.stripe),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          BhSpace.m - BhSize.stripe,
          compact ? BhSpace.xs : BhSpace.s,
          BhSpace.m,
          compact ? BhSpace.xs : BhSpace.m,
        ),
        child: Column(
          key: const Key('apa_insight_content'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The 40 dp status row carries its own breathing room.
            if (loud)
              _SeverityHeader(severity: severity!)
            else
              const _StatusRow(),
            Padding(
              padding: const EdgeInsets.only(bottom: BhSpace.s),
              child: Divider(height: 1, thickness: 1, color: p.outlineVariant),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InsightCardBody extends ConsumerWidget {
  const _InsightCardBody({
    required this.insight,
    required this.tip,
    required this.more,
    required this.screen,
    super.key,
  });

  final ApaInsight insight;
  final ApaInsight? tip;

  /// Further active danger/caution insights (the sheet lists them).
  final int more;
  final String screen;

  Future<void> _act(BuildContext context, WidgetRef ref) async {
    switch (insight.action) {
      case ApaAction.openSafety:
        apaNavigate(context, apaSafetyRoute, inModal: false);
      case ApaAction.openApproveOrHeld:
        final approve = apaApproveLocation(ref);
        if (approve != null) {
          apaNavigate(context, approve, inModal: false);
        } else {
          await _openSheet(
            context,
            ref,
            screen,
            insight: insight,
            then: ApaAction.openApproveOrHeld,
          );
        }
      case ApaAction.callHelpline:
        await ExternalLinks.callBank(ref.read(uriLauncherProvider));
      case ApaAction.openApaScamCheck:
      case ApaAction.learnRules:
        await _openSheet(
          context,
          ref,
          screen,
          insight: insight,
          then: insight.action,
        );
      case ApaAction.none:
        await _openSheet(context, ref, screen, insight: insight);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final p = context.palette;
    final l10n = context.l10n;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final c = _colours(p, insight.severity);
    final (IconData icon, String label) = switch (insight.severity) {
      ApaSeverity.danger => (Icons.gpp_bad_outlined, l10n.apaSeverityDanger),
      ApaSeverity.caution => (
        Icons.warning_amber_rounded,
        l10n.apaSeverityCaution,
      ),
      ApaSeverity.ok => (Icons.verified_user_outlined, l10n.apaSeverityOk),
      ApaSeverity.info => (Icons.lightbulb_outline, l10n.apaSeverityInfo),
    };
    final title = insight.title(english);
    final shown = tip ?? insight;
    final body = shown.body(english);
    final source = apaSourceLabel(l10n, shown.source);
    final urgent = insight.severity == ApaSeverity.danger;
    final semantics = [
      l10n.apaSays,
      if (c.status != null) label,
      title,
      body,
      source,
    ].where((s) => s.isNotEmpty).join(': ');
    void openSheet() => _openSheet(context, ref, screen, insight: insight);

    // Calm and caution states collapse to the compact form so the feature
    // grid stays on the first screen at 412 x 915; only danger stays tall.
    if (!urgent) {
      return _calm(
        context,
        ref,
        c: c,
        title: title,
        body: body,
        semantics: semantics,
        onOpen: openSheet,
        actionLabel: insight.actionLabel(english),
        severityIcon: icon,
        severityLabel: label,
      );
    }

    return _Frame(
      materialKey: Key('apa_insight_card_${insight.id}'),
      fill: c.fill,
      stripe: c.stripe,
      severity: insight.severity,
      children: [
        Semantics(
          button: true,
          label: semantics,
          child: ExcludeSemantics(
            child: InkWell(
              key: const Key('apa_insight_card_tap'),
              onTap: openSheet,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: BhSize.touch),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: ApaInsightCard.tileSize,
                      child: Row(
                        children: [
                          const ApaTile(size: ApaInsightCard.tileSize),
                          const SizedBox(width: BhSpace.s),
                          Expanded(
                            child: Text(
                              l10n.apaSays,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelMedium?.copyWith(
                                color: c.status == null ? p.mutedText : c.body,
                              ),
                            ),
                          ),
                          // Status is never colour alone: icon + word for
                          // danger and caution (safe is in the status row).
                          if (c.status != null) ...[
                            Icon(icon, size: 20, color: c.title),
                            const SizedBox(width: BhSpace.xs),
                            Text(
                              label,
                              key: const Key('apa_insight_severity'),
                              maxLines: 1,
                              style: text.labelSmall?.copyWith(color: c.title),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: ApaInsightCard.indent,
                        top: BhSpace.xs,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            key: const Key('apa_insight_title'),
                            style: text.titleSmall?.copyWith(color: c.title),
                          ),
                          if (body.isNotEmpty)
                            Text(
                              body,
                              key: const Key('apa_insight_body'),
                              maxLines: ApaInsightCard.bodyLines,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(color: c.body),
                            ),
                          Text(
                            source,
                            key: Key('apa_insight_source_${shown.source.name}'),
                            style: text.bodySmall?.copyWith(
                              color: c.status == null ? p.mutedText : c.body,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const _PhoneCaption(),
        const SizedBox(height: BhSpace.s),
        BhButton(
          key: const Key('apa_insight_action'),
          label: insight.actionLabel(english),
          icon: Icons.arrow_forward,
          variant: urgent ? BhButtonVariant.primary : BhButtonVariant.outlined,
          onPressed: () => _act(context, ref),
        ),
        if (more > 0)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('apa_insight_more'),
              style: TextButton.styleFrom(
                minimumSize: const Size(BhSize.touch, BhSize.touch),
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
                foregroundColor: c.status == null ? p.primary : c.title,
              ),
              onPressed: () => _openSheet(
                context,
                ref,
                screen,
                insight: insight,
                others: true,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.apaInsightMore(context.digits('$more'))),
                  const Icon(Icons.chevron_right, size: 16),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on _InsightCardBody {
  /// Calm and caution states (all clear, not checked, tips, a held
  /// transfer): a row with Apa's tile and the whole title (up to two lines,
  /// never ellipsised) and, for caution, the severity icon and word; one
  /// body line (the safe-state copy is written to fit; long server text is
  /// cut, the whole text is the sheet's first bubble); then the action as a
  /// right-aligned text link on its own 28 dp row (56 dp hit area). No source
  /// caption. At most 150 dp, so the nine tiles fit the first screen at
  /// 412 x 915.
  Widget _calm(
    BuildContext context,
    WidgetRef ref, {
    required ({
      Color fill,
      Color stripe,
      Color title,
      Color body,
      BhStatus? status,
    })
    c,
    required String title,
    required String body,
    required String semantics,
    required VoidCallback onOpen,
    required String actionLabel,
    required IconData severityIcon,
    required String severityLabel,
  }) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final loud = c.status != null;
    final link = loud ? c.title : p.primary;
    return _Frame(
      materialKey: Key('apa_insight_card_${insight.id}'),
      fill: c.fill,
      stripe: c.stripe,
      compact: true,
      severity: insight.severity,
      children: [
        Semantics(
          button: true,
          label: semantics,
          child: ExcludeSemantics(
            child: InkWell(
              key: const Key('apa_insight_card_tap'),
              onTap: onOpen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: ApaInsightCard.tileSize,
                    ),
                    child: Row(
                      children: [
                        const ApaTile(size: ApaInsightCard.tileSize),
                        const SizedBox(width: BhSpace.s),
                        // The whole title, never ellipsised: up to two
                        // lines (the safe-state copy fits one at 412 dp).
                        Expanded(
                          child: Text(
                            title,
                            key: const Key('apa_insight_title'),
                            maxLines: 2,
                            style: text.titleSmall?.copyWith(color: c.title),
                          ),
                        ),
                        // Status is never colour alone: icon + word for
                        // caution (safe is in the status row).
                        if (loud) ...[
                          const SizedBox(width: BhSpace.s),
                          Icon(severityIcon, size: 20, color: c.title),
                          const SizedBox(width: BhSpace.xs),
                          Text(
                            severityLabel,
                            key: const Key('apa_insight_severity'),
                            maxLines: 1,
                            style: text.labelSmall?.copyWith(color: c.title),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (body.isNotEmpty)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: ApaInsightCard.indent,
                        top: BhSpace.xxs,
                      ),
                      child: Text(
                        body,
                        key: const Key('apa_insight_body'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: c.body),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (loud) const _PhoneCaption(),
        // No source caption in the compact form (the sheet's bubble
        // carries it): only the action link, right-aligned on its own
        // 28 dp row (56 dp hit area).
        SizedBox(
          height: 28,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: OverflowBox(
              alignment: AlignmentDirectional.centerEnd,
              maxHeight: BhSize.touch,
              child: TextButton(
                key: const Key('apa_insight_action'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(BhSize.touch, BhSize.touch),
                  padding: const EdgeInsets.symmetric(horizontal: BhSpace.s),
                  foregroundColor: link,
                  textStyle: text.labelMedium,
                ),
                onPressed: () => _act(context, ref),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(actionLabel, maxLines: 1)),
                    const Icon(Icons.chevron_right, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (more > 0) _moreButton(context, ref, c.title),
      ],
    );
  }

  Widget _moreButton(BuildContext context, WidgetRef ref, Color ink) {
    final p = context.palette;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        key: const Key('apa_insight_more'),
        style: TextButton.styleFrom(
          minimumSize: const Size(BhSize.touch, BhSize.touch),
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
          foregroundColor: ink == p.onSurface ? p.primary : ink,
        ),
        onPressed: () =>
            _openSheet(context, ref, screen, insight: insight, others: true),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.apaInsightMore(context.digits('$more'))),
            const Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }
}

/// Phone check running and nothing urgent: the status row spinner and two
/// skeleton bars where the title and body go; no button.
class _LoadingCard extends StatelessWidget {
  const _LoadingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final skeleton = Color.alphaBlend(
      p.onSurface.withValues(alpha: 0.08),
      p.surfaceVariant,
    );
    Widget bar(double factor) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: factor,
      child: Container(height: 16, color: skeleton),
    );
    return Semantics(
      liveRegion: true,
      label: context.l10n.apaInsightLoading,
      child: ExcludeSemantics(
        child: KeyedSubtree(
          key: const Key('apa_insight_loading'),
          child: _Frame(
            fill: p.surfaceVariant,
            stripe: p.outline,
            children: [
              SizedBox(
                height: ApaInsightCard.tileSize,
                child: Row(
                  children: [
                    const ApaTile(size: ApaInsightCard.tileSize),
                    const SizedBox(width: BhSpace.s),
                    Expanded(
                      child: Text(
                        context.l10n.apaInsightLoading,
                        style: text.labelMedium?.copyWith(color: p.mutedText),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: ApaInsightCard.indent,
                  top: BhSpace.s,
                ),
                child: Column(
                  children: [
                    bar(0.64),
                    const SizedBox(height: BhSpace.s),
                    bar(0.40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCard extends ConsumerWidget {
  const _EmptyCard({required this.screen, super.key});

  final String screen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final l10n = context.l10n;
    return _Frame(
      materialKey: const Key('apa_insight_empty'),
      fill: p.surfaceVariant,
      stripe: p.outline,
      children: [
        Semantics(
          button: true,
          label: l10n.askApa,
          child: ExcludeSemantics(
            child: InkWell(
              onTap: () => _openSheet(context, ref, screen),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: BhSize.touch),
                child: Row(
                  children: [
                    const ApaTile(size: ApaInsightCard.tileSize),
                    const SizedBox(width: BhSpace.s),
                    Expanded(
                      child: Text(
                        l10n.apaActionAskApa,
                        style: text.titleSmall?.copyWith(color: p.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
