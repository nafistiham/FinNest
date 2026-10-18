import 'package:bhorosha/app/theme/palette.dart';
import 'package:bhorosha/app/widgets/animated/status_pulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';

Color _dotColor(WidgetTester tester) {
  final boxes = tester
      .widgetList<Container>(
        find.descendant(
          of: find.byType(StatusPulse),
          matching: find.byType(Container),
        ),
      )
      .toList();
  return (boxes.last.decoration! as BoxDecoration).color!;
}

void main() {
  testWidgets('breathes while active, stops solid when settled', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(const StatusPulse(status: BhStatus.info, active: true)),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.hasRunningAnimations, isTrue);
    expect(_dotColor(tester).a, lessThan(0.5));
    await tester.pumpWidget(
      themedApp(const StatusPulse(status: BhStatus.success)),
    );
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(_dotColor(tester).a, closeTo(1, 0.001));
  });

  testWidgets('brightness-aware severity colour', (tester) async {
    for (final b in Brightness.values) {
      await tester.pumpWidget(
        themedApp(const StatusPulse(status: BhStatus.danger), brightness: b),
      );
      await tester.pumpAndSettle();
      final expected = BhPalette.of(BhPreset.teal, b).danger;
      expect(_dotColor(tester).toARGB32(), expected.toARGB32());
    }
  });

  testWidgets('reduce motion: a solid dot, no loop', (tester) async {
    await tester.pumpWidget(
      themedApp(
        const StatusPulse(status: BhStatus.warning, active: true),
        disableAnimations: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.hasRunningAnimations, isFalse);
    expect(_dotColor(tester).a, closeTo(1, 0.001));
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(
      tester,
      () => const Row(
        children: [
          StatusPulse(status: BhStatus.info, active: true),
          StatusPulse(status: BhStatus.danger),
        ],
      ),
    );
  });
}
