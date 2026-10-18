import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/widgets/txn_row.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/history/logic/history_providers.dart';
import 'package:bhorosha/features/history/ui/widgets/txn_detail_sheet.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart'
    show clockProvider;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/screen_harness.dart';
import '../safety/safety_test_support.dart' show loadBanglaFont;

LedgerTxn _t(
  String id,
  DateTime ts, {
  String type = 'send_money',
  String from = 'acct_rina',
  String to = 'acct_x',
  String status = LedgerStatus.ok,
}) => LedgerTxn(
  txnId: id,
  ts: ts,
  type: type,
  amountBdt: 100,
  fromAcct: from,
  toAcct: to,
  status: status,
);

/// A ledger with no rows at all.
class _EmptyLedger implements LedgerRepo {
  @override
  Stream<List<LedgerTxn>> watchRecent(String uid, {int limit = 8}) =>
      Stream.value(const []);

  @override
  Stream<double> watchBalance(String uid) => Stream.value(0);

  @override
  List<Payee> savedPayees(Persona p) => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _shownTypes(WidgetTester tester) => [
  for (final r in tester.widgetList<TxnRow>(find.byType(TxnRow))) r.txn.type,
];

void main() {
  setUpAll(loadBanglaFont);

  group('groupByDay', () {
    // 12:00 in Dhaka on 17 Oct 2026.
    final now = DateTime.utc(2026, 10, 17, 6);

    test('today, yesterday, then dates; newest first inside a day', () {
      final rows = [
        _t('a', DateTime.utc(2026, 10, 17, 1)), // today 07:00 Dhaka
        _t('b', DateTime.utc(2026, 10, 16, 20)), // today 02:00 Dhaka
        _t('c', DateTime.utc(2026, 10, 16, 5)), // yesterday
        _t('d', DateTime.utc(2026, 10, 10, 5)),
        _t('e', DateTime.utc(2026, 10, 17, 4)), // today 10:00 Dhaka
        _t('f', DateTime.utc(2025, 11, 10, 5)),
      ];
      final bn = groupByDay(rows, const Locale('bn'), now: now);
      expect(bn.map((d) => d.header), [
        'আজ',
        'গতকাল',
        '১০ অক্টোবর',
        '১০ নভেম্বর ২০২৫',
      ]);
      expect(bn.first.rows.map((t) => t.txnId), ['e', 'a', 'b']);
      final en = groupByDay(rows, const Locale('en'), now: now);
      expect(en.map((d) => d.header), [
        'Today',
        'Yesterday',
        '10 October',
        '10 November 2025',
      ]);
    });

    test('the Dhaka day decides, not UTC', () {
      // 19:00 UTC on the 16th is 01:00 on the 17th in Dhaka: today.
      final rows = [_t('late', DateTime.utc(2026, 10, 16, 19))];
      expect(
        groupByDay(rows, const Locale('bn'), now: now).single.header,
        'আজ',
      );
    });

    test('filters match by type and direction', () {
      const me = 'acct_rina';
      final sent = _t('s', now);
      final got = _t('g', now, from: 'acct_rafiq', to: me);
      final cashOut = _t('co', now, type: 'cash_out', to: 'AG-0027');
      final cashIn = _t('ci', now, type: 'cash_in', from: 'AG-0030', to: me);
      final bill = _t('b', now, type: 'payment', to: 'biller_desco');
      final recharge = _t('r', now, type: 'recharge', to: 'mob_0181');
      final salary = _t('sal', now, type: 'salary', from: 'acct_pay', to: me);
      final all = [sent, got, cashOut, cashIn, bill, recharge, salary];
      List<String> ids(HistoryFilter f) => [
        for (final t in all)
          if (f.matches(t, me)) t.txnId,
      ];
      expect(ids(HistoryFilter.all), hasLength(all.length));
      expect(ids(HistoryFilter.sent), ['s']);
      expect(ids(HistoryFilter.cashOut), ['co']);
      expect(ids(HistoryFilter.cashIn), ['ci']);
      expect(ids(HistoryFilter.recharge), ['r']);
      expect(ids(HistoryFilter.bill), ['b']);
      expect(ids(HistoryFilter.received), ['g', 'ci', 'sal']);
      expect(HistoryFilter.parse('cashout'), HistoryFilter.cashOut);
      expect(HistoryFilter.parse('nonsense'), HistoryFilter.all);
    });
  });

  testWidgets('Rina: every row under sticky day headers, Apa in the bar', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.history);
    final rows = (await tester.runAsync(
      () => c.read(ledgerRepoProvider).watchRecent('rina', limit: 500).first,
    ))!;

    expect(find.text('লেনদেন'), findsWidgets);
    expect(find.byType(TxnRow), findsNWidgets(rows.length));
    final days = groupByDay(rows, const Locale('bn'));
    for (final d in days) {
      final header = find.byKey(ValueKey('history_day_${d.header}'));
      expect(header, findsOneWidget, reason: d.header);
      // The day's rows sit below its header.
      for (final t in d.rows) {
        expect(
          tester.getTopLeft(find.byKey(ValueKey('history_row_${t.txnId}'))).dy,
          greaterThan(tester.getTopLeft(header).dy),
        );
      }
    }
    expect(find.byKey(const Key('apa_bar_history')), findsOneWidget);
    // Seeded rows are final: no tags (the "আটকে আছে" filter chip aside).
    expect(
      find.descendant(
        of: find.byKey(const Key('history_list')),
        matching: find.text('আটকে আছে'),
      ),
      findsNothing,
    );
  });

  testWidgets('filters: cash out, received, and an empty kind', (tester) async {
    final h = ScreenHarness();
    await pumpApp(tester, harness: h, location: Routes.history);
    final all = find.byType(TxnRow).evaluate().length;

    await tester.ensureVisible(find.byKey(const Key('history_filter_cashout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history_filter_cashout')));
    await tester.pumpAndSettle();
    expect(_shownTypes(tester), everyElement('cash_out'));
    expect(_shownTypes(tester), hasLength(2));

    await tester.ensureVisible(
      find.byKey(const Key('history_filter_received')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history_filter_received')));
    await tester.pumpAndSettle();
    for (final r in tester.widgetList<TxnRow>(find.byType(TxnRow))) {
      expect(r.txn.toAcct, 'acct_rina');
    }
    expect(_shownTypes(tester).toSet(), {'cash_in', 'salary'});

    // Nobody recharged in the seed: say so and how to get back.
    await tester.ensureVisible(
      find.byKey(const Key('history_filter_recharge')),
    );
    await tester.tap(find.byKey(const Key('history_filter_recharge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history_empty_filter')), findsOneWidget);
    expect(find.text('এই ধরনের কোনো লেনদেন নেই'), findsOneWidget);
    expect(find.byType(TxnRow), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('history_filter_all')));
    await tester.tap(find.byKey(const Key('history_filter_all')));
    await tester.pumpAndSettle();
    expect(find.byType(TxnRow), findsNWidgets(all));

    // Chips are 56 dp targets and say which one is on.
    final chip = find.byKey(const Key('history_filter_all'));
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(56));
    expect(tester.getSemantics(chip), isSemantics(isSelected: true));
  });

  testWidgets('a row opens its detail sheet: kind, amount, status, time, '
      'reference suffix', (tester) async {
    final h = ScreenHarness();
    await pumpApp(tester, harness: h, location: Routes.history);
    final row = tester.widget<TxnRow>(find.byType(TxnRow).first);
    await tester.tap(find.byType(TxnRow).first);
    await tester.pumpAndSettle();

    expect(find.byType(TxnDetailSheet), findsOneWidget);
    expect(find.text('ধরন'), findsOneWidget);
    expect(find.text('অবস্থা'), findsOneWidget);
    expect(find.text('সময়'), findsOneWidget);
    expect(find.text('রেফারেন্স'), findsOneWidget);
    expect(find.text('সম্পন্ন'), findsOneWidget);
    // Only a short suffix of the id, never the whole id; a code in ASCII
    // capitals even in Bangla (never localised digits).
    expect(find.text(row.txn.txnId), findsNothing);
    expect(
      find.text(TxnDetailSheet.referenceSuffix(row.txn.txnId)),
      findsOneWidget,
    );
    expect(
      TxnDetailSheet.referenceSuffix(row.txn.txnId),
      matches(RegExp(r'^[A-Z0-9]{1,6}$')),
    );
    expect(find.byKey(const Key('txn_detail_amount')), findsOneWidget);

    await tester.tap(find.text('বন্ধ'));
    await tester.pumpAndSettle();
    expect(find.byType(TxnDetailSheet), findsNothing);
  });

  testWidgets('?txn= from Home opens that row\'s sheet', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.home);
    final rows = (await tester.runAsync(
      () => c.read(ledgerRepoProvider).watchRecent('rina', limit: 50).first,
    ))!;
    final target = rows[1];
    routerOf(c).go('${Routes.history}?txn=${target.txnId}');
    await tester.pumpAndSettle();
    expect(find.byType(TxnDetailSheet), findsOneWidget);
    expect(
      tester.widget<TxnDetailSheet>(find.byType(TxnDetailSheet)).txn.txnId,
      target.txnId,
    );
  });

  testWidgets('a held row carries its tag in History too', (tester) async {
    final h = ScreenHarness();
    // One fixed clock for the screen and the row: the day header cannot
    // flip at midnight while the test runs.
    final now = DateTime.utc(2026, 10, 17, 6);
    final c = await pumpApp(
      tester,
      harness: h,
      location: Routes.history,
      extraOverrides: [clockProvider.overrideWithValue(FakeClock(now))],
    );
    await tester.runAsync(
      () => c
          .read(ledgerRepoProvider)
          .create('rina', _t('held_1', now, status: LedgerStatus.held)),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('history_row_held_1'));
    expect(
      find.descendant(of: row, matching: find.text('আটকে আছে')),
      findsOneWidget,
    );
  });

  testWidgets('no transactions at all: an empty state that says what next', (
    tester,
  ) async {
    final h = ScreenHarness();
    await pumpApp(
      tester,
      harness: h,
      location: Routes.history,
      extraOverrides: [ledgerRepoProvider.overrideWithValue(_EmptyLedger())],
    );
    expect(find.byKey(const Key('history_empty')), findsOneWidget);
    expect(find.text('এখনো কোনো লেনদেন নেই'), findsOneWidget);
    expect(find.byType(TxnRow), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final locale in ['bn', 'en']) {
      testWidgets('renders $locale/${brightness.name} at 360 x 640 without '
          'overflow', (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final h = ScreenHarness();
        await pumpApp(
          tester,
          harness: h,
          location: Routes.history,
          extraOverrides: [
            initialLocaleProvider.overrideWithValue(Locale(locale)),
          ],
        );
        tester.view.physicalSize = const Size(1080, 1920);
        tester.view.devicePixelRatio = 3;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(TxnRow), findsWidgets);
        if (locale == 'en') {
          expect(find.text('History'), findsOneWidget);
          expect(find.text('All'), findsOneWidget);
        }
      });
    }
  }

  test('reference suffix keeps the last six characters only', () {
    expect(TxnDetailSheet.referenceSuffix('txn_9f3a2c308c9'), 'C308C9');
    expect(TxnDetailSheet.referenceSuffix('t1'), 'T1');
  });
}
