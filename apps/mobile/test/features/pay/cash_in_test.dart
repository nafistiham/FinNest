import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/ui/cash_in_code_screen.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart'
    show clockProvider;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pay_test_support.dart';

void main() {
  testWidgets('cash in: amount → code writes a requested row; the agent '
      'confirming credits the balance on screen', (tester) async {
    final h = ScreenHarness();
    final clock = FakeClock(DateTime.utc(2026, 10, 17, 6));
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.start(PayKind.cashIn),
      extraOverrides: [clockProvider.overrideWithValue(clock)],
    );
    expect(h.api.callsTo(RiskRoutes.health), isEmpty);
    expect(find.text('ক্যাশ ইন'), findsOneWidget);
    expect(find.text('কত টাকা জমা দেবেন'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick_1000')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();

    expect(find.byType(CashInCodeScreen), findsOneWidget);
    final code = tester.widget<Text>(find.byKey(const Key('cashin_code')));
    expect(code.data, matches(RegExp(r'^FN-[২-৯A-HJ-NP-Z]{4}$')));
    expect(find.text('ডেমো কোড — আসল QR নয়'), findsOneWidget);
    expect(find.byKey(const Key('cashin_grid')), findsOneWidget);
    expect(find.textContaining('সময় বাকি ১৫:০০'), findsOneWidget);

    var rows = await ledgerRows(tester, c);
    final row = rows.first;
    expect(row.type, 'cash_in');
    expect(row.status, LedgerStatus.requested);
    expect(row.amountBdt, 1000);
    expect(row.toAcct, 'acct_rina');
    expect(row.counterpartyNameBn, 'এজেন্ট ক্যাশ ইন');
    expect(await ledgerBalance(tester, c), 9841);
    expect(h.api.callsTo(RiskRoutes.score), isEmpty);

    clock.advance(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('সময় বাকি ১৪:৫৮'), findsOneWidget);

    // The demo panel's "এজেন্ট ক্যাশ ইন নিশ্চিত করলেন".
    await tester.runAsync(
      () => c.read(ledgerRepoProvider).confirmCashIn(row.txnId),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cashin_confirmed')), findsOneWidget);
    expect(await ledgerBalance(tester, c), 10841);
    rows = await ledgerRows(tester, c);
    expect(rows.first.status, LedgerStatus.done);
  });

  testWidgets('the code expires after 15 minutes of clock time: the row is '
      'cancelled', (tester) async {
    final h = ScreenHarness();
    final clock = FakeClock(DateTime.utc(2026, 10, 17, 6));
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.start(PayKind.cashIn),
      extraOverrides: [clockProvider.overrideWithValue(clock)],
    );
    await tester.tap(find.byKey(const Key('quick_500')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    // The countdown reads the clock, it does not count ticks: a phone that
    // was backgrounded for ten minutes shows the right time on the next tick.
    clock.advance(const Duration(minutes: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('সময় বাকি ০৫:০০'), findsOneWidget);
    clock.advance(const Duration(minutes: 5, seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cashin_expired')), findsOneWidget);
    final rows = await ledgerRows(tester, c);
    expect(rows.first.status, LedgerStatus.cancelled);
    expect(await ledgerBalance(tester, c), 9841);
  });

  testWidgets('a failed row write shows no code: an error state with a retry '
      'that mints a fresh code once the write succeeds', (tester) async {
    final h = ScreenHarness();
    final flaky = _FlakyLedger(LocalLedgerRepo(h.assets), failures: 1);
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.start(PayKind.cashIn),
      extraOverrides: [ledgerRepoProvider.overrideWithValue(flaky)],
    );
    await tester.tap(find.byKey(const Key('quick_500')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    // Never a code the agent cannot confirm.
    expect(find.byKey(const Key('cashin_code')), findsNothing);
    expect(find.byKey(const Key('cashin_countdown')), findsNothing);
    expect(find.byKey(const Key('cashin_write_failed')), findsOneWidget);
    expect(find.text('কোড তৈরি করা যায়নি। আবার চেষ্টা করুন।'), findsOneWidget);
    expect(flaky.attempts, 1);

    await tester.tap(find.text('আবার চেষ্টা করুন'));
    await tester.pumpAndSettle();
    expect(flaky.attempts, 2);
    expect(find.byKey(const Key('cashin_write_failed')), findsNothing);
    expect(find.byKey(const Key('cashin_code')), findsOneWidget);
    expect(find.byKey(const Key('cashin_countdown')), findsOneWidget);
    final rows = await ledgerRows(tester, c);
    expect(rows.first.status, LedgerStatus.requested);
  });

  testWidgets('opening the code without an amount goes back to the amount', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.code(PayKind.cashIn),
    );
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.start(PayKind.cashIn));
  });
}

/// A ledger whose first [failures] writes throw, then delegates.
class _FlakyLedger extends LedgerRepo {
  _FlakyLedger(this._inner, {required this.failures});

  final LedgerRepo _inner;
  int failures;
  int attempts = 0;

  @override
  Future<LedgerTxn> create(String uid, LedgerTxn t) {
    attempts++;
    if (failures > 0) {
      failures--;
      throw StateError('write failed');
    }
    return _inner.create(uid, t);
  }

  @override
  Stream<List<LedgerTxn>> watchRecent(String uid, {int limit = 8}) =>
      _inner.watchRecent(uid, limit: limit);

  @override
  Stream<double> watchBalance(String uid) => _inner.watchBalance(uid);

  @override
  Future<void> setStatus(String txnId, String status) =>
      _inner.setStatus(txnId, status);

  @override
  List<Payee> savedPayees(Persona p) => _inner.savedPayees(p);

  @override
  Future<void> confirmCashIn(String txnId) => _inner.confirmCashIn(txnId);

  @override
  Future<void> reset(String uid) => _inner.reset(uid);
}
