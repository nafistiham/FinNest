import 'package:bhorosha/app/widgets/animated/rolling_amount.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';
import 'animated_harness.dart';

void main() {
  final root = find.byType(RollingAmount);

  testWidgets('bn: Bangla digits, lakh grouping, ends on the target', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(const RollingAmount(5000)));
    expect(shownText(tester, root), '৳ ৫,০০০');

    await tester.pumpWidget(themedApp(const RollingAmount(123456)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.hasRunningAnimations, isTrue);
    // Mid-roll the spoken value is already the final one, and only it.
    expect(find.bySemanticsLabel('১,২৩,৪৫৬ টাকা'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(shownText(tester, root), '৳ ১,২৩,৪৫৬');
  });

  testWidgets('en: Latin digits, rolls down to a smaller value', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(
      themedApp(const RollingAmount(9841), locale: const Locale('en')),
    );
    expect(shownText(tester, root), '৳ 9,841');
    await tester.pumpWidget(
      themedApp(const RollingAmount(3209), locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    expect(shownText(tester, root), '৳ 3,209');
    expect(find.bySemanticsLabel('3,209 taka'), findsOneWidget);
  });

  testWidgets('from: rolls up from 0 on first build', (tester) async {
    await tester.pumpWidget(themedApp(const RollingAmount(1450, from: 0)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(shownText(tester, root), '৳ ১,৪৫০');
  });

  testWidgets('from: shows the start value until the route has entered', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(
        Builder(
          builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const Material(child: RollingAmount(1450, from: 0)),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // Still at the start value (the three slots that are new at 1,450 sit
    // transparent until the roll begins).
    expect(shownText(tester, root), '৳ ০,০০০');
    await tester.pumpAndSettle();
    expect(shownText(tester, root), '৳ ১,৪৫০');
  });

  testWidgets('the width stays fixed while the digits roll', (tester) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(const RollingAmount(1111)));
    final before = tester.getSize(root).width;
    await tester.pumpWidget(themedApp(const RollingAmount(4444)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getSize(root).width, closeTo(before, 0.01));
    }
    await tester.pumpAndSettle();
  });

  testWidgets('reduce motion: the new value is there at once', (tester) async {
    await tester.pumpWidget(
      themedApp(const RollingAmount(5000), disableAnimations: true),
    );
    await tester.pumpWidget(
      themedApp(const RollingAmount(7000), disableAnimations: true),
    );
    expect(find.byKey(const ValueKey(7000)), findsOneWidget);
    expect(shownText(tester, find.byKey(const ValueKey(7000))), '৳ ৭,০০০');
    // No roll, no scale: only the opacity cross-fade runs.
    expect(
      find.descendant(of: root, matching: find.byType(Transform)),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(shownText(tester, root), '৳ ৭,০০০');
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(tester, () => const RollingAmount(12345678));
  });
}
