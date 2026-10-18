import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dates.dart';
import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/digit_slots.dart';
import '../../../app/widgets/step_progress.dart';
import '../../../data/native/bhorosha_native.dart';
import '../logic/pay_controller.dart';
import '../logic/pay_paths.dart';
import 'steps/bill_step.dart' show billerIcon;
import 'widgets/pay_format.dart';

/// Pay bill, step 2 of 3: the bill card replaces the amount step (the
/// amount is fixed). Biller, customer number in fours, billed month, the
/// amount as the largest thing on screen, due date, and a muted "ডেমো বিল".
class BillConfirmStep extends ConsumerStatefulWidget {
  const BillConfirmStep({super.key});

  @override
  ConsumerState<BillConfirmStep> createState() => _BillConfirmStepState();
}

class _BillConfirmStepState extends ConsumerState<BillConfirmStep> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(nativeProvider).setSecure(AppEnv.secureScreensEnabled));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(payControllerProvider).bill == null) {
        context.go(PayPaths.start(PayKind.bill));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final bill = ref.watch(payControllerProvider).bill;
    final locale = Localizations.localeOf(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.featureBill),
        leading: BackButton(
          onPressed: () => context.go(PayPaths.start(PayKind.bill)),
        ),
      ),
      bottomNavigationBar: BhBottomBar(
        apaScreen: 'bill',
        primary: BhButton(
          key: const Key('bill_pay'),
          label: l10n.billPay,
          icon: Icons.receipt_long_outlined,
          onPressed: bill == null
              ? null
              : () => context.go(PayPaths.pin(PayKind.bill)),
        ),
      ),
      body: Column(
        children: [
          const StepProgress(step: 2, total: 3),
          if (bill != null)
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(BhSpace.m),
                children: [
                  Container(
                    key: const Key('bill_card'),
                    color: p.surfaceVariant,
                    padding: const EdgeInsets.all(BhSpace.m),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              billerIcon(bill.biller),
                              size: 24,
                              color: p.mutedText,
                            ),
                            const SizedBox(width: BhSpace.s),
                            Expanded(
                              child: Text(
                                context.billerName(bill.biller),
                                style: text.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: BhSpace.xs),
                        Text(
                          '${l10n.billAccount} ${context.digits(bill.accountGrouped)}',
                          style: text.bodySmall?.copyWith(color: p.mutedText),
                        ),
                        Text(
                          BhDates.monthYear(bill.biller.month, locale),
                          style: text.bodySmall?.copyWith(color: p.mutedText),
                        ),
                        const SizedBox(height: BhSpace.m),
                        TakaSlots(
                          key: const Key('bill_amount'),
                          amount: bill.amountBdt,
                          style: context.textRoles.amountHero.copyWith(
                            color: p.onSurface,
                          ),
                          signColor: p.mutedText,
                        ),
                        const SizedBox(height: BhSpace.s),
                        Text(
                          l10n.billDue(
                            BhDates.longDate(bill.biller.due, locale),
                          ),
                          style: text.bodyMedium,
                        ),
                        const SizedBox(height: BhSpace.xs),
                        Text(
                          l10n.billDemo,
                          style: text.bodySmall?.copyWith(color: p.mutedText),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
