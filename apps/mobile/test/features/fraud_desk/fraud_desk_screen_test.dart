import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/features/fraud_desk/ui/fraud_desk_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fraud_desk_test_support.dart';

StatusTag tagWith(WidgetTester tester, String label) => tester
    .widgetList<StatusTag>(find.byType(StatusTag))
    .firstWhere((t) => t.label == label);

void main() {
  late DeskHarness h;
  late List<String> opened;
  late List<Uri> launched;

  // The harness is built inside each test body: futures created in setUp
  // live in the real zone and never resolve under the widget test's fake
  // async zone.
  void deskTest(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        h = await DeskHarness.create(tester);
        opened = [];
        launched = [];
        await body(tester);
      });

  Widget desk({int tab = 0, Future<bool> Function(Uri)? open}) =>
      FraudDeskScreen(
        consoleUrl: 'https://case-zero.test',
        open:
            open ??
            (u) async {
              launched.add(u);
              return true;
            },
        initialTab: tab,
        openCase: (_, id) => opened.add(id),
      );

  Future<void> openCases(WidgetTester tester) async {
    await tester.tap(find.byKey(FraudDeskScreen.tabCases));
    await tester.pumpAndSettle();
  }

  deskTest('watch-list: staff tag, masked ids, roles, status tones', (
    tester,
  ) async {
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();

    expect(find.text('স্টাফ ভিউ · ডেমো'), findsOneWidget);
    expect(tagWith(tester, 'স্টাফ ভিউ · ডেমো').status, BhStatus.info);
    expect(find.text('নজরে থাকা অ্যাকাউন্ট'), findsOneWidget);
    expect(find.text('তদন্ত'), findsOneWidget);

    // Masked ids in Bangla digits; never the raw account id.
    expect(find.text('…১০৭০'), findsOneWidget);
    expect(find.text('…১৩৪১'), findsOneWidget);
    expect(find.text('…০০৩৬'), findsOneWidget);
    expect(find.text('…০১৯২'), findsOneWidget);
    expect(find.textContaining('acct_'), findsNothing);

    expect(find.text('প্রথম স্তর'), findsOneWidget);
    expect(find.text('নিয়ন্ত্রক'), findsOneWidget);
    expect(find.text('দ্বিতীয় স্তর'), findsOneWidget);
    expect(find.text('অন্যান্য'), findsOneWidget);

    expect(tagWith(tester, 'সন্দেহভাজন').status, BhStatus.warning);
    expect(tagWith(tester, 'নিশ্চিত').status, BhStatus.danger);
    expect(tagWith(tester, 'সন্দেহমুক্ত').status, BhStatus.success);
    expect(tagWith(tester, 'অজানা').status, BhStatus.neutral);

    // Only the approved payee carries the flag; facts are shown (staff).
    expect(find.byKey(const Key('approved_acct_01341')), findsOneWidget);
    expect(find.byKey(const Key('approved_acct_01070')), findsNothing);
    expect(find.text('বিশ্লেষক অনুমোদিত'), findsOneWidget);
    expect(
      find.text(
        'তথ্য: Forwarded received funds within minutes.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('তদন্ত খোলা হয়নি'), findsNWidgets(2));
  });

  deskTest('tapping a listed case opens it and stores the link', (
    tester,
  ) async {
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('payee_acct_01070')));
    await tester.pumpAndSettle();
    expect(opened, ['CZ-0002']);
    final links = await h.links.all('rina');
    expect(links.single.caseId, 'CZ-0002');
    expect(links.single.acctId, 'acct_01070');
    expect(links.single.openedAt, deskNow);
    expect(
      links.single.adopted,
      isTrue,
      reason: 'picked up from the watch-list, not started here',
    );

    // A payee without a case does nothing.
    await tester.tap(find.byKey(const Key('payee_acct_00036')));
    await tester.pumpAndSettle();
    expect(opened, ['CZ-0002']);
  });

  deskTest('watch-list failure shows a retry that reloads', (tester) async {
    h.desk.listFailure = const NetworkFailure();
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('watch_list_error')), findsOneWidget);
    h.desk.listFailure = null;
    await tester.tap(find.text('আবার চেষ্টা করুন'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('watch_list')), findsOneWidget);
    expect(h.desk.listCalls, 2);
  });

  deskTest('an empty watch-list says so', (tester) async {
    h.desk.list = const PayeeRisk(version: 'payee-risk/1', generatedAt: '');
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('watch_list_empty')), findsOneWidget);
  });

  deskTest('investigations: newest first, status tags, empty state', (
    tester,
  ) async {
    await pumpDesk(tester, h, desk(tab: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cases_empty')), findsOneWidget);

    {
      await h.links.upsert(
        'rina',
        CaseLink(
          caseId: 'CZ-0001',
          acctId: 'acct_01070',
          openedAt: deskNow.subtract(const Duration(hours: 2)),
          lastStatus: CaseStatus.done,
          lastAction: 'freeze',
        ),
      );
      await h.links.upsert(
        'rina',
        CaseLink(
          caseId: 'CZ-0003',
          acctId: 'acct_01341',
          openedAt: deskNow.subtract(const Duration(minutes: 1)),
          lastStatus: CaseStatus.running,
        ),
      );
    }
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.byKey(const Key('case_CZ-0003'))).dy;
    final second = tester.getTopLeft(find.byKey(const Key('case_CZ-0001'))).dy;
    expect(first, lessThan(second));
    expect(tagWith(tester, 'চলছে').status, BhStatus.info);
    expect(tagWith(tester, 'শেষ').status, BhStatus.success);
    expect(find.text('সুপারিশ: অ্যাকাউন্ট আটকানো'), findsOneWidget);

    await tester.tap(find.byKey(const Key('case_CZ-0001')));
    await tester.pumpAndSettle();
    expect(opened, ['CZ-0001']);
  });

  deskTest('start a case: picker, busy, link stored, case opened', (
    tester,
  ) async {
    h.desk.risk.investigateResponse = const InvestigateResponse(
      caseId: 'CZ-0009',
      streamUrl: '/v1/investigations/CZ-0009/events',
    );
    final release = h.desk.risk.hold(RiskRoutes.investigate);
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();
    await openCases(tester);
    await tester.tap(find.byKey(const Key('start_case')));
    await tester.pumpAndSettle();
    expect(find.text('কোন অ্যাকাউন্টের তদন্ত?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pick_acct_00036')));
    await tester.pump();
    await tester.pump();

    // Busy while the start is in flight.
    expect(
      find.descendant(
        of: find.byKey(const Key('start_case')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    release();
    await tester.pumpAndSettle();
    expect(find.text('তদন্ত শুরু হয়েছে'), findsOneWidget);
    expect(opened, ['CZ-0009']);
    final link = (await h.links.all('rina')).single;
    expect(link.caseId, 'CZ-0009');
    expect(link.acctId, 'acct_00036');
    expect(link.lastStatus, CaseStatus.queued);
    expect(h.desk.risk.callsTo(RiskRoutes.investigate).single.body, {
      'acct_id': 'acct_00036',
    });
  });

  deskTest('guard: an open case hides the payee, a recent one disables', (
    tester,
  ) async {
    {
      await h.links.upsert(
        'rina',
        CaseLink(
          caseId: 'CZ-0003',
          acctId: 'acct_01070',
          openedAt: deskNow.subtract(const Duration(minutes: 1)),
          lastStatus: CaseStatus.running,
        ),
      );
      await h.links.upsert(
        'rina',
        CaseLink(
          caseId: 'CZ-0004',
          acctId: 'acct_00036',
          openedAt: deskNow.subtract(const Duration(minutes: 10)),
          lastStatus: CaseStatus.done,
        ),
      );
    }
    await pumpDesk(tester, h, desk(tab: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start_case')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pick_acct_01070')), findsNothing);
    expect(find.byKey(const Key('pick_acct_00036')), findsOneWidget);
    expect(find.text('৩০ মিনিটে একবার। পরে আবার চেষ্টা করুন।'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pick_acct_00036')));
    await tester.pumpAndSettle();
    // Disabled: the sheet stays, nothing was posted.
    expect(find.text('কোন অ্যাকাউন্টের তদন্ত?'), findsOneWidget);
    expect(h.desk.risk.callsTo(RiskRoutes.investigate), isEmpty);
  });

  deskTest('429 is retried once after Retry-After, then succeeds', (
    tester,
  ) async {
    h.desk.risk.failNext[RiskRoutes.investigate] = [
      const RateLimited(retryAfterSeconds: 5),
    ];
    await pumpDesk(tester, h, desk(tab: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start_case')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_acct_00036')));
    await tester.pumpAndSettle();
    expect(h.waited, [const Duration(seconds: 5)]);
    expect(h.desk.risk.callsTo(RiskRoutes.investigate), hasLength(2));
    expect(opened, ['CZ-FAKE']);
  });

  for (final (name, failures, calls, waits) in [
    (
      'a second 429',
      const [
        RateLimited(retryAfterSeconds: 5),
        RateLimited(retryAfterSeconds: 5),
      ],
      2,
      1,
    ),
    (
      'a 429 asking for over 30 s',
      const [RateLimited(retryAfterSeconds: 60)],
      1,
      0,
    ),
    ('a 429 without Retry-After', const [RateLimited()], 1, 0),
    ('a 502', const [InvestigatorUnavailable()], 1, 0),
    ('a 500', const [ServerFailure(500)], 1, 0),
  ]) {
    deskTest('$name shows the reviewer copy', (tester) async {
      h.desk.risk.failNext[RiskRoutes.investigate] = [...failures];
      await pumpDesk(tester, h, desk(tab: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start_case')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick_acct_00036')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('start_failed')), findsOneWidget);
      expect(
        find.text(
          'তদন্ত শুরু করা যায়নি। একজন ঝুঁকি পর্যালোচক বিষয়টি হাতে দেখবেন।',
        ),
        findsOneWidget,
      );
      expect(h.desk.risk.callsTo(RiskRoutes.investigate), hasLength(calls));
      expect(h.waited, hasLength(waits));
      expect(opened, isEmpty);
      expect(await h.links.all('rina'), isEmpty);
    });
  }

  deskTest('console in the bottom bar opens the console URL', (tester) async {
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();
    final bar = find.byType(BhBottomBar);
    expect(
      find.descendant(of: bar, matching: find.byKey(const Key('open_console'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(ApaSquareButton)),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('open_console'))).height,
      greaterThanOrEqualTo(BhSize.touch),
    );
    await tester.tap(find.byKey(const Key('open_console')));
    await tester.pumpAndSettle();
    expect(launched, [Uri.parse('https://case-zero.test')]);
  });

  deskTest('a failed console launch says so', (tester) async {
    await pumpDesk(tester, h, desk(open: (_) async => false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_console')));
    await tester.pumpAndSettle();
    expect(find.text('কনসোল খোলা যায়নি'), findsOneWidget);
  });

  deskTest('English: masked ids in Latin digits', (tester) async {
    await pumpDesk(tester, h, desk(), locale: const Locale('en'));
    await tester.pumpAndSettle();
    expect(find.text('Staff view · demo'), findsOneWidget);
    expect(find.text('…1070'), findsOneWidget);
    expect(find.text('First layer'), findsOneWidget);
    expect(find.text('Analyst approved'), findsOneWidget);
  });

  deskTest('no overflow at 360/412, both themes and languages, both tabs', (
    tester,
  ) async {
    await h.links.upsert(
      'rina',
      CaseLink(
        caseId: 'CZ-0003',
        acctId: 'acct_01341',
        openedAt: deskNow,
        lastStatus: CaseStatus.done,
        lastAction: 'route_to_risk_reviewer',
      ),
    );
    for (final width in const [360.0, 412.0]) {
      for (final b in Brightness.values) {
        for (final l in const [Locale('bn'), Locale('en')]) {
          for (final tab in const [0, 1]) {
            await pumpDesk(
              tester,
              h,
              desk(tab: tab),
              brightness: b,
              locale: l,
              width: width,
              height: 640,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: '$width $b $l $tab');
          }
        }
      }
    }
  });

  deskTest('facts: only the row own, at most two, ids masked, agent code '
      'named, small and muted behind "তথ্য:"', (
    tester,
  ) async {
    h.desk.list = const PayeeRisk(
      version: 'payee-risk/1',
      generatedAt: '2026-10-17T04:47:08+00:00',
      payees: [
        PayeeRiskEntry(
          acctId: 'acct_00036',
          status: 'suspected',
          caseId: 'CZ-0002',
          role: 'mule_L2',
          facts: [
            'acct_01070 received funds from acct_rina via txn_011308.',
            'acct_00036 received Tk 2,000 from acct_01070.',
            'acct_00036 cashed out at agent AG-0014.',
            'acct_00036 shares a device with acct_01288.',
          ],
        ),
      ],
    );
    await pumpDesk(tester, h, desk());
    await tester.pumpAndSettle();
    final first = find.byKey(const Key('fact_acct_00036_0'));
    final second = find.byKey(const Key('fact_acct_00036_1'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(find.byKey(const Key('fact_acct_00036_2')), findsNothing);
    String plain(Finder f) => tester.widget<Text>(f).textSpan!.toPlainText();
    expect(plain(first), 'তথ্য: …০০৩৬ received Tk 2,000 from …১০৭০.');
    expect(plain(second), 'তথ্য: …০০৩৬ cashed out at এজেন্ট AG-0014.');
    expect(find.textContaining('acct_', findRichText: true), findsNothing);
    expect(find.textContaining('txn_', findRichText: true), findsNothing);
    final style = tester.widget<Text>(first).style!;
    final context = tester.element(first);
    expect(style.fontSize, Theme.of(context).textTheme.labelSmall!.fontSize);
    expect(style.color, context.palette.mutedText);
  });
}
