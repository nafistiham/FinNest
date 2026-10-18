import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_badge.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_status_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'safety_test_support.dart';

void main() {
  // pumpSafety uses the light Teal theme; status colours are the same in
  // every preset and differ only by brightness.
  final p = BhPalette.tealLight;

  Finder badge() => find.byType(SafetyBadge);

  Color? cardColor(WidgetTester tester) => tester
      .widget<Material>(
        find.descendant(of: badge(), matching: find.byType(Material)).first,
      )
      .color;

  Color? iconColor(WidgetTester tester, IconData icon) =>
      tester.widget<Icon>(find.byIcon(icon)).color;

  Size badgeSize(WidgetTester tester) => tester.getSize(badge());

  group('verdict states', () {
    testWidgets('SAFE: green, label, user_message_bn, no tag', (tester) async {
      final h = SafetyHarness(response: safeResponse);
      final c = await pumpSafety(
        tester,
        harness: h,
        child: const Scaffold(body: SafetyBadge()),
      );
      await c.read(safetyControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(cardColor(tester), p.successContainer);
      expect(iconColor(tester, Icons.verified_user), p.success);
      expect(find.text('নিরাপদ'), findsOneWidget);
      expect(find.text(safeResponse.userMessageBn), findsOneWidget);
      expect(find.text('সিমুলেটেড'), findsNothing);
      expect(badgeSize(tester).height, greaterThanOrEqualTo(BhSize.touch));
    });

    testWidgets('CAUTION: amber and its label', (tester) async {
      final h = SafetyHarness(response: cautionResponse);
      final c = await pumpSafety(
        tester,
        harness: h,
        child: const Scaffold(body: SafetyBadge()),
      );
      await c.read(safetyControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(cardColor(tester), p.warningContainer);
      // Amber text and icons use the readable warning ink (5.67:1), never
      // the 2.6:1 fill.
      expect(iconColor(tester, Icons.warning_amber_rounded), p.warning);
      expect(find.text('সাবধান'), findsOneWidget);
      expect(find.text(cautionResponse.userMessageBn), findsOneWidget);
    });

    testWidgets('BLOCK: red, label, message and the simulated tag', (
      tester,
    ) async {
      final h = SafetyHarness(response: blockResponse);
      final c = await pumpSafety(
        tester,
        harness: h,
        child: const Scaffold(body: SafetyBadge()),
      );
      await c.read(safetyControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(cardColor(tester), p.dangerContainer);
      expect(iconColor(tester, Icons.gpp_bad), p.danger);
      expect(find.text('ঝুঁকিপূর্ণ'), findsOneWidget);
      expect(find.text(blockResponse.userMessageBn), findsOneWidget);
      expect(find.text('সিমুলেটেড'), findsOneWidget);
      expect(find.byType(StatusTag), findsOneWidget);

      final semantics = tester.getSemantics(badge());
      expect(semantics.label, contains(blockResponse.userMessageBn));
      expect(semantics.label, contains('সিমুলেটেড'));
      expect(semantics.flagsCollection.isButton, isTrue);
    });
  });

  testWidgets('before any check and while checking: the checking line', (
    tester,
  ) async {
    final h = SafetyHarness(response: safeResponse);
    final c = await pumpSafety(
      tester,
      harness: h,
      child: const Scaffold(body: SafetyBadge()),
    );
    await tester.pump();
    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);
    expect(find.text('ফোনের নিরাপত্তা'), findsOneWidget);

    final release = h.api.hold(RiskRoutes.appSafety);
    final done = c.read(safetyControllerProvider.notifier).refresh();
    await tester.pump();
    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);
    expect(find.byKey(SafetyStatusRow.checkingKey), findsOneWidget);
    expect(cardColor(tester), p.surfaceVariant);

    release();
    await done;
    await tester.pumpAndSettle();
    expect(find.text('যাচাই হচ্ছে…'), findsNothing);
    expect(find.text(safeResponse.userMessageBn), findsOneWidget);
  });

  testWidgets('error: failure line, tapping the card retries', (tester) async {
    final h = SafetyHarness(response: cautionResponse);
    h.api.failures[RiskRoutes.appSafety] = const NetworkFailure();
    final c = await pumpSafety(
      tester,
      harness: h,
      child: const Scaffold(body: SafetyBadge()),
    );
    await c.read(safetyControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();

    expect(
      find.text('যাচাই করা যায়নি। আবার চেষ্টা করতে চাপুন।'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(cardColor(tester), p.surfaceVariant);
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));

    h.api.failures.clear();
    await tester.tap(badge());
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));
    expect(find.text(cautionResponse.userMessageBn), findsOneWidget);
    expect(
      find.text('যাচাই করা যায়নি। আবার চেষ্টা করতে চাপুন।'),
      findsNothing,
    );
  });

  testWidgets('error with a standing verdict: verdict colours, fallback line', (
    tester,
  ) async {
    final h = SafetyHarness(response: safeResponse, user: rinaProfile);
    h.api.failures[RiskRoutes.appSafety] = const TimeoutFailure();
    h.api.latestResponse = blockLatest;
    final c = await pumpSafety(
      tester,
      harness: h,
      child: const Scaffold(body: SafetyBadge()),
    );
    c.listen(currentUserProvider, (_, _) {});
    await tester.pump();
    await c.read(safetyControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();

    expect(cardColor(tester), p.dangerContainer);
    expect(iconColor(tester, Icons.gpp_bad), p.danger);
    expect(find.text('ঝুঁকিপূর্ণ'), findsOneWidget);
    expect(
      find.text('নতুন যাচাই করা যায়নি। আগের ফলাফল দেখানো হচ্ছে।'),
      findsOneWidget,
    );
    // No user_message_bn exists for a standing verdict; nothing is composed.
    expect(find.text(blockResponse.userMessageBn), findsNothing);
    expect(c.read(lastSafetyVerdictProvider), SafetyVerdict.block);

    // Tapping retries; a success replaces the fallback.
    h.api.failures.clear();
    await tester.tap(badge());
    await tester.pumpAndSettle();
    expect(cardColor(tester), p.successContainer);
    expect(find.text(safeResponse.userMessageBn), findsOneWidget);
  });

  testWidgets('tap navigates to /safety', (tester) async {
    final h = SafetyHarness(response: blockResponse);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: SafetyBadge()),
        ),
        GoRoute(
          path: SafetyBadge.route,
          builder: (_, _) => const Scaffold(body: Text('findings-dest')),
        ),
      ],
    );
    addTearDown(router.dispose);
    final c = await pumpSafety(tester, harness: h, router: router);
    await c.read(safetyControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();

    await tester.tap(badge());
    await tester.pumpAndSettle();
    expect(find.text('findings-dest'), findsOneWidget);
    expect(SafetyBadge.route, '/safety');
  });
}
