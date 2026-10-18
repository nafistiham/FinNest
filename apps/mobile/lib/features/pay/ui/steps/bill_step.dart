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
import '../../logic/billers.dart';
import '../../logic/pay_controller.dart';
import '../../logic/pay_paths.dart';
import '../widgets/number_entry.dart';
import '../widgets/pay_format.dart';
import '../widgets/pay_step_scaffold.dart';

IconData billerIcon(Biller b) => switch (b.icon) {
  'electricity' => Icons.bolt_outlined,
  'water' => Icons.water_drop_outlined,
  'gas' => Icons.local_fire_department_outlined,
  _ => Icons.receipt_long_outlined,
};

/// Pay bill, step 1 of 3: three billers as rows with
/// icon tiles; a tap opens the "গ্রাহক নম্বর" panel (8 digits DESCO, 10
/// WASA, 9 Titas) and "বিল দেখুন" opens the bill card.
class BillStep extends ConsumerStatefulWidget {
  const BillStep({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  @override
  ConsumerState<BillStep> createState() => _BillStepState();
}

class _BillStepState extends ConsumerState<BillStep> {
  Biller? _biller;
  NumberEntryController? _account;

  @override
  void dispose() {
    _account?.dispose();
    super.dispose();
  }

  void _open(Biller b) {
    unawaited(widget.haptics.selection());
    if (_biller?.id != b.id) {
      _account?.dispose();
      _account = NumberEntryController(
        kind: NumberKind.account,
        length: b.accountDigits,
      );
    }
    _biller = b;
    setState(_account!.open);
  }

  void _close() => setState(() => _account?.close());

  void _see() {
    final b = _biller!;
    ref
        .read(payControllerProvider.notifier)
        .setBill(Bill(biller: b, account: _account!.digits));
    context.go(PayPaths.confirm(PayKind.bill));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final billers = ref.watch(billersProvider);
    final account = _account;
    final biller = _biller;
    final open = account != null && account.isOpen && biller != null;

    return PayStepScaffold(
      title: l10n.featureBill,
      step: 1,
      total: 3,
      onClosePanel: _close,
      panel: open
          ? NumberEntryPanel(
              controller: account,
              title: '${context.billerName(biller)} · ${l10n.billAccount}',
              haptics: widget.haptics,
              onCancel: _close,
            )
          : null,
      bottomBar: open
          ? ListenableBuilder(
              listenable: account,
              builder: (context, _) {
                final label = account.isComplete
                    ? '${l10n.billSee} →'
                    : l10n.billAccountNeed(
                        context.digits('${biller.accountDigits}'),
                      );
                return BhBottomBar(
                  apaScreen: 'bill',
                  primary: BhButton(
                    key: const Key('bill_see'),
                    label: label,
                    semanticsLabel: label,
                    onPressed: account.isComplete ? _see : null,
                  ),
                );
              },
            )
          : const BhBottomBar.apa(
              apaScreen: 'bill',
              style: ApaBarStyle.secondary,
            ),
      list: ListView(
        key: const Key('biller_list'),
        padding: const EdgeInsets.only(top: BhSpace.s, bottom: BhSpace.m),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: DemoNote(l10n.demoNoteFeature),
          ),
          const SizedBox(height: BhSpace.m),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: SectionHeader(title: l10n.billWhich),
          ),
          ...switch (billers) {
            AsyncData(:final value) => [
              for (final b in value)
                RecipientRow(
                  key: Key('biller_${b.id}'),
                  counterparty: Counterparty(
                    acctId: 'biller_${b.id}',
                    nameBn: b.nameBn,
                    nameEn: b.nameEn,
                    avatar: CounterpartyAvatar.icon(billerIcon(b)),
                  ),
                  onTap: () => _open(b),
                ),
            ],
            AsyncError() => [
              Padding(
                padding: const EdgeInsets.all(BhSpace.m),
                child: Text(l10n.financeLoadFailed),
              ),
            ],
            _ => [
              const Padding(
                padding: EdgeInsets.all(BhSpace.l),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
          },
        ],
      ),
    );
  }
}
