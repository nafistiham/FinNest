import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/persona_avatar.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/app/widgets/txn_row.dart';
import 'package:bhorosha/data/repos/ledger_repo.dart';
import 'package:bhorosha/features/history/logic/history_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../theme_harness.dart';

final _now = DateTime.utc(2026, 10, 17, 6);

LedgerTxn _txn(
  String type, {
  String from = 'acct_rina',
  String to = 'acct_x',
  String? name,
}) => LedgerTxn(
  txnId: 't_$type',
  ts: _now,
  type: type,
  amountBdt: 500,
  fromAcct: from,
  toAcct: to,
  counterpartyNameBn: name,
);

void main() {
  testWidgets('a step-up release says so in the subtitle and carries no tag', (
    tester,
  ) async {
    useViewport(tester);
    final txn = LedgerTxn(
      txnId: 't_step_up',
      ts: _now,
      type: 'send_money',
      amountBdt: 1000,
      fromAcct: 'acct_rina',
      toAcct: 'acct_rahima',
      status: LedgerStatus.releasedByStepUp,
      counterpartyNameBn: 'মা',
    );
    await tester.pumpWidget(
      themedApp(TxnRow(txn: txn, acctId: 'acct_rina', now: _now)),
    );
    expect(find.textContaining('ফোনে যাচাই করে পাঠানো'), findsOneWidget);
    expect(find.byType(StatusTag), findsNothing);
  });

  testWidgets('every row type has an icon tile, never a letter avatar', (
    tester,
  ) async {
    useViewport(tester);
    final rows = [
      _txn('send_money', name: 'সালমা', to: 'acct_s'),
      _txn('cash_out', name: 'এজেন্ট ক্যাশ আউট', to: 'AG-0027'),
      _txn(
        'cash_in',
        name: 'এজেন্ট ক্যাশ ইন',
        from: 'AG-0030',
        to: 'acct_rina',
      ),
      _txn('recharge', name: 'অপারেটর ক · 01712-345678', to: 'mob_017'),
      _txn('payment', name: 'ডেসকো বিদ্যুৎ বিল', to: 'biller_desco_1'),
      _txn(
        'salary',
        name: 'গার্মেন্টস বেতন',
        from: 'acct_pay',
        to: 'acct_rina',
      ),
      _txn(TxnRow.dpsType, name: 'ডিপিএস জমা', to: 'acct_bhorosha_dps'),
      _txn('other', name: 'অন্য'),
    ];
    await tester.pumpWidget(
      themedApp(
        Column(
          children: [
            for (final t in rows)
              TxnRow(txn: t, acctId: 'acct_rina', now: _now, dense: true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PersonaAvatar), findsNothing);
    expect(find.text('S'), findsNothing);
    expect(find.text('সা'), findsNothing);
    expect(find.byKey(const Key('txn_row_icon')), findsNWidgets(rows.length));
    final icons = tester
        .widgetList<Icon>(
          find.descendant(
            of: find.byKey(const Key('txn_row_icon')),
            matching: find.byType(Icon),
          ),
        )
        .map((i) => i.icon)
        .toList();
    expect(icons, [
      Icons.send_outlined,
      Icons.south,
      Icons.north,
      Icons.phone_android,
      Icons.receipt_long,
      Icons.work_outline,
      Icons.savings_outlined,
      Icons.swap_horiz,
    ]);
    // The DPS row has its own type label, not "লেনদেন".
    expect(find.text('ডিপিএস জমা'), findsOneWidget);
    expect(find.textContaining('লেনদেন'), findsOneWidget); // the 'other' row
  });

  testWidgets('digits in a stored name follow the language', (tester) async {
    useViewport(tester);
    final t = _txn('send_money', name: '01712-345678', to: 'acct_01712345678');
    await tester.pumpWidget(themedApp(TxnRow(txn: t, acctId: 'acct_rina')));
    expect(find.text('০১৭১২-৩৪৫৬৭৮'), findsOneWidget);
    await tester.pumpWidget(
      themedApp(
        TxnRow(txn: t, acctId: 'acct_rina'),
        locale: const Locale('en'),
      ),
    );
    expect(find.text('01712-345678'), findsOneWidget);
  });

  group('englishNameFor', () {
    const names = {
      ...seedNamesEn,
      'অপারেটর ক': 'Operator A',
      'ডেসকো বিদ্যুৎ বিল': 'DESCO electricity bill',
      'acct_rafiq': 'Rafiq Islam',
      'রফিক ইসলাম': 'Rafiq Islam',
    };
    test('seed names, saved payees, billers and operators', () {
      expect(
        englishNameFor(
          _txn('salary', name: 'গার্মেন্টস বেতন'),
          'acct_rina',
          names,
        ),
        'Garment wages',
      );
      expect(
        englishNameFor(
          _txn('send_money', name: 'নতুন নম্বর'),
          'acct_rina',
          names,
        ),
        'New number',
      );
      expect(
        englishNameFor(
          _txn(TxnRow.dpsType, name: 'ডিপিএস জমা'),
          'acct_rina',
          names,
        ),
        'DPS deposit',
      );
      expect(
        englishNameFor(
          _txn('send_money', name: 'রফিক', to: 'acct_rafiq'),
          'acct_rina',
          names,
        ),
        'Rafiq Islam',
      );
      expect(
        englishNameFor(
          _txn('payment', name: 'ডেসকো বিদ্যুৎ বিল'),
          'acct_rina',
          names,
        ),
        'DESCO electricity bill',
      );
    });

    test('recharge rows translate the operator and keep the number', () {
      expect(
        englishNameFor(
          _txn('recharge', name: 'অপারেটর ক · 01712-345678'),
          'acct_rina',
          names,
        ),
        'Operator A · 01712-345678',
      );
      expect(
        englishNameFor(
          _txn('recharge', name: '01712-345678'),
          'acct_rina',
          names,
        ),
        isNull,
      );
    });
  });

  group('received rows and stopped sends (11)', () {
    LedgerTxn row({
      String from = 'acct_rina',
      String to = 'acct_rahima',
      String status = LedgerStatus.done,
      String? name = 'মা',
    }) => LedgerTxn(
      txnId: 't_$status',
      ts: _now,
      type: 'send_money',
      amountBdt: 1000,
      fromAcct: from,
      toAcct: to,
      status: status,
      counterpartyNameBn: name,
    );

    Future<void> pump(
      WidgetTester tester,
      LedgerTxn t,
      String acctId, {
      String? fromName,
    }) async {
      // The test font is wider than SolaimanLipi: a 412 dp phone keeps the
      // longest tag ("ঝুঁকিতে বাতিল") beside the subtitle.
      useViewport(tester, width: 412);
      await tester.pumpWidget(
        themedApp(
          TxnRow(txn: t, acctId: acctId, now: _now, fromName: fromName),
        ),
      );
      await tester.pumpAndSettle();
    }

    String subtitle(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('txn_row_subtitle'))).data!;

    testWidgets("Rina's send to Ma is unchanged: 'মা', 'টাকা পাঠানো · time', "
        'minus', (tester) async {
      await pump(tester, row(), 'acct_rina');
      expect(find.text('মা'), findsOneWidget);
      expect(subtitle(tester), startsWith('টাকা পাঠানো · '));
      expect(find.text('− '), findsOneWidget);
    });

    testWidgets('the same row seen by Rahima: titled by the sender, '
        '"টাকা এসেছে", never "মা" or "টাকা পাঠানো"', (tester) async {
      await pump(tester, row(), 'acct_rahima', fromName: 'রিনা');
      expect(find.text('রিনা'), findsOneWidget);
      expect(find.text('মা'), findsNothing);
      expect(subtitle(tester), startsWith('টাকা এসেছে · '));
      expect(find.textContaining('টাকা পাঠানো'), findsNothing);
      expect(find.text('+ '), findsOneWidget);
    });

    testWidgets('a received row with no name known: the masked number, or '
        '"টাকা এসেছে" as the title', (tester) async {
      await pump(
        tester,
        row(from: 'acct_01712345678', name: null),
        'acct_rahima',
      );
      expect(find.text('০১৭XX-XXX৬৭৮'), findsOneWidget);
      expect(subtitle(tester), startsWith('টাকা এসেছে · '));
      await pump(tester, row(name: null), 'acct_rahima');
      expect(find.text('টাকা এসেছে'), findsOneWidget);
      expect(find.textContaining('টাকা পাঠানো'), findsNothing);
    });

    testWidgets('a seeded credit keeps its stored sender name', (tester) async {
      await pump(
        tester,
        row(from: 'acct_rafiq', status: LedgerStatus.ok, name: 'রফিক ইসলাম'),
        'acct_rahima',
      );
      expect(find.text('রফিক ইসলাম'), findsOneWidget);
      expect(subtitle(tester), startsWith('টাকা এসেছে · '));
    });

    for (final status in [
      LedgerStatus.held,
      LedgerStatus.blocked,
      LedgerStatus.cancelled,
    ]) {
      testWidgets('a $status send never shows "+" or green', (tester) async {
        // Incoming: no sign at all.
        await pump(tester, row(status: status), 'acct_rahima');
        expect(find.text('+ '), findsNothing);
        final context = tester.element(find.byType(TxnRow));
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          expect(t.style?.color, isNot(context.palette.success));
        }
        // An account mismatch (the viewer is neither side) is not a credit.
        await pump(tester, row(status: status), 'acct_other');
        expect(find.text('+ '), findsNothing);
      });
    }
  });
}
