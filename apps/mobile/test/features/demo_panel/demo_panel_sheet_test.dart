import 'package:bhorosha/app/widgets/choice_tile.dart';
import 'package:bhorosha/app/widgets/sheet_header.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/demo_panel/logic/demo_panel_controller.dart';
import 'package:bhorosha/features/demo_panel/ui/demo_panel_screen.dart';
import 'package:bhorosha/features/demo_panel/ui/demo_panel_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadBanglaFont;
import 'demo_panel_test_support.dart';

/// A page whose logo opens the sheet on long press.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: DemoLongPressTarget(
        child: SizedBox(
          key: Key('logo'),
          width: 120,
          height: 120,
          child: ColoredBox(color: Colors.teal),
        ),
      ),
    ),
  );
}

/// The panel's own vertical scroll view.
final Finder panelList = find
    .descendant(
      of: find.byType(DemoPanelBody),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the panel's list down until [finder] is on stage, then aligns it.
/// Each step settles so a fling from the synthetic drag has finished before
/// the next one; `scrollUntilVisible` ends on a jump that is not laid out.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.drag(panelList, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget, reason: 'not reached by scrolling down');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// Brings [finder] into view through every ancestor scrollable (the
/// integrity row scrolls horizontally inside the list) and taps it.
Future<void> revealAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'long-pressing the target opens the sheet with switches and the preset',
    (tester) async {
      final h = DemoPanelHarness();
      await pumpDemo(tester, harness: h, child: const _Host());

      expect(find.byType(DemoPanelBody), findsNothing);
      await tester.longPress(find.byKey(const Key('logo')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(DemoPanelBody), findsOneWidget);
      expect(find.text('ডেমো প্যানেল'), findsOneWidget);
      // The four flags and the enrolment switch (আচরণ).
      expect(find.byType(SwitchListTile), findsNWidgets(5));
      expect(find.byKey(DemoPanelBody.enrolToggleKey), findsOneWidget);
      for (final flag in DemoFlagNames.all) {
        expect(find.byKey(DemoPanelBody.switchKey(flag)), findsOneWidget);
      }
      expect(find.byKey(DemoPanelBody.presetKey), findsOneWidget);
      expect(find.textContaining('ক্লাউড: চালু করা নেই'), findsOneWidget);
      expect(find.textContaining('absent'), findsNothing);

      // Opening the sheet runs a health check; the fake answers ok with 42 ms.
      expect(find.byKey(DemoPanelBody.healthDotKey), findsOneWidget);
      expect(find.textContaining('৪২'), findsOneWidget);
      expect(h.api.callsTo(RiskRoutes.health), hasLength(1));

      // Primary targets are at least 56 dp tall.
      expect(tester.getSize(find.byKey(DemoPanelBody.presetKey)).height, 56);
      expect(
        tester.getSize(find.byKey(DemoPanelBody.switchKey('sim_swap'))).height,
        greaterThanOrEqualTo(56),
      );
    },
  );

  testWidgets('toggling a switch writes the repo', (tester) async {
    final h = DemoPanelHarness();
    final c = await pumpDemo(tester, harness: h, child: const _Host());
    await tester.longPress(find.byKey(const Key('logo')));
    await tester.pumpAndSettle();

    await reveal(tester, find.byKey(DemoPanelBody.switchKey('sim_swap')));
    await tester.tap(find.byKey(DemoPanelBody.switchKey('sim_swap')));
    await tester.pumpAndSettle();

    expect(panel(c).demo.simSwap, isTrue, reason: 'tap reached controller');
    final tile = tester.widget<SwitchListTile>(
      find.byKey(DemoPanelBody.switchKey('sim_swap')),
    );
    expect(tile.value, isTrue);
    expect((await storedIn(tester, c, 'rina')).simSwap, isTrue);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('video preset sets call_active and shows the rolling score', (
    tester,
  ) async {
    final h = DemoPanelHarness();
    final c = await pumpDemo(tester, harness: h, child: const _Host());
    await tester.longPress(find.byKey(const Key('logo')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(DemoPanelBody.presetKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(panel(c).replaying, isFalse);
    expect(panel(c).error, isNull);
    await tester.pumpAndSettle();

    final d = await storedIn(tester, c, 'rina');
    expect(d.callActive, isTrue);
    expect(d.scamScore, 0.85);
    await reveal(tester, find.byType(LinearProgressIndicator));
    expect(find.text(otpScam.evidenceQuote), findsOneWidget);
    expect(find.text('প্রতারণার স্কোর ০.৮৫'), findsOneWidget);
    // Readable first, the scam type as a muted wire suffix.
    expect(
      find.textContaining('স্কোর ০.৮৫ · তাড়া: বেশি', findRichText: true),
      findsNWidgets(3),
    );
    expect(
      find.textContaining('otp_phishing', findRichText: true),
      findsNWidgets(3),
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.85);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('preview button plays apa_hold_call_active; resets are wired', (
    tester,
  ) async {
    final h = DemoPanelHarness();
    final audio = FakeApaAudio();
    final c = await pumpDemo(
      tester,
      harness: h,
      child: const DemoPanelScreen(),
      extraOverrides: [apaAudioProvider.overrideWithValue(audio)],
    );

    // The screen hosts the same body under an app bar.
    expect(find.byType(DemoPanelBody), findsOneWidget);
    expect(find.text('ডেমো প্যানেল'), findsOneWidget);

    // The signals group, below the scene group.
    await reveal(tester, find.byKey(DemoPanelBody.switchKey('screen_share')));
    await tester.tap(find.byKey(DemoPanelBody.switchKey('screen_share')));
    await tester.pumpAndSettle();
    expect(panel(c).demo.screenShare, isTrue);
    expect((await storedIn(tester, c, 'rina')).screenShare, isTrue);

    await reveal(tester, find.byKey(DemoPanelBody.previewAudioKey));
    await tester.tap(find.byKey(DemoPanelBody.previewAudioKey));
    await tester.pump();
    expect(audio.played, ['apa_hold_call_active']);

    await reveal(tester, find.byKey(DemoPanelBody.resetAllKey));
    await tester.tap(find.byKey(DemoPanelBody.resetAllKey));
    await tester.pumpAndSettle();
    expect(panel(c).demo, DemoState.initial);
    expect(await storedIn(tester, c, 'rina'), DemoState.initial);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('choosing an integrity scenario writes the repo; re-run posts', (
    tester,
  ) async {
    final h = DemoPanelHarness();
    final c = await pumpDemo(tester, harness: h, child: const _Host());
    await tester.longPress(find.byKey(const Key('logo')));
    await tester.pumpAndSettle();

    await reveal(tester, find.byKey(DemoPanelBody.integrityKey));
    expect(find.byKey(DemoPanelBody.integrityKey), findsOneWidget);
    await revealAndTap(tester, find.text('বদলানো অ্যাপ'));
    expect(panel(c).demo.integrityScenario, IntegrityScenarios.moddedApp);
    expect(
      (await storedIn(tester, c, 'rina')).integrityScenario,
      IntegrityScenarios.moddedApp,
    );

    await revealAndTap(tester, find.text('স্বাভাবিক'));
    expect((await storedIn(tester, c, 'rina')).integrityScenario, isNull);

    await reveal(tester, find.byKey(DemoPanelBody.rerunSafetyKey));
    await tester.tap(find.byKey(DemoPanelBody.rerunSafetyKey));
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('confirm cash in: credits the waiting row, says so', (
    tester,
  ) async {
    final h = DemoPanelHarness();
    final c = await pumpDemo(
      tester,
      harness: h,
      child: const DemoPanelScreen(),
    );
    final ledger = c.read(ledgerRepoProvider);
    final before = (await tester.runAsync(
      () => ledger.watchBalance('rina').first,
    ))!;
    await tester.runAsync(
      () => ledger.create(
        'rina',
        LedgerTxn(
          txnId: 'txn_ci',
          ts: DateTime.now(),
          type: 'cash_in',
          amountBdt: 1000,
          fromAcct: 'cashin_BH-4K7Q',
          toAcct: 'acct_rina',
          channel: 'agent',
          status: LedgerStatus.requested,
          counterpartyNameBn: 'এজেন্ট ক্যাশ ইন',
        ),
      ),
    );

    await reveal(tester, find.byKey(DemoPanelBody.confirmCashInKey));
    expect(find.text('এজেন্ট ক্যাশ ইন নিশ্চিত করলেন'), findsOneWidget);
    await tester.tap(find.byKey(DemoPanelBody.confirmCashInKey));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      find.text('ক্যাশ ইন নিশ্চিত হয়েছে, ব্যালেন্স বেড়েছে'),
      findsOneWidget,
    );
    final after = await tester.runAsync(
      () => ledger.watchBalance('rina').first,
    );
    expect(after, before + 1000);

    // A second tap finds nothing waiting.
    ScaffoldMessenger.of(tester.element(find.byType(DemoPanelBody)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(DemoPanelBody.confirmCashInKey));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('এজেন্টের অপেক্ষায় কোনো ক্যাশ ইন নেই'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('sheet header, three groups, verdicts as a 2 x 2 grid', (
    tester,
  ) async {
    final h = DemoPanelHarness();
    await pumpDemo(tester, harness: h, child: const _Host());
    await tester.longPress(find.byKey(const Key('logo')));
    await tester.pumpAndSettle();
    expect(find.byType(SheetHeader), findsOneWidget);
    for (final g in ['দৃশ্য', 'সংকেত', 'কাজ']) {
      expect(find.text(g), findsOneWidget, reason: g);
    }
    // No Latin digit or raw English status in the Bangla header.
    expect(find.textContaining('সার্ভার ৪২ মি.সে.'), findsOneWidget);
    expect(find.textContaining('Firebase'), findsNothing);
    final tiles = find.descendant(
      of: find.byKey(DemoPanelBody.verdictKey),
      matching: find.byType(ChoiceTile),
    );
    expect(tiles, findsNWidgets(4));
    final r = [
      for (final e in tiles.evaluate()) tester.getRect(find.byWidget(e.widget)),
    ];
    expect(r[0].top, r[1].top);
    expect(r[2].top, r[3].top);
    expect(r[2].top, greaterThan(r[0].bottom));
    for (final rect in r) {
      expect(rect.height, greaterThanOrEqualTo(56));
    }
  }, timeout: const Timeout(Duration(seconds: 45)));

  for (final size in const [Size(360, 640), Size(412, 915)]) {
    for (final b in Brightness.values) {
      for (final l in const [Locale('bn'), Locale('en')]) {
        testWidgets('no overflow at $size, $b, $l', (tester) async {
          tester.view.devicePixelRatio = 3;
          tester.view.physicalSize = size * 3;
          addTearDown(tester.view.reset);
          final h = DemoPanelHarness();
          await pumpDemo(
            tester,
            harness: h,
            child: const DemoPanelScreen(),
            brightness: b,
            locale: l,
          );
          for (var i = 0; i < 20; i++) {
            await tester.drag(panelList, const Offset(0, -300));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }, timeout: const Timeout(Duration(seconds: 45)));
      }
    }
  }

  testWidgets('360 dp: the preset label and the status line are whole '
      '(short label + caption; the status wraps)', (tester) async {
    await loadBanglaFont();
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final h = DemoPanelHarness();
    await pumpDemo(tester, harness: h, child: const _Host());
    await tester.longPress(find.byKey(const Key('logo')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('ভিডিওর জন্য সাজান'), findsOneWidget);
    expect(find.text('কল চলছে + প্রতারণার কল'), findsOneWidget);
    for (final f in [
      find.byKey(DemoPanelBody.presetKey),
      find.byKey(const Key('demo_status_line')),
    ]) {
      for (final r in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: f, matching: find.byType(RichText)),
      )) {
        expect(r.didExceedMaxLines, isFalse, reason: r.text.toPlainText());
      }
    }
    for (final t in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('demo_status_line')),
        matching: find.byType(Text),
      ),
    )) {
      expect(t.overflow, isNot(TextOverflow.ellipsis));
    }
  });
}
