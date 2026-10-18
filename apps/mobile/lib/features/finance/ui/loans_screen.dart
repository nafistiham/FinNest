import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n.dart';
import '../../../app/motion/motion_specs.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/pressable.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/demo_note.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/hero_balance.dart';
import '../../../app/widgets/section_header.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../core/haptics.dart';
import '../logic/finance_models.dart';
import '../logic/finance_providers.dart';
import 'widgets/finance_chrome.dart';

/// Loans. Eligibility as a hero ("আপনি পেতে পারেন"
/// + the limit in `amountHero` + the income line), the products as
/// selectable rows (amount, tenure and monthly, a "ডেমো ফি" tag), the fixed
/// "never asks for an OTP" strip, and the applications filed so far with
/// their status tags. ONE primary action: the bottom bar's "আবেদন করুন"
/// for the selected product, beside the Apa square. Everything is local
/// demo data.
class LoansScreen extends ConsumerStatefulWidget {
  const LoansScreen({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  static const applyKey = Key('loan_apply');

  @override
  ConsumerState<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends ConsumerState<LoansScreen> {
  /// The product the bottom bar applies for; null = the first eligible.
  String? _selectedId;

  LoanProduct? _selected(FinanceState state) {
    final picked = LoanProducts.all
        .where((p) => p.id == _selectedId && state.canBorrow(p))
        .firstOrNull;
    return picked ?? LoanProducts.all.where(state.canBorrow).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(financeStateProvider);
    final action = ref.watch(financeControllerProvider);
    final value = state.value;
    final selected = value == null ? null : _selected(value);

    final Widget body = switch (state) {
      AsyncData(:final value) => _LoansBody(
        state: value,
        selectedId: selected?.id,
        onSelect: (p) {
          unawaited(widget.haptics.selection());
          setState(() => _selectedId = p.id);
        },
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
        title: Text(l10n.financeLoansTitle),
      ),
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: BhBottomBar(
        apaScreen: 'loans',
        primary: BhButton(
          key: LoansScreen.applyKey,
          label: l10n.loanApply,
          loading: action.busy,
          onPressed: selected == null ? null : () => _apply(selected),
        ),
      ),
    );
  }

  Future<void> _apply(LoanProduct product) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final application = await ref
        .read(financeControllerProvider.notifier)
        .applyLoan(product);
    if (application == null) {
      // A failed request is a warning; `error()` is for a wrong PIN (6.3).
      unawaited(widget.haptics.warning());
      messenger.showSnackBar(SnackBar(content: Text(l10n.financeActionFailed)));
      return;
    }
    unawaited(widget.haptics.success());
    messenger.showSnackBar(SnackBar(content: Text(l10n.loanApplied)));
  }
}

class _LoansBody extends StatelessWidget {
  const _LoansBody({
    required this.state,
    required this.selectedId,
    required this.onSelect,
  });

  final FinanceState state;
  final String? selectedId;
  final ValueChanged<LoanProduct> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.m,
        BhSpace.m,
        BhSpace.l,
      ),
      children: [
        _Eligibility(state: state),
        const SizedBox(height: BhSpace.l),
        SectionHeader(title: l10n.loanProducts),
        StaggeredReveal(
          children: [
            for (final (i, product) in LoanProducts.all.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : BhSpace.s),
                child: LoanProductCard(
                  product: product,
                  eligible: state.canBorrow(product),
                  selected: product.id == selectedId,
                  onSelect: () => onSelect(product),
                ),
              ),
          ],
        ),
        const SizedBox(height: BhSpace.m),
        KeyedSubtree(
          key: const Key('loan_never_otp'),
          child: DemoNote(l10n.loanNeverAsksOtp, icon: Icons.lock_outline),
        ),
        if (state.applications.isNotEmpty) ...[
          const SizedBox(height: BhSpace.l),
          SectionHeader(title: l10n.loanApplications),
          StaggeredReveal(
            children: [
              for (final (i, a) in state.applications.indexed)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : BhSpace.s),
                  child: LoanApplicationRow(application: a),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The limit as a hero, no card (3.3): caption, amount, muted income line.
class _Eligibility extends StatelessWidget {
  const _Eligibility({required this.state});

  final FinanceState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return Column(
      key: const Key('loan_eligibility'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HeroBalance.value(
          state.loanLimitBdt,
          captionOverride: l10n.loanYouCanGet,
          showToggle: false,
        ),
        if (state.monthlyIncomeBdt > 0)
          Text(
            l10n.loanIncomeLine(context.taka(state.monthlyIncomeBdt)),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: p.mutedText),
          ),
      ],
    );
  }
}

/// One loan offer as a selectable 4.3-style row: the name with the
/// "ডেমো ফি" tag pinned to the trailing padding line, the amount in
/// `titleSmall`, tenure and monthly repayment as the subtitle, and the total
/// repayable. Over the limit: not selectable, with a muted reason.
class LoanProductCard extends StatelessWidget {
  const LoanProductCard({
    required this.product,
    required this.eligible,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final LoanProduct product;
  final bool eligible;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final name = context.localName(product.nameBn, product.nameEn);
    final subtitle = l10n.loanRowSubtitle(
      l10n.loanTenureMonths(product.tenureMonths),
      context.taka(product.monthlyBdt),
    );
    final total =
        '${l10n.loanTotalRepayable} ${context.taka(product.totalRepayableBdt)}';
    final muted = text.bodySmall?.copyWith(color: p.mutedText);
    return Pressable(
      key: Key('loan_product_${product.id}'),
      onTap: eligible ? onSelect : null,
      selected: selected,
      semanticLabel: [
        name,
        context.taka(product.amountBdt),
        subtitle,
        if (!eligible) l10n.loanOverLimit,
      ].join(', '),
      child: AnimatedContainer(
        duration: BhMotion.of(context).fast,
        padding: const EdgeInsets.all(BhSpace.m - 2),
        decoration: BoxDecoration(
          color: selected ? p.primaryContainer : p.surfaceVariant,
          border: Border.all(
            color: selected ? p.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: eligible ? p.onSurface : p.mutedText,
                    ),
                  ),
                ),
                const SizedBox(width: BhSpace.s),
                StatusTag(
                  label: l10n.loanDemoFee(
                    context.digits(percentLabel(product.flatFeePct)),
                  ),
                  // A neutral fact, not a hold: info, never amber.
                  status: BhStatus.info,
                ),
              ],
            ),
            const SizedBox(height: BhSpace.xs),
            Text(
              context.taka(product.amountBdt),
              key: Key('loan_amount_${product.id}'),
              style: text.titleSmall?.copyWith(
                color: eligible ? p.onSurface : p.mutedText,
              ),
            ),
            Text(subtitle, style: muted),
            Text(total, style: muted),
            if (!eligible) ...[
              const SizedBox(height: BhSpace.xs),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 20, color: p.mutedText),
                  const SizedBox(width: BhSpace.xs),
                  Expanded(child: Text(l10n.loanOverLimit, style: muted)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One filed application: product name and amount, the status tag pinned to
/// the trailing padding line.
class LoanApplicationRow extends StatelessWidget {
  const LoanApplicationRow({required this.application, super.key});

  final LoanApplication application;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final (label, status) = switch (application.status) {
      LoanStatus.approved => (l10n.loanStatusApproved, BhStatus.success),
      LoanStatus.rejected => (l10n.loanStatusRejected, BhStatus.danger),
      _ => (l10n.loanStatusPending, BhStatus.warning),
    };
    final product = application.product;
    final name = product == null
        ? l10n.loanGeneric
        : context.localName(product.nameBn, product.nameEn);
    return Container(
      color: p.surfaceVariant,
      padding: const EdgeInsets.all(BhSpace.m),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                Text(
                  context.taka(application.amountBdt),
                  style: text.bodySmall?.copyWith(color: p.mutedText),
                ),
              ],
            ),
          ),
          const SizedBox(width: BhSpace.s),
          StatusTag(label: label, status: status),
        ],
      ),
    );
  }
}
