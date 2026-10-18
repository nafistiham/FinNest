import 'package:bhorosha/app/theme/palette.dart';
import 'package:bhorosha/app/widgets/animated/numpad_key_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';
import 'animated_harness.dart';

Color _fill(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(KeyFeedback),
            matching: find.byType(ColoredBox),
          )
          .first,
    )
    .color;

void main() {
  final root = find.byType(KeyFeedback);
  final p = BhPalette.tealLight;
  final pressed = Color.alphaBlend(
    p.primaryContainer.withValues(alpha: 0.6),
    p.surfaceVariant,
  );

  Widget key(VoidCallback onTap) => Center(
    child: SizedBox.square(
      dimension: 72,
      child: KeyFeedback(
        child: GestureDetector(
          onTap: onTap,
          child: const Center(child: Text('৫')),
        ),
      ),
    ),
  );

  testWidgets('tints and scales while held; the key still gets its tap', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(themedApp(key(() => taps++)));
    await tester.pump(); // the first frame of the test app is not hittable
    expect(_fill(tester), p.surfaceVariant);
    final g = await tester.startGesture(tester.getCenter(root));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_fill(tester), pressed);
    expect(scaleUnder(tester, root), closeTo(0.96, 0.001));
    await g.up();
    await tester.pumpAndSettle();
    expect(_fill(tester), p.surfaceVariant);
    expect(scaleUnder(tester, root), 1);
    expect(taps, 1);
  });

  testWidgets('reduce motion: fill only, instantly', (tester) async {
    await tester.pumpWidget(themedApp(key(() {}), disableAnimations: true));
    await tester.pump();
    final g = await tester.startGesture(tester.getCenter(root));
    await tester.pump();
    expect(_fill(tester), pressed);
    expect(scaleUnder(tester, root), 1);
    await g.up();
    await tester.pump();
    expect(_fill(tester), p.surfaceVariant);
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(tester, () => key(() {}));
  });
}
