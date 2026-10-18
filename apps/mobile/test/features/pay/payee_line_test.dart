import 'dart:io';

import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/logic/payee_map.dart';
import 'package:bhorosha/features/pay/ui/amount_step.dart';
import 'package:bhorosha/features/pay/ui/widgets/payee_state_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pay_test_support.dart';

const _saved = Key('payee_state_saved');
const _unfamiliar = Key('payee_state_unfamiliar');

/// The send-money amount step with a saved payee (Ma) or the seed's recent
/// unsaved recipient (`acct_01070`).
Future<ProviderContainer> _openSend(
  WidgetTester tester, {
  required bool saved,
  Locale? locale,
}) async {
  final c = await pumpPay(
    tester,
    harness: ScreenHarness(),
    location: PayPaths.send,
    locale: locale,
    extraOverrides: [
      payeeMapProvider.overrideWith(
        (_) async => PayeeMap.parse(File(PayeeMap.path).readAsStringSync()),
      ),
    ],
  );
  final row = Key(saved ? 'payee_acct_rahima' : 'recent_acct_01070');
  await tester.ensureVisible(find.byKey(row));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(row));
  await tester.pumpAndSettle();
  expect(find.byType(AmountStep), findsOneWidget);
  return c;
}

void phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 72, bottom: 144);
  tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 144);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('saved payee: a muted "সেভ করা প্রাপক", no warning recorded', (
    tester,
  ) async {
    final c = await _openSend(tester, saved: true);
    expect(find.byKey(_saved), findsOneWidget);
    expect(find.byKey(_unfamiliar), findsNothing);
    expect(find.text('সেভ করা প্রাপক'), findsOneWidget);
    final text = tester.widget<Text>(find.byKey(_saved));
    final p = tester.element(find.byKey(_saved)).palette;
    expect(text.style?.color, p.mutedText);

    await tester.tap(find.byKey(const Key('quick_500')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    final i = c.read(payControllerProvider);
    expect(locationOf(c), PayPaths.sendPin);
    expect(i.warningShown, isNull);
    expect(i.warningChoice, isNull);
  });

  testWidgets('unfamiliar payee: the info line with a 16 dp info icon; '
      'Next records unfamiliar_payee / continued', (tester) async {
    final c = await _openSend(tester, saved: false);
    expect(find.byKey(_unfamiliar), findsOneWidget);
    expect(find.byKey(_saved), findsNothing);
    expect(
      find.text('নতুন বা অচেনা প্রাপক। পাঠানোর আগে একবার ভাবুন।'),
      findsOneWidget,
    );
    final p = tester.element(find.byKey(_unfamiliar)).palette;
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(_unfamiliar),
        matching: find.byIcon(Icons.info_outline),
      ),
    );
    expect(icon.size, PayeeStateLine.iconSize);
    expect(icon.size, 16);
    expect(icon.color, p.info);
    expect(icon.color, isNot(p.warning));
    final text = tester.widget<Text>(
      find.descendant(of: find.byKey(_unfamiliar), matching: find.byType(Text)),
    );
    expect(text.style?.color, p.info);
    expect(c.read(payControllerProvider).warningShown, isNull);

    await tester.tap(find.byKey(const Key('quick_7900')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    final i = c.read(payControllerProvider);
    expect(locationOf(c), PayPaths.sendPin);
    expect(i.counterparty?.acctId, 'acct_01070');
    expect(i.isNewPayee, isTrue);
    expect(i.warningShown, 'unfamiliar_payee');
    expect(i.warningChoice, 'continued');
  });

  testWidgets('English copy for both states', (tester) async {
    await _openSend(tester, saved: false, locale: const Locale('en'));
    expect(
      find.text('New or unfamiliar recipient. Think once before you send.'),
      findsOneWidget,
    );
  });

  testWidgets('English saved line', (tester) async {
    await _openSend(tester, saved: true, locale: const Locale('en'));
    expect(find.text('Saved recipient'), findsOneWidget);
  });

  testWidgets('cash out never shows the payee line', (tester) async {
    final c = await pumpPay(
      tester,
      harness: ScreenHarness(),
      location: PayPaths.start(PayKind.cashOut),
    );
    await tester.tap(find.byKey(const Key('agent_AG-0027')));
    await tester.pumpAndSettle();
    expect(find.byType(AmountStep), findsOneWidget);
    expect(find.byType(PayeeStateLine), findsNothing);
    await tester.tap(find.byKey(const Key('quick_500')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('amount_next')));
    await tester.pumpAndSettle();
    expect(c.read(payControllerProvider).warningShown, isNull);
  });

  for (final size in const [Size(360, 640), Size(412, 915)]) {
    for (final locale in const [Locale('bn'), Locale('en')]) {
      for (final saved in [true, false]) {
        testWidgets('fits at ${size.width.toInt()} dp, ${locale.languageCode}, '
            '${saved ? 'saved' : 'unfamiliar'}', (tester) async {
          await _openSend(tester, saved: saved, locale: locale);
          phone(tester, size);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('quick_7900')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final line = find.byKey(saved ? _saved : _unfamiliar);
          expect(line, findsOneWidget);
          final r = tester.getRect(line);
          final screen = Rect.fromLTWH(0, 0, size.width, size.height);
          expect(screen.contains(r.topLeft), isTrue, reason: '$r');
          expect(
            screen.contains(r.bottomRight - const Offset(1, 1)),
            isTrue,
            reason: '$r',
          );
          expect(
            find.byKey(const Key('amount_next')).hitTestable(),
            findsOneWidget,
          );
        });
      }
    }
  }
}
