import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n.dart';
import '../../../app/motion/motion_specs.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/expressive_text.dart';
import '../../../app/widgets/animated/rolling_amount.dart';
import '../../../app/widgets/animated/sheet_reveal.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/choice_tile.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/recipient_row.dart';
import '../../../app/widgets/sheet_header.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../core/haptics.dart';
import '../../../data/providers.dart';
import '../../pay/logic/pay_controller.dart';
import '../../pay/logic/pay_paths.dart';
import '../logic/finance_models.dart';
import '../logic/finance_providers.dart';
import 'widgets/finance_chrome.dart';

/// Savings (DPS). One card per plan: the monthly
/// amount as the card title with the "ডেমো হার" tag pinned top-right, a
/// 6 dp progress bar with "১২/৩৬ কিস্তি", and the maturity amount trailing.
/// The single primary "নতুন ডিপিএস খুলুন" sits in the bottom bar beside the
/// Apa square and opens [DpsOpenSheet]. Everything is local demo data.
/// The sheet's confirm goes through the shared PIN step (`PayKind.dps`);
/// the plan opens only after the right PIN.
class SavingsScreen extends ConsumerWidget {
  const SavingsScreen({super.key});

  static const openKey = Key('savings_open_dps');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(financeStateProvider);
    final signedIn = ref.watch(currentUserProvider).value != null;

    final Widget body = switch (state) {
      AsyncData(:final value) when value.plans.isEmpty => EmptyState(
        key: const Key('savings_empty'),
        icon: Icons.savings_outlined,
        title: l10n.financeEmpty,
        body: l10n.dpsEmptyBody,
      ),
      AsyncData(:final value) => ListView(
        padding: const EdgeInsets.fromLTRB(
          BhSpace.m,
          BhSpace.m,
          BhSpace.m,
          BhSpace.l,
        ),
        children: [
          StaggeredReveal(
            children: [
              for (final (i, plan) in value.plans.indexed)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : BhSpace.m),
                  child: DpsPlanCard(key: ValueKey(plan.id), plan: plan),
                ),
            ],
          ),
        ],
      ),
      // A failed load says what to do next and offers the retry (2.6); a
      // retry in flight shows the skeleton again, not the stale error.
      AsyncError() when !state.isLoading => EmptyState(
        key: const Key('finance_failed'),
        icon: Icons.cloud_off,
        title: l10n.financeLoadFailed,
        body: l10n.safetyErrorBody,
        actionLabel: l10n.retry,
        onAction: () => ref.invalidate(financeStateProvider),
      ),
      _ => const FinanceLoading(),
    };

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: BhSize.appBar,
        title: Text(l10n.financeSavingsTitle),
      ),
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: BhBottomBar(
        apaScreen: 'savings',
        primary: BhButton(
          key: openKey,
          label: l10n.dpsOpenNew,
          icon: Icons.add,
          onPressed: signedIn ? () => _openSheet(context) : null,
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) {
    unawaited(const SystemHaptics().light());
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const DpsOpenSheet(),
    );
  }
}

/// One plan: the monthly amount as the title (rolls when it changes), the
/// demo-rate tag on the card's trailing padding line, the progress bar and
/// instalments, paid so far, and the maturity amount trailing.
class DpsPlanCard extends StatelessWidget {
  const DpsPlanCard({required this.plan, super.key});

  final DpsPlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: p.mutedText);
    final instalments = l10n.dpsInstalments(
      context.digits('${plan.instalmentsPaid}'),
      context.digits('${plan.tenureMonths}'),
    );
    return Container(
      color: p.surfaceVariant,
      padding: const EdgeInsets.all(BhSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.dpsMonthly, style: muted),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: RollingAmount(
                    plan.monthlyBdt,
                    key: const Key('dps_monthly'),
                    style: DisplayAmountStyle(
                      context,
                      size: 28,
                      color: p.onSurface,
                    ),
                    semanticsLabel: l10n.dpsPlanTitle(
                      context.takaSpoken(plan.monthlyBdt),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: BhSpace.s),
              StatusTag(
                label: l10n.dpsDemoRate(
                  context.digits(percentLabel(plan.demoRatePct)),
                ),
                // A neutral fact, not a hold: info, never amber.
                status: BhStatus.info,
              ),
            ],
          ),
          const SizedBox(height: BhSpace.m),
          FinanceProgressBar(
            key: const Key('dps_progress'),
            value: plan.progress,
            color: plan.matured ? p.success : p.primary,
            semanticLabel: instalments,
          ),
          const SizedBox(height: BhSpace.s),
          Row(
            children: [
              Expanded(child: Text(instalments, style: muted)),
              Text(l10n.dpsTenureYears(plan.tenureMonths ~/ 12), style: muted),
            ],
          ),
          const SizedBox(height: BhSpace.s),
          _KeyValue(
            label: l10n.dpsPaidSoFar,
            value: context.taka(plan.paidBdt),
          ),
          Divider(height: BhSpace.m, color: p.outlineVariant),
          _KeyValue(
            label: l10n.dpsMaturity,
            value: context.taka(plan.maturityBdt),
            strong: true,
          ),
        ],
      ),
    );
  }
}

/// Label left, value right (baseline-aligned); [strong] = `titleSmall` in
/// the success colour (the maturity amount).
class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.strong = false,
  });

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            label,
            style: text.bodyMedium?.copyWith(color: p.mutedText),
          ),
        ),
        const SizedBox(width: BhSpace.s),
        Text(
          value,
          style: strong
              ? text.titleSmall?.copyWith(color: p.success)
              : text.bodyMedium,
        ),
      ],
    );
  }
}

/// Bottom sheet (8.11): `SheetHandleReveal`, `SheetHeader`, amount and
/// tenure as shared `ChoiceTile`s, the projection as a `ConfirmSummary`, the
/// first-instalment line and a 56 dp confirm. Confirm sets the plan and its
/// first instalment on the pay flow, pops itself and opens the shared PIN
/// step (`/pay/dps/pin`); the plan is stored after the right PIN, and the
/// result says "ডিপিএস খোলা হয়েছে". The content slides up on open
/// (`SlideFadeIn`).
class DpsOpenSheet extends ConsumerStatefulWidget {
  const DpsOpenSheet({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  static const amounts = <int>[500, 1000, 2000];
  static const tenureYears = <int>[1, 3, 5];

  @override
  ConsumerState<DpsOpenSheet> createState() => _DpsOpenSheetState();
}

class _DpsOpenSheetState extends ConsumerState<DpsOpenSheet> {
  int _amount = 500;
  int _years = 3;

  DpsPlan get _preview => DpsPlan(
    id: 'preview',
    monthlyBdt: _amount,
    tenureMonths: _years * 12,
    instalmentsPaid: 0,
    startedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final label = text.bodyMedium;
    return SingleChildScrollView(
      child: SlideFadeIn(
        offset: 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The drag handle grows in a beat after the sheet (7.10).
            const SheetHandleReveal(),
            SheetHeader(title: l10n.dpsOpenNew, icon: Icons.savings_outlined),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BhSpace.m,
                BhSpace.m,
                BhSpace.m,
                BhSpace.m,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.dpsChooseAmount, style: label),
                  const SizedBox(height: BhSpace.s),
                  _ChoiceRow(
                    keyPrefix: 'dps_amount_',
                    labels: [
                      for (final a in DpsOpenSheet.amounts) context.taka(a),
                    ],
                    selected: DpsOpenSheet.amounts.indexOf(_amount),
                    onSelect: (i) =>
                        _pick(() => _amount = DpsOpenSheet.amounts[i]),
                  ),
                  const SizedBox(height: BhSpace.l),
                  Text(l10n.dpsChooseTenure, style: label),
                  const SizedBox(height: BhSpace.s),
                  _ChoiceRow(
                    keyPrefix: 'dps_years_',
                    labels: [
                      for (final y in DpsOpenSheet.tenureYears)
                        l10n.dpsTenureYears(y),
                    ],
                    selected: DpsOpenSheet.tenureYears.indexOf(_years),
                    onSelect: (i) =>
                        _pick(() => _years = DpsOpenSheet.tenureYears[i]),
                  ),
                  const SizedBox(height: BhSpace.l),
                  KeyedSubtree(
                    key: const Key('dps_projection'),
                    child: ConfirmSummary(
                      kindLine: l10n.dpsProjectionLabel,
                      amountBdt: _preview.maturityBdt,
                      feeLine: l10n.dpsDemoRate(
                        context.digits(percentLabel(_preview.demoRatePct)),
                      ),
                    ),
                  ),
                  const SizedBox(height: BhSpace.m),
                  Text(
                    l10n.dpsFirstInstalment(context.taka(_amount)),
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(color: p.mutedText),
                  ),
                  const SizedBox(height: BhSpace.m),
                  BhButton(
                    key: const Key('dps_confirm'),
                    label: l10n.dpsConfirm,
                    icon: Icons.check,
                    onPressed: _confirm,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pick(VoidCallback change) {
    // Chips are a selection, like the quick amounts (6.3).
    unawaited(widget.haptics.selection());
    setState(change);
  }

  /// Money moves only after the PIN, as everywhere else: set the plan on the pay flow and go to its PIN step.
  void _confirm() {
    final router = GoRouter.of(context);
    ref
        .read(payControllerProvider.notifier)
        .beginDps(monthlyBdt: _amount, tenureMonths: _years * 12);
    Navigator.of(context).pop();
    router.go(PayPaths.pin(PayKind.dps));
  }
}

/// Equal shared `ChoiceTile`s in one row, 56 dp tall, 8 dp gaps.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.keyPrefix,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final String keyPrefix;
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: BhSpace.s),
          Expanded(
            child: ChoiceTile(
              key: Key('$keyPrefix$i'),
              label: labels[i],
              selected: i == selected,
              height: BhSize.touch,
              tabular: true,
              scaleDown: true,
              onTap: () => onSelect(i),
            ),
          ),
        ],
      ],
    );
  }
}
