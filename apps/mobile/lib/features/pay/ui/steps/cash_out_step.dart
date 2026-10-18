import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/bh_bottom_bar.dart';
import '../../../../app/widgets/bh_button.dart';
import '../../../../app/widgets/demo_note.dart';
import '../../../../app/widgets/recipient_row.dart';
import '../../../../app/widgets/section_header.dart';
import '../../../../core/haptics.dart';
import '../../../../data/providers.dart';
import '../../logic/pay_controller.dart';
import '../../logic/pay_ledger.dart';
import '../../logic/pay_paths.dart';
import '../../logic/pay_rules.dart';
import '../widgets/number_entry.dart';
import '../widgets/pay_step_scaffold.dart';

/// Cash out, step 1 of 3 (9.3): the customer stands at
/// the agent's counter and types the agent's wallet number. Two recent
/// agents from the history (`to_acct` of `cash_out` rows) come first, then
/// "নতুন এজেন্ট নম্বর" opens the inline number panel. A recent agent is a
/// known payee (`is_new_payee: false`); a typed one is new.
class CashOutStep extends ConsumerStatefulWidget {
  const CashOutStep({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  @override
  ConsumerState<CashOutStep> createState() => _CashOutStepState();
}

class _CashOutStepState extends ConsumerState<CashOutStep> {
  final _number = NumberEntryController();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _pick(Counterparty agent) {
    unawaited(widget.haptics.selection());
    ref.read(payControllerProvider.notifier).selectCounterparty(agent);
    context.go(PayPaths.amount(PayKind.cashOut));
  }

  void _confirm(List<Counterparty> recent) {
    final d = _number.digits;
    final acct = 'agent_$d';
    final known = recent.any((a) => a.acctId == acct);
    _pick(
      Counterparty(
        acctId: acct,
        nameBn: 'এজেন্ট',
        nameEn: 'Agent',
        subtitle: d,
        avatar: const CounterpartyAvatar.icon(Icons.storefront_outlined),
        isSaved: known,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final acct = ref.watch(currentUserProvider.select((u) => u.value?.acctId));
    final rows = ref.watch(payRecentRowsProvider).value ?? const [];
    final recent = acct == null
        ? const <Counterparty>[]
        : recentAgents(rows, acct);
    final open = _number.isOpen;

    return PayStepScaffold(
      title: l10n.featureCashOut,
      step: 1,
      total: 3,
      onClosePanel: () => setState(_number.close),
      panel: open
          ? NumberEntryPanel(
              controller: _number,
              title: l10n.cashOutNewAgent,
              haptics: widget.haptics,
              onCancel: () => setState(_number.close),
            )
          : null,
      bottomBar: open
          ? ListenableBuilder(
              listenable: _number,
              builder: (context, _) {
                final label = switch (_number.check) {
                  PhoneCheck.incomplete => l10n.numberNeed11,
                  PhoneCheck.invalid => l10n.numberInvalid,
                  PhoneCheck.valid => '${l10n.numberUseThis} →',
                };
                return BhBottomBar(
                  apaScreen: 'cashout',
                  primary: BhButton(
                    key: const Key('number_confirm'),
                    label: label,
                    semanticsLabel: label,
                    onPressed: _number.isValid ? () => _confirm(recent) : null,
                  ),
                );
              },
            )
          : const BhBottomBar.apa(
              apaScreen: 'cashout',
              style: ApaBarStyle.secondary,
            ),
      list: ListView(
        key: const Key('agent_list'),
        padding: const EdgeInsets.only(top: BhSpace.s, bottom: BhSpace.m),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: DemoNote(l10n.demoNoteFeature),
          ),
          const SizedBox(height: BhSpace.m),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: SectionHeader(title: l10n.cashOutAgent),
          ),
          for (final a in recent)
            RecipientRow(
              key: Key('agent_${a.acctId}'),
              counterparty: a,
              onTap: () => _pick(a),
            ),
          RecipientRow.action(
            key: const Key('cashout_new_agent'),
            icon: Icons.dialpad,
            title: l10n.cashOutNewAgent,
            onTap: () {
              unawaited(widget.haptics.light());
              setState(_number.open);
            },
          ),
          const SizedBox(height: BhSpace.l),
          PayHelperLine(l10n.cashOutHelper),
          const SizedBox(height: BhSpace.s),
          PayHelperLine(l10n.agentNeverPin, icon: Icons.shield_outlined),
        ],
      ),
    );
  }
}
