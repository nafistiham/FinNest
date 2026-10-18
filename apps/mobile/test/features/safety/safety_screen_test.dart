import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/app/widgets/bh_button.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/external_links.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/safety/ui/safety_screen.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_badge.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_status_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'safety_test_support.dart';

void main() {
  setUpAll(loadBanglaFont);

  /// Mounts the screen on a phone-sized viewport and lets its own first
  /// check (started in `initState`) settle.
  Future<void> pumpChecked(
    WidgetTester tester,
    SafetyHarness h, {
    bool blocked = false,
    Size size = const Size(1080, 2400),
    double ratio = 2.0,
    Locale locale = const Locale('bn'),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpSafety(
      tester,
      harness: h,
      child: SafetyScreen(blocked: blocked),
      locale: locale,
      brightness: brightness,
    );
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));
  }

  const recheck = Key('safety-recheck');
  Finder appCard(String pkg) => find.byKey(ValueKey('safety-app-$pkg'));
  Finder barButtons() => find.descendant(
    of: find.byType(BhBottomBar),
    matching: find.byType(BhButton),
  );

  testWidgets('BLOCK: verdict card, one card per app, server strings only', (
    tester,
  ) async {
    final h = SafetyHarness(
      response: blockResponse,
      demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
    );
    await pumpChecked(tester, h);

    // The app bar names the screen; the verdict card's status row carries
    // the verdict label and the simulated tag.
    expect(find.text('ফোনের নিরাপত্তা'), findsOneWidget);
    expect(find.text('ঝুঁকিপূর্ণ'), findsOneWidget);
    expect(find.text(blockResponse.userMessageBn), findsOneWidget);
    expect(find.text('সিমুলেটেড'), findsOneWidget);
    expect(find.text('লেনদেন বাতিল করা হয়েছে'), findsNothing);

    // One card per app: the uninstall target first, then the other app.
    expect(appCard('com.demo.takanow'), findsOneWidget);
    expect(appCard('com.example.bank'), findsOneWidget);
    expect(
      tester.getTopLeft(appCard('com.demo.takanow')).dy,
      lessThan(tester.getTopLeft(appCard('com.example.bank')).dy),
    );
    expect(find.byType(FindingCard), findsNWidgets(2));
    expect(find.text(blockFinding.titleBn), findsOneWidget);
    expect(find.text('TakaNow'), findsOneWidget);
    expect(find.text('Bank'), findsOneWidget);
    expect(find.text('গুরুতর'), findsOneWidget);
    expect(find.text('মাঝারি'), findsOneWidget);
    expect(find.text(blockFinding.explanationBn), findsOneWidget);
    expect(find.text(mediumFinding.explanationBn), findsOneWidget);
    expect(find.text(blockFinding.explanationEn), findsNothing);
    expect(find.textContaining('SIDELOADED_ACCESSIBILITY'), findsNothing);
    expect(find.text('আপনার ফোন'), findsNothing);

    // Evidence is technical: collapsed behind "বিস্তারিত" until asked.
    expect(find.text(blockFinding.evidence), findsNothing);
    await tester.tap(
      find.descendant(
        of: appCard('com.demo.takanow'),
        matching: find.byKey(const Key('safety-evidence-toggle')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(blockFinding.evidence), findsOneWidget);
    expect(find.text(mediumFinding.evidence), findsNothing);

    // Every Text is a server string, an ARB label or the status row's
    // separator (FR-3 / design 3.8a "render as sent").
    final server = {
      blockResponse.userMessageBn,
      for (final f in blockResponse.findings) ...[
        f.titleBn,
        f.evidence,
        f.explanationBn,
      ],
      'TakaNow',
      'Bank',
    };
    final arb = arbStringsBn();
    for (final text in allTexts(tester)) {
      final allowed =
          server.contains(text) || arb.contains(text) || text == ' · ';
      expect(allowed, isTrue, reason: 'unexpected UI text "$text"');
    }
  });

  testWidgets('the simulated tag is pinned to the card\'s trailing edge', (
    tester,
  ) async {
    for (final (size, ratio) in [
      (const Size(1080, 1920), 3.0), // 360 dp
      (const Size(1080, 2400), 2.625), // 412 dp
    ]) {
      final h = SafetyHarness(
        response: blockResponse,
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
      );
      await pumpChecked(tester, h, size: size, ratio: ratio);
      final card = find.byKey(const Key('safety-verdict-card'));
      final content = find.descendant(
        of: card,
        matching: find.byKey(SafetyVerdictCard.contentKey),
      );
      final tag = find.descendant(
        of: card,
        matching: find.byKey(SafetyStatusRow.tagKey),
      );
      expect(tag, findsOneWidget);
      final tagRect = tester.getRect(tag);
      expect(
        tagRect.right,
        moreOrLessEquals(tester.getRect(content).right, epsilon: 1),
      );
      expect(
        tagRect.right,
        moreOrLessEquals(tester.getRect(card).right - BhSpace.m, epsilon: 1),
      );
      // On the status row's line, not floating mid-card.
      final label = tester.getRect(
        find.descendant(
          of: card,
          matching: find.byKey(SafetyStatusRow.labelKey),
        ),
      );
      expect(tagRect.center.dy, moreOrLessEquals(label.center.dy, epsilon: 6));
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
    'UNINSTALL_AND_RECHECK: inline uninstall in the app card, one re-check in the bar',
    (tester) async {
      final h = SafetyHarness(
        response: blockResponse,
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
      );
      await pumpChecked(tester, h);

      expect(
        find.text('ঝুঁকিপূর্ণ অ্যাপ সরিয়ে আবার যাচাই করুন'),
        findsOneWidget,
      );
      final button = find.byType(UninstallButton);
      expect(button, findsOneWidget);
      expect(
        find.descendant(of: appCard('com.demo.takanow'), matching: button),
        findsOneWidget,
      );
      expect(find.text('আনইনস্টল করুন'), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(BhSize.touch));
      // Full card width (inside the 16 dp card padding).
      expect(
        tester.getSize(button).width,
        moreOrLessEquals(
          tester.getSize(appCard('com.demo.takanow')).width - 2 * BhSpace.m,
          epsilon: 1,
        ),
      );
      expect(
        tester.widget<UninstallButton>(button).target.package,
        'com.demo.takanow',
      );

      // Exactly one re-check, in the bottom bar, 56 dp.
      expect(find.byKey(recheck), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BhBottomBar),
          matching: find.byKey(recheck),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(recheck)).height,
        greaterThanOrEqualTo(56),
      );
      expect(barButtons(), findsOneWidget);

      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(h.native.openedPackages, ['com.demo.takanow']);
      final c = ProviderScope.containerOf(tester.element(button));
      expect(c.read(safetyControllerProvider.notifier).pendingRecheck, isTrue);

      await tester.tap(find.byKey(recheck));
      await tester.pumpAndSettle();
      expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));
    },
  );

  testWidgets('a kept BLOCK (recheck_lifts_block false) offers no re-check', (
    tester,
  ) async {
    const kept = AppSafetyResponse(
      verdict: SafetyVerdict.block,
      riskScore: 0.97,
      findings: [blockFinding],
      recommendedAction: 'uninstall',
      appsToUninstall: ['com.demo.takanow'],
      userMessageBn: 'TakaNow সরান।',
      userMessageEn: 'Remove TakaNow.',
      simulatedVerdict: false,
      resolution: 'UNINSTALL_AND_RECHECK',
      recheckLiftsBlock: false,
      uninstallTargets: [takaNowTarget],
    );
    final h = SafetyHarness(response: kept);
    await pumpChecked(tester, h);
    expect(find.byKey(recheck), findsNothing);
    expect(find.byType(UninstallButton), findsOneWidget);
    expect(barButtons(), findsNothing);
    expect(find.byKey(const Key('apa_bar_safety')), findsOneWidget);
  });

  testWidgets(
    'uninstall falls back to apps_to_uninstall when no targets are sent',
    (tester) async {
      const legacy = AppSafetyResponse(
        verdict: SafetyVerdict.block,
        riskScore: 0.9,
        findings: [blockFinding],
        recommendedAction: 'uninstall',
        appsToUninstall: ['com.demo.takanow'],
        userMessageBn: 'TakaNow সরান।',
        userMessageEn: 'Remove TakaNow.',
        simulatedVerdict: false,
        resolution: 'UNINSTALL_AND_RECHECK',
      );
      final h = SafetyHarness(response: legacy);
      await pumpChecked(tester, h);

      // Not in the posted bundle (no forced verdict), so there is no label:
      // a readable placeholder, never the bare package name.
      expect(find.text('নাম না জানা অ্যাপ'), findsOneWidget);
      expect(find.textContaining('com.demo.takanow'), findsNothing);
      await tester.ensureVisible(find.byType(UninstallButton));
      await tester.tap(find.byType(UninstallButton));
      await tester.pump();
      expect(h.native.openedPackages, ['com.demo.takanow']);
    },
  );

  testWidgets(
    'blocked=true adds the blocked line; the explanation is user_message_bn',
    (tester) async {
      final h = SafetyHarness(response: blockResponse);
      await pumpChecked(tester, h, blocked: true);

      expect(find.text('লেনদেন বাতিল করা হয়েছে'), findsOneWidget);
      expect(find.text(blockResponse.userMessageBn), findsOneWidget);
      expect(find.byIcon(Icons.block), findsOneWidget);
    },
  );

  testWidgets(
    'CAUTION + FIX_PHONE_AND_RECHECK: device rows under "আপনার ফোন", a line and a re-check',
    (tester) async {
      final h = SafetyHarness(response: cautionResponse);
      await pumpChecked(tester, h);

      expect(find.text('সাবধান'), findsOneWidget);
      expect(find.text(cautionResponse.userMessageBn), findsOneWidget);
      expect(find.text('সিমুলেটেড'), findsNothing);

      // App section then the device section with the phone icon.
      expect(find.text('যা পাওয়া গেছে'), findsOneWidget);
      expect(find.text('আপনার ফোন'), findsOneWidget);
      expect(find.byIcon(Icons.phone_android), findsOneWidget);
      expect(find.byType(FindingCard), findsNWidgets(2));
      expect(find.byType(DeviceFindingRow), findsOneWidget);
      expect(find.text(deviceFinding.titleBn), findsOneWidget);
      expect(find.text(deviceFinding.explanationBn), findsOneWidget);
      expect(find.text('মাঝারি'), findsOneWidget);
      expect(find.text('কম'), findsOneWidget);
      final appSection = tester.getTopLeft(find.text('যা পাওয়া গেছে'));
      final deviceSection = tester.getTopLeft(find.text('আপনার ফোন'));
      expect(deviceSection.dy, greaterThan(appSection.dy));
      final mediumTag = tester
          .widgetList<StatusTag>(find.byType(StatusTag))
          .firstWhere((t) => t.label == 'মাঝারি');
      expect(mediumTag.status, BhStatus.warning);

      // Resolution line in the body, the one re-check in the bar.
      expect(find.text('ফোনের সেটিংস ঠিক করে আবার যাচাই করুন'), findsOneWidget);
      expect(find.byType(UninstallButton), findsNothing);
      expect(find.byKey(recheck), findsOneWidget);
      await tester.tap(find.byKey(recheck));
      await tester.pumpAndSettle();
      expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));
    },
  );

  testWidgets(
    'REINSTALL_FROM_PLAY: line and a Play Store button (market, then web)',
    (tester) async {
      final h = SafetyHarness(response: reinstallResponse);
      await pumpChecked(tester, h);

      expect(find.text(reinstallResponse.userMessageBn), findsOneWidget);
      expect(
        find.text('প্লে স্টোর থেকে ফিননেস্ট আবার ইনস্টল করুন'),
        findsOneWidget,
      );
      expect(find.byKey(recheck), findsNothing);
      expect(find.byType(UninstallButton), findsNothing);
      final button = find.byKey(const Key('safety-open-play'));
      expect(find.text('প্লে স্টোরে যান'), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(BhSize.touch));

      await tester.tap(button);
      await tester.pump();
      expect(h.launched, [Uri.parse('market://details?id=com.bhorosha.app')]);

      // No Play Store app: the web page is the fallback.
      h.launched.clear();
      h.launchResult = false;
      await tester.tap(button);
      await tester.pump();
      expect(h.launched, [
        Uri.parse('market://details?id=com.bhorosha.app'),
        Uri.parse(
          'https://play.google.com/store/apps/details?id=com.bhorosha.app',
        ),
      ]);
      expect(ExternalLinks.appPackage, 'com.bhorosha.app');
    },
  );

  testWidgets('CALL_BANK: line and a 56 dp call button dialing the '
      'fictional helpline (AppEnv.helpline, never a real number)', (
    tester,
  ) async {
    final h = SafetyHarness(response: callBankResponse);
    await pumpChecked(tester, h);

    expect(find.text(callBankResponse.userMessageBn), findsOneWidget);
    expect(find.text('ফিননেস্টের হেল্পলাইনে কথা বলুন'), findsOneWidget);
    final button = find.byKey(const Key('safety-call-bank'));
    expect(find.text('ফিননেস্টে কল করুন'), findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(BhSize.touch));
    expect(find.byKey(recheck), findsNothing);

    await tester.tap(button);
    await tester.pump();
    expect(h.launched, [
      Uri.parse('tel:${AppEnv.helpline.replaceAll(RegExp(r'[^0-9+]'), '')}'),
    ]);
    expect(ExternalLinks.bankHotline, AppEnv.helpline);
  });

  testWidgets('SAFE / NONE: no findings, no action; the bar is Apa alone', (
    tester,
  ) async {
    final h = SafetyHarness(response: safeResponse);
    await pumpChecked(tester, h);

    expect(find.text('নিরাপদ'), findsOneWidget);
    expect(find.text(safeResponse.userMessageBn), findsOneWidget);
    expect(find.text('কোনো ঝুঁকিপূর্ণ অ্যাপ পাওয়া যায়নি'), findsOneWidget);
    expect(find.byType(FindingCard), findsNothing);
    expect(find.byType(UninstallButton), findsNothing);
    expect(find.byKey(recheck), findsNothing);
    expect(find.byKey(const Key('safety-open-play')), findsNothing);
    expect(find.byKey(const Key('safety-call-bank')), findsNothing);
    expect(barButtons(), findsNothing);
    expect(find.byKey(const Key('apa_bar_safety')), findsOneWidget);
  });

  testWidgets('WAIT: nothing extra either', (tester) async {
    const wait = AppSafetyResponse(
      verdict: SafetyVerdict.caution,
      riskScore: 0.4,
      findings: [],
      recommendedAction: 'wait',
      appsToUninstall: [],
      userMessageBn: 'একটু পরে আবার দেখুন।',
      userMessageEn: 'Check back later.',
      simulatedVerdict: false,
      resolution: 'WAIT',
    );
    final h = SafetyHarness(response: wait);
    await pumpChecked(tester, h);
    expect(find.byKey(recheck), findsNothing);
    expect(find.byType(UninstallButton), findsNothing);
    expect(find.text(wait.userMessageBn), findsOneWidget);
  });

  testWidgets('every text is at least 16 sp', (tester) async {
    final h = SafetyHarness(
      response: blockResponse,
      demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
    );
    await pumpChecked(tester, h, blocked: true);

    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      final size = rich.text.style?.fontSize;
      expect(
        size,
        anyOf(isNull, greaterThanOrEqualTo(16)),
        reason: '"${rich.text.toPlainText()}" is $size sp',
      );
    }
  });

  group('app bar', () {
    for (final locale in const [Locale('bn'), Locale('en')]) {
      testWidgets(
        '${locale.languageCode} at 360 dp: title only, not truncated',
        (tester) async {
          final h = SafetyHarness(
            response: blockResponse,
            demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
          );
          await pumpChecked(
            tester,
            h,
            size: const Size(1080, 1920),
            ratio: 3,
            locale: locale,
          );
          final bar = tester.widget<AppBar>(find.byType(AppBar));
          expect(bar.actions, isNull);
          final title = find.byKey(const Key('safety-title'));
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: title, matching: find.byType(RichText)),
          );
          expect(
            paragraph.getMaxIntrinsicWidth(double.infinity),
            lessThanOrEqualTo(paragraph.size.width + 0.5),
            reason: 'the title is cut',
          );
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  for (final brightness in Brightness.values) {
    for (final locale in const [Locale('bn'), Locale('en')]) {
      testWidgets(
        'renders ${locale.languageCode}/${brightness.name} at 360 dp without overflow',
        (tester) async {
          final h = SafetyHarness(
            response: blockResponse,
            demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
          );
          await pumpChecked(
            tester,
            h,
            blocked: true,
            size: const Size(1080, 1920),
            ratio: 3,
            locale: locale,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          // Never more than two buttons in the bottom bar.
          expect(barButtons().evaluate().length, lessThanOrEqualTo(2));
          if (locale.languageCode == 'en') {
            expect(find.text(blockResponse.userMessageEn), findsOneWidget);
            expect(find.text('Simulated'), findsOneWidget);
          }
        },
      );
    }
  }

  testWidgets('opened before any check: starts one and shows checking', (
    tester,
  ) async {
    final h = SafetyHarness(response: safeResponse);
    final release = h.api.hold(RiskRoutes.appSafety);
    await pumpSafety(
      tester,
      harness: h,
      child: const SafetyScreen(blocked: false),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('যাচাই হচ্ছে…'), findsOneWidget);
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));

    release();
    await tester.pumpAndSettle();
    expect(find.text(safeResponse.userMessageBn), findsOneWidget);
  });

  testWidgets('error: empty state in the body, the one retry in the bar', (
    tester,
  ) async {
    final h = SafetyHarness(response: cautionResponse);
    h.api.failures[RiskRoutes.appSafety] = const ServerFailure(500);
    await pumpChecked(tester, h);

    expect(find.byKey(const Key('safety-error')), findsOneWidget);
    expect(find.text('যাচাই করা যায়নি'), findsOneWidget);
    expect(
      find.text('ইন্টারনেট চালু আছে কি না দেখে আবার চেষ্টা করুন।'),
      findsOneWidget,
    );
    // One retry on screen, in the bottom bar; none in the app bar or body.
    expect(find.text('আবার চেষ্টা করুন'), findsOneWidget);
    expect(barButtons(), findsOneWidget);
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));

    h.api.failures.clear();
    await tester.tap(find.byKey(const Key('safety-retry')));
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));
    expect(find.text(cautionResponse.userMessageBn), findsOneWidget);
  });

  group('blocked transfer is never a dead end', () {
    Future<void> pumpBlocked(WidgetTester tester, SafetyHarness h) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '${SafetyBadge.route}?block=1',
        routes: [
          GoRoute(
            path: SafetyBadge.route,
            builder: (_, _) => const SafetyScreen(blocked: true),
          ),
          GoRoute(
            path: SafetyScreen.homeRoute,
            builder: (_, _) => const Scaffold(body: Text('home-stub')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await pumpSafety(tester, harness: h, router: router);
      await tester.pumpAndSettle();
    }

    testWidgets('NONE resolution: the bar still offers হোমে ফিরুন', (
      tester,
    ) async {
      await pumpBlocked(tester, SafetyHarness());
      final home = find.byKey(const Key('safety-go-home'));
      expect(home, findsOneWidget);
      expect(find.text('হোমে ফিরুন'), findsOneWidget);
      expect(tester.getSize(home).height, greaterThanOrEqualTo(56));
      await tester.tap(home);
      await tester.pumpAndSettle();
      expect(find.text('home-stub'), findsOneWidget);
    });

    testWidgets('UNINSTALL: home is the primary, the re-check above it', (
      tester,
    ) async {
      await pumpBlocked(tester, SafetyHarness(response: blockResponse));
      final homeY = tester
          .getTopLeft(find.byKey(const Key('safety-go-home')))
          .dy;
      final recheckY = tester.getTopLeft(find.byKey(recheck)).dy;
      expect(homeY, greaterThan(recheckY));
      expect(barButtons(), findsNWidgets(2));
    });

    testWidgets('not blocked: no go-home button', (tester) async {
      await pumpChecked(tester, SafetyHarness());
      expect(find.byKey(const Key('safety-go-home')), findsNothing);
    });
  });
}
