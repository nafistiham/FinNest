import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/amount_display.dart';
import 'package:bhorosha/app/widgets/bangla_numpad.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/app/widgets/bh_button.dart';
import 'package:bhorosha/app/widgets/demo_note.dart';
import 'package:bhorosha/app/widgets/empty_state.dart';
import 'package:bhorosha/app/widgets/feature_tile.dart';
import 'package:bhorosha/app/widgets/hero_balance.dart';
import 'package:bhorosha/app/widgets/number_display.dart';
import 'package:bhorosha/app/widgets/section_header.dart';
import 'package:bhorosha/app/widgets/settings_row.dart';
import 'package:bhorosha/app/widgets/sheet_header.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/app/widgets/step_progress.dart';
import 'package:bhorosha/app/widgets/txn_row.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/repos/ledger_repo.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/safety/safety_test_support.dart' show loadBanglaFont;
import 'theme_harness.dart';

// One fixed "now" for the rows and their date labels (no midnight flip).
final _now = DateTime.utc(2026, 10, 17, 6);

LedgerTxn _txn({
  String type = 'send_money',
  String from = 'acct_rina',
  String to = 'acct_rahima',
  String status = LedgerStatus.ok,
  String? name = 'মা',
  double amount = 5000,
}) => LedgerTxn(
  txnId: 't1',
  ts: _now,
  type: type,
  amountBdt: amount,
  fromAcct: from,
  toAcct: to,
  status: status,
  counterpartyNameBn: name,
);

void main() {
  // Real Bangla metrics: the test font draws every glyph (combining marks
  // included) one em wide, which makes a 13-character tag twice as wide as
  // it is on a phone.
  setUpAll(loadBanglaFont);

  group('render in both brightnesses, both locales, 360 and 412 dp', () {
    testWidgets('FeatureGrid of nine tiles', (tester) async {
      await pumpEverywhere(
        tester,
        () => FeatureGrid(
          children: [
            for (final (i, l) in [
              (Icons.send, 'টাকা পাঠান'),
              (Icons.south, 'ক্যাশ আউট'),
              (Icons.north, 'ক্যাশ ইন'),
              (Icons.phone_android, 'মোবাইল রিচার্জ'),
              (Icons.receipt_long, 'বিল দিন'),
              (Icons.account_balance, 'ঋণ'),
              (Icons.savings, 'সঞ্চয়'),
              (Icons.history, 'লেনদেন'),
              (Icons.policy, 'ফ্রড ডেস্ক'),
            ])
              FeatureTile(icon: i, label: l, onTap: () {}),
          ],
        ),
      );
      final tile = tester.getSize(find.byType(FeatureTile).first);
      expect(tile.height, closeTo(BhSize.tile, 0.01));
      // 412 dp: (412 - 32 - 16) / 3.
      expect(tile.width, closeTo((412 - 32 - 16) / 3, 0.5));
    });

    testWidgets('HeroBalance: data, loading and error', (tester) async {
      await pumpEverywhere(
        tester,
        () => const Column(
          children: [
            HeroBalance(balance: AsyncValue.data(9841)),
            HeroBalance(balance: AsyncValue.loading()),
            HeroBalance(balance: AsyncValue.error('x', StackTrace.empty)),
          ],
        ),
      );
    });

    testWidgets('TxnRow with every tag and a long name', (tester) async {
      await pumpEverywhere(
        tester,
        () => Column(
          children: [
            TxnRow(
              txn: _txn(status: LedgerStatus.held),
              acctId: 'acct_rina',
              now: _now,
            ),
            TxnRow(
              txn: _txn(
                name: 'খুব লম্বা একটি নাম যা এক লাইনে ধরবে না কখনো',
                status: LedgerStatus.blocked,
                amount: 1234567,
              ),
              acctId: 'acct_rina',
              now: _now,
            ),
            TxnRow(
              txn: _txn(
                type: 'cash_in',
                from: 'AG-0030',
                to: 'acct_rina',
                name: 'এজেন্ট ক্যাশ ইন',
                status: 'requested',
              ),
              acctId: 'acct_rina',
              now: _now,
            ),
            TxnRow(
              txn: _txn(type: 'salary', status: LedgerStatus.cancelled),
              acctId: 'acct_rina',
              dense: true,
              now: _now,
            ),
          ],
        ),
      );
    });

    testWidgets('AmountDisplay regular and compact', (tester) async {
      await pumpEverywhere(
        tester,
        () => const Column(
          children: [
            AmountDisplay(
              amount: 0,
              compact: false,
              caption: 'কত',
              caret: false,
            ),
            AmountDisplay(
              amount: 999999999,
              compact: false,
              caption: 'কত টাকা পাঠাবেন',
              status: Text('ব্যালেন্স ৳ ৯,৮৪১'),
              caret: false,
            ),
            AmountDisplay(amount: 5000, compact: true, caret: false),
          ],
        ),
      );
    });

    testWidgets('Numpad variants', (tester) async {
      await pumpEverywhere(
        tester,
        () => Column(
          children: [
            for (final v in NumpadVariant.values)
              Numpad(
                variant: v,
                onDigit: (_) {},
                onBackspace: () {},
                keyHeight: BhSize.keyCompact,
                gap: BhSpace.xs,
              ),
          ],
        ),
      );
    });

    testWidgets('SectionHeader, EmptyState, SheetHeader, DemoNote, '
        'StepProgress, NumberDisplay, StatusTag', (tester) async {
      await pumpEverywhere(
        tester,
        () => Column(
          children: [
            SectionHeader(
              title: 'সাম্প্রতিক লেনদেন',
              actionLabel: 'সব দেখুন',
              onAction: () {},
            ),
            const EmptyState(
              icon: Icons.receipt_long,
              title: 'এখনো কোনো লেনদেন নেই',
              body: 'টাকা পাঠালে এখানে দেখা যাবে।',
              actionLabel: 'টাকা পাঠান',
            ),
            const EmptyState(
              icon: Icons.person_outline,
              title: 'এখনো কাউকে সেভ করেননি',
              inline: true,
            ),
            const SheetHeader(
              title: 'আপা · নিরাপত্তা সহায়ক এবং আরও অনেক লম্বা শিরোনাম',
              icon: Icons.record_voice_over_outlined,
              bottom: Text('ইংরেজিতে'),
            ),
            const DemoNote(
              'এটি ডেমো লগইন। আপনি একজন নমুনা গ্রাহক হিসেবে ঢুকবেন।',
            ),
            const StepProgress(step: 2, total: 3),
            const NumberDisplay(digits: '01712345', maxDigits: 11),
            const NumberDisplay(
              digits: '01212345678',
              maxDigits: 11,
              invalid: true,
            ),
            for (final s in BhStatus.values)
              StatusTag(label: 'সিমুলেটেড', status: s),
          ],
        ),
      );
    });

    testWidgets('SettingsRow variants and BhSegmented', (tester) async {
      await pumpEverywhere(
        tester,
        () => Column(
          children: [
            SettingsRow.nav(
              icon: Icons.shield_outlined,
              title: 'ফোনের নিরাপত্তা',
              subtitle: 'শেষ যাচাই আজ',
              onTap: () {},
            ),
            SettingsRow.action(
              icon: Icons.logout,
              title: 'লগ আউট',
              destructive: true,
              onTap: () {},
            ),
            SettingsRow.control(
              title: 'আলো / অন্ধকার',
              child: BhSegmented<int>(
                haptics: const NoHaptics(),
                selected: 0,
                onChanged: (_) {},
                segments: const [
                  BhSegment(value: 0, label: 'আলো'),
                  BhSegment(value: 1, label: 'অন্ধকার'),
                  BhSegment(value: 2, label: 'ফোনের মতো'),
                ],
              ),
            ),
          ],
        ),
      );
    });

    testWidgets('BhBottomBar with the Apa square and the Apa bar', (
      tester,
    ) async {
      await pumpEverywhere(
        tester,
        overrides: [apaInsightsProvider.overrideWithValue(const [])],
        scaffold: false,
        () => Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BhBottomBar(
                apaScreen: 'test',
                primary: BhButton(label: 'পরের ধাপ →', onPressed: () {}),
              ),
              const BhBottomBar.apa(apaScreen: 'home'),
              const BhBottomBar.apa(
                apaScreen: 'history',
                style: ApaBarStyle.secondary,
              ),
            ],
          ),
        ),
      );
    });
  });

  group('behaviour', () {
    testWidgets('Numpad pin variant keeps key indices at today\'s positions', (
      tester,
    ) async {
      useViewport(tester);
      final downs = <int>[];
      await tester.pumpWidget(
        themedApp(
          Numpad(
            onDigit: (_) {},
            onBackspace: () {},
            onKeyDown: (i, _, _, _, _) => downs.add(i),
          ),
        ),
      );
      // Row-major reading order of today's pad: 1..9, then ⌫ 0 (inert).
      final centres = <int, Offset>{
        for (final d in List.generate(10, (i) => i))
          d: tester.getCenter(find.text(bnDigits('$d'))),
        Numpad.backspaceIndex: tester.getCenter(
          find.byIcon(Icons.backspace_outlined),
        ),
      };
      Offset c(int i) => centres[i]!;
      for (final row in [
        [1, 2, 3],
        [4, 5, 6],
        [7, 8, 9],
        [Numpad.backspaceIndex, 0],
      ]) {
        for (var i = 1; i < row.length; i++) {
          expect(c(row[i]).dy, closeTo(c(row[0]).dy, 0.1));
          expect(c(row[i]).dx, greaterThan(c(row[i - 1]).dx));
        }
      }
      expect(c(4).dy, greaterThan(c(1).dy));
      expect(c(Numpad.backspaceIndex).dx, closeTo(c(7).dx, 0.1));
      expect(c(0).dx, closeTo(c(8).dx, 0.1));
      // The bottom-right cell is an inert lock.
      expect(find.byKey(const Key('numpad_lock')), findsOneWidget);
      await tester.tap(find.byKey(const Key('numpad_lock')));
      await tester.tap(find.text('৫'));
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      expect(downs, [5, Numpad.backspaceIndex]);
    });

    testWidgets(
      'Numpad amount variant: ০০ appends two zeros, long press clears',
      (tester) async {
        useViewport(tester);
        final digits = <int>[];
        var cleared = 0;
        await tester.pumpWidget(
          themedApp(
            Numpad(
              variant: NumpadVariant.amount,
              onDigit: digits.add,
              onBackspace: () {},
              onClear: () => cleared++,
            ),
          ),
        );
        await tester.tap(find.text('০০'));
        await tester.longPress(find.byIcon(Icons.backspace_outlined));
        expect(digits, [0, 0]);
        expect(cleared, 1);
        expect(find.byKey(const Key('numpad_lock')), findsNothing);
      },
    );

    testWidgets('Numpad number variant has a paste key', (tester) async {
      useViewport(tester);
      var pasted = 0;
      await tester.pumpWidget(
        themedApp(
          Numpad(
            variant: NumpadVariant.number,
            onDigit: (_) {},
            onBackspace: () {},
            onPaste: () => pasted++,
          ),
        ),
      );
      await tester.tap(find.text('পেস্ট'));
      expect(pasted, 1);
    });

    testWidgets('AmountDisplay: typing ১ then ৪ does not move the ৳ sign', (
      tester,
    ) async {
      useViewport(tester);
      Future<Offset> signAt(int amount) async {
        await tester.pumpWidget(
          themedApp(
            Align(
              alignment: Alignment.centerLeft,
              child: AmountDisplay(
                amount: amount,
                compact: false,
                caret: false,
              ),
            ),
          ),
        );
        return tester.getTopLeft(find.byKey(AmountDisplay.signKey));
      }

      final one = await signAt(1);
      final fourteen = await signAt(14);
      // Left-aligned display: the sign stays put while digits are appended.
      expect(fourteen.dx, closeTo(one.dx, 0.01));
      // Equal-width slots: ১১ and ৪৪ are the same width.
      Future<double> widthOf(int amount) async {
        await signAt(amount);
        return tester.getSize(find.byKey(AmountDisplay.amountKey)).width;
      }

      expect(await widthOf(11), closeTo(await widthOf(44), 0.01));
      expect(
        tester.getSemantics(find.byType(AmountDisplay)).label,
        contains('৪৪ টাকা'),
      );
    });

    testWidgets('StatusTag in a card header sits on the 16 dp padding line', (
      tester,
    ) async {
      useViewport(tester);
      await tester.pumpWidget(
        themedApp(
          Container(
            key: const Key('card'),
            padding: const EdgeInsets.all(16),
            child: StatusTag.header(
              title: const Text('ফোনের নিরাপত্তা · ঝুঁকিপূর্ণ'),
              tag: const StatusTag(
                label: 'সিমুলেটেড',
                status: BhStatus.warning,
              ),
            ),
          ),
        ),
      );
      final card = tester.getRect(find.byKey(const Key('card')));
      final tag = tester.getRect(find.byType(StatusTag));
      expect(tag.right, closeTo(card.right - 16, 1));
      expect(tag.height, greaterThanOrEqualTo(StatusTag.minHeight));
    });

    testWidgets('TxnRow never repeats its title in the subtitle', (
      tester,
    ) async {
      useViewport(tester);
      await tester.pumpWidget(
        themedApp(
          Column(
            children: [
              TxnRow(
                key: const Key('agent'),
                txn: _txn(
                  type: 'cash_out',
                  to: 'AG-0027',
                  name: 'এজেন্ট ক্যাশ আউট',
                ),
                acctId: 'acct_rina',
              ),
              TxnRow(
                key: const Key('salary'),
                txn: _txn(
                  type: 'salary',
                  from: 'acct_payroll',
                  to: 'acct_rina',
                  name: 'গার্মেন্টস বেতন',
                ),
                acctId: 'acct_rina',
              ),
              TxnRow(
                key: const Key('held'),
                txn: _txn(status: LedgerStatus.held),
                acctId: 'acct_rina',
              ),
              TxnRow(
                key: const Key('done'),
                txn: _txn(status: LedgerStatus.done),
                acctId: 'acct_rina',
              ),
            ],
          ),
        ),
      );
      expect(find.text('এজেন্ট · ০১৭XX-XXX০২৭'), findsOneWidget);
      expect(find.textContaining('ক্যাশ আউট · আজ'), findsOneWidget);
      expect(find.text('গার্মেন্টস বেতন'), findsOneWidget);
      expect(find.textContaining('বেতন · '), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('held')),
          matching: find.text('আটকে আছে'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('done')),
          matching: find.byType(StatusTag),
        ),
        findsNothing,
      );
      expect(
        tester.getSemantics(find.byKey(const Key('held'))).label,
        contains('৫,০০০ টাকা পাঠানো হয়েছে'),
      );
    });

    testWidgets('HeroBalance hides and shows the digits', (tester) async {
      useViewport(tester);
      await tester.pumpWidget(
        themedApp(const HeroBalance(balance: AsyncValue.data(9841))),
      );
      await tester.pumpAndSettle();
      expect(find.text('লুকান'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(HeroBalance.amountKey)).label,
        'মোট ব্যালেন্স ৯,৮৪১ টাকা',
      );
      await tester.tap(find.byKey(HeroBalance.toggleKey));
      await tester.pumpAndSettle();
      expect(find.text('দেখুন'), findsOneWidget);
      expect(find.text('• • • • •'), findsOneWidget);
    });

    testWidgets('ApaBar shows the accent dot for a danger or caution insight', (
      tester,
    ) async {
      useViewport(tester);
      const urgent = ApaInsight(
        id: 'held_transfer',
        severity: ApaSeverity.danger,
        priority: 1,
        titleBn: 'টাকা আটকে আছে',
        titleEn: 'Money held',
        bodyBn: '',
        bodyEn: '',
      );
      const caution = ApaInsight(
        id: 'caution_verdict',
        severity: ApaSeverity.caution,
        priority: 3,
        titleBn: 'সতর্ক থাকুন',
        titleEn: 'Be careful',
        bodyBn: '',
        bodyEn: '',
      );
      const tip = ApaInsight(
        id: 'tip',
        severity: ApaSeverity.info,
        priority: 6,
        titleBn: 'টিপ',
        titleEn: 'Tip',
        bodyBn: '',
        bodyEn: '',
      );
      // No trailing status dot in any state (the owner removed it; the
      // security card above the bar carries the colour).
      for (final list in [
        const <ApaInsight>[],
        const [urgent],
        const [caution],
        const [tip],
      ]) {
        await tester.pumpWidget(
          themedApp(
            const ApaBar(screen: 'home'),
            overrides: [apaInsightsProvider.overrideWithValue(list)],
          ),
        );
        expect(find.byKey(const Key('apa_bar_dot')), findsNothing);
        expect(find.text('এফএনএ-কে জিজ্ঞাসা করুন'), findsOneWidget);
        expect(tester.getSize(find.byType(ApaBar)).height, BhSize.touch);
      }
    });

    testWidgets('BhSegmented reports the tapped value with a key haptic', (
      tester,
    ) async {
      useViewport(tester);
      var value = 0;
      final haptics = _CountingHaptics();
      await tester.pumpWidget(
        themedApp(
          StatefulBuilder(
            builder: (context, set) => BhSegmented<int>(
              haptics: haptics,
              selected: value,
              onChanged: (v) => set(() => value = v),
              segments: const [
                BhSegment(value: 0, label: 'সাধারণ'),
                BhSegment(value: 1, label: 'বড়'),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('বড়'));
      await tester.pump();
      expect(value, 1);
      expect(haptics.keys, 1);
      expect(
        tester.getSize(find.byType(BhSegmented<int>)).height,
        BhSize.touch,
      );
    });
  });
}

class _CountingHaptics extends NoHaptics {
  int keys = 0;
  @override
  Future<void> key() async => keys++;
}
