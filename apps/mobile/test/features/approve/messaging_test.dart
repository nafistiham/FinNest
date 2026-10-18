import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/firebase/messaging.dart';
import 'package:bhorosha/features/approve/ui/approve_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../app/screen_harness.dart';

void main() {
  // With the test binding but no Firebase app, any FirebaseMessaging call
  // throws ("No Firebase App '[DEFAULT]' has been created"), so a clean
  // completion proves nothing was touched.
  TestWidgetsFlutterBinding.ensureInitialized();

  GoRouter router() => GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
  );

  test('init with status absent completes without touching Firebase', () async {
    var called = false;
    await Messaging.init(
      status: FirebaseStatus.absent,
      router: router(),
      onForegroundMessage: (_, _) => called = true,
    );
    expect(called, isFalse);
  });

  test('init with status failed is also a no-op', () async {
    await Messaging.init(
      status: FirebaseStatus.failed,
      router: router(),
      onForegroundMessage: null,
    );
    await Messaging.dispose();
  });

  test('deepLinkOf reads the deep_link payload key', () {
    expect(
      Messaging.deepLinkOf({'deep_link': 'bhorosha://approve/req_9'})
          ?.toRoute(),
      '/approve/req_9',
    );
    expect(
      Messaging.deepLinkOf({'deep_link': 'https://bhorosha.app/approve/req_9'})
          ?.requestId,
      'req_9',
    );
    expect(Messaging.deepLinkOf({'deep_link': 'https://evil/x'}), isNull);
    expect(Messaging.deepLinkOf({'deep_link': 42}), isNull);
    expect(Messaging.deepLinkOf({}), isNull);
  });

  testWidgets('a notification tap that cold-starts the app signed out '
      '(getInitialMessage) opens the request after the demo login', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, persona: null);

    Messaging.openData(routerOf(c), {
      Messaging.deepLinkKey: 'bhorosha://approve/req_9',
    });
    await tester.pump();
    await tester.pump();
    expect(locationOf(c), Routes.login);

    await tester.tap(find.byKey(const Key('demo_login')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(locationOf(c), Routes.approveFor('req_9'));
    expect(find.byType(ApproveScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a payload with a crafted link routes nowhere', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);
    Messaging.openData(routerOf(c), {
      Messaging.deepLinkKey: 'bhorosha://approve/pay/send/result?state=done',
    });
    await tester.pumpAndSettle();
    expect(locationOf(c), Routes.home);
  });
}
