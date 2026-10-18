import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/amount_display.dart';
import '../../../app/widgets/bangla_numpad.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/choice_tile.dart';
import '../../../app/widgets/recipient_row.dart';
import '../../../app/widgets/step_progress.dart';
import '../../../core/haptics.dart';
import '../../../data/native/bhorosha_native.dart';
import '../logic/pay_controller.dart';
import '../logic/pay_ledger.dart';
import '../logic/pay_paths.dart';
import '../logic/pay_rules.dart';
import '../logic/payee_map.dart';
import 'widgets/pay_format.dart';
import 'widgets/payee_state_line.dart';

/// The shared amount step: a fixed, non-scrolling
/// column with measured heights. Regular when the body (between the app bar
/// and the bottom bar) is at least [compactBelow] tall, compact otherwise,
/// so the decision includes the status bar, the demo banner and the
/// navigation bar. Compact folds the recipient into a 28 dp line above the
/// amount and the status line into the primary label.
///
/// The primary's label doubles as the disabled reason (no line under the
/// bar), and its semantics label is the same sentence.
///
/// Cash in uses this as its first step (no recipient, "কোড তৈরি করুন").
class AmountStep extends ConsumerStatefulWidget {
  const AmountStep({
    required this.kind,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  final PayKind kind;
  final Haptics haptics;

  /// Bodies shorter than this use the compact layout.
  static const compactBelow = 560.0;

  @override
  ConsumerState<AmountStep> createState() => _AmountStepState();
}

class _AmountStepState extends ConsumerState<AmountStep> {
  int _nudge = 0;

  /// Computed once per kind, not per key press.
  late final List<int> _quickAmounts = PayRules.quickAmounts(_kind);

  /// Set by a quick-amount pick: the display rolls from the old value;
  /// cleared by any typing.
  int? _rollFrom;

  PayKind get _kind => widget.kind;

  @override
  void initState() {
    super.initState();
    // Step 1 (PayStartScreen) owns FLAG_SECURE; this step only turns it on.
    // Cash in's amount step *is* step 1, which already did.
    if (_kind != PayKind.cashIn) {
      unawaited(
        ref.read(nativeProvider).setSecure(AppEnv.secureScreensEnabled),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _kind == PayKind.cashIn) return;
      final intent = ref.read(payControllerProvider);
      if (intent.kind != _kind || intent.counterparty == null) {
        context.go(PayPaths.start(_kind));
      }
    });
  }

  PayController get _ctl => ref.read(payControllerProvider.notifier);

  void _digit(int d) {
    unawaited(widget.haptics.key());
    _typed();
    if (!_ctl.appendDigit(d)) _refuse();
  }

  void _typed() {
    if (_rollFrom != null) setState(() => _rollFrom = null);
  }

  void _doubleZero() {
    unawaited(widget.haptics.key());
    _typed();
    if (!_ctl.appendDoubleZero()) _refuse();
  }

  void _refuse() {
    unawaited(widget.haptics.warning());
    setState(() => _nudge++);
  }

  void _backspace() {
    unawaited(widget.haptics.key());
    _typed();
    _ctl.backspaceAmount();
  }

  void _clear() {
    unawaited(widget.haptics.warning());
    _typed();
    _ctl.clearAmount();
  }

  void _pick(int a) {
    unawaited(widget.haptics.selection());
    setState(() => _rollFrom = ref.read(payControllerProvider).amountBdt);
    _ctl.setAmount(a);
  }

  void _next() {
    if (_kind == PayKind.send) {
      final c = ref.read(payControllerProvider).counterparty;
      _ctl.recordPayeeLine(unfamiliar: !(c?.isSaved ?? true));
    }
    context.go(
      _kind == PayKind.cashIn ? PayPaths.code(_kind) : PayPaths.pin(_kind),
    );
  }

  void _back() => context.go(
    _kind == PayKind.cashIn ? PayPaths.home : PayPaths.start(_kind),
  );

  String _caption(AppLocalizations l10n) => switch (_kind) {
    PayKind.cashOut => l10n.amountHowMuchCashOut,
    PayKind.cashIn => l10n.amountHowMuchCashIn,
    PayKind.recharge => l10n.amountHowMuchRecharge,
    _ => l10n.amountHowMuch,
  };

  /// The primary's label: the disabled reason, or what it does (2.2 table).
  ({String label, bool enabled}) _primary(
    BuildContext context,
    PayIntent intent, {
    required bool compact,
  }) {
    final l10n = context.l10n;
    return switch (PayRules.checkAmount(_kind, intent.amountBdt)) {
      AmountCheck.empty => (label: l10n.amountEnter, enabled: false),
      AmountCheck.outOfRange => (
        label: l10n.amountRange(
          context.taka(PayRules.rechargeMin),
          context.taka(PayRules.rechargeMax),
        ),
        enabled: false,
      ),
      AmountCheck.belowMin => (
        label: l10n.amountMin(context.taka(PayRules.cashOutMin)),
        enabled: false,
      ),
      AmountCheck.ok => (
        label: _kind == PayKind.cashIn
            ? l10n.cashInMakeCode
            : compact && _kind == PayKind.cashOut
            ? l10n.nextWithTotal(context.taka(intent.debitBdt))
            : '${l10n.next} →',
        enabled: true,
      ),
    };
  }

  /// Regular-only line under the amount, first match wins: cash-out fee,
  /// over balance (caution), balance.
  Widget? _status(BuildContext context, PayIntent intent, double? balance) {
    final l10n = context.l10n;
    final p = context.palette;
    if (_kind == PayKind.cashOut && intent.amountBdt > 0) {
      return Text(
        l10n.amountFeeLine(
          context.taka(intent.feeBdt),
          context.taka(intent.debitBdt),
        ),
        key: const Key('amount_status'),
        style: TextStyle(color: p.mutedText),
      );
    }
    if (balance == null) return null;
    final debit = _kind != PayKind.cashIn;
    if (debit && intent.debitBdt > balance) {
      return Text(
        l10n.amountOverBalance(context.taka(balance)),
        key: const Key('amount_status'),
        style: TextStyle(color: p.warning),
      );
    }
    return Text(
      l10n.amountBalanceLine(context.taka(balance)),
      key: const Key('amount_status'),
      style: TextStyle(color: p.mutedText),
    );
  }

  /// The amount-dependent fields; everything else on this step (the
  /// scaffold, the step bar, the recipient, the chips, the twelve keys)
  /// is built once and left alone while the customer types.
  static (int amount, int fee, int debit) _money(PayIntent i) =>
      (i.amountBdt, i.feeBdt, i.debitBdt);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The recipient and operator change on step 1 only: a key press on the
    // numpad does not rebuild this widget.
    final c = ref.watch(payControllerProvider.select((i) => i.counterparty));
    final operator = ref.watch(payControllerProvider.select((i) => i.operator));
    final shortScreen =
        MediaQuery.sizeOf(context).height < BhSize.compactBelowHeight;
    final total = _kind == PayKind.cashIn ? 2 : 3;
    final step = _kind == PayKind.cashIn ? 1 : 2;
    final line = _kind == PayKind.recharge && c != null
        ? [
            context.counterpartyNumber(c),
            if (operator != null) context.operatorName(operator),
          ].join(' · ')
        : null;

    return LayoutBuilder(
      builder: (context, screen) {
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: shortScreen ? BhSize.appBarCompact : BhSize.appBar,
            title: Text(context.payTitle(_kind)),
            leading: BackButton(onPressed: _back),
          ),
          bottomNavigationBar: Consumer(
            builder: (context, ref, _) {
              // Only the label and enabled state follow the amount.
              ref.watch(payControllerProvider.select(_money));
              final intent = ref.read(payControllerProvider);
              // The bar's label needs the layout decision; recompute it from
              // the same threshold the body uses.
              final compact = _bodyCompact(context);
              final primary = _primary(context, intent, compact: compact);
              return BhBottomBar(
                apaScreen: 'amount',
                primary: BhButton(
                  key: const Key('amount_next'),
                  label: primary.label,
                  semanticsLabel: primary.label,
                  onPressed: primary.enabled ? _next : null,
                ),
              );
            },
          ),
          body: LayoutBuilder(
            builder: (context, body) {
              final compact = body.maxHeight < AmountStep.compactBelow;
              if (_lastCompact != compact) {
                final first = _lastCompact == null;
                _lastCompact = compact;
                // The bottom bar built before this layout; rebuild it with
                // the measured decision (one extra frame, first time only
                // unless the screen changes).
                if (!first || compact != _bodyCompactGuess(context)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                }
              }
              final gap = compact ? BhSpace.xs : BhSpace.s;
              return Column(
                children: [
                  StepProgress(step: step, total: total),
                  if (!compact && c != null) ...[
                    RecipientSummary(
                      counterparty: c,
                      changeLabel: l10n.change,
                      onChange: _back,
                      line: line,
                    ),
                    if (_kind == PayKind.send)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          BhSpace.m + BhSize.avatar + BhSpace.m,
                          0,
                          BhSpace.m,
                          BhSpace.s,
                        ),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: PayeeStateLine(saved: c.isSaved),
                        ),
                      ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: context.palette.outlineVariant,
                    ),
                  ],
                  Expanded(
                    child: ClipRect(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: BhSpace.m,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: screen.maxWidth - 2 * BhSpace.m,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (compact && c != null)
                                    RecipientSummary(
                                      counterparty: c,
                                      changeLabel: l10n.change,
                                      onChange: _back,
                                      compact: true,
                                      line: line,
                                    ),
                                  if (compact &&
                                      c != null &&
                                      _kind == PayKind.send)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: BhSpace.xs,
                                      ),
                                      child: PayeeStateLine(saved: c.isSaved),
                                    ),
                                  Consumer(
                                    builder: (context, ref, _) {
                                      ref.watch(
                                        payControllerProvider.select(_money),
                                      );
                                      final intent = ref.read(
                                        payControllerProvider,
                                      );
                                      final balance = ref
                                          .watch(payBalanceProvider)
                                          .value;
                                      return AmountDisplay(
                                        amount: intent.amountBdt,
                                        compact: compact,
                                        caption: _caption(l10n),
                                        status: _status(
                                          context,
                                          intent,
                                          balance,
                                        ),
                                        nudge: _nudge,
                                        rollFrom: _rollFrom,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      BhSpace.m,
                      gap,
                      BhSpace.m,
                      gap,
                    ),
                    child: Consumer(
                      builder: (context, ref, _) => QuickAmountRow(
                        amounts: _quickAmounts,
                        selected: ref.watch(
                          payControllerProvider.select((i) => i.amountBdt),
                        ),
                        onPick: _pick,
                        height: compact ? 48 : BhSize.touch,
                      ),
                    ),
                  ),
                  Numpad(
                    variant: NumpadVariant.amount,
                    keyHeight: compact ? BhSize.keyCompact : BhSize.keyAmount,
                    gap: gap,
                    onDigit: _digit,
                    onDoubleZero: _doubleZero,
                    onBackspace: _backspace,
                    onClear: _clear,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// The body's layout decision from the last build (the bottom bar builds
  /// first, so the first frame falls back to the screen height).
  bool? _lastCompact;

  bool _bodyCompact(BuildContext context) =>
      _lastCompact ?? _bodyCompactGuess(context);

  bool _bodyCompactGuess(BuildContext context) =>
      MediaQuery.sizeOf(context).height < BhSize.compactBelowHeight;
}
