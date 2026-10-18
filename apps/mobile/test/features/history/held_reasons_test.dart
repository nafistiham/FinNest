import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/history/ui/widgets/txn_detail_sheet.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart'
    show clockProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/screen_harness.dart';
import '../safety/safety_test_support.dart' show loadBanglaFont;

const _mule = Reason(
  code: 'DEST_MULE_RISK',
  weight: 0.87,
  textBn: 'এই প্রাপকের অ্যাকাউন্টে সন্দেহজনক লেনদেন দেখা গেছে।',
  textEn: 'This recipient\'s account shows suspicious activity.',
);
const _newPayee = Reason(
  code: 'NEW_PAYEE_HIGH_AMOUNT',
  weight: 0.4,
  textBn: 'নতুন প্রাপককে বড় অঙ্ক।',
  textEn: 'A large amount to a new recipient.',
);

/// Pumps History with a held (or [status]) row whose intervention stored
/// two reasons, and opens its detail sheet.
Future<ProviderContainer> _openHeld(
  WidgetTester tester, {
  Locale locale = const Locale('bn'),
  String status = LedgerStatus.held,
  bool linkById = true,
}) async {
  final now = DateTime.utc(2026, 10, 17, 6);
  final c = await pumpApp(
    tester,
    harness: ScreenHarness(),
    location: Routes.history,
    extraOverrides: [
      clockProvider.overrideWithValue(FakeClock(now)),
      initialLocaleProvider.overrideWithValue(locale),
    ],
  );
  await tester.runAsync(() async {
    await c
        .read(interventionRepoProvider)
        .upsert(
          InterventionRecord(
            id: 'iv_held_1',
            uid: 'rina',
            txnId: 'held_1',
            trigger: 'mule_payee',
            scriptBn: 'স্ক্রিপ্ট',
            reasons: const [_mule, _newPayee],
            actions: const [],
            status: InterventionStatus.open,
            createdAt: now,
          ),
        );
    await c
        .read(ledgerRepoProvider)
        .create(
          'rina',
          LedgerTxn(
            txnId: 'held_1',
            ts: now,
            type: 'send_money',
            amountBdt: 7900,
            fromAcct: 'acct_rina',
            toAcct: 'acct_01070',
            status: status,
            counterpartyNameBn: 'নতুন নম্বর',
            interventionId: linkById ? 'iv_held_1' : null,
          ),
        );
  });
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('history_row_held_1')));
  await tester.pumpAndSettle();
  expect(find.byType(TxnDetailSheet), findsOneWidget);
  return c;
}

void main() {
  setUpAll(loadBanglaFont);

  testWidgets('a held row lists every stored reason in Bangla, no codes', (
    tester,
  ) async {
    await _openHeld(tester);
    final list = find.byKey(const Key('txn_detail_reasons'));
    expect(list, findsOneWidget);
    expect(
      find.descendant(of: list, matching: find.text(_mule.textBn)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: list, matching: find.text(_newPayee.textBn)),
      findsOneWidget,
    );
    expect(find.text(_mule.textEn), findsNothing);
    expect(find.textContaining('DEST_MULE_RISK'), findsNothing);
    expect(find.textContaining('NEW_PAYEE'), findsNothing);
    // The review lines follow the reasons.
    final review = find.byKey(const Key('review_lines'));
    expect(review, findsOneWidget);
    expect(find.text('টাকা পাঠানো হয়নি, আপনার কাছেই আছে।'), findsOneWidget);
    expect(
      tester.getTopLeft(review).dy,
      greaterThan(tester.getTopLeft(list).dy),
    );
    // Under the existing lines.
    expect(
      tester.getTopLeft(list).dy,
      greaterThan(tester.getTopLeft(find.text('রেফারেন্স')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('English: the text_en of each reason', (tester) async {
    await _openHeld(tester, locale: const Locale('en'));
    expect(find.text(_mule.textEn), findsOneWidget);
    expect(find.text(_newPayee.textEn), findsOneWidget);
    expect(find.text(_mule.textBn), findsNothing);
  });

  testWidgets('found by txn_id when the row has no intervention id', (
    tester,
  ) async {
    await _openHeld(tester, linkById: false);
    expect(find.text(_mule.textBn), findsOneWidget);
  });

  testWidgets('a row that is not held shows no reasons', (tester) async {
    await _openHeld(tester, status: LedgerStatus.released);
    expect(find.byKey(const Key('txn_detail_reasons')), findsNothing);
    expect(find.byKey(const Key('review_lines')), findsNothing);
    expect(find.text(_mule.textBn), findsNothing);
  });

  for (final locale in const [Locale('bn'), Locale('en')]) {
    testWidgets('360 dp, ${locale.languageCode}: the reasons fit', (
      tester,
    ) async {
      await _openHeld(tester, locale: locale);
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('txn_detail_reasons')), findsOneWidget);
    });
  }

  testWidgets('held detail: amount in onSurface, '
      'status as an amber tag, reasons above the review line with its info '
      'icon and 16 dp space; the row behind carries no "+"', (tester) async {
    await _openHeld(tester);
    final sheet = find.byType(TxnDetailSheet);
    final context = tester.element(sheet);
    final p = context.palette;
    final amount = find.descendant(
      of: find.byKey(const Key('txn_detail_amount')),
      matching: find.byType(Text),
    );
    for (final t in tester.widgetList<Text>(amount)) {
      if ((t.data ?? '').contains(RegExp('[০-৯]'))) {
        expect(t.style?.color, isNot(p.success));
      }
    }
    final tag = tester.widget<StatusTag>(
      find.byKey(const Key('txn_detail_status_tag')),
    );
    expect(tag.status, BhStatus.warning);
    expect(tag.label, 'আটকে আছে');
    final reasons = tester.getRect(find.byKey(const Key('txn_detail_reasons')));
    final review = tester.getRect(find.byKey(const Key('txn_detail_review')));
    expect(review.top, greaterThanOrEqualTo(reasons.bottom));
    final icon = tester.widget<Icon>(
      find.byKey(const Key('txn_detail_review_icon')),
    );
    expect(icon.icon, Icons.info_outline);
    expect(icon.size, 16);
    final pad = tester.widget<Padding>(
      find.byKey(const Key('txn_detail_review')),
    );
    expect(pad.padding, const EdgeInsets.only(top: 16));

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('history_row_held_1'));
    expect(find.descendant(of: row, matching: find.text('+ ')), findsNothing);
    expect(find.descendant(of: row, matching: find.text('− ')), findsOneWidget);
  });
}
