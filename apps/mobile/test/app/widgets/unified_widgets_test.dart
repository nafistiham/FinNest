/// WP-D: the shared widgets that replaced the packages' private copies, and
/// the animated components wired into them.
library;

import 'package:bhorosha/app/motion/motion_specs.dart';
import 'package:bhorosha/app/widgets/animated/numpad_key_feedback.dart';
import 'package:bhorosha/app/widgets/animated/pressable.dart';
import 'package:bhorosha/app/widgets/bangla_numpad.dart';
import 'package:bhorosha/app/widgets/brand_glyph.dart';
import 'package:bhorosha/app/widgets/choice_tile.dart';
import 'package:bhorosha/app/widgets/number_display.dart';
import 'package:bhorosha/app/widgets/recipient_row.dart';
import 'package:bhorosha/app/widgets/txn_row.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/pay_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../theme_harness.dart';

LedgerTxn _bill() => LedgerTxn(
  txnId: 'txn_bill',
  ts: DateTime.utc(2026, 10, 17, 6),
  type: 'payment',
  amountBdt: 1200,
  fromAcct: 'acct_rina',
  toAcct: 'biller_desco_1234',
);

LedgerTxn _toMother() => LedgerTxn(
  txnId: 'txn_ma',
  ts: DateTime.utc(2026, 10, 17, 6),
  type: 'send_money',
  amountBdt: 5000,
  fromAcct: 'acct_rina',
  toAcct: 'acct_rahima',
  counterpartyNameBn: 'মা',
);

void main() {
  group('TxnRow', () {
    testWidgets('a payment row reads "বিল / পেমেন্ট"', (tester) async {
      await tester.pumpWidget(
        themedApp(TxnRow(txn: _bill(), acctId: 'acct_rina')),
      );
      expect(find.text('বিল / পেমেন্ট'), findsOneWidget);
      await tester.pumpWidget(
        themedApp(
          TxnRow(txn: _bill(), acctId: 'acct_rina'),
          locale: const Locale('en'),
        ),
      );
      expect(find.text('Bill / payment'), findsOneWidget);
    });

    testWidgets('English mode shows the saved payee\'s English name', (
      tester,
    ) async {
      await tester.pumpWidget(
        themedApp(
          TxnRow(txn: _toMother(), acctId: 'acct_rina', nameEn: 'Mother'),
          locale: const Locale('en'),
        ),
      );
      expect(find.text('Mother'), findsOneWidget);
      expect(find.text('মা'), findsNothing);
      // Bangla keeps the Bangla name.
      await tester.pumpWidget(
        themedApp(
          TxnRow(txn: _toMother(), acctId: 'acct_rina', nameEn: 'Mother'),
        ),
      );
      expect(find.text('Mother'), findsNothing);
    });

    testWidgets('a tappable row is one Pressable button', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        themedApp(
          TxnRow(txn: _bill(), acctId: 'acct_rina', onTap: () => taps++),
        ),
      );
      expect(find.byType(Pressable), findsOneWidget);
      await tester.tap(find.byType(TxnRow));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  testWidgets('RecipientRow: selected state is announced; a district '
      'subtitle is not grouped like a phone number', (tester) async {
    await tester.pumpWidget(
      themedApp(
        RecipientRow(
          key: const Key('row'),
          counterparty: const Counterparty(
            acctId: 'rina',
            nameBn: 'রিনা',
            subtitle: 'গাজীপুর',
          ),
          selected: true,
          trailingChevron: false,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('গাজীপুর'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(
      tester.getSemantics(find.byKey(const Key('row'))),
      isSemantics(isSelected: true, isButton: true),
    );
  });

  testWidgets('ConfirmSummary formats amountBdt and adds words from ১,০০০', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(
        const ConfirmSummary(kindLine: 'মা-কে পাঠাচ্ছেন', amountBdt: 5000),
      ),
    );
    expect(find.text('৳ ৫,০০০'), findsOneWidget);
    expect(find.byKey(const Key('confirm_words')), findsOneWidget);
  });

  testWidgets('ChoiceTile and QuickAmountRow: selection semantics, 56 dp '
      'quick chips, taps', (tester) async {
    int? picked;
    await tester.pumpWidget(
      themedApp(
        Column(
          children: [
            ChoiceTile(label: 'জিপি', selected: true, onTap: () {}),
            QuickAmountRow(
              amounts: const [500, 1000, 2000, 5000],
              selected: 1000,
              onPick: (a) => picked = a,
            ),
          ],
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('quick_1000'))),
      isSemantics(isSelected: true, isButton: true),
    );
    expect(tester.getSize(find.byKey(const Key('quick_500'))).height, 56);
    await tester.tap(find.byKey(const Key('quick_5000')));
    expect(picked, 5000);
  });

  testWidgets('NumberDisplay.grouped shows the caret and the counter', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(
        const NumberDisplay.grouped(grouped: '01712-3', count: 6, length: 11),
      ),
    );
    expect(find.text('০১৭১২-৩'), findsOneWidget);
    expect(find.byKey(const Key('number_counter')), findsOneWidget);
  });

  testWidgets('BrandGlyph: the ring breathes a few times, then rests; '
      'reduce motion keeps it still', (tester) async {
    await tester.pumpWidget(themedApp(const BrandGlyph(size: 48, ring: true)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('BrandGlyph: reduce motion keeps the ring still', (tester) async {
    await tester.pumpWidget(
      themedApp(
        const BrandGlyph(size: 48, ring: true),
        disableAnimations: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final box = tester.widget<Container>(
      find.descendant(
        of: find.byType(BrandGlyph),
        matching: find.byType(Container),
      ),
    );
    final border = (box.decoration! as BoxDecoration).border! as Border;
    expect(border.top.color.a, 1.0);
  });

  testWidgets('Numpad keys carry KeyFeedback (fill + 0.96 scale on press)', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(Numpad(onDigit: (_) {}, onBackspace: () {})),
    );
    expect(find.byType(KeyFeedback), findsWidgets);
    final key = find.ancestor(
      of: find.text('৭'),
      matching: find.byType(KeyFeedback),
    );
    final g = await tester.startGesture(tester.getCenter(find.text('৭')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final scales = tester
        .widgetList<Transform>(
          find.descendant(of: key, matching: find.byType(Transform)),
        )
        .map((t) => t.transform.entry(0, 0))
        .toList();
    expect(scales.first, closeTo(0.96, 0.001));
    await g.up();
    await tester.pumpAndSettle();
  });

  test('one motion token source', () {
    expect(identical(Motion.standard, BhMotion.standard), isTrue);
    expect(MotionCurves.enter, BhCurves.enter);
  });
}
