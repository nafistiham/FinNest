import 'dart:io';

import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_ledger.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/logic/payee_map.dart';
import 'package:bhorosha/features/pay/ui/amount_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../pay/pay_test_support.dart';

final _mapOverride = payeeMapProvider.overrideWith(
  (_) async => PayeeMap.parse(File(PayeeMap.path).readAsStringSync()),
);

Future<ProviderContainer> _open(
  WidgetTester tester, {
  Locale? locale,
  List<Override> extra = const [],
}) => pumpPay(
  tester,
  harness: ScreenHarness(),
  location: PayPaths.send,
  locale: locale,
  extraOverrides: [_mapOverride, ...extra],
);

LedgerTxn _send(String id, DateTime ts, String to) => LedgerTxn(
  txnId: id,
  ts: ts,
  type: 'send_money',
  amountBdt: 100,
  fromAcct: 'acct_rina',
  toAcct: to,
  status: LedgerStatus.done,
  counterpartyNameBn: 'নতুন নম্বর',
);

List<String> _recentKeys(WidgetTester tester) {
  final keys = <String>[];
  for (final e in find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith('recent_acct');
  }).evaluate()) {
    keys.add((e.widget.key! as ValueKey<String>).value);
  }
  return keys;
}

void main() {
  testWidgets('/pay/send?payee=acct_01070 lands on the amount step with that '
      'recent row selected (the demo story)', (tester) async {
    final c = await pumpPay(
      tester,
      harness: ScreenHarness(),
      location: '${PayPaths.send}?payee=acct_01070',
      extraOverrides: [_mapOverride],
    );
    await tester.pumpAndSettle();
    expect(find.byType(AmountStep), findsOneWidget);
    final intent = c.read(payControllerProvider);
    expect(intent.counterparty?.acctId, 'acct_01070');
    expect(intent.isNewPayee, isTrue);
  });

  testWidgets('Rina: the seed\'s unsaved 7,900 recipient sits under '
      '"সাম্প্রতিক" as "নতুন নম্বর" with a masked number and date', (
    tester,
  ) async {
    await _open(tester);
    final row = find.byKey(const Key('recent_acct_01070'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(find.text('সাম্প্রতিক'), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('নতুন নম্বর')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('০১৭XX-XXX০৭০ · '),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.dialpad)),
      findsOneWidget,
    );
    // Saved payees never repeat in the group.
    expect(find.byKey(const Key('recent_acct_rafiq')), findsNothing);
    expect(find.byKey(const Key('recent_acct_rahima')), findsNothing);
    // Between "সেভ করা" and the hint.
    final header = tester.getTopLeft(find.byKey(const Key('recent_header')));
    expect(
      header.dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const Key('payee_acct_rafiq'))).dy,
      ),
    );
    expect(
      header.dy,
      lessThan(tester.getTopLeft(find.textContaining('চেনা মানুষকে')).dy),
    );
  });

  testWidgets('tapping a recent row selects it as a new payee', (tester) async {
    final c = await _open(tester);
    final row = find.byKey(const Key('recent_acct_01070'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    final s = c.read(payControllerProvider);
    expect(s.counterparty?.acctId, 'acct_01070');
    expect(s.counterparty?.nameBn, 'নতুন নম্বর');
    expect(s.counterparty?.nameEn, 'New number');
    expect(s.counterparty?.subtitle, '017XXXXX070');
    expect(s.counterparty?.isSaved, isFalse);
    expect(s.isNewPayee, isTrue);
    expect(locationOf(c), PayPaths.sendAmount);
    expect(find.byType(AmountStep), findsOneWidget);
  });

  testWidgets('distinct, newest first, at most three', (tester) async {
    final c = await _open(tester);
    final now = DateTime.now().toUtc();
    final repo = c.read(ledgerRepoProvider);
    await tester.runAsync(() async {
      await repo.create(
        'rina',
        _send('a_old', now.subtract(const Duration(minutes: 9)), 'acct_A1'),
      );
      await repo.create(
        'rina',
        _send('b', now.subtract(const Duration(minutes: 5)), 'acct_B1'),
      );
      await repo.create(
        'rina',
        _send('a_new', now.subtract(const Duration(minutes: 3)), 'acct_A1'),
      );
      await repo.create(
        'rina',
        _send('saved', now.subtract(const Duration(minutes: 1)), 'acct_rafiq'),
      );
      await repo.create(
        'rina',
        _send('c', now.subtract(const Duration(minutes: 4)), 'acct_C1'),
      );
    });
    await tester.pumpAndSettle();
    expect(_recentKeys(tester), [
      'recent_acct_A1',
      'recent_acct_C1',
      'recent_acct_B1',
    ]);
    expect(find.byKey(const Key('recent_acct_01070')), findsNothing);
    // Ordered top to bottom as listed.
    final ys = [
      for (final k in _recentKeys(tester))
        tester.getTopLeft(find.byKey(Key(k))).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
  });

  testWidgets('hidden when there is no unsaved recipient', (tester) async {
    await _open(
      tester,
      extra: [
        payRecentRowsProvider.overrideWith(
          (ref) => Stream.value(const <LedgerTxn>[]),
        ),
      ],
    );
    expect(find.byKey(const Key('recent_header')), findsNothing);
    expect(find.text('সাম্প্রতিক'), findsNothing);
    expect(find.byKey(const Key('payee_acct_rahima')), findsOneWidget);
  });

  testWidgets('a typed demo number maps to its ring id', (tester) async {
    final c = await _open(tester);
    await tester.tap(find.byKey(const Key('send_new_number')));
    await tester.pumpAndSettle();
    await padDigits(tester, '01700001288');
    await tester.tap(find.byKey(const Key('number_confirm')));
    await tester.pumpAndSettle();
    final s = c.read(payControllerProvider);
    expect(s.counterparty?.acctId, 'acct_01288');
    expect(s.isNewPayee, isTrue);
  });

  testWidgets('English: "New number" and Latin digits', (tester) async {
    await _open(tester, locale: const Locale('en'));
    final row = find.byKey(const Key('recent_acct_01070'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(find.text('Recent'), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('New number')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('017XX-XXX070 · '),
      ),
      findsOneWidget,
    );
  });

  for (final locale in const [Locale('bn'), Locale('en')]) {
    testWidgets('360 dp, ${locale.languageCode}: no overflow with the '
        'recent group', (tester) async {
      await _open(tester, locale: locale);
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('recent_acct_01070'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(row).width, 360);
    });
  }
}
