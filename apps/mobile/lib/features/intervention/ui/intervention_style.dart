import 'package:flutter/material.dart';

import '../../../app/l10n.dart';
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../data/contracts/common.dart';
import '../../../data/contracts/score.dart';
import '../logic/action_labels.dart';

/// Colours and chrome title keyed by the server's `decision` (red is for
/// block only; hold, delay and step_up are amber, the same "held" colour as
/// History, Home and Result), from the palette, so dark mode gets dark
/// containers with light text. The title is a label keyed by an enum, like a
/// button label; the risk copy itself is `script_bn`/`script_en` and
/// `reasons[].text_bn`/`text_en`, picked by the app language
/// (`lib/app/server_text.dart`).
class InterventionStyle {
  const InterventionStyle._({
    required this.status,
    required this.fill,
    required this.container,
    required this.onContainer,
    required this.text,
    required this.title,
  });

  factory InterventionStyle.of(BuildContext context, Decision decision) {
    final l10n = context.l10n;
    final p = context.palette;
    InterventionStyle make(BhStatus s, String title) => InterventionStyle._(
      status: s,
      fill: s == BhStatus.info ? p.primary : p.statusFill(s),
      container: s == BhStatus.info ? p.primaryContainer : p.statusContainer(s),
      onContainer: s == BhStatus.info
          ? p.onPrimaryContainer
          : p.onStatusContainer(s),
      text: s == BhStatus.info ? p.primary : p.statusText(s),
      title: title,
    );
    return switch (decision) {
      Decision.hold => make(BhStatus.warning, l10n.interventionHeldTitle),
      Decision.block => make(BhStatus.danger, l10n.interventionBlockedTitle),
      Decision.delay => make(BhStatus.warning, l10n.interventionDelayTitle),
      Decision.stepUp => make(BhStatus.warning, l10n.interventionStepUpTitle),
      Decision.allow => make(BhStatus.info, ''),
    };
  }

  final BhStatus status;

  /// Strong fill: stripes and bullets.
  final Color fill;

  /// Soft fill of the top strip and the banner card (dark tint in dark mode).
  final Color container;

  /// Text and icons on [container].
  final Color onContainer;

  /// The decision colour for text and icons on the screen surface.
  final Color text;
  final String title;
}

/// Button colours per `actions[].type`: red only for a block (the design
/// system reserves it), warning for delay / freeze / step_up, the brand
/// primary for the hold's "টাকা আমার কাছেই থাকুক" (the calm, safe default:
/// a red fill made it read as the dangerous choice in device tests), for the
/// protective trusted-contact action and for anything unknown.
({Color background, Color foreground}) actionColors(BhPalette p, String type) =>
    switch (type) {
      ActionLabels.blockTransaction => (
        background: p.dangerFill,
        foreground: p.onDangerFill,
      ),
      ActionLabels.delayNewPayee ||
      ActionLabels.freezePinReset ||
      ActionLabels.stepUpVerification => (
        background: p.warningFill,
        foreground: p.onWarningFill,
      ),
      _ => (background: p.primary, foreground: p.onPrimary),
    };

/// `trusted_contact_check` goes last so the protective action sits lowest, in
/// the thumb zone; everything else keeps the server's order.
List<ActionItem> orderForThumbZone(List<ActionItem> actions) {
  final others = <ActionItem>[];
  final trusted = <ActionItem>[];
  for (final a in actions) {
    (a.type == ActionLabels.trustedContactCheck ? trusted : others).add(a);
  }
  return [...others, ...trusted];
}

/// A 56 dp, full-width action button labelled from `actions[].type`. While
/// [busy] (the request went out and has not answered) it is disabled and
/// shows a small indicator before the label, so a tap burst sends one request.
///
/// [outlined] (by default only for [ActionLabels.biometricStepUp])
/// draws a `primary` outline on the surface instead of a fill, so the
/// step-up never reads as a second primary beside the trusted contact; it is
/// at least 56 dp tall and grows with the text scale (its label is long, a
/// fixed 56 dp would cut it at 1.3x on a 360 dp phone).
class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    required this.action,
    required this.onPressed,
    this.busy = false,
    this.outlined,
  });

  final ActionItem action;
  final VoidCallback onPressed;
  final bool busy;

  /// `null`: outlined only for [ActionLabels.biometricStepUp].
  final bool? outlined;

  bool get isOutlined =>
      outlined ?? action.type == ActionLabels.biometricStepUp;

  @override
  Widget build(BuildContext context) {
    if (isOutlined) return _outlinedButton(context);
    final colors = actionColors(context.palette, action.type);
    final label = Text(
      ActionLabels.labelFor(context.l10n, action),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return SizedBox(
      width: double.infinity,
      height: BhSize.touch,
      child: FilledButton(
        key: ValueKey('action_${action.type}'),
        style: FilledButton.styleFrom(
          backgroundColor: colors.background,
          foregroundColor: colors.foreground,
          disabledBackgroundColor: colors.background.withValues(alpha: 0.7),
          disabledForegroundColor: colors.foreground,
        ),
        onPressed: busy ? null : onPressed,
        child: busy
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    key: ValueKey('action_${action.type}_busy'),
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.foreground,
                    ),
                  ),
                  const SizedBox(width: BhSpace.s),
                  Flexible(child: label),
                ],
              )
            : label,
      ),
    );
  }

  Widget _outlinedButton(BuildContext context) {
    final p = context.palette;
    // The step-up's label is long and must stay whole at 1.3x on a 360 dp
    // phone, so that button grows; every other outlined button keeps the
    // 56 dp slot of the filled one, so a line that replaces it (the trusted
    // request "sent") lands in the same place.
    final grows = action.type == ActionLabels.biometricStepUp;
    final label = Text(
      ActionLabels.labelFor(context.l10n, action),
      textAlign: TextAlign.center,
      maxLines: grows ? 3 : 1,
      overflow: TextOverflow.ellipsis,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: double.infinity,
        minHeight: BhSize.touch,
        maxHeight: grows ? double.infinity : BhSize.touch,
      ),
      child: OutlinedButton(
        key: ValueKey('action_${action.type}'),
        style: OutlinedButton.styleFrom(
          foregroundColor: p.primary,
          side: BorderSide(color: p.primary, width: 2),
          minimumSize: const Size(double.infinity, BhSize.touch),
          padding: const EdgeInsets.symmetric(
            horizontal: BhSpace.m,
            vertical: BhSpace.s,
          ),
        ),
        onPressed: busy ? null : onPressed,
        child: busy
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    key: ValueKey('action_${action.type}_busy'),
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.primary,
                    ),
                  ),
                  const SizedBox(width: BhSpace.s),
                  Flexible(child: label),
                ],
              )
            : label,
      ),
    );
  }
}

/// The chrome line "আমিই পাঠাচ্ছি" over the step-up button: who is confirming,
/// not why the money was stopped.
class StepUpChromeLine extends StatelessWidget {
  const StepUpChromeLine({super.key});

  @override
  Widget build(BuildContext context) => Text(
    context.l10n.stepUpIsThisYou,
    key: const ValueKey('step_up_chrome'),
    textAlign: TextAlign.center,
    style: Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: context.palette.onSurface),
  );
}

/// Replaces the step-up button after a failed fingerprint (terminal: the
/// sensor is locked): "যাচাই হয়নি। আপনজনের মত নিন।" in the hold colour, in
/// the same slot, so the trusted contact below is the next step. With
/// [exhausted] (three prompts in this session did not pass, cancels
/// included) it says "তিনবার যাচাই হয়নি। এখন আপনজনের মত
/// নিন।" instead.
class StepUpFailedLine extends StatelessWidget {
  const StepUpFailedLine({this.exhausted = false, super.key});

  final bool exhausted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = exhausted
        ? context.l10n.stepUpExhausted
        : context.l10n.stepUpFailed;
    return Semantics(
      key: ValueKey(exhausted ? 'step_up_exhausted' : 'step_up_failed'),
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: BhSize.touch),
          padding: const EdgeInsets.symmetric(
            horizontal: BhSpace.m,
            vertical: BhSpace.s,
          ),
          color: p.warningContainer,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline, color: p.onWarningContainer, size: 24),
              const SizedBox(width: BhSpace.s),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: p.onWarningContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Replaces the trusted-contact button once the request went out: a
/// green line in the same 56 dp slot, so the thumb finds the answer where it
/// pressed (no snackbar to chase, no request id).
class TrustedRequestSentLine extends StatelessWidget {
  const TrustedRequestSentLine({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = context.l10n.trustedRequestSentLine;
    return Semantics(
      key: const ValueKey('trusted_request_sent'),
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: BhSize.touch),
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
          color: p.successContainer,
          // A foreground border adds no padding: the line keeps the 56 dp
          // slot of the button it replaces.
          foregroundDecoration: BoxDecoration(
            border: Border.all(color: p.success, width: 2),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: p.success, size: 26),
              const SizedBox(width: BhSpace.s),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: p.onSuccessContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 12 dp square bullet aligned to the first line's x-height, then the
/// server's reason (FR-3).
/// The server's reasons with duplicate texts dropped (the first of each
/// kept): two codes can carry the same sentence in the app language, and
/// the same line would otherwise show as two bullets.
List<Reason> uniqueReasons(BuildContext context, Iterable<Reason> reasons) {
  final seen = <String>{};
  return [
    for (final r in reasons)
      if (seen.add(r.text(context).trim())) r,
  ];
}

class ReasonLine extends StatelessWidget {
  const ReasonLine({
    required this.text,
    required this.color,
    this.style,
    super.key,
  });

  final String text;
  final Color color;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = style ?? Theme.of(context).textTheme.bodyLarge!;
    final lineHeight = (s.fontSize ?? 18) * (s.height ?? 1.4);
    final scaled = MediaQuery.textScalerOf(context).scale(lineHeight);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: ((scaled - 12) / 2).clamp(0, 40)),
          child: SizedBox.square(
            dimension: 12,
            child: ColoredBox(color: color),
          ),
        ),
        const SizedBox(width: BhSpace.m),
        Expanded(child: Text(text, style: s)),
      ],
    );
  }
}
