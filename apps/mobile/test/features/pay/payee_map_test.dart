import 'dart:io';

import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/pay_intent.dart';
import 'package:bhorosha/features/pay/logic/payee_map.dart';
import 'package:flutter_test/flutter_test.dart';

LedgerTxn _send(
  String id,
  DateTime ts,
  String to, {
  String from = 'acct_rina',
  String type = 'send_money',
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

void main() {
  final map = PayeeMap.parse(File(PayeeMap.path).readAsStringSync());

  group('PayeeMap', () {
    test('the bundled demo numbers reach the ring ids', () {
      expect(map.acctForTyped('01700001070'), 'acct_01070');
      expect(map.acctForTyped('01700001288'), 'acct_01288');
      expect(map.acctForTyped('01700000036'), 'acct_00036');
    });

    test('an unmapped number keeps the acct_<digits> fallback', () {
      expect(map.acctForTyped('01712345678'), 'acct_01712345678');
      expect(PayeeMap.empty.acctForTyped('01700001070'), 'acct_01700001070');
      expect(PayeeMap.fallbackFor('01812345678'), 'acct_01812345678');
    });

    test('comment keys are not numbers', () {
      final raw = File(PayeeMap.path).readAsStringSync();
      expect(raw, contains('"_comment"'));
      expect(map.acctForTyped('_comment'), 'acct__comment');
    });

    test('masked numbers: mapped, typed, and other ids', () {
      expect(map.maskedFor('acct_01070'), '017XXXXX070');
      expect(map.maskedFor('acct_01712345678'), '017XXXXX678');
      expect(map.maskedFor('acct_01166'), '017XXXXX166');
      expect(map.numberFor('acct_00036'), '01700000036');
      expect(map.numberFor('acct_rahima'), isNull);
    });
  });

  group('recentUnsavedSends', () {
    const me = 'acct_rina';
    const saved = [
      Payee(acctId: 'acct_rahima', nameBn: 'মা'),
      Payee(acctId: 'acct_rafiq', nameBn: 'রফিক'),
    ];
    final t0 = DateTime.utc(2026, 10, 17, 6);
    DateTime ago(int h) => t0.subtract(Duration(hours: h));

    test('filters saved payees, keeps only my sends, distinct, newest '
        'first, max three', () {
      final rows = [
        _send('a_old', ago(9), 'acct_A'),
        _send('saved', ago(1), 'acct_rahima'),
        _send('b', ago(5), 'acct_B', status: LedgerStatus.held),
        _send('in', ago(2), me, from: 'acct_X'),
        _send('cash', ago(2), 'AG-0027', type: 'cash_out'),
        _send('a_new', ago(3), 'acct_A'),
        _send('c', ago(6), 'acct_C', status: LedgerStatus.cancelled),
        _send('d', ago(7), 'acct_D'),
      ];
      final out = recentUnsavedSends(rows, me, saved);
      expect(out.map((t) => t.txnId), ['a_new', 'b', 'c']);
    });

    test('empty when every send went to a saved payee', () {
      final rows = [
        _send('r', ago(1), 'acct_rafiq'),
        _send('m', ago(2), 'acct_rahima'),
      ];
      expect(recentUnsavedSends(rows, me, saved), isEmpty);
      expect(recentUnsavedSends(const [], me, saved), isEmpty);
    });
  });

  group('PayIntent warning fields', () {
    test('default null, set, kept by unrelated copies, cleared', () {
      const i = PayIntent(kind: PayKind.send, sessionId: 's');
      expect(i.warningShown, isNull);
      expect(i.warningChoice, isNull);
      final w = i.copyWith(
        warningShown: PayeeWarning.unfamiliarPayee,
        warningChoice: PayeeWarning.continued,
      );
      expect(w.warningShown, 'unfamiliar_payee');
      expect(w.warningChoice, 'continued');
      final kept = w.copyWith(amountBdt: 500);
      expect(kept.warningShown, 'unfamiliar_payee');
      expect(kept.warningChoice, 'continued');
      final cleared = kept.copyWith(warningShown: null, warningChoice: null);
      expect(cleared.warningShown, isNull);
      expect(cleared.warningChoice, isNull);
      expect(cleared.amountBdt, 500);
    });
  });
}
