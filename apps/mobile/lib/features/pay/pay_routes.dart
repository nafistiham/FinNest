/// Routes of the shared money flow:
///
/// ```
/// /pay/:kind            step 1 (PayStartScreen; cash in: the amount step)
/// /pay/:kind/amount     shared amount step (send, cash out, recharge)
/// /pay/bill/confirm     the bill card (replaces the amount step)
/// /pay/:kind/pin        PIN pad (every kind but cash in)
/// /pay/dps/pin          DPS first instalment (from the Savings sheet)
/// /pay/:kind/result     outcome (?state=&amount=&txn=&banner=&intervention=)
/// /pay/cashin/code      cash-in reference code
/// ```
///
/// The router (`lib/app/router.dart`) spreads [payRoutes] into its route
/// list and maps the old `/send`, `/send/pin`, `/send/result` with
/// [payLegacyRoutes] (or [payLegacyRedirect]).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/theme.dart';
import '../pin_pad/ui/pin_pad_screen.dart';
import '../result/ui/result_screen.dart';
import 'logic/pay_paths.dart';
import 'ui/amount_step.dart';
import 'ui/bill_confirm_step.dart';
import 'ui/cash_in_code_screen.dart';
import 'ui/pay_start_screen.dart';

export 'logic/pay_intent.dart' show PayKind;
export 'logic/pay_paths.dart';

PayKind _kindOf(GoRouterState s) =>
    PayKind.parse(s.pathParameters['kind']) ?? PayKind.send;

/// Steps inside a pay flow: the incoming page slides in from +24 dp and
/// fades in over `normal`; back reverses. Instant with reduce motion.
Page<void> _step(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: BhMotion.standard.normal,
      reverseTransitionDuration: BhMotion.standard.exit,
      transitionsBuilder: (context, animation, secondary, child) {
        if (BhMotion.of(context).reduced) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: BhCurves.enter,
          reverseCurve: BhCurves.exit,
        );
        return AnimatedBuilder(
          animation: curved,
          child: child,
          builder: (_, child) => Opacity(
            opacity: curved.value,
            child: Transform.translate(
              offset: Offset(24 * (1 - curved.value), 0),
              child: child,
            ),
          ),
        );
      },
    );

String? _onlyFor(GoRouterState s, bool Function(PayKind) allowed) {
  final k = PayKind.parse(s.pathParameters['kind']);
  if (k == null) return PayPaths.home;
  return allowed(k) ? null : PayPaths.start(k);
}

/// The `/pay/:kind` tree. Any other `:kind` redirects to `/home`; a step a
/// kind does not have redirects to that kind's step 1.
final List<RouteBase> payRoutes = [
  GoRoute(
    path: '/pay/:kind',
    redirect: (_, s) => switch (PayKind.parse(s.pathParameters['kind'])) {
      null => PayPaths.home,
      // A DPS has no step 1 or amount step: it starts on Savings.
      PayKind.dps when s.uri.path == PayPaths.start(PayKind.dps) =>
        PayPaths.savings,
      _ => null,
    },
    builder: (_, s) => PayStartScreen(kind: _kindOf(s)),
    routes: [
      GoRoute(
        path: 'amount',
        redirect: (_, s) =>
            _onlyFor(s, (k) => !k.fixedAmount && k != PayKind.cashIn),
        pageBuilder: (_, s) => _step(s, AmountStep(kind: _kindOf(s))),
      ),
      GoRoute(
        path: 'confirm',
        redirect: (_, s) => _onlyFor(s, (k) => k == PayKind.bill),
        pageBuilder: (_, s) => _step(s, const BillConfirmStep()),
      ),
      GoRoute(
        path: 'pin',
        redirect: (_, s) => _onlyFor(s, (k) => k.usesPin),
        pageBuilder: (_, s) => _step(s, PinPadScreen(kind: _kindOf(s))),
      ),
      GoRoute(
        path: 'code',
        redirect: (_, s) => _onlyFor(s, (k) => k == PayKind.cashIn),
        pageBuilder: (_, s) => _step(s, const CashInCodeScreen()),
      ),
      GoRoute(
        path: 'result',
        builder: (_, s) {
          final q = s.uri.queryParameters;
          return ResultScreen(
            kind: _kindOf(s),
            state: q['state'] ?? ResultScreen.done,
            amount: int.tryParse(q['amount'] ?? ''),
            txnId: q['txn'],
            showBanner: q['banner'] == '1',
            interventionId: q['intervention'],
          );
        },
      ),
    ],
  ),
];

/// `/send` → `/pay/send`, `/send/pin` → `/pay/send/pin`, `/send/result?…`
/// → `/pay/send/result?…` (query kept); null for anything else.
String? payLegacyRedirect(Uri uri) {
  final path = uri.path;
  if (path != '/send' && !path.startsWith('/send/')) return null;
  final rest = path.substring('/send'.length);
  return Uri(
    path: '/pay/send$rest',
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}

/// The old send-money routes as redirects, for the app router.
final List<RouteBase> payLegacyRoutes = [
  GoRoute(
    path: '/send',
    redirect: (_, s) => payLegacyRedirect(s.uri),
    routes: [
      GoRoute(path: 'pin', redirect: (_, s) => payLegacyRedirect(s.uri)),
      GoRoute(path: 'result', redirect: (_, s) => payLegacyRedirect(s.uri)),
    ],
  ),
];
