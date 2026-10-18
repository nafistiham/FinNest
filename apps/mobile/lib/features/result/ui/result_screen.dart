import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dates.dart';
import '../../../app/l10n.dart';
import '../../../app/router.dart' show Routes;
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/rolling_amount.dart';
import '../../../app/widgets/animated/sheet_reveal.dart';
import '../../../app/widgets/animated/success_check.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/demo_note.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../core/haptics.dart';
import '../../../core/log.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../../domain/risk/trigger.dart';
import '../../approve/logic/trusted_contact_flow.dart';
import '../../intervention/logic/action_labels.dart';
import '../../intervention/ui/intervention_banner.dart';
import '../../intervention/ui/intervention_style.dart'
    show ReasonLine, uniqueReasons;
import '../../pay/logic/pay_controller.dart';
import '../../pay/logic/pay_ledger.dart';
import '../../pay/logic/pay_paths.dart';
import '../../pay/ui/widgets/pay_format.dart';
import '../../send_money/logic/risk_providers.dart';

/// Step 4, the outcome of a payment: one status square
/// (done: the [SuccessCheck] draws inside it, `Haptics.success()` when it
/// lands, then the amount rolls up from ০ — the `AmountConfirm` sequence;
/// held / blocked: a static icon square that only scales in, never a
/// celebration), the title per kind, the amount, the
/// counterparty right under it and the time; for done the new balance and a
/// short reference suffix. Held shows "your money is still here" and the
/// server's reasons (or the delay banner); blocked the reasons and a way to
/// the phone-safety findings; unavailable a retry that returns to the PIN
/// pad in the same session. Back and "হোমে ফিরুন" both go Home.
///
/// A sent payment that carried the App Safety Check's CAUTION shows
/// the server's own reason in an amber note under the receipt and offers the
/// phone-safety page in the bottom bar: the money went, so no overlay.
///
/// A held `delay` (`banner=1`) shows the intervention banner inside the list,
/// so it never covers the bottom bar; its `trusted_contact_check` action runs
/// the same [TrustedContactFlow] request as the overlay on the PIN pad.
class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({
    required this.state,
    this.kind = PayKind.send,
    this.amount,
    this.txnId,
    this.showBanner = false,
    this.interventionId,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  /// done | released_by_step_up | held | blocked | unavailable
  final String state;
  final PayKind kind;

  /// Amount in taka, when the route carried it.
  final int? amount;

  /// The ledger row, for the reference suffix.
  final String? txnId;

  /// `held` from a `delay`: show the intervention banner on this screen.
  final bool showBanner;
  final String? interventionId;
  final Haptics haptics;

  static const done = 'done';
  static const held = 'held';
  static const blocked = 'blocked';
  static const unavailable = 'unavailable';

  /// A server hold the owner released with a biometric step-up: a sent
  /// transfer with the step-up title and a demo note saying the server still
  /// has it as held.
  static const releasedByStepUp = 'released_by_step_up';

  /// The status square (dp).
  static const iconSize = 112.0;

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen>
    with SingleTickerProviderStateMixin {
  static const _tag = 'result';

  /// The money left: a plain done or a step-up release.
  bool get _sent =>
      widget.state == ResultScreen.done ||
      widget.state == ResultScreen.releasedByStepUp;

  /// The banner's inputs once loaded; `null` when hidden or dismissed.
  ({ScoreResponse score, List<ActionItem> actions, InterventionRecord? record})?
  _banner;
  bool _trustedSent = false;
  bool _trustedBusy = false;
  late final AnimationController _enter;
  late final DateTime _at;
  bool _hapticDone = false;

  /// Done: the check has landed, so the amount confirms (rolls from ০).
  bool _checked = false;

  void _checkDone() {
    if (mounted && !_checked) setState(() => _checked = true);
  }

  @override
  void initState() {
    super.initState();
    _at = ref.read(clockProvider).now();
    _enter = AnimationController(
      vsync: this,
      duration: BhMotion.standard.normal + BhMotion.standard.slow,
    );
    _enter.addStatusListener((s) {
      if (s == AnimationStatus.completed) _settled();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (BhMotion.of(context).reduced) {
        _enter.value = 1;
        _settled();
      } else {
        unawaited(_enter.forward());
      }
      if (widget.showBanner) unawaited(_loadBanner());
    });
  }

  /// The success haptic fires once the tick has drawn (6.3); held and
  /// blocked get a warning.
  void _settled() {
    if (_hapticDone) return;
    _hapticDone = true;
    switch (widget.state) {
      case ResultScreen.done || ResultScreen.releasedByStepUp:
        // SuccessCheck fires `success()` when the check lands.
        break;
      case ResultScreen.held || ResultScreen.blocked:
        unawaited(widget.haptics.warning());
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  /// The amount in `amountHero`, the ৳ at 60 % muted. Done: invisible (but
  /// holding its width) until the check lands, then it fades in rolling up
  /// from ০. Other states show it settled.
  Widget _amount(BuildContext context, int amount) {
    final p = context.palette;
    final style = context.textRoles.amountHero.copyWith(color: p.onSurface);
    final sign = style.copyWith(
      fontSize: (style.fontSize ?? 44) * 0.6,
      color: p.mutedText,
    );
    if (!_sent) {
      return RollingAmount(
        amount,
        key: const Key('result_amount'),
        style: style,
        prefixStyle: sign,
      );
    }
    final m = BhMotion.of(context);
    return AnimatedOpacity(
      opacity: _checked ? 1 : 0,
      duration: m.reduced ? BhMotion.crossfade : m.enter,
      curve: BhCurves.enter,
      // A new key once checked: a fresh RollingAmount that rolls from 0.
      child: RollingAmount(
        amount,
        key: _checked
            ? const Key('result_amount')
            : const Key('result_amount_pending'),
        from: _checked ? 0 : null,
        style: style,
        prefixStyle: sign,
      ),
    );
  }

  Future<void> _loadBanner() async {
    final score = ref.read(lastScoreProvider);
    if (score == null) return;
    final uid = ref.read(currentUserProvider).value?.uid;
    final id = widget.interventionId;
    final record = uid == null || id == null
        ? null
        : (await ref.read(interventionRepoProvider).watch(uid).first)
              .where((r) => r.id == id)
              .firstOrNull;
    if (!mounted) return;
    setState(
      () => _banner = (
        score: score,
        actions: record?.actions ?? score.actions,
        record: record,
      ),
    );
  }

  void _hideBanner() => setState(() => _banner = null);

  Future<void> _onBannerAction(ActionItem a) async {
    if (a.type != ActionLabels.trustedContactCheck) {
      // delay / step-up / anything else: acknowledged; the hold stands.
      _hideBanner();
      return;
    }
    if (_trustedBusy || _trustedSent) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final record = _banner?.record;
    final user = ref.read(currentUserProvider).value;
    if (record == null || user == null) {
      Log.w(_tag, 'trusted contact asked without a local record');
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trustedRequestFailed)),
      );
      return;
    }
    setState(() => _trustedBusy = true);
    try {
      final updated = await ref
          .read(trustedContactFlowProvider)
          .request(record: record, contactUid: user.trustedContactUid);
      Log.i(_tag, 'trusted contact request ${updated.requestId}');
      if (!mounted) return;
      setState(() => _trustedSent = true);
      messenger.showSnackBar(SnackBar(content: Text(l10n.trustedRequestSent)));
    } on Object catch (e) {
      Log.w(_tag, 'trusted contact request failed', e);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trustedRequestFailed)),
      );
    } finally {
      if (mounted) setState(() => _trustedBusy = false);
    }
  }

  String _title(AppLocalizations l10n) => switch (widget.state) {
    ResultScreen.held => l10n.resultHeld,
    ResultScreen.blocked => l10n.resultBlocked,
    ResultScreen.unavailable => l10n.resultUnavailable,
    ResultScreen.releasedByStepUp => l10n.stepUpReleasedTitle,
    _ => switch (widget.kind) {
      PayKind.cashOut => l10n.resultCashOutTitle,
      PayKind.recharge => l10n.resultRechargeDone,
      PayKind.bill => l10n.resultBillDone,
      PayKind.dps => l10n.dpsOpened,
      _ => l10n.resultDone,
    },
  };

  String? _body(AppLocalizations l10n) => switch (widget.state) {
    ResultScreen.held => l10n.resultHeldBody,
    ResultScreen.unavailable => l10n.resultUnavailableBody,
    ResultScreen.done when widget.kind == PayKind.cashOut =>
      l10n.resultCashOutBody,
    _ => null,
  };

  /// "মা · ০১৯XX-XXX৮৮১", "এজেন্ট · …", "০১৭XX-XXX৪১২ · অপারেটর ক",
  /// "ডেসকো বিদ্যুৎ বিল".
  String? _counterpartyLine(BuildContext context, PayIntent intent) {
    final c = intent.counterparty;
    if (intent.kind != widget.kind || c == null) return null;
    final number = context.counterpartyNumber(c);
    return switch (intent.kind) {
      PayKind.recharge => [
        number,
        if (intent.operator != null) context.operatorName(intent.operator!),
      ].join(' · '),
      PayKind.bill =>
        intent.bill == null
            ? context.counterpartyName(c)
            : '${context.billName(intent.bill!.biller)} · $number',
      PayKind.dps => context.dpsPlanLine(intent),
      _ => [
        context.counterpartyName(c),
        if (number.isNotEmpty) number,
      ].join(' · '),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final score = ref.watch(lastScoreProvider);
    final intent = ref.watch(payControllerProvider);
    final balance = _sent ? ref.watch(payBalanceProvider).value : null;
    final look = _Look.of(p, widget.state);
    final amount = widget.amount;
    final banner = _banner;
    final locale = Localizations.localeOf(context);
    final cpLine = _counterpartyLine(context, intent);
    final body = _body(l10n);
    final txn = widget.txnId;
    final fromSafety = widget.state == ResultScreen.blocked;
    // The App Safety Check's CAUTION on a payment that went.
    final caution = _sent
        ? score?.reasons.where((r) => r.code == _cautionCode).firstOrNull
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(PayPaths.home);
      },
      child: Scaffold(
        bottomNavigationBar: BhBottomBar(
          apaScreen: 'result',
          // Held: the Apa square beside "হোমে ফিরুন" is the one way to ask
          // Apa; no second, duplicate button.
          secondary: widget.state == ResultScreen.unavailable
              ? BhButton(
                  key: const Key('result_retry'),
                  label: l10n.retry,
                  icon: Icons.refresh,
                  variant: BhButtonVariant.outlined,
                  onPressed: () => context.go(PayPaths.pin(widget.kind)),
                )
              : fromSafety
              ? BhButton(
                  key: const Key('result_safety'),
                  label: l10n.resultSeeSafety,
                  icon: Icons.shield_outlined,
                  variant: BhButtonVariant.outlined,
                  onPressed: () => context.go('${Routes.safety}?block=1'),
                )
              : caution != null
              ? BhButton(
                  key: const Key('result_caution_safety'),
                  label: l10n.resultSeeSafety,
                  icon: Icons.shield_outlined,
                  variant: BhButtonVariant.outlined,
                  onPressed: () => context.go(Routes.safety),
                )
              : null,
          primary: BhButton(
            key: const Key('result_home'),
            label: l10n.goHome,
            icon: Icons.home_outlined,
            onPressed: () => context.go(PayPaths.home),
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              BhSpace.m,
              BhSpace.xl,
              BhSpace.m,
              BhSpace.m,
            ),
            children: [
              Center(
                child: _StatusSquare(
                  look: look,
                  animation: _enter,
                  draw: _sent,
                  haptics: widget.haptics,
                  onChecked: _checkDone,
                ),
              ),
              const SizedBox(height: BhSpace.l),
              FadeTransition(
                opacity: CurvedAnimation(
                  parent: _enter,
                  curve: const Interval(0.5, 1, curve: Curves.easeOut),
                ),
                child: Column(
                  children: [
                    Text(
                      _title(l10n),
                      key: const Key('result_title'),
                      textAlign: TextAlign.center,
                      style: text.headlineMedium?.copyWith(color: look.text),
                    ),
                    if (amount != null && amount > 0) ...[
                      const SizedBox(height: BhSpace.m),
                      Center(child: _amount(context, amount)),
                    ],
                    if (cpLine != null && cpLine.isNotEmpty) ...[
                      const SizedBox(height: BhSpace.xs),
                      Text(
                        cpLine,
                        key: const Key('result_counterparty'),
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(color: p.mutedText),
                      ),
                    ],
                    Text(
                      BhDates.rowLabel(_at, locale, now: _at),
                      key: const Key('result_time'),
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                  ],
                ),
              ),
              if (body != null) ...[
                const SizedBox(height: BhSpace.m),
                Text(
                  body,
                  key: const Key('result_body'),
                  textAlign: TextAlign.center,
                  style: text.bodyLarge,
                ),
              ],
              if (widget.state == ResultScreen.releasedByStepUp) ...[
                const SizedBox(height: BhSpace.m),
                DemoNote(
                  l10n.stepUpReleasedDemoNote,
                  key: const Key('result_step_up_note'),
                ),
              ],
              if (_sent) ...[
                const SizedBox(height: BhSpace.l),
                Divider(height: 1, thickness: 1, color: p.outlineVariant),
                if (balance != null)
                  _KeyValue(
                    key: const Key('result_new_balance'),
                    label: l10n.resultNewBalance,
                    value: context.taka(balance),
                  ),
                if (txn != null && referenceCode(txn).isNotEmpty)
                  _KeyValue(
                    key: const Key('result_reference'),
                    label: l10n.resultReference,
                    // A code, not a number: ASCII in both languages.
                    value: referenceCode(txn),
                    muted: true,
                  ),
              ],
              if (caution != null) ...[
                const SizedBox(height: BhSpace.l),
                _cautionNote(context, caution.text(context)),
              ],
              if (banner != null) ...[
                // The banner carries the server's reasons itself.
                const SizedBox(height: BhSpace.l),
                // Inserted with motion (6.2): firm, no overshoot (a hold is
                // not a celebration); tappable from the first frame.
                SlideFadeIn(
                  firm: true,
                  offset: 16,
                  child: InterventionBanner(
                    score: banner.score,
                    intervene: null,
                    script: banner.record?.script(context),
                    reasons: banner.record?.reasons,
                    actions: banner.actions,
                    trustedSent: _trustedSent,
                    trustedBusy: _trustedBusy,
                    servedClip: switch (banner.record) {
                      null => null,
                      final r => (
                        assetId: r.audioAssetId,
                        scriptBn: r.scriptBn,
                      ),
                    },
                    predictedAsset: switch (banner.record) {
                      null => null,
                      final r => Triggers.predictedAsset(r.trigger),
                    },
                    onAction: _onBannerAction,
                    onDismiss: _hideBanner,
                  ),
                ),
              ] else if (widget.state == ResultScreen.held ||
                  widget.state == ResultScreen.blocked) ...[
                const SizedBox(height: BhSpace.l),
                // Server reasons only (FR-3), in the app language.
                for (final r in uniqueReasons(
                  context,
                  score?.reasons ?? const <Reason>[],
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ReasonLine(
                      text: r.text(context),
                      color: look.fill,
                      style: text.bodyLarge,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// risk-mw's reason code for the App Safety Check's CAUTION.
const _cautionCode = 'APP_SAFETY_CAUTION';

/// The CAUTION note (design system 3 and 5): `warningContainer` with the
/// 4 dp amber stripe, a "Caution" tag (icon and word, never colour alone)
/// beside a plain title, then the server's reason verbatim (FR-3).
Widget _cautionNote(BuildContext context, String reason) {
  final l10n = context.l10n;
  final p = context.palette;
  final text = Theme.of(context).textTheme;
  return Container(
    key: const Key('result_caution'),
    decoration: BoxDecoration(
      color: p.warningContainer,
      border: Border(
        left: BorderSide(color: p.warningFill, width: BhSize.stripe),
      ),
    ),
    padding: const EdgeInsets.fromLTRB(
      BhSpace.m - BhSize.stripe,
      BhSpace.m,
      BhSpace.m,
      BhSpace.m,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatusTag.header(
          title: Text(
            l10n.apaInsightCautionTitle,
            style: text.titleSmall?.copyWith(color: p.onWarningContainer),
          ),
          tag: StatusTag(
            label: l10n.safetyVerdictCaution,
            status: BhStatus.warning,
          ),
        ),
        const SizedBox(height: BhSpace.s),
        Text(
          reason,
          style: text.bodyLarge?.copyWith(color: p.onWarningContainer),
        ),
      ],
    ),
  );
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.muted = false,
    super.key,
  });

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: BhSize.touch),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: p.mutedText),
            ),
          ),
          Text(
            value,
            style: text.titleSmall?.copyWith(
              color: muted ? p.mutedText : p.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Colours and icon per result state, from the palette (dark containers in
/// dark mode).
class _Look {
  const _Look({
    required this.icon,
    required this.container,
    required this.onContainer,
    required this.text,
    required this.fill,
  });

  final IconData icon;
  final Color container;
  final Color onContainer;

  /// Title colour on the surface.
  final Color text;

  /// Reason bullets.
  final Color fill;

  static _Look of(BhPalette p, String state) => switch (state) {
    ResultScreen.held => _Look(
      icon: Icons.hourglass_top,
      container: p.warningContainer,
      onContainer: p.onWarningContainer,
      text: p.warning,
      fill: p.warningFill,
    ),
    ResultScreen.blocked => _Look(
      icon: Icons.block,
      container: p.dangerContainer,
      onContainer: p.onDangerContainer,
      text: p.danger,
      fill: p.dangerFill,
    ),
    ResultScreen.unavailable => _Look(
      icon: Icons.cloud_off_outlined,
      container: p.surfaceVariant,
      onContainer: p.mutedText,
      text: p.mutedText,
      fill: p.outline,
    ),
    _ => _Look(
      icon: Icons.check,
      container: p.successContainer,
      onContainer: p.onSuccessContainer,
      text: p.success,
      fill: p.successFill,
    ),
  };
}

/// The 112 dp status square: scales in (0.8 → 1.0 for done, 0.9 → 1.0
/// otherwise) over the first part of [animation]; for done the tick then
/// draws itself over the rest.
class _StatusSquare extends StatelessWidget {
  const _StatusSquare({
    required this.look,
    required this.animation,
    required this.draw,
    required this.haptics,
    required this.onChecked,
  });

  final _Look look;
  final Animation<double> animation;
  final bool draw;
  final Haptics haptics;
  final VoidCallback onChecked;

  @override
  Widget build(BuildContext context) {
    final scaleIn = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, 0.4, curve: BhCurves.enter),
    );
    // Built once: the check keeps its own animation across the scale-in.
    final Widget content = draw
        ? SuccessCheck(
            key: const Key('result_tick'),
            size: 72,
            color: look.onContainer,
            haptics: haptics,
            onDone: onChecked,
          )
        : Icon(look.icon, size: 64, color: look.onContainer);
    return AnimatedBuilder(
      animation: animation,
      child: content,
      builder: (context, child) {
        final from = draw ? 0.8 : 0.9;
        return Transform.scale(
          scale: from + (1 - from) * scaleIn.value,
          child: Container(
            key: const Key('result_icon'),
            width: ResultScreen.iconSize,
            height: ResultScreen.iconSize,
            color: look.container,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
    );
  }
}
