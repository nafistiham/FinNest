import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/history/logic/history_providers.dart';
import 'package:bhorosha/features/history/ui/history_screen.dart';
import 'package:bhorosha/features/home/logic/home_providers.dart';
import 'package:bhorosha/features/home/ui/widgets/pending_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/screen_harness.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17, 8);
  const money = 'টাকা পাঠানো হয়নি, আপনার কাছেই আছে।';

  Future<ProviderContainer> pumpHome(WidgetTester tester) => pumpApp(
    tester,
    harness: ScreenHarness(),
    location: Routes.home,
    extraOverrides: [homeClockProvider.overrideWithValue(() => now)],
  );

  Future<void> addHeld(
    ProviderContainer c,
    WidgetTester tester, {
    required String id,
    required String status,
  }) async {
    await tester.runAsync(() async {
      await c
          .read(ledgerRepoProvider)
          .create(
            'rina',
            LedgerTxn(
              txnId: 'txn_$id',
              ts: now,
              type: 'send_money',
              amountBdt: 7900,
              fromAcct: 'acct_rina',
              toAcct: 'acct_01070',
              status: status,
              counterpartyNameBn: 'নতুন নম্বর',
            ),
          );
      await c
          .read(interventionRepoProvider)
          .upsert(
            InterventionRecord(
              id: 'int_$id',
              uid: 'rina',
              txnId: 'txn_$id',
              trigger: 'mule_payee',
              scriptBn: '',
              reasons: const [],
              actions: const [ActionItem(type: 'trusted_contact_check')],
              status: InterventionStatus.pending,
              createdAt: now,
            ),
          );
    });
    await tester.pumpAndSettle();
  }

  Finder inCard(String id, String text) => find.descendant(
    of: find.byKey(Key('pending_int_$id')),
    matching: find.text(text),
  );

  testWidgets('held: the money line, then the review line once a case runs', (
    tester,
  ) async {
    final c = await pumpHome(tester);
    await addHeld(c, tester, id: 'h', status: LedgerStatus.held);
    expect(inCard('h', money), findsOneWidget);
    expect(find.text('যাচাই চলছে।'), findsNothing);

    await c
        .read(caseLinkRepoProvider)
        .upsert(
          'rina',
          CaseLink(
            caseId: 'CZ-1',
            acctId: 'acct_01070',
            openedAt: now.add(const Duration(minutes: 1)),
            lastStatus: CaseStatus.running,
          ),
        );
    await tester.pumpAndSettle();
    expect(inCard('h', 'যাচাই চলছে।'), findsOneWidget);

    await c
        .read(caseLinkRepoProvider)
        .upsert(
          'rina',
          CaseLink(
            caseId: 'CZ-1',
            acctId: 'acct_01070',
            openedAt: now.add(const Duration(minutes: 1)),
            lastStatus: CaseStatus.done,
            lastAction: 'freeze',
          ),
        );
    await tester.pumpAndSettle();
    expect(inCard('h', 'যাচাই চলছে।'), findsNothing);
    expect(inCard('h', 'যাচাই শেষ, টাকা আপনার কাছেই।'), findsOneWidget);
    // Never the payee status, the recommendation or a case id.
    expect(find.textContaining('সুপারিশ'), findsNothing);
    expect(find.textContaining('সন্দেহ'), findsNothing);
    expect(find.textContaining('CZ-'), findsNothing);
  });

  testWidgets('not held (released): the card shows no review lines', (
    tester,
  ) async {
    final c = await pumpHome(tester);
    await addHeld(c, tester, id: 'r', status: LedgerStatus.released);
    expect(find.byKey(const Key('pending_int_r')), findsOneWidget);
    expect(find.text(money), findsNothing);
    expect(find.byKey(const Key('review_lines')), findsNothing);
  });

  testWidgets('one held card: no trailing tag, title and review line run '
      'the full width', (tester) async {
    final c = await pumpHome(tester);
    await addHeld(c, tester, id: 'h', status: LedgerStatus.held);
    final card = find.byKey(const Key('pending_int_h'));
    expect(
      find.descendant(of: card, matching: find.byType(StatusTag)),
      findsNothing,
    );
    final cardRight = tester.getTopRight(card).dx;
    final title = tester.getRect(find.byKey(const Key('pending_title')));
    // The text column ends at the card's 16 dp end padding.
    final column = tester.getRect(
      find
          .ancestor(
            of: find.byKey(const Key('pending_title')),
            matching: find.byType(Column),
          )
          .first,
    );
    expect(column.right, closeTo(cardRight - 16, 1));
    expect(title.height, lessThan(60), reason: 'one or two lines, not five');
    expect(find.byKey(const Key('pending_summary')), findsNothing);
  });

  testWidgets('two held: one summary card "২টি লেনদেন আটকে আছে" with the '
      'newest amount line; "দেখুন ›" opens History filtered to held', (
    tester,
  ) async {
    final c = await pumpHome(tester);
    await addHeld(c, tester, id: 'a', status: LedgerStatus.held);
    await addHeld(c, tester, id: 'b', status: LedgerStatus.held);
    expect(find.byKey(const Key('pending_int_a')), findsNothing);
    expect(find.byKey(const Key('pending_int_b')), findsNothing);
    final card = find.byKey(const Key('pending_summary'));
    expect(card, findsOneWidget);
    expect(find.text('২টি লেনদেন আটকে আছে'), findsOneWidget);
    expect(find.text('৳ ৭,৯০০ · নতুন নম্বর'), findsOneWidget);
    expect(find.text('দেখুন ›'), findsOneWidget);
    expect(PendingSummaryCard.location, '${Routes.history}?filter=held');

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(
      tester.widget<HistoryScreen>(find.byType(HistoryScreen)).initialFilter,
      HistoryFilter.held,
    );
    // Only held rows: the seeded ok rows are filtered out.
    expect(find.byKey(const ValueKey('history_row_txn_a')), findsOneWidget);
    expect(find.text('গার্মেন্টস বেতন'), findsNothing);
  });
}
