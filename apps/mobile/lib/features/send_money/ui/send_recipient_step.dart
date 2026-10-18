import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dates.dart';
import '../../../app/l10n.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/recipient_row.dart';
import '../../../app/widgets/section_header.dart';
import '../../../app/widgets/step_progress.dart';
import '../../../core/haptics.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../../domain/behaviour/behaviour_sample.dart';
import '../../pay/logic/pay_controller.dart';
import '../../pay/logic/pay_ledger.dart';
import '../../pay/logic/pay_paths.dart';
import '../../pay/logic/pay_rules.dart';
import '../../pay/logic/payee_map.dart';
import '../../pay/ui/widgets/number_entry.dart';
import '../../pay/ui/widgets/pay_format.dart';
import '../logic/risk_providers.dart' show clockProvider;

/// Send money, step 1 of 3: choose the recipient.
///
/// Tapping a saved row selects it and opens the amount step in the same
/// frame (the eleven-seconds path keeps its tap count). "নতুন নম্বরে পাঠান"
/// swaps the list for the inline number panel, no new route. The whole list
/// is the one recorded swipe on this path: the `Listener` sees the raw
/// pointer before the scroll gesture claims it.
///
/// "সাম্প্রতিক" lists up to three recent recipients
/// that are not saved payees, from the ledger; picking one is the same as
/// confirming that number by hand (`is_new_payee: true`). A typed number
/// becomes an account id through [PayeeMap.acctForTyped] (demo ring map).
class SendRecipientStep extends ConsumerStatefulWidget {
  const SendRecipientStep({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  /// Search appears above "নতুন নম্বরে পাঠান" from this many saved payees.
  static const searchFrom = 7;

  @override
  ConsumerState<SendRecipientStep> createState() => _SendRecipientStepState();
}

class _SendRecipientStepState extends ConsumerState<SendRecipientStep> {
  final _number = NumberEntryController();
  String _query = '';

  /// A demo story opens `/pay/send?payee=<acct>` to land on that recent
  /// row; honoured once, after the rows have loaded.
  bool _preselected = false;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  PayController get _ctl => ref.read(payControllerProvider.notifier);

  // ----------------------------------------------------------- swipe record

  double get _dpr => MediaQuery.devicePixelRatioOf(context);

  Point2 _physical(Offset o) => Point2(o.dx * _dpr, o.dy * _dpr);

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  void _swipeDown(PointerDownEvent e) => _ctl.swipeRecorder.start(
    _physical(e.position),
    e.pressure,
    _now(),
    size: e.size,
  );

  void _swipeMove(PointerMoveEvent e) => _ctl.swipeRecorder.move(
    _physical(e.position),
    e.pressure,
    _now(),
    size: e.size,
  );

  void _swipeUp(PointerEvent e) => _ctl.swipeRecorder.end(
    _physical(e.position),
    e.pressure,
    _now(),
    size: e.size,
  );

  // -------------------------------------------------------------- actions

  void _pick(Payee p) {
    unawaited(widget.haptics.selection());
    _ctl.selectPayee(p);
    context.go(PayPaths.amount(PayKind.send));
  }

  void _pickRecent(Counterparty c) {
    unawaited(widget.haptics.selection());
    _ctl.selectCounterparty(c);
    context.go(PayPaths.amount(PayKind.send));
  }

  void _openPanel() {
    unawaited(widget.haptics.light());
    _number.open();
    setState(() {});
  }

  void _closePanel() {
    _number.close();
    setState(() {});
  }

  Payee? _savedMatch(List<Payee> payees) {
    final d = _number.digits;
    if (d.length != PayRules.phoneLength) return null;
    for (final p in payees) {
      if (p.phoneMasked == d) return p;
    }
    return null;
  }

  void _confirmNumber(List<Payee> payees) {
    final saved = _savedMatch(payees);
    if (saved != null) {
      _ctl.selectPayee(saved);
    } else {
      final d = _number.digits;
      final grouped = PayRules.groupPhone(d);
      _ctl.selectCounterparty(
        Counterparty(
          acctId: ref.read(payeeMapNowProvider).acctForTyped(d),
          nameBn: grouped,
          nameEn: grouped,
          subtitle: d,
          isSaved: false,
        ),
      );
    }
    context.go(PayPaths.amount(PayKind.send));
  }

  List<Payee> _filtered(List<Payee> all) {
    final q = asciiDigits(_query.trim()).toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final p in all)
        if (p.nameBn.toLowerCase().contains(q) ||
            p.nameEn.toLowerCase().contains(q) ||
            p.phoneMasked.contains(q))
          p,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final persona = ref.watch(
      currentUserProvider.select((u) => u.value?.persona),
    );
    final payees = persona == null
        ? const <Payee>[]
        : ref.watch(ledgerRepoProvider).savedPayees(persona);
    final rows = ref.watch(payRecentRowsProvider).value ?? const [];
    final acctId = ref.watch(
      currentUserProvider.select((u) => u.value?.acctId),
    );
    // Watched so the map is loaded by the time a number is confirmed.
    final payeeMap = ref.watch(payeeMapNowProvider);
    final recent = acctId == null
        ? const <Counterparty>[]
        : [
            for (final t in recentUnsavedSends(rows, acctId, payees))
              _recentCounterparty(context, t, payeeMap),
          ];
    final payeeParam = GoRouter.maybeOf(context) == null
        ? null
        : GoRouterState.of(context).uri.queryParameters['payee'];
    if (!_preselected && payeeParam != null) {
      final match = recent.where((c) => c.acctId == payeeParam).firstOrNull;
      if (match != null) {
        _preselected = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pickRecent(match);
        });
      }
    }
    final panel = _number.isOpen;
    final motion = BhMotion.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (panel) {
          _closePanel();
        } else {
          context.go(PayPaths.home);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.featureSend),
          leading: BackButton(onPressed: () => context.go(PayPaths.home)),
        ),
        bottomNavigationBar: panel
            ? ListenableBuilder(
                listenable: _number,
                builder: (context, _) {
                  final check = _number.check;
                  final label = switch (check) {
                    PhoneCheck.incomplete => l10n.numberNeed11,
                    PhoneCheck.invalid => l10n.numberInvalid,
                    PhoneCheck.valid => '${l10n.numberConfirm} →',
                  };
                  return BhBottomBar(
                    apaScreen: 'send',
                    primary: BhButton(
                      key: const Key('number_confirm'),
                      label: label,
                      semanticsLabel: label,
                      onPressed: check == PhoneCheck.valid
                          ? () => _confirmNumber(payees)
                          : null,
                    ),
                  );
                },
              )
            : const BhBottomBar.apa(
                apaScreen: 'send',
                style: ApaBarStyle.secondary,
              ),
        body: Column(
          children: [
            const StepProgress(step: 1, total: 3),
            Expanded(
              child: AnimatedSwitcher(
                duration: motion.normal,
                switchInCurve: BhCurves.enter,
                switchOutCurve: BhCurves.exit,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.08),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: panel
                    ? ListenableBuilder(
                        key: const ValueKey('panel'),
                        listenable: _number,
                        builder: (context, _) {
                          final saved = _savedMatch(payees);
                          return NumberEntryPanel(
                            controller: _number,
                            title: l10n.newNumber,
                            onCancel: _closePanel,
                            haptics: widget.haptics,
                            note: saved == null
                                ? null
                                : l10n.numberIsSaved(
                                    context.localName(
                                      saved.nameBn,
                                      saved.nameEn,
                                    ),
                                  ),
                          );
                        },
                      )
                    : _list(context, payees, rows, recent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A "সাম্প্রতিক" row: no name is known, so "নতুন নম্বর", the masked
  /// number and when it was last paid.
  Counterparty _recentCounterparty(
    BuildContext context,
    LedgerTxn t,
    PayeeMap map,
  ) => Counterparty(
    acctId: t.toAcct,
    nameBn: lookupAppLocalizations(const Locale('bn')).unknownNumber,
    nameEn: lookupAppLocalizations(const Locale('en')).unknownNumber,
    subtitle: map.maskedFor(t.toAcct),
    // The tile of a typed, unsaved number.
    avatar: const CounterpartyAvatar.icon(Icons.dialpad),
    isSaved: false,
  );

  Widget _list(
    BuildContext context,
    List<Payee> payees,
    List<LedgerTxn> rows,
    List<Counterparty> recent,
  ) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final shown = _filtered(payees);
    return Listener(
      key: const ValueKey('list'),
      onPointerDown: _swipeDown,
      onPointerMove: _swipeMove,
      onPointerUp: _swipeUp,
      onPointerCancel: _swipeUp,
      child: ListView(
        key: const Key('payee_list'),
        padding: const EdgeInsets.only(top: BhSpace.s, bottom: BhSpace.m),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: SectionHeader(title: l10n.sendWho),
          ),
          if (payees.length >= SendRecipientStep.searchFrom)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BhSpace.m,
                0,
                BhSpace.m,
                BhSpace.s,
              ),
              child: TextField(
                key: const Key('payee_search'),
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
          RecipientRow.action(
            key: const Key('send_new_number'),
            icon: Icons.dialpad,
            title: l10n.sendNewNumber,
            onTap: _openPanel,
          ),
          const SizedBox(height: BhSpace.l),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: SectionHeader(title: l10n.sendSaved),
          ),
          if (payees.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: BhSpace.m,
                vertical: BhSpace.m,
              ),
              child: Text(
                l10n.sendNoSaved,
                style: text.bodyMedium?.copyWith(color: p.mutedText),
              ),
            ),
          for (final (i, payee) in shown.indexed) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 80,
                color: p.outlineVariant,
              ),
            Builder(
              builder: (context) {
                final c = Counterparty(
                  acctId: payee.acctId,
                  nameBn: payee.nameBn,
                  nameEn: payee.nameEn,
                  subtitle: payee.phoneMasked,
                );
                final last = lastPaidTo(rows, payee.acctId);
                final number = context.counterpartyNumber(c);
                return RecipientRow(
                  key: Key('payee_${payee.acctId}'),
                  counterparty: c,
                  subtitle: last == null
                      ? number
                      : '$number · ${context.lastPaidLabel(last)}',
                  onTap: () => _pick(payee),
                );
              },
            ),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: BhSpace.l),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
              child: SectionHeader(
                key: const Key('recent_header'),
                title: l10n.payeeRecent,
              ),
            ),
            for (final (i, c) in recent.indexed) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 80,
                  color: p.outlineVariant,
                ),
              Builder(
                builder: (context) {
                  final last = lastPaidTo(rows, c.acctId);
                  final number = context.counterpartyNumber(c);
                  final when = last == null
                      ? null
                      : BhDates.rowLabel(
                          last,
                          Localizations.localeOf(context),
                          now: ref.read(clockProvider).now(),
                        );
                  return RecipientRow(
                    key: Key('recent_${c.acctId}'),
                    counterparty: c,
                    subtitle: when == null ? number : '$number · $when',
                    onTap: () => _pickRecent(c),
                  );
                },
              ),
            ],
          ],
          const SizedBox(height: BhSpace.l),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.info_outline, size: 20, color: p.mutedText),
                ),
                const SizedBox(width: BhSpace.s),
                Expanded(
                  child: Text(
                    l10n.sendHelper,
                    style: text.bodySmall?.copyWith(color: p.mutedText),
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
