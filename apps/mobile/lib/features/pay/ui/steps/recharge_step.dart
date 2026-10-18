import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/bh_bottom_bar.dart';
import '../../../../app/widgets/bh_button.dart';
import '../../../../app/widgets/choice_tile.dart';
import '../../../../app/widgets/demo_note.dart';
import '../../../../app/widgets/recipient_row.dart';
import '../../../../app/widgets/section_header.dart';
import '../../../../core/haptics.dart';
import '../../../../data/providers.dart';
import '../../../../data/repos/repos.dart';
import '../../logic/pay_controller.dart';
import '../../logic/pay_paths.dart';
import '../../logic/pay_rules.dart';
import '../widgets/number_entry.dart';
import '../widgets/pay_format.dart';
import '../widgets/pay_step_scaffold.dart';

/// Mobile recharge, step 1 of 3: "কোন নম্বরে?" with
/// the customer's own number first, saved payees' numbers next, then "অন্য
/// নম্বর" (inline number panel). Under the chosen number: the operator
/// chips, auto-picked by prefix (a guess: numbers are portable, so the
/// customer can change it), and prepaid / postpaid. Operator names are
/// plain text only.
class RechargeStep extends ConsumerStatefulWidget {
  const RechargeStep({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  @override
  ConsumerState<RechargeStep> createState() => _RechargeStepState();
}

class _RechargeStepState extends ConsumerState<RechargeStep> {
  final _number = NumberEntryController();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  PayController get _ctl => ref.read(payControllerProvider.notifier);

  static Counterparty _forNumber(
    String digits,
    String nameBn,
    String? nameEn,
  ) => Counterparty(
    acctId: 'mob_$digits',
    nameBn: nameBn,
    nameEn: nameEn,
    subtitle: digits,
    avatar: CounterpartyAvatar.operator(
      Operator.forNumber(digits) ?? Operator.a,
    ),
  );

  void _select(Counterparty c) {
    unawaited(widget.haptics.selection());
    _ctl
      ..setOperator(Operator.forNumber(c.subtitle))
      ..selectCounterparty(c);
  }

  void _confirmOther() {
    final d = _number.digits;
    final grouped = PayRules.groupPhone(d);
    _select(_forNumber(d, grouped, grouped));
    setState(_number.close);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final user = ref.watch(currentUserProvider).value;
    final intent = ref.watch(payControllerProvider);
    final payees = user == null
        ? const <Payee>[]
        : ref.watch(ledgerRepoProvider).savedPayees(user.persona);
    final open = _number.isOpen;
    final chosen = intent.kind == PayKind.recharge ? intent.counterparty : null;
    final op = intent.operator;

    final numbers = <Counterparty>[
      if (user != null && user.phoneMasked.isNotEmpty)
        _forNumber(user.phoneMasked, user.nameBn, user.nameEn),
      for (final payee in payees)
        if (payee.phoneMasked.isNotEmpty)
          _forNumber(payee.phoneMasked, payee.nameBn, payee.nameEn),
    ];
    // A number typed in the panel that is not one of the rows.
    if (chosen != null && !numbers.any((n) => n.acctId == chosen.acctId)) {
      numbers.add(chosen);
    }

    final guess = chosen == null ? null : Operator.forNumber(chosen.subtitle);
    final ready = chosen != null && op != null;
    final label = chosen == null
        ? l10n.rechargeChooseNumber
        : op == null
        ? l10n.rechargeChooseOperator
        : '${l10n.next} →';

    return PayStepScaffold(
      title: l10n.featureRecharge,
      step: 1,
      total: 3,
      onClosePanel: () => setState(_number.close),
      panel: open
          ? NumberEntryPanel(
              controller: _number,
              title: l10n.rechargeOther,
              haptics: widget.haptics,
              onCancel: () => setState(_number.close),
            )
          : null,
      bottomBar: open
          ? ListenableBuilder(
              listenable: _number,
              builder: (context, _) {
                final l = switch (_number.check) {
                  PhoneCheck.incomplete => l10n.numberNeed11,
                  PhoneCheck.invalid => l10n.numberInvalid,
                  PhoneCheck.valid => l10n.numberUseThis,
                };
                return BhBottomBar(
                  apaScreen: 'recharge',
                  primary: BhButton(
                    key: const Key('number_confirm'),
                    label: l,
                    semanticsLabel: l,
                    onPressed: _number.isValid ? _confirmOther : null,
                  ),
                );
              },
            )
          : BhBottomBar(
              apaScreen: 'recharge',
              primary: BhButton(
                key: const Key('recharge_next'),
                label: label,
                semanticsLabel: label,
                onPressed: ready
                    ? () => context.go(PayPaths.amount(PayKind.recharge))
                    : null,
              ),
            ),
      list: ListView(
        key: const Key('recharge_list'),
        padding: const EdgeInsets.only(top: BhSpace.s, bottom: BhSpace.m),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: DemoNote(l10n.demoNoteFeature),
          ),
          const SizedBox(height: BhSpace.m),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: SectionHeader(title: l10n.rechargeWhich),
          ),
          for (final (i, n) in numbers.indexed)
            RecipientRow(
              key: Key('recharge_${n.subtitle}'),
              counterparty: n,
              selected: chosen?.acctId == n.acctId,
              subtitle: i == 0 && user != null && n.subtitle == user.phoneMasked
                  ? '${l10n.rechargeMine} · ${context.counterpartyNumber(n)}'
                  : null,
              trailing: chosen?.acctId == n.acctId
                  ? Icon(Icons.check, color: p.primary)
                  : const SizedBox(width: 24),
              onTap: () => _select(n),
            ),
          RecipientRow.action(
            key: const Key('recharge_other'),
            icon: Icons.dialpad,
            title: l10n.rechargeOther,
            onTap: () {
              unawaited(widget.haptics.light());
              setState(_number.open);
            },
          ),
          if (chosen != null) ...[
            const SizedBox(height: BhSpace.l),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
              child: SectionHeader(title: l10n.rechargeOperator),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
              child: _OperatorChips(
                selected: op,
                onPick: (o) {
                  unawaited(widget.haptics.selection());
                  _ctl.setOperator(o);
                },
              ),
            ),
            if (guess != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  BhSpace.m,
                  BhSpace.s,
                  BhSpace.m,
                  0,
                ),
                child: Text(
                  l10n.rechargeOperatorGuess(context.operatorName(guess)),
                  key: const Key('recharge_operator_guess'),
                  style: text.bodySmall?.copyWith(color: p.mutedText),
                ),
              ),
            const SizedBox(height: BhSpace.m),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
              child: Row(
                children: [
                  Expanded(
                    child: ChoiceTile(
                      key: const Key('recharge_prepaid'),
                      label: l10n.rechargePrepaid,
                      selected: !intent.postpaid,
                      onTap: () => _ctl.setPostpaid(false),
                    ),
                  ),
                  const SizedBox(width: BhSpace.s),
                  Expanded(
                    child: ChoiceTile(
                      key: const Key('recharge_postpaid'),
                      label: l10n.rechargePostpaid,
                      selected: intent.postpaid,
                      onTap: () => _ctl.setPostpaid(true),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OperatorChips extends StatelessWidget {
  const _OperatorChips({required this.selected, required this.onPick});

  final Operator? selected;
  final ValueChanged<Operator> onPick;

  @override
  Widget build(BuildContext context) {
    Widget tile(Operator o) => Expanded(
      child: ChoiceTile(
        key: Key('op_${o.name}'),
        label: context.operatorName(o),
        selected: selected == o,
        onTap: () => onPick(o),
      ),
    );
    const ops = Operator.values;
    return Column(
      children: [
        Row(
          children: [
            tile(ops[0]),
            const SizedBox(width: BhSpace.s),
            tile(ops[1]),
            const SizedBox(width: BhSpace.s),
            tile(ops[2]),
          ],
        ),
        const SizedBox(height: BhSpace.s),
        Row(
          children: [
            tile(ops[3]),
            const SizedBox(width: BhSpace.s),
            tile(ops[4]),
            const SizedBox(width: BhSpace.s),
            const Spacer(),
          ],
        ),
      ],
    );
  }
}
