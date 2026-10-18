import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/approve_controller.dart';
import 'package:bhorosha/features/approve/logic/approve_link.dart';
import 'package:bhorosha/features/approve/ui/approve_screen.dart';
import 'package:bhorosha/features/login/ui/login_screen.dart';
import 'package:bhorosha/features/pay/logic/pay_intent.dart';
import 'package:bhorosha/features/settings/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../features/approve/approve_test_support.dart';
import 'screen_harness.dart';

/// Delivers [uri] the way the Android embedding does for a VIEW intent.
Future<void> pushPlatformRoute(WidgetTester tester, Uri uri) async {
  const codec = JSONMethodCodec();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.navigation.name,
    codec.encodeMethodCall(
      MethodCall('pushRouteInformation', <String, Object?>{
        'location': uri.toString(),
        'state': null,
      }),
    ),
    (_) {},
  );
}

/// The approve screen runs a countdown ticker: pump frames, never settle.
Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('legacy /send paths map to the /pay/send tree', () {
    test('unit mapping keeps the query', () {
      String? m(String s) => legacyPayRedirect(Uri.parse(s));
      expect(m('/send'), Routes.send);
      expect(m('/send/'), Routes.send);
      expect(m('/send/pin'), Routes.pin);
      expect(
        m('/send/result?state=held&amount=7900'),
        '${Routes.result}?state=held&amount=7900',
      );
      expect(m('/home'), isNull);
      expect(m('/sendx'), isNull);
      expect(Routes.payFor(PayKind.cashOut), '/pay/cashout');
      expect(Routes.payFor(PayKind.bill, 'confirm'), '/pay/bill/confirm');
    });

    for (final (from, to) in [
      ('/send', Routes.send),
      ('/send/pin', Routes.pin),
      (
        '/send/result?state=done&amount=500',
        '${Routes.result}?state=done&amount=500',
      ),
    ]) {
      testWidgets('router.go($from) lands on $to', (tester) async {
        final h = ScreenHarness();
        final c = await pumpApp(tester, harness: h, location: Routes.home);
        routerOf(c).go(from);
        await tester.pumpAndSettle();
        expect(locationOf(c), to);
      });
    }

    testWidgets('an unknown pay kind goes Home', (tester) async {
      final h = ScreenHarness();
      final c = await pumpApp(tester, harness: h, location: '/pay/lottery');
      expect(locationOf(c), Routes.home);
    });

    testWidgets('/settings and /history open', (tester) async {
      final h = ScreenHarness();
      final c = await pumpApp(tester, harness: h, location: Routes.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);
      routerOf(c).go(Routes.history);
      await pumpFrames(tester);
      expect(locationOf(c), Routes.history);
    });
  });

  testWidgets('bhorosha://approve/abc from the platform lands on the approve '
      'route', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);

    await pushPlatformRoute(tester, Uri.parse('bhorosha://approve/abc'));
    await pumpFrames(tester);

    expect(locationOf(c), Routes.approveFor('abc'));
    final screen = tester.widget<ApproveScreen>(find.byType(ApproveScreen));
    expect(screen.requestId, 'abc');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('router.go with the full custom-scheme URI is rewritten too', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);

    routerOf(c).go(Uri.parse('bhorosha://approve/abc').toString());
    await pumpFrames(tester);

    expect(locationOf(c), Routes.approveFor('abc'));
    expect(find.byType(ApproveScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('signed out: the deep link waits on login and opens after the '
      'demo login (US-5 cold start)', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, persona: null);
    expect(c.read(authRepoProvider).current, isNull);

    await pushPlatformRoute(tester, Uri.parse('bhorosha://approve/abc'));
    await pumpFrames(tester);
    expect(locationOf(c), Routes.login);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(c.read(pendingLocationProvider).value, Routes.approveFor('abc'));

    await tester.tap(find.byKey(const Key('demo_login')));
    await pumpFrames(tester);
    expect(locationOf(c), Routes.approveFor('abc'));
    expect(find.byType(ApproveScreen), findsOneWidget);
    expect(c.read(pendingLocationProvider).value, isNull, reason: 'consumed');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('signed out, a non-approve route is not remembered', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, persona: null);
    routerOf(c).go(Routes.history);
    await pumpFrames(tester);
    expect(locationOf(c), Routes.login);
    expect(c.read(pendingLocationProvider).value, isNull);
  });

  group(
    'external links other than /approve/<id> go Home',
    () {
      for (final link in [
        'bhorosha://approve/pay/send/result?state=done&amount=50000',
        'bhorosha://approve/a%2Fb',
        'bhorosha://approve/a%3Fstate=done',
        'bhorosha://approve/',
        'bhorosha://approve/${'x' * 1024}',
        'bhorosha://approve/abc%zz',
        'bhorosha://pay/send/result?state=done&amount=50000',
        'https://evil.example/pay/send/result?state=done',
        'https://bhorosha.app/pay/send/result?state=done',
      ]) {
        testWidgets(link.length > 80 ? '${link.substring(0, 80)}…' : link, (
          tester,
        ) async {
          final h = ScreenHarness();
          final c = await pumpApp(tester, harness: h, location: Routes.home);
          await pushPlatformRoute(tester, Uri.parse(link));
          await pumpFrames(tester);
          expect(locationOf(c), Routes.home);
          expect(find.byType(ApproveScreen), findsNothing);
        });
      }

      testWidgets('an in-app /approve/<bad id> goes Home too', (tester) async {
        final h = ScreenHarness();
        final c = await pumpApp(tester, harness: h, location: Routes.home);
        routerOf(c).go('/approve/${'y' * 65}');
        await pumpFrames(tester);
        expect(locationOf(c), Routes.home);
      });

      test('approveFor encodes; ids are [A-Za-z0-9_-]{1,64}', () {
        expect(Routes.approveFor('a/b?c'), '/approve/a%2Fb%3Fc');
        expect(ApproveLink.isValidId('req_1-AB'), isTrue);
        expect(ApproveLink.isValidId(''), isFalse);
        expect(ApproveLink.isValidId('a' * 65), isFalse);
        expect(ApproveLink.isValidId('a.b'), isFalse);
      });
    },
  );

  group('trusted-contact deep link end to end', () {
    Future<ProviderContainer> openSeeded(
      WidgetTester tester, {
      List<Override> extra = const [],
    }) async {
      final h = ScreenHarness();
      final c = await pumpApp(
        tester,
        harness: h,
        location: Routes.home,
        extraOverrides: extra,
      );
      await tester.runAsync(() async {
        await c.read(ledgerRepoProvider).create('rina', heldTxn());
        await c
            .read(interventionRepoProvider)
            .upsert(
              openRecord(
                status: InterventionStatus.pending,
                requestId: 'req_1',
                expiresAt: DateTime.now().add(const Duration(minutes: 10)),
              ),
            );
      });
      await pushPlatformRoute(tester, Uri.parse('bhorosha://approve/req_1'));
      await pumpFrames(tester);
      expect(locationOf(c), Routes.approveFor('req_1'));
      return c;
    }

    testWidgets('the real contact approves through the link', (tester) async {
      await openSeeded(
        tester,
        extra: [approveViewerUidProvider.overrideWithValue('rafiq')],
      );
      expect(find.byKey(const Key('approve_not_yours')), findsNothing);
      await tester.tap(find.byKey(const Key('approve_approve')));
      await pumpFrames(tester);
      expect(find.byKey(const Key('approve_result')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the requester (Rina, signed in) only reads it', (
      tester,
    ) async {
      await openSeeded(tester);
      expect(find.byKey(const Key('approve_not_yours')), findsOneWidget);
      expect(find.byKey(const Key('approve_approve')), findsNothing);
      expect(find.byKey(const Key('approve_decline')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('/demo is registered in a debug build (AppEnv.demoPanel)', (
    tester,
  ) async {
    expect(AppEnv.demoPanel, isTrue, reason: 'kDebugMode default');
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.demo);
    expect(locationOf(c), Routes.demo);
  });

  testWidgets('the Fraud desk is behind the demo gate too: registered in a '
      'debug build', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.fraudDesk);
    expect(locationOf(c), Routes.fraudDesk);
  });

  test('with the demo panel off, /demo and every /fraud-desk path go Home', () {
    for (final path in [
      Routes.demo,
      Routes.fraudDesk,
      Routes.fraudDeskCase('CZ-0002'),
    ]) {
      expect(
        staffGateRedirect(path, enabled: false),
        Routes.home,
        reason: path,
      );
      expect(staffGateRedirect(path, enabled: true), isNull, reason: path);
    }
    for (final path in [Routes.home, Routes.history, '/fraud-deskette']) {
      expect(staffGateRedirect(path, enabled: false), isNull, reason: path);
    }
  });
}
