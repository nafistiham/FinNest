// Shared helpers for the pay-flow widget tests: the real app on a router
// that carries `payRoutes` (whatever lib/app/router.dart has wired so far),
// reduced motion so `pumpAndSettle` never spins on a caret or a pulse, and
// numpad taps scoped to the pad. Not a test file.

import 'dart:io';

import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/widgets/bangla_numpad.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/billers.dart';
import 'package:bhorosha/features/pay/pay_routes.dart';
import 'package:bhorosha/features/safety/ui/safety_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../app/screen_harness.dart';

export '../../app/screen_harness.dart';

/// Stand-in for Home, which another package is rebuilding.
class FakeHome extends StatelessWidget {
  const FakeHome({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('HOME')));
}

/// The app router with only what the pay flow touches: fake login and Home,
/// the real Safety screen, the pay tree and the legacy `/send` redirects.
final payTestRouter = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: Routes.login,
    observers: [ref.watch(routeObserverProvider)],
    redirect: (_, state) => appRedirect(ref, state),
    routes: [
      GoRoute(
        path: Routes.login,
        builder: (_, _) => const Scaffold(body: Center(child: Text('LOGIN'))),
      ),
      GoRoute(path: Routes.home, builder: (_, _) => const FakeHome()),
      GoRoute(
        path: Routes.safety,
        builder: (_, state) =>
            SafetyScreen(blocked: state.uri.queryParameters['block'] == '1'),
      ),
      ...payRoutes,
      ...payLegacyRoutes,
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

List<Override> payOverrides({Locale? locale}) => [
  routerProvider.overrideWith((ref) => ref.watch(payTestRouter)),
  billersProvider.overrideWith(
    (_) async =>
        BillerCatalog.parse(File(BillerCatalog.path).readAsStringSync()),
  ),
  if (locale != null) initialLocaleProvider.overrideWithValue(locale),
];

/// Reduce motion for the whole test (no caret blink, no sweep, instant
/// step transitions).
void reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Pumps the app on [location] with the pay router, Rina signed in.
Future<ProviderContainer> pumpPay(
  WidgetTester tester, {
  required ScreenHarness harness,
  String? location,
  Persona? persona = Persona.rina,
  Locale? locale,
  List<Override> extraOverrides = const [],
}) {
  reduceMotion(tester);
  return pumpApp(
    tester,
    harness: harness,
    persona: persona,
    location: location,
    extraOverrides: [
      ...payOverrides(locale: locale),
      ...extraOverrides,
    ],
  );
}

const _bn = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

/// Taps the numpad key for [d] (Bangla glyph unless [english]).
Future<void> padDigit(
  WidgetTester tester,
  int d, {
  bool english = false,
}) async {
  await tester.tap(
    find.descendant(
      of: find.byType(Numpad),
      matching: find.text(english ? '$d' : _bn[d]),
    ),
  );
  await tester.pump();
}

Future<void> padDigits(
  WidgetTester tester,
  String digits, {
  bool english = false,
}) async {
  for (final ch in digits.split('')) {
    await padDigit(tester, int.parse(ch), english: english);
  }
}

/// Ledger reads after `pumpAndSettle` run under `runAsync`.
Future<List<LedgerTxn>> ledgerRows(
  WidgetTester tester,
  ProviderContainer c, [
  String uid = 'rina',
]) async => (await tester.runAsync(
  () => c.read(ledgerRepoProvider).watchRecent(uid, limit: 50).first,
))!;

Future<double> ledgerBalance(
  WidgetTester tester,
  ProviderContainer c, [
  String uid = 'rina',
]) async => (await tester.runAsync(
  () => c.read(ledgerRepoProvider).watchBalance(uid).first,
))!;

/// The enabled state of the FilledButton under [key].
bool buttonEnabled(WidgetTester tester, Key key) => tester
    .widget<FilledButton>(
      find.descendant(of: find.byKey(key), matching: find.byType(FilledButton)),
    )
    .enabled;

/// The visible label of the BhButton under [key].
String buttonLabel(WidgetTester tester, Key key) => tester
    .widgetList<Text>(
      find.descendant(of: find.byKey(key), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .join();
