import 'package:bhorosha/app/widgets/animated/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';

Widget _loading() => const Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [Skeleton.amount(), SkeletonRow(), SkeletonRow()],
);

void main() {
  testWidgets('sweeps while loading', (tester) async {
    await tester.pumpWidget(themedApp(_loading()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isTrue);
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .first;
    expect(box.gradient, isA<LinearGradient>());
    expect(box.borderRadius, isNull); // square corners
  });

  testWidgets('reduce motion: static blocks', (tester) async {
    await tester.pumpWidget(themedApp(_loading(), disableAnimations: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byType(ColoredBox), findsWidgets);
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(tester, _loading);
  });
}
