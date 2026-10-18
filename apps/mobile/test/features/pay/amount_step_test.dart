import 'package:bhorosha/app/widgets/amount_display.dart';
import 'package:bhorosha/app/widgets/bangla_numpad.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pay/ui/amount_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pay_test_support.dart';

/// Opens the amount step of [kind] with a counterparty picked on step 1.
Future<ProviderContainer> openAmount(
  WidgetTester tester, {
  PayKind kind = PayKind.send,
  Locale? locale,
}) async {
  final h = ScreenHarness();
  final c = await pumpPay(
    tester,
    harness: h,
    location: PayPaths.start(kind),
    locale: locale,
  );
  final ctl = c.read(payControllerProvider.notifier);
  switch (kind) {
    case PayKind.send:
      await tester.tap(find.byKey(const Key('payee_acct_rahima')));
    case PayKind.cashOut:
      await tester.tap(find.byKey(const Key('agent_AG-0027')));
    case PayKind.recharge:
      await tester.tap(find.byKey(const Key('recharge_017XXXXX412')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recharge_next')));
    case PayKind.cashIn || PayKind.bill || PayKind.dps:
      break;
  }
  await tester.pumpAndSettle();
  expect(c.read(payControllerProvider).kind, kind);
  expect(find.byType(AmountStep), findsOneWidget);
  ctl.clearAmount();
  await tester.pump();
  return c;
}

const _next = Key('amount_next');
const _bnDigit = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

/// Sets a small phone: [size] dp at 3x, status bar and a 3-button nav bar.
void phone(
  WidgetTester tester,
  Size size, {
  double top = 24,
  double bottom = 48,
}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = FakeViewPadding(top: top * 3, bottom: bottom * 3);
  tester.view.viewPadding = FakeViewPadding(top: top * 3, bottom: bottom * 3);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('quick amount, typing, ০০, backspace, long-press clear', (
    tester,
  ) async {
    final c = await openAmount(tester);
    int amount() => c.read(payControllerProvider).amountBdt;

    await tester.tap(find.byKey(const Key('quick_5000')));
    await tester.pump();
    expect(amount(), 5000);
    // Tapping a chip replaces, never adds.
    await tester.tap(find.byKey(const Key('quick_7900')));
    await tester.pump();
    expect(amount(), 7900);

    await tester.tap(find.bySemanticsLabel('মুছুন'));
    await tester.pump();
    expect(amount(), 790);
    await tester.longPress(find.bySemanticsLabel('মুছুন'));
    await tester.pump();
    expect(amount(), 0);

    await padDigit(tester, 5);
    await tester.tap(find.bySemanticsLabel('দুই শূন্য'));
    await tester.pump();
    expect(amount(), 500);
    expect(
      tester.getSemantics(find.byType(AmountDisplay)).label,
      contains('৫০০'),
    );
  });

  testWidgets('over the maximum the key is refused', (tester) async {
    final c = await openAmount(tester);
    await padDigits(tester, '99999999');
    await padDigit(tester, 9);
    expect(c.read(payControllerProvider).amountBdt, 99999999);
    expect(tester.takeException(), isNull);
  });

  group('primary label doubles as the disabled reason; TalkBack reads it', () {
    Future<void> expectLabel(
      WidgetTester tester,
      String label, {
      required bool enabled,
    }) async {
      expect(buttonLabel(tester, _next), label);
      expect(buttonEnabled(tester, _next), enabled);
      expect(find.bySemanticsLabel(label), findsWidgets);
    }

    testWidgets('send', (tester) async {
      await openAmount(tester);
      await expectLabel(tester, 'পরিমাণ লিখুন', enabled: false);
      await padDigit(tester, 5);
      await expectLabel(tester, 'পরের ধাপ →', enabled: true);
    });

    testWidgets('cash out: at least ৳ ৫০, fee line under the amount', (
      tester,
    ) async {
      final c = await openAmount(tester, kind: PayKind.cashOut);
      await padDigits(tester, '40');
      await expectLabel(tester, 'কমপক্ষে ৳ ৫০', enabled: false);
      await tester.tap(find.byKey(const Key('quick_2000')));
      await tester.pump();
      await expectLabel(tester, 'পরের ধাপ →', enabled: true);
      expect(find.text('চার্জ ৳ ৩০ · মোট ৳ ২,০৩০'), findsOneWidget);
      expect(c.read(payControllerProvider).debitBdt, 2030);
    });

    testWidgets('recharge: ৳ ১০ to ৳ ১,০০০', (tester) async {
      await openAmount(tester, kind: PayKind.recharge);
      await padDigit(tester, 5);
      await expectLabel(tester, '৳ ১০ থেকে ৳ ১,০০০', enabled: false);
      await padDigit(tester, 0);
      await expectLabel(tester, 'পরের ধাপ →', enabled: true);
      await padDigits(tester, '00');
      await expectLabel(tester, '৳ ১০ থেকে ৳ ১,০০০', enabled: false);
    });

    testWidgets('cash in: "কোড তৈরি করুন"', (tester) async {
      await openAmount(tester, kind: PayKind.cashIn);
      await tester.tap(find.byKey(const Key('quick_1000')));
      await tester.pump();
      await expectLabel(tester, 'কোড তৈরি করুন', enabled: true);
    });
  });

  testWidgets('above the balance: a caution line, Next stays enabled', (
    tester,
  ) async {
    await openAmount(tester);
    expect(find.text('ব্যালেন্স ৳ ৯,৮৪১'), findsOneWidget);
    await padDigits(tester, '10000');
    expect(
      find.text('ব্যালেন্সের চেয়ে বেশি · ব্যালেন্স ৳ ৯,৮৪১'),
      findsOneWidget,
    );
    expect(buttonEnabled(tester, _next), isTrue);
  });

  testWidgets('back returns to step 1 with the recipient still selected; '
      '"বদলান" too', (tester) async {
    final c = await openAmount(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.send);
    expect(c.read(payControllerProvider).counterparty?.acctId, 'acct_rahima');

    await tester.tap(find.byKey(const Key('payee_acct_rahima')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.send);
    expect(c.read(payControllerProvider).counterparty?.acctId, 'acct_rahima');

    await tester.tap(find.byKey(const Key('payee_acct_rahima')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recipient_change')));
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.send);
  });

  testWidgets('Next opens the PIN pad', (tester) async {
    final c = await openAmount(tester);
    await tester.tap(find.byKey(const Key('quick_5000')));
    await tester.pump();
    await tester.tap(find.byKey(_next));
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.sendPin);
  });

  testWidgets('a deep link without a recipient goes back to step 1', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.sendAmount);
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.send);
  });

  // The fixed layout never scrolls and never overflows: recipient, amount,
  // four quick amounts, all 12 keys and Next on screen at once.
  for (final (name, size, top, bottom, compact) in [
    ('360x640, 3-button nav', const Size(360, 640), 24.0, 48.0, true),
    ('412x915, gesture nav', const Size(412, 915), 32.0, 24.0, false),
  ]) {
    for (final dark in [false, true]) {
      for (final locale in [const Locale('bn'), const Locale('en')]) {
        final label =
            '$name, ${dark ? 'dark' : 'light'}, ${locale.languageCode}';
        testWidgets('layout fits: $label', (tester) async {
          if (dark) {
            tester.platformDispatcher.platformBrightnessTestValue =
                Brightness.dark;
            addTearDown(
              tester.platformDispatcher.clearPlatformBrightnessTestValue,
            );
          }
          await openAmount(tester, locale: locale);
          phone(tester, size, top: top, bottom: bottom);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('quick_7900')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final screen = Rect.fromLTWH(0, 0, size.width, size.height);
          void onScreen(Finder f, {bool tappable = true}) {
            if (tappable) expect(f.hitTestable(), findsWidgets, reason: '$f');
            final r = tester.getRect(f.first);
            expect(screen.contains(r.topLeft), isTrue, reason: '$f $r');
            expect(
              screen.contains(r.bottomRight - const Offset(1, 1)),
              isTrue,
              reason: '$f $r',
            );
          }

          final pad = find.byType(Numpad);
          for (var d = 0; d <= 9; d++) {
            onScreen(
              find.descendant(
                of: pad,
                matching: find.text(
                  locale.languageCode == 'en' ? '$d' : _bnDigit[d],
                ),
              ),
            );
          }
          onScreen(
            find.bySemanticsLabel(
              locale.languageCode == 'en' ? 'Delete' : 'মুছুন',
            ),
          );
          for (final q in [500, 1000, 5000, 7900]) {
            onScreen(find.byKey(Key('quick_$q')));
          }
          onScreen(find.byKey(_next));
          onScreen(find.byKey(const Key('recipient_summary')), tappable: false);
          onScreen(find.byKey(const Key('recipient_change')));
          onScreen(find.byKey(AmountDisplay.amountKey), tappable: false);
          // The amount sits above the chips; nothing overlaps.
          expect(
            tester.getRect(find.byKey(AmountDisplay.amountKey)).bottom,
            lessThanOrEqualTo(
              tester.getRect(find.byKey(const Key('quick_amounts'))).top,
            ),
          );
          expect(
            tester.getRect(find.byKey(const Key('quick_amounts'))).bottom,
            lessThanOrEqualTo(tester.getRect(pad).top + 1),
          );
          expect(
            tester.getSize(find.byKey(const Key('recipient_summary'))).height,
            compact ? 28 : 72,
          );
          // Not a scroll view: the amount step has no Scrollable.
          expect(
            find.descendant(
              of: find.byType(AmountStep),
              matching: find.byType(Scrollable),
            ),
            findsNothing,
          );
        });
      }
    }
  }
}
