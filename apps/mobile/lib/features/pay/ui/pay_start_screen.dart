import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/env.dart';
import '../../../app/router.dart' show routeObserverProvider;
import '../../../data/native/bhorosha_native.dart';
import '../../../data/providers.dart';
import '../../send_money/ui/send_recipient_step.dart';
import '../logic/pay_controller.dart';
import 'amount_step.dart';
import 'steps/bill_step.dart';
import 'steps/cash_out_step.dart';
import 'steps/recharge_step.dart';

/// `/pay/:kind`, step 1 of every money flow (1.5).
///
/// Opening it starts a fresh [PayIntent] for [kind] (IMU window on), warms
/// the Cloud Run instance with `GET /health` for the scored kinds, and shows
/// that kind's first step: recipient (send), agent (cash out), number and
/// operator (recharge), biller and account (bill), or the amount itself
/// (cash in).
///
/// FR-5: this screen owns FLAG_SECURE for the whole `/pay/*` stack: on in
/// [State.initState] and again whenever a route above it pops (amount, PIN
/// pad, overlay), off only in [State.dispose], i.e. when the customer leaves
/// `/pay` entirely. The steps above it only ever turn it on.
///
/// It owns the IMU window the same way: leaving `/pay` (back from step 1,
/// "হোমে ফিরুন" on the result, any `go(home)`) disposes this screen, which
/// stops the accelerometer and gyroscope streams.
class PayStartScreen extends ConsumerStatefulWidget {
  const PayStartScreen({required this.kind, super.key});

  final PayKind kind;

  @override
  ConsumerState<PayStartScreen> createState() => _PayStartScreenState();
}

class _PayStartScreenState extends ConsumerState<PayStartScreen>
    with RouteAware {
  // Kept in fields: dispose() may not touch ref.
  late final BhoroshaNative _native;
  late final PayController _controller;
  late final RouteObserver<ModalRoute<void>> _routes;
  ModalRoute<void>? _route;

  @override
  void initState() {
    super.initState();
    _native = ref.read(nativeProvider);
    _routes = ref.read(routeObserverProvider);
    unawaited(_native.setSecure(AppEnv.secureScreensEnabled));
    _controller = ref.read(payControllerProvider.notifier);
    // begin() resets another provider's state: never inside build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A DPS was begun by the Savings sheet (plan and amount set); this
      // page only sits under its PIN route and must not reset it.
      if (!mounted || widget.kind == PayKind.dps) return;
      _controller.begin(widget.kind);
      // Warm-up only; the result is ignored.
      if (widget.kind.scored) unawaited(ref.read(riskApiProvider).health());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _routes.unsubscribe(this);
      _route = route;
      if (route != null) _routes.subscribe(this, route);
    }
  }

  /// A step above popped back here: re-arm secure, whatever it did on its
  /// way out.
  @override
  void didPopNext() =>
      unawaited(_native.setSecure(AppEnv.secureScreensEnabled));

  @override
  void dispose() {
    _routes.unsubscribe(this);
    unawaited(_native.setSecure(false));
    // The flow is over: no more motion sensors.
    unawaited(_controller.stopImu());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keeps the signed-in user alive for the whole /pay stack: the PIN pad
    // reads it, and nothing else on a bill or cash-in path watches it.
    ref.watch(currentUserProvider);
    return _step();
  }

  Widget _step() => switch (widget.kind) {
    PayKind.send => const SendRecipientStep(),
    PayKind.cashOut => const CashOutStep(),
    PayKind.recharge => const RechargeStep(),
    PayKind.bill => const BillStep(),
    PayKind.cashIn => const AmountStep(kind: PayKind.cashIn),
    // DPS starts on Savings; the route redirects there (pay_routes.dart).
    PayKind.dps => const SizedBox.shrink(),
  };
}
