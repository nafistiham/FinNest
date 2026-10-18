import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../features/apa/ui/apa_screen.dart';
import '../features/approve/logic/approve_link.dart';
import '../features/approve/ui/approve_screen.dart';
import '../features/demo_panel/ui/demo_panel_screen.dart';
import '../features/finance/ui/loans_screen.dart';
import '../features/finance/ui/savings_screen.dart';
import '../features/fraud_desk/ui/case_screen.dart';
import '../features/fraud_desk/ui/fraud_desk_screen.dart';
import '../features/history/ui/history_screen.dart';
import '../features/home/ui/home_screen.dart';
import '../features/login/ui/login_screen.dart';
import '../features/pay/pay_routes.dart';
import '../features/safety/ui/safety_screen.dart';
import '../features/settings/ui/settings_screen.dart';
import 'env.dart';

/// Route paths. Deep link `bhorosha://approve/{requestId}` maps to [approve].
///
/// Every money flow lives under `/pay/:kind` with the
/// steps `amount`, `confirm`, `pin`, `result` and `code`; [send], [amount],
/// [pin] and [result] are the Send money instances, and the old `/send`
/// paths redirect to them ([legacyPayRedirect]).
abstract final class Routes {
  static const login = '/login';
  static const home = '/home';
  static const pay = '/pay/:kind';
  static const send = '/pay/send';
  static const amount = '/pay/send/amount';
  static const pin = '/pay/send/pin';
  static const result = '/pay/send/result';
  static const history = '/history';
  static const settings = '/settings';
  static const apa = '/apa';
  static const safety = '/safety';
  static const approve = '/approve/:requestId';
  static const demo = '/demo';
  static const fraudDesk = '/fraud-desk';

  /// One Case Zero investigation on the staff Fraud desk.
  static const fraudDeskCasePattern = '/fraud-desk/case/:id';
  static const loans = '/loans';
  static const savings = '/savings';

  /// `/approve/<id>`, the id percent-encoded (valid ids need none; see
  /// [ApproveLink.isValidId]).
  static String approveFor(String requestId) =>
      '/approve/${Uri.encodeComponent(requestId)}';

  /// `/fraud-desk/case/<id>`, the id percent-encoded.
  static String fraudDeskCase(String caseId) =>
      '/fraud-desk/case/${Uri.encodeComponent(caseId)}';

  /// `/pay/<kind>` or `/pay/<kind>/<step>`.
  static String payFor(PayKind kind, [String? step]) =>
      step == null ? '/pay/${kind.slug}' : '/pay/${kind.slug}/$step';
}

/// The pre-redesign `/send`, `/send/amount`, `/send/pin` and `/send/result`
/// (with their query) map to the `/pay/send` tree, so old links, tests and
/// the demo panel keep working. Null for any other path.
String? legacyPayRedirect(Uri uri) {
  const legacy = {'/send', '/send/amount', '/send/pin', '/send/result'};
  final path = uri.path.endsWith('/') && uri.path.length > 1
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  if (!legacy.contains(path)) return null;
  return Uri(
    path: '/pay$path',
    query: uri.query.isEmpty ? null : uri.query,
  ).toString();
}

/// A location held back by the signed-out guard, to open after login. Only
/// ever an `/approve/<id>` route (a trusted-contact deep link or push that
/// arrived while signed out, including a cold start from it). A plain holder,
/// not a notifier: it is written from the router's redirect, where no widget
/// should rebuild.
class PendingLocation {
  /// The held location, if any.
  String? value;

  /// Returns the held location and clears it.
  String? take() {
    final l = value;
    value = null;
    return l;
  }
}

/// The deep link to open after the next login (US-5 S1).
final pendingLocationProvider = Provider<PendingLocation>(
  (_) => PendingLocation(),
);

/// `/approve/<valid id>` as an in-app path, else `null`.
String? approveRouteOf(Uri uri) {
  final List<String> segments;
  try {
    segments = uri.pathSegments;
  } on FormatException {
    return null; // a malformed %-escape
  }
  if (uri.hasScheme ||
      segments.length != 2 ||
      segments.first != ApproveLink.schemeHost ||
      !ApproveLink.isValidId(segments[1])) {
    return null;
  }
  return Routes.approveFor(segments[1]);
}

/// Signed-out guard: every navigation to a route other than login while
/// nobody is signed in lands on login. Checked per navigation (no
/// `refreshListenable`), so the demo panel's persona switch, which signs out
/// and back in within one call, does not bounce the open screen. A blocked
/// `/approve/<id>` is kept in [pendingLocationProvider], and the Login
/// screen opens it after the demo login, so a link that cold-starts the app
/// is not lost.
String? authRedirect(Ref ref, String location) {
  final signedIn = ref.read(authRepoProvider).current != null;
  if (signedIn || location == Routes.login) return null;
  final approve = approveRouteOf(Uri.parse(location));
  if (approve != null) ref.read(pendingLocationProvider).value = approve;
  return Routes.login;
}

/// Top-level redirect. A trusted-contact deep link arrives as the full URI
/// (`bhorosha://approve/<id>`: scheme and host survive, the path is only
/// `/<id>`), which no route matches; it is rewritten to `/approve/<id>`
/// first. That second navigation then passes [authRedirect] like any other.
///
/// Anything else that arrives from outside the app (any URI with a scheme)
/// goes Home: the manifest filter is BROWSABLE, so a crafted
/// `bhorosha://approve/pay/send/result?state=done` must never reach a pay
/// screen. An in-app `/approve/<id>` with an id that is not
/// `[A-Za-z0-9_-]{1,64}` goes Home too.
String? appRedirect(Ref ref, GoRouterState state) {
  final uri = state.uri;
  final link = ApproveLink.parse(uri);
  if (link != null) return link.toRoute();
  if (uri.hasScheme) return authRedirect(ref, Routes.home) ?? Routes.home;
  final path = uri.path;
  final isApprove =
      path == '/${ApproveLink.schemeHost}' ||
      path.startsWith('/${ApproveLink.schemeHost}/');
  if (isApprove && approveRouteOf(uri) == null) {
    return authRedirect(ref, Routes.home) ?? Routes.home;
  }
  final legacy = legacyPayRedirect(uri);
  if (legacy != null) return legacy;
  final gated = staffGateRedirect(path);
  if (gated != null) return authRedirect(ref, gated) ?? gated;
  return authRedirect(ref, state.matchedLocation);
}

/// The demo panel and the staff Fraud desk exist only in debug builds and
/// the `DEMO_PANEL` video build: with
/// [enabled] off, `/demo` and every `/fraud-desk` path go Home. Null when
/// [path] may open.
String? staffGateRedirect(String path, {bool enabled = AppEnv.demoPanel}) {
  if (enabled) return null;
  final gated =
      path == Routes.demo ||
      path == Routes.fraudDesk ||
      path.startsWith('${Routes.fraudDesk}/');
  return gated ? Routes.home : null;
}

/// Route lifecycle events for screens that own a per-route side effect: Send
/// money subscribes to re-arm FLAG_SECURE when the PIN pad above it pops.
final routeObserverProvider = Provider<RouteObserver<ModalRoute<void>>>(
  (_) => RouteObserver<ModalRoute<void>>(),
);

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: Routes.login,
    debugLogDiagnostics: false,
    observers: [ref.watch(routeObserverProvider)],
    redirect: (_, state) => appRedirect(ref, state),
    routes: [
      GoRoute(path: '/', redirect: (_, _) => Routes.login),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
      // The shared money flow (/pay/:kind/...) is owned by lib/features/pay.
      ...payRoutes,
      GoRoute(
        path: Routes.history,
        builder: (_, state) =>
            HistoryScreen.fromQuery(state.uri.queryParameters),
      ),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      GoRoute(path: Routes.apa, builder: (_, _) => const ApaScreen()),
      GoRoute(
        path: Routes.safety,
        builder: (_, state) =>
            SafetyScreen(blocked: state.uri.queryParameters['block'] == '1'),
      ),
      GoRoute(
        path: Routes.approve,
        builder: (_, state) =>
            ApproveScreen(requestId: state.pathParameters['requestId'] ?? ''),
      ),
      // Debug builds and the DEMO_PANEL video build only.
      if (AppEnv.demoPanel)
        GoRoute(path: Routes.demo, builder: (_, _) => const DemoPanelScreen()),
      // The staff desk behind the same gate.
      if (AppEnv.demoPanel)
        GoRoute(
          path: Routes.fraudDesk,
          builder: (_, _) => const FraudDeskScreen(),
          routes: [
            GoRoute(
              path: 'case/:id',
              builder: (_, state) =>
                  CaseScreen(caseId: state.pathParameters['id'] ?? ''),
            ),
          ],
        ),
      GoRoute(path: Routes.loans, builder: (_, _) => const LoansScreen()),
      GoRoute(path: Routes.savings, builder: (_, _) => const SavingsScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
