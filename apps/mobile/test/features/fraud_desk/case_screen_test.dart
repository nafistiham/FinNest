import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/features/fraud_desk/ui/case_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fraud_desk_test_support.dart';

void main() {
  late DeskHarness h;
  late List<Uri> launched;

  void caseTest(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        h = await DeskHarness.create(tester);
        launched = [];
        await body(tester);
        // Dispose the screen so its poll timer is cancelled.
        await tester.pumpWidget(const SizedBox());
      });

  Widget screen([String id = 'CZ-0002']) => CaseScreen(
    caseId: id,
    consoleUrl: 'https://case-zero.test',
    open: (u) async {
      launched.add(u);
      return true;
    },
  );

  int reads() => h.desk.risk.callsTo(RiskRoutes.investigationTemplate).length;

  caseTest('polls every 2 s while running, every 10 s once done', (
    tester,
  ) async {
    h.desk.risk.cases['CZ-0002'] = report(status: CaseStatus.running);
    await pumpDesk(tester, h, screen());
    await tester.pump();
    expect(reads(), 1);
    expect(find.byKey(const Key('case_running')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1900));
    expect(reads(), 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(reads(), 2);

    h.desk.risk.cases['CZ-0002'] = report();
    await tester.pump(const Duration(seconds: 2));
    expect(reads(), 3);
    expect(find.byKey(const Key('case_recommendation')), findsOneWidget);

    // Done: the next read is 10 s away.
    await tester.pump(const Duration(seconds: 9));
    expect(reads(), 3);
    await tester.pump(const Duration(seconds: 1));
    expect(reads(), 4);

    // The link follows the report.
    final link = (await h.links.all('rina')).single;
    expect(link.lastStatus, CaseStatus.done);
    expect(link.lastAction, 'freeze');
  });

  caseTest('no polling in the background; a resume reads at once', (
    tester,
  ) async {
    h.desk.risk.cases['CZ-0002'] = report(status: CaseStatus.queued);
    await pumpDesk(tester, h, screen());
    await tester.pump();
    expect(reads(), 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(reads(), 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads(), 2);
    await tester.pump(const Duration(seconds: 2));
    expect(reads(), 3);
  });

  caseTest('no polling while another route covers the case', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report(status: CaseStatus.running);
    final nav = GlobalKey<NavigatorState>();
    await pumpDesk(
      tester,
      h,
      Navigator(
        key: nav,
        observers: [h.routes],
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => screen()),
      ),
    );
    await tester.pump();
    expect(reads(), 1);
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 10));
    expect(reads(), 1);
    nav.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 500));
    expect(reads(), 2);
  });

  caseTest('done: header, recommendation, score, counts, evidence, ring', (
    tester,
  ) async {
    h.desk.risk.cases['CZ-0002'] = report();
    await pumpDesk(tester, h, screen());
    await frames(tester);
    expect(find.text('স্টাফ ভিউ · ডেমো'), findsOneWidget);
    expect(find.text('…১০৭০'), findsWidgets);
    expect(find.text('শেষ'), findsOneWidget);
    expect(find.text('সুপারিশ: অ্যাকাউন্ট আটকানো'), findsOneWidget);
    expect(
      find.text('এজেন্টের সুপারিশ, বিশ্লেষকের অনুমোদন বাকি'),
      findsOneWidget,
    );
    expect(find.text('মডেল স্কোর ৮৭%'), findsOneWidget);
    expect(find.text('প্রমাণ ১ · রিং ৩'), findsOneWidget);
    expect(find.text('…১৩০৮'), findsOneWidget);
    expect(find.text('Rapid forwarding.'), findsOneWidget);
    expect(find.text('…১৩৪১'), findsOneWidget);
    expect(find.textContaining('acct_'), findsNothing);
    expect(find.text('মডেল: mule-lgbm-0.1+gemini'), findsOneWidget);

    // Summary in the app language, the toggle shows the other one.
    expect(find.text('অ্যাকাউন্টটি দ্রুত টাকা সরিয়েছে।'), findsOneWidget);
    await tester.tap(find.byKey(const Key('case_summary_toggle')));
    await frames(tester, 2);
    expect(find.text('The seed forwarded funds rapidly.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('case_summary_toggle')));
    await frames(tester, 2);
    expect(find.text('অ্যাকাউন্টটি দ্রুত টাকা সরিয়েছে।'), findsOneWidget);
  });

  caseTest('approved on the watch-list: the pending line goes', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report(acctId: 'acct_01341');
    await pumpDesk(tester, h, screen());
    await frames(tester);
    expect(find.text('বিশ্লেষক অনুমোদিত'), findsOneWidget);
    expect(
      find.text('এজেন্টের সুপারিশ, বিশ্লেষকের অনুমোদন বাকি'),
      findsNothing,
    );
  });

  for (final (wire, label) in const [
    ('edd', 'বাড়তি যাচাই'),
    ('monitor', 'নজরে রাখা'),
    ('close_no_action', 'ব্যবস্থা নেই'),
    ('route_to_risk_reviewer', 'পর্যালোচকের কাছে'),
    ('something_new', 'পর্যালোচকের কাছে'),
  ]) {
    caseTest('action $wire reads "$label"', (tester) async {
      h.desk.risk.cases['CZ-0002'] = report(action: wire);
      await pumpDesk(tester, h, screen());
      await frames(tester);
      expect(find.text('সুপারিশ: $label'), findsOneWidget);
    });
  }

  caseTest('failed: the failure and the reviewer line', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report(status: CaseStatus.failed);
    await pumpDesk(tester, h, screen());
    await frames(tester);
    expect(find.text('তদন্ত ব্যর্থ হয়েছে'), findsOneWidget);
    expect(
      find.text('একজন ঝুঁকি পর্যালোচক বিষয়টি হাতে দেখবেন।'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('case_recommendation')), findsNothing);
  });

  caseTest('stub fallback is labelled scripted', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report(modelVersion: 'stub-fallback');
    await pumpDesk(tester, h, screen());
    await frames(tester);
    expect(find.text('স্ক্রিপ্টেড উত্তর (তদন্তকারী ব্যস্ত)'), findsOneWidget);
  });

  caseTest('a stale link (404) says so, stops polling, closes the link', (
    tester,
  ) async {
    await h.links.upsert(
      'rina',
      CaseLink(
        caseId: 'CZ-0042',
        acctId: 'acct_01070',
        openedAt: deskNow,
        lastStatus: CaseStatus.running,
      ),
    );
    await pumpDesk(tester, h, screen('CZ-0042'));
    await frames(tester);
    expect(find.text('তদন্তটি আর পাওয়া যাচ্ছে না'), findsOneWidget);
    expect(reads(), 1);
    await tester.pump(const Duration(seconds: 30));
    expect(reads(), 1);
    final link = (await h.links.all('rina')).single;
    expect(link.lastStatus, CaseStatus.failed);
  });

  caseTest('a 5xx keeps the last report and keeps polling', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report(status: CaseStatus.running);
    await pumpDesk(tester, h, screen());
    await tester.pump();
    h.desk.risk.failNext[RiskRoutes.investigationTemplate] = [
      const InvestigatorUnavailable(),
    ];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const Key('case_refresh_failed')), findsOneWidget);
    expect(find.byKey(const Key('case_running')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(reads(), 3);
    expect(find.byKey(const Key('case_refresh_failed')), findsNothing);
  });

  caseTest('console button in the bottom bar', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report();
    await pumpDesk(tester, h, screen());
    await frames(tester);
    final bar = find.byType(BhBottomBar);
    expect(
      find.descendant(of: bar, matching: find.byKey(const Key('open_console'))),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('open_console')));
    await frames(tester, 2);
    expect(launched, [Uri.parse('https://case-zero.test')]);
  });

  caseTest('English: summary and labels', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report();
    await pumpDesk(tester, h, screen(), locale: const Locale('en'));
    await frames(tester);
    expect(find.text('Recommendation: Freeze the account'), findsOneWidget);
    expect(find.text('Model score 87%'), findsOneWidget);
    expect(find.text('The seed forwarded funds rapidly.'), findsOneWidget);
    expect(find.text('Show Bangla'), findsOneWidget);
  });

  caseTest('no overflow at 360/412, both themes and languages', (tester) async {
    for (final status in const [
      CaseStatus.running,
      CaseStatus.done,
      CaseStatus.failed,
    ]) {
      h.desk.risk.cases['CZ-0002'] = report(status: status);
      for (final width in const [360.0, 412.0]) {
        for (final b in Brightness.values) {
          for (final l in const [Locale('bn'), Locale('en')]) {
            await pumpDesk(
              tester,
              h,
              screen(),
              brightness: b,
              locale: l,
              width: width,
              height: 640,
            );
            await frames(tester, 3);
            expect(
              tester.takeException(),
              isNull,
              reason: '$status $width $b $l',
            );
            await tester.pumpWidget(const SizedBox());
          }
        }
      }
    }
  });

  caseTest('the live summary: ids masked (the victim by number), transfer '
      'ids moved to the evidence, readable times, "ভুক্তভোগী"', (
    tester,
  ) async {
    h.desk.risk.cases['CZ-0002'] = report(
      summaryBn:
          '২০২৬-১১-১০ তারিখে ১৪:১৩:০০ সময়ে ভিকটিম acct_rina থেকে '
          'txn_011308 এর মাধ্যমে acct_01070-এ টাকা গেছে।',
      summaryEn:
          'On 2026-11-10 at 14:13:00, victim acct_rina transferred Tk 7,900 '
          'to first-layer mule acct_01070 in txn_011308 and txn_011309.',
    );
    await pumpDesk(tester, h, screen());
    await frames(tester);
    final summary = tester.widget<Text>(find.byKey(const Key('case_summary')));
    expect(
      summary.data,
      '১০ নভেম্বর, ১৪:১৩ সময়ে ভুক্তভোগী …৪১২ থেকে তালিকার লেনদেনের '
      'মাধ্যমে …১০৭০-এ টাকা গেছে।',
    );
    for (final raw in ['acct_', 'txn_', 'rina', 'ভিকটিম', '১৪:১৩:০০']) {
      expect(find.textContaining(raw), findsNothing, reason: raw);
    }
    // txn_011308 is already an evidence row; txn_011309 is listed as named.
    expect(find.text('সারাংশে উল্লেখিত লেনদেন: …১৩০৯'), findsOneWidget);
    await tester.tap(find.byKey(const Key('case_summary_toggle')));
    await frames(tester, 2);
    expect(
      tester.widget<Text>(find.byKey(const Key('case_summary'))).data,
      'On 10 November, 14:13, victim …412 transferred Tk 7,900 to '
      'first-layer mule …1070 in a listed transfer and a listed transfer.',
    );
  });

  caseTest('no evidence rows: "প্রমাণ পাওয়া যায়নি" instead of a zero', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report(evidence: const []);
    await pumpDesk(tester, h, screen());
    await frames(tester);
    expect(find.text('প্রমাণ পাওয়া যায়নি · রিং ৩'), findsOneWidget);
    expect(find.textContaining('প্রমাণ ০'), findsNothing);
  });

  caseTest('polish: the toggle on the text gutter, ring rows '
      'left-aligned with the role, no chips', (tester) async {
    h.desk.risk.cases['CZ-0002'] = report();
    await pumpDesk(tester, h, screen());
    await frames(tester);
    final summaryLeft = tester
        .getTopLeft(find.byKey(const Key('case_summary')))
        .dx;
    final toggleText = find.descendant(
      of: find.byKey(const Key('case_summary_toggle')),
      matching: find.byType(Text),
    );
    expect(tester.getTopLeft(toggleText).dx, closeTo(summaryLeft, 1));
    expect(summaryLeft, closeTo(16, 1));

    final ring = find.byKey(const Key('case_ring'));
    expect(
      find.descendant(of: ring, matching: find.byType(StatusTag)),
      findsNothing,
    );
    final row = find.byKey(const Key('ring_acct_01341'));
    expect(tester.getTopLeft(row).dx, closeTo(16, 1));
    expect(
      find.descendant(of: row, matching: find.text('নিয়ন্ত্রক')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('ring_acct_01070')),
        matching: find.text('প্রথম স্তর'),
      ),
      findsOneWidget,
    );
    final version = tester.widget<Text>(
      find.byKey(const Key('case_model_version')),
    );
    final context = tester.element(find.byKey(const Key('case_model_version')));
    expect(
      version.style?.fontSize,
      Theme.of(context).textTheme.labelSmall!.fontSize,
    );
    expect(version.style?.color, context.palette.mutedText);
  });
}
