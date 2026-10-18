import 'package:bhorosha/app/widgets/hero_balance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../theme_harness.dart';
import 'animated/animated_harness.dart';

void main() {
  testWidgets('the first amount counts up from 0, later ones roll in place', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(HeroBalance.value(9841)));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.hasRunningAnimations, isTrue);
    expect(
      shownText(tester, find.byKey(HeroBalance.amountKey)),
      isNot('৳ ৯,৮৪১'),
    );
    await tester.pumpAndSettle();
    expect(shownText(tester, find.byKey(HeroBalance.amountKey)), '৳ ৯,৮৪১');
    // Hiding and showing again does not replay the count-up.
    await tester.tap(find.byKey(HeroBalance.toggleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HeroBalance.toggleKey));
    await tester.pump(const Duration(milliseconds: 250));
    expect(shownText(tester, find.byKey(HeroBalance.amountKey)), '৳ ৯,৮৪১');
  });

  testWidgets('prepares, shows the amount, masks with the eye toggle', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(HeroBalance.value(9841)));
    // The preparation beat: transparent at first, sharp after 180 ms.
    final prep = find.ancestor(
      of: find.byKey(HeroBalance.amountKey),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(prep.first).opacity, lessThan(1));
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(prep.first).opacity, 1);
    expect(shownText(tester, find.byKey(HeroBalance.amountKey)), '৳ ৯,৮৪১');
    // Caption 24, gap 4, amount 48: no padding of its own.
    expect(tester.getSize(find.byType(HeroBalance)).height, HeroBalance.height);
    expect(HeroBalance.height, 84);
    expect(find.text('মোট ব্যালেন্স'), findsOneWidget);
    expect(find.bySemanticsLabel('মোট ব্যালেন্স ৯,৮৪১ টাকা'), findsOneWidget);

    await tester.tap(find.byKey(HeroBalance.toggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(HeroBalance.maskKey), findsOneWidget);
    expect(find.byKey(HeroBalance.amountKey), findsNothing);
    expect(find.bySemanticsLabel('ব্যালেন্স লুকানো'), findsOneWidget);
  });

  testWidgets('controlled revealed + onTap', (tester) async {
    bool? asked;
    var taps = 0;
    await tester.pumpWidget(
      themedApp(
        HeroBalance.value(
          5000,
          revealed: false,
          onRevealedChanged: (v) => asked = v,
          onTap: () => taps++,
          captionOverride: 'Savings',
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(HeroBalance.maskKey), findsOneWidget);
    await tester.tap(find.byKey(HeroBalance.toggleKey));
    expect(asked, isTrue);
    await tester.tap(find.byKey(HeroBalance.maskKey));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('a new balance rolls to the new value', (tester) async {
    await tester.pumpWidget(themedApp(HeroBalance.value(9841)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(themedApp(HeroBalance.value(14841)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(shownText(tester, find.byKey(HeroBalance.amountKey)), '৳ ১৪,৮৪১');
  });

  testWidgets('reduce motion: sharp and final on the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(HeroBalance.value(9841), disableAnimations: true),
    );
    final prep = find.ancestor(
      of: find.byKey(HeroBalance.amountKey),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(prep.first).opacity, 1);
    expect(tester.hasRunningAnimations, isFalse);
    expect(shownText(tester, find.byKey(HeroBalance.amountKey)), '৳ ৯,৮৪১');
    // Caption 24, gap 4, amount 48: no padding of its own.
    expect(tester.getSize(find.byType(HeroBalance)).height, HeroBalance.height);
    expect(HeroBalance.height, 84);
  });

  testWidgets('loading shows the skeleton, error the retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      themedApp(const HeroBalance(balance: AsyncValue.loading())),
    );
    expect(find.byKey(HeroBalance.skeletonKey), findsOneWidget);
    expect(find.byKey(HeroBalance.toggleKey), findsNothing);
    await tester.pumpWidget(
      themedApp(
        HeroBalance(
          balance: const AsyncValue.error('x', StackTrace.empty),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ব্যালেন্স দেখা যাচ্ছে না'), findsOneWidget);
    await tester.tap(find.text('আবার চেষ্টা করুন'));
    expect(retries, 1);
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(tester, () => HeroBalance.value(123456789));
  });
}
