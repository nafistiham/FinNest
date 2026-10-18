import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/animated/rolling_amount.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/app/widgets/feature_tile.dart';
import 'package:bhorosha/app/widgets/hero_balance.dart';
import 'package:bhorosha/app/widgets/language_toggle.dart';
import 'package:bhorosha/app/widgets/txn_row.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_insight_card.dart';
import 'package:bhorosha/features/finance/ui/loans_screen.dart';
import 'package:bhorosha/features/fraud_desk/ui/fraud_desk_screen.dart';
import 'package:bhorosha/features/history/ui/history_screen.dart';
import 'package:bhorosha/features/home/logic/home_providers.dart';
import 'package:bhorosha/features/home/ui/home_screen.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/ui/amount_step.dart';
import 'package:bhorosha/features/pay/ui/pay_start_screen.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_status_row.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:bhorosha/features/settings/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/screen_harness.dart';
import '../safety/safety_test_support.dart' show loadAppFonts;

/// A BLOCK verdict the server marked as simulated (the demo's forced
/// verdict), with one app to remove.
const _simulatedBlock = AppSafetyResponse(
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  findings: [],
  recommendedAction: 'uninstall',
  appsToUninstall: ['com.demo.takanow'],
  userMessageBn: 'TakaNow অ্যাপটি বিপজ্জনক। এখনই আনইনস্টল করুন।',
  userMessageEn: 'TakaNow is dangerous. Uninstall it now.',
  simulatedVerdict: true,
  resolution: 'UNINSTALL_AND_RECHECK',
  uninstallTargets: [
    UninstallTarget(
      package: 'com.demo.takanow',
      label: 'TakaNow',
      primarySignal: 'SIDELOADED_ACCESSIBILITY',
      deepLink: 'package:com.demo.takanow',
    ),
  ],
);

Finder _amount(num value) =>
    find.byWidgetPredicate((w) => w is RollingAmount && w.amount == value);

/// Sets the viewport to [w] x [h] dp.
void _viewport(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.devicePixelRatio = 3;
}

void main() {
  setUpAll(loadAppFonts);

  test('the Fraud desk tile only with the demo panel', () {
    expect(homeFeaturesFor(demoPanel: true).map((f) => f.id), [
      'send',
      'cashout',
      'cashin',
      'recharge',
      'bill',
      'loans',
      'savings',
      'history',
      'fraud_desk',
    ]);
    final off = homeFeaturesFor(demoPanel: false);
    expect(off, hasLength(8));
    expect(off.map((f) => f.id), isNot(contains('fraud_desk')));
    expect(homeFeatures, hasLength(9), reason: 'debug build: panel on');
  });

  testWidgets('Rina: hub order, balance without a card, one security card, '
      'nine tiles, three recent rows', (tester) async {
    final h = ScreenHarness();
    await pumpApp(tester, harness: h, location: Routes.home);

    expect(find.text('স্বাগতম, রিনা'), findsOneWidget);
    expect(find.byType(HeroBalance), findsOneWidget);
    expect(
      find.descendant(of: find.byType(HeroBalance), matching: _amount(9841)),
      findsOneWidget,
    );
    expect(find.text('মোট ব্যালেন্স'), findsOneWidget);
    expect(find.textContaining('ডেমো মোড'), findsOneWidget);

    // One security surface: Apa's card carries the phone-safety status row.
    expect(find.byType(ApaInsightCard), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ApaInsightCard),
        matching: find.byType(SafetyStatusRow),
      ),
      findsOneWidget,
    );
    // Calm state: Apa's line is the all-clear title with the day's tip.
    expect(
      find.descendant(
        of: find.byType(ApaInsightCard),
        matching: find.byKey(const Key('apa_insight_title')),
      ),
      findsOneWidget,
    );
    // Home triggered the one safety check.
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));

    // Nine tiles in the brief's order; Send money is one of them.
    final tiles = tester.widgetList<FeatureTile>(find.byType(FeatureTile));
    expect(tiles.map((t) => t.label), [
      'টাকা পাঠান',
      'ক্যাশ আউট',
      'ক্যাশ ইন',
      'মোবাইল রিচার্জ',
      'বিল দিন',
      'ঋণ',
      'সঞ্চয়',
      'লেনদেন',
      'ফ্রড ডেস্ক',
    ]);
    expect(find.byKey(const Key('home_tile_send')), findsOneWidget);

    // Recent: header with "সব দেখুন", exactly three rows.
    await tester.scrollUntilVisible(
      find.byKey(const Key('home_recent_header')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const Key('home_scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.text('সাম্প্রতিক লেনদেন'), findsOneWidget);
    expect(find.text('সব দেখুন'), findsOneWidget);
    expect(find.byType(TxnRow), findsNWidgets(HomeScreen.recentCount));
    // Seeded rows are final: no tags.
    expect(find.text('আটকে আছে'), findsNothing);
    expect(find.text('সম্পন্ন'), findsNothing);

    // Order top to bottom: greeting, balance, card, grid, recent.
    await tester.drag(
      find.byKey(const Key('home_scroll')),
      const Offset(0, 2000),
    );
    await tester.pumpAndSettle();
    double y(Finder f) => tester.getTopLeft(f).dy;
    expect(
      y(find.text('স্বাগতম, রিনা')),
      lessThan(y(find.byType(HeroBalance))),
    );
    expect(
      y(find.byType(HeroBalance)),
      lessThan(y(find.byType(ApaInsightCard))),
    );
    expect(
      y(find.byType(ApaInsightCard)),
      lessThan(y(find.byType(FeatureGrid))),
    );

    // Chrome: no ⋮ menu; language toggle and a labelled Settings button in
    // the app bar; Apa alone in the bottom bar (no money action there).
    expect(find.byType(PopupMenuButton<Object>), findsNothing);
    expect(find.byKey(const Key('home_menu')), findsNothing);
    expect(find.byType(LanguageToggle), findsOneWidget);
    // Settings is icon-only: the word is its tooltip and semantics label,
    // and the app bar stays one line (56 dp).
    final settings = find.byKey(const Key('home_settings'));
    expect(settings, findsOneWidget);
    expect(find.text('সেটিংস'), findsNothing);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(of: settings, matching: find.byType(Tooltip)),
          )
          .message,
      'সেটিংস',
    );
    expect(find.bySemanticsLabel('সেটিংস'), findsOneWidget);
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(BhSize.touch));
    expect(tester.getSize(settings).width, greaterThanOrEqualTo(BhSize.touch));
    expect(
      tester.getSize(find.byType(LanguageToggle)).height,
      LanguageToggle.touchHeight,
    );
    expect(
      tester.getSize(find.byKey(const Key('language_segment_bn'))).height,
      LanguageToggle.height,
    );
    expect(tester.getSize(find.byType(AppBar)).height, BhSize.appBarCompact);
    expect(find.byKey(const Key('apa_bar_home')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BhBottomBar),
        matching: find.text('টাকা পাঠান'),
      ),
      findsNothing,
    );
  });

  testWidgets('at 412 x 915 the whole grid is visible on first paint', (
    tester,
  ) async {
    final h = ScreenHarness();
    await pumpApp(tester, harness: h, location: Routes.home);
    _viewport(tester, 412, 915);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final barTop = tester.getTopLeft(find.byType(BhBottomBar)).dy;
    for (final f in homeFeatures) {
      final tile = find.byKey(f.key);
      expect(tile, findsOneWidget);
      expect(
        tester.getBottomLeft(tile).dy,
        lessThanOrEqualTo(barTop),
        reason: '${f.id} is below the fold',
      );
    }
  });

  testWidgets('412 x 915 with a 24 dp status bar and a 48 dp nav bar: the '
      'bottom bar stays fixed above the inset, the body scrolls under the app '
      'bar only, and every tile can be brought fully above the bar', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);
    _viewport(tester, 412, 915);
    tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
    tester.view.viewPadding = const FakeViewPadding(
      top: 24 * 3,
      bottom: 48 * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final bar = tester.getRect(find.byType(BhBottomBar));
    // The bar ends at the screen edge and its 56 dp content clears the
    // 48 dp system inset.
    expect(bar.bottom, 915);
    final apa = tester.getRect(find.byKey(const Key('apa_bar_home')));
    expect(apa.bottom, lessThanOrEqualTo(915 - 48));
    // The app bar clears the status bar.
    expect(
      tester.getTopLeft(find.byKey(const Key('home_logo'))).dy,
      greaterThanOrEqualTo(24),
    );
    // The scroll view ends where the bar starts: nothing sits behind it.
    final scroll = tester.getRect(find.byKey(const Key('home_scroll')));
    expect(scroll.bottom, lessThanOrEqualTo(bar.top + 0.5));
    // First paint: all nine tiles are already in view above the bar, in
    // both languages (the owner's phone showed only two rows).
    for (final f in homeFeatures) {
      expect(
        tester.getBottomLeft(find.byKey(f.key)).dy,
        lessThanOrEqualTo(bar.top),
        reason: '${f.id} is below the fold',
      );
    }
    await c.read(localeProvider.notifier).set(const Locale('en'));
    await tester.pumpAndSettle();
    for (final f in homeFeatures) {
      expect(
        tester.getBottomLeft(find.byKey(f.key)).dy,
        lessThanOrEqualTo(bar.top),
        reason: '${f.id} is below the fold in English',
      );
    }
    await c.read(localeProvider.notifier).set(const Locale('bn'));
    await tester.pumpAndSettle();
    // The rest scrolls fully into view above the bar; the bar never moves.
    for (final f in homeFeatures) {
      await tester.ensureVisible(find.byKey(f.key));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.byKey(f.key)).dy,
        lessThanOrEqualTo(bar.top),
        reason: '${f.id} sits behind the bottom bar',
      );
      expect(tester.getRect(find.byType(BhBottomBar)), bar);
    }
  });

  for (final (w, hgt) in [(360.0, 640.0), (412.0, 915.0)]) {
    for (final brightness in Brightness.values) {
      for (final locale in ['bn', 'en']) {
        testWidgets(
          'renders at ${w.toInt()} x ${hgt.toInt()} $locale/${brightness.name} '
          'without overflow',
          (tester) async {
            tester.platformDispatcher.platformBrightnessTestValue = brightness;
            addTearDown(
              tester.platformDispatcher.clearPlatformBrightnessTestValue,
            );
            final h = ScreenHarness();
            await pumpApp(
              tester,
              harness: h,
              location: Routes.home,
              extraOverrides: [
                initialLocaleProvider.overrideWithValue(Locale(locale)),
              ],
            );
            _viewport(tester, w, hgt);
            addTearDown(tester.view.reset);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              Theme.of(tester.element(find.byType(HomeScreen))).brightness,
              brightness,
            );
            // Scroll to the end: the recent rows lay out too.
            await tester.drag(
              find.byKey(const Key('home_scroll')),
              const Offset(0, -2000),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byType(FeatureTile), findsNWidgets(9));
            if (locale == 'en') {
              expect(find.text('Send money'), findsOneWidget);
              expect(find.text('See all'), findsOneWidget);
            }
          },
        );
      }
    }
  }

  testWidgets('tiles, "সব দেখুন", a recent row and Settings navigate', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);

    Future<void> home() async {
      routerOf(c).go(Routes.home);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('home_tile_send')));
    await tester.pumpAndSettle();
    expect(find.byType(PayStartScreen), findsOneWidget);

    for (final (id, type) in [
      ('loans', LoansScreen),
      ('history', HistoryScreen),
      ('fraud_desk', FraudDeskScreen),
    ]) {
      await home();
      await tester.tap(find.byKey(Key('home_tile_$id')));
      await tester.pumpAndSettle();
      expect(find.byType(type), findsOneWidget, reason: id);
    }

    await home();
    await tester.drag(
      find.byKey(const Key('home_scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('সব দেখুন'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(
      tester.widget<HistoryScreen>(find.byType(HistoryScreen)).highlightTxnId,
      isNull,
    );

    await home();
    await tester.drag(
      find.byKey(const Key('home_scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    final row = tester.widget<TxnRow>(find.byType(TxnRow).first);
    await tester.tap(find.byType(TxnRow).first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<HistoryScreen>(find.byType(HistoryScreen)).highlightTxnId,
      row.txn.txnId,
    );

    await home();
    await tester.tap(find.byKey(const Key('home_settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Send money from the tile keeps the payee through the amount '
      'step (regression: a pushed flow lost its intent on the first go)', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);
    await tester.tap(find.byKey(const Key('home_tile_send')));
    await tester.pumpAndSettle();
    expect(find.byType(PayStartScreen), findsOneWidget);
    final startState = tester.state(find.byType(PayStartScreen));

    await tester.tap(find.text('মা').first);
    // The amount step animates continuously; settle by time, not by idle.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AmountStep), findsOneWidget);
    expect(
      tester.state(find.byType(PayStartScreen, skipOffstage: false)),
      same(startState),
      reason: 'the start page must survive the step change',
    );
    final intent = c.read(payControllerProvider);
    expect(intent.kind, PayKind.send);
    expect(intent.counterparty?.nameBn, 'মা');
  });

  testWidgets('held row shows its tag; pending intervention shows the card', (
    tester,
  ) async {
    final h = ScreenHarness();
    // One fixed clock for the rows and the screen (no midnight flip).
    final now = DateTime.utc(2026, 10, 17, 6);
    final c = await pumpApp(
      tester,
      harness: h,
      location: Routes.home,
      extraOverrides: [homeClockProvider.overrideWithValue(() => now)],
    );
    await tester.runAsync(() async {
      await c
          .read(ledgerRepoProvider)
          .create(
            'rina',
            LedgerTxn(
              txnId: 'txn_t',
              ts: now,
              type: 'send_money',
              amountBdt: 7900,
              fromAcct: 'acct_rina',
              toAcct: 'acct_x',
              status: LedgerStatus.held,
              counterpartyNameBn: 'নতুন নম্বর',
            ),
          );
      await c
          .read(interventionRepoProvider)
          .upsert(
            InterventionRecord(
              id: 'int_t',
              uid: 'rina',
              txnId: 'txn_t',
              trigger: 'new_payee_high_amount',
              scriptBn: '',
              reasons: const [],
              actions: const [ActionItem(type: 'trusted_contact_check')],
              status: InterventionStatus.pending,
              createdAt: now,
            ),
          );
    });
    await tester.pumpAndSettle();

    // The pending card (title, amount · payee, tag) above Apa's card.
    final card = find.byKey(const Key('pending_int_t'));
    expect(card, findsOneWidget);
    expect(find.text('আপনজনের উত্তরের অপেক্ষায়'), findsOneWidget);
    expect(find.text('৳ ৭,৯০০ · নতুন নম্বর'), findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      lessThan(tester.getTopLeft(find.byType(ApaInsightCard)).dy),
    );
    expect(tester.getSize(card).height, greaterThanOrEqualTo(72));
    // The security card does not repeat the pending card (ux-review 2c):
    // no held insight in it, the next insight instead; the FNA list keeps it.
    expect(
      find.byKey(const Key('apa_insight_card_held_transfer')),
      findsNothing,
    );
    expect(find.text('আপনার একটি লেনদেন আটকে আছে'), findsNothing);
    expect(
      c.read(apaInsightsProvider).map((i) => i.id),
      contains('held_transfer'),
    );
    // The held row is the newest recent row and carries "আটকে আছে".
    await tester.drag(
      find.byKey(const Key('home_scroll')),
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    final newest = find.byKey(const ValueKey('home_txn_txn_t'));
    expect(newest, findsOneWidget);
    expect(
      find.descendant(of: newest, matching: find.text('আটকে আছে')),
      findsOneWidget,
    );
    // A held debit does not move the balance.
    await tester.drag(
      find.byKey(const Key('home_scroll')),
      const Offset(0, 2000),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(HeroBalance), matching: _amount(9841)),
      findsOneWidget,
    );
  });

  for (final w in [360.0, 412.0]) {
    testWidgets('English pending card at ${w.toInt()} dp: whole title, the '
        'payee by English name', (tester) async {
      final h = ScreenHarness();
      final now = DateTime.utc(2026, 10, 17, 6);
      final c = await pumpApp(
        tester,
        harness: h,
        location: Routes.home,
        extraOverrides: [
          homeClockProvider.overrideWithValue(() => now),
          initialLocaleProvider.overrideWithValue(const Locale('en')),
        ],
      );
      _viewport(tester, w, 915);
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await c
            .read(ledgerRepoProvider)
            .create(
              'rina',
              LedgerTxn(
                txnId: 'txn_ma',
                ts: now,
                type: 'send_money',
                amountBdt: 5000,
                fromAcct: 'acct_rina',
                toAcct: 'acct_rahima',
                status: LedgerStatus.held,
                counterpartyNameBn: 'মা',
              ),
            );
        await c
            .read(interventionRepoProvider)
            .upsert(
              InterventionRecord(
                id: 'int_ma',
                uid: 'rina',
                txnId: 'txn_ma',
                trigger: 'call_active',
                scriptBn: '',
                reasons: const [],
                actions: const [],
                status: InterventionStatus.pending,
                createdAt: now,
              ),
            );
      });
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('pending_int_ma'));
      expect(card, findsOneWidget);
      expect(find.text('Waiting for your trusted person'), findsOneWidget);
      expect(find.text('৳ 5,000 · Ma (Rahima Begum)'), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.textContaining('মা')),
        findsNothing,
      );
      for (final t in tester.widgetList<Text>(
        find.descendant(of: card, matching: find.byType(Text)),
      )) {
        expect(t.overflow, isNot(TextOverflow.ellipsis), reason: t.data);
      }
      for (final r in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: card, matching: find.byType(RichText)),
      )) {
        expect(r.didExceedMaxLines, isFalse, reason: r.text.toPlainText());
      }
    });
  }

  for (final persona in [Persona.rina, Persona.rahima]) {
    testWidgets('${persona.uid}: no seeded row repeats its title in its '
        'subtitle; ok/done rows carry no tag', (tester) async {
      final h = ScreenHarness();
      final c = await pumpApp(
        tester,
        harness: h,
        persona: persona,
        location: Routes.home,
      );
      final rows = (await tester.runAsync(
        () => c
            .read(ledgerRepoProvider)
            .watchRecent(persona.uid, limit: 50)
            .first,
      ))!;
      expect(rows, isNotEmpty);
      final user = c.read(authRepoProvider).current!;
      final context = tester.element(find.byType(HomeScreen));
      final l10n = context.l10n;
      for (final t in rows) {
        final (title, type) = TxnRow.titleAndType(context, t, user.acctId);
        expect(title, isNotEmpty);
        if (type != null) {
          expect(title, isNot(contains(type)), reason: '$t');
          expect(type, isNot(contains(title)), reason: '$t');
        }
        if (t.status == LedgerStatus.ok || t.status == LedgerStatus.done) {
          expect(TxnRow.tagFor(l10n, t.status), isNull, reason: '$t');
        }
      }
      expect(TxnRow.tagFor(l10n, LedgerStatus.held)?.$1, 'আটকে আছে');
    });
  }

  testWidgets('the simulated tag is pinned to the security card\'s trailing '
      'edge', (tester) async {
    for (final (w, hgt) in [(360.0, 640.0), (412.0, 915.0)]) {
      final h = ScreenHarness();
      h.api.appSafetyResponse = _simulatedBlock;
      await pumpApp(tester, harness: h, location: Routes.home);
      _viewport(tester, w, hgt);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();

      final card = find.byType(ApaInsightCard);
      final tag = find.descendant(
        of: card,
        matching: find.byKey(SafetyStatusRow.tagKey),
      );
      expect(tag, findsOneWidget);
      expect(find.text('সিমুলেটেড'), findsOneWidget);
      final content = find.descendant(
        of: card,
        matching: find.byKey(const Key('apa_insight_content')),
      );
      final tagRight = tester.getRect(tag).right;
      expect(
        tagRight,
        moreOrLessEquals(tester.getRect(content).right, epsilon: 1),
      );
      expect(
        tagRight,
        moreOrLessEquals(tester.getRect(card).right - BhSpace.m, epsilon: 1),
      );
      // In the card's top row, beside the header's first line (a BLOCK
      // leads with "এফএনএ: বিপদ", not the phone-safety row).
      final prefix = find.descendant(
        of: card,
        matching: find.byKey(const Key('apa_insight_header_text')),
      );
      expect(
        tester.getRect(tag).center.dy,
        moreOrLessEquals(tester.getRect(prefix).center.dy, epsilon: 6),
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('pull to refresh re-runs the safety check', (tester) async {
    final h = ScreenHarness();
    await pumpApp(tester, harness: h, location: Routes.home);
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));
    await tester.fling(
      find.byKey(const Key('home_scroll')),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(2));
  });

  testWidgets('a scored hold makes the security card say so (server reasons)', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);
    c.read(lastScoreProvider.notifier).state = const ScoreResponse(
      decision: Decision.hold,
      riskScore: 0.91,
      band: Band.critical,
      reasons: [
        Reason(
          code: 'CALL_ACTIVE',
          weight: 0.6,
          textBn: 'আপনি এখন একটি কলে আছেন।',
          textEn: 'You are on a call right now.',
        ),
      ],
      actions: [ActionItem(type: 'hold_transaction')],
      modelVersion: 'rules-v1',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apa_insight_severity')), findsOneWidget);
    expect(find.text('আপনি এখন একটি কলে আছেন।'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home on load expires cash-in codes the agent never confirmed', (
    tester,
  ) async {
    final h = ScreenHarness();
    final at = DateTime.utc(2026, 10, 17, 6);
    final c = await pumpApp(
      tester,
      harness: h,
      location: Routes.history,
      extraOverrides: [
        homeClockProvider.overrideWithValue(
          () => at.add(const Duration(minutes: 20)),
        ),
      ],
    );
    await tester.runAsync(
      () => c
          .read(ledgerRepoProvider)
          .create(
            'rina',
            LedgerTxn(
              txnId: 'txn_ci_old',
              ts: at,
              type: 'cash_in',
              amountBdt: 1000,
              fromAcct: 'AG-0030',
              toAcct: 'acct_rina',
              status: LedgerStatus.requested,
              counterpartyNameBn: 'এজেন্ট ক্যাশ ইন',
            ),
          ),
    );
    c.read(routerProvider).go(Routes.home);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final rows = (await tester.runAsync(
      () => c.read(ledgerRepoProvider).watchRecent('rina', limit: 50).first,
    ))!;
    expect(
      rows.firstWhere((t) => t.txnId == 'txn_ci_old').status,
      LedgerStatus.cancelled,
    );
  });
}
