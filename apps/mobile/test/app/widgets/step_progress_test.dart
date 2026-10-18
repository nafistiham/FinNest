import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/step_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../theme_harness.dart';

Color _of(WidgetTester tester, Key key) =>
    tester.widget<ColoredBox>(find.byKey(key)).color;

void main() {
  for (final preset in BhPreset.values) {
    for (final b in Brightness.values) {
      testWidgets(
        'step 2 of 3: done, current and upcoming segments all read against '
        'the scaffold (${preset.id}, ${b.name})',
        (tester) async {
          useViewport(tester);
          await tester.pumpWidget(
            themedApp(
              const StepProgress(step: 2, total: 3),
              preset: preset,
              brightness: b,
            ),
          );
          await tester.pumpAndSettle();
          final p = BhPalette.of(preset, b);
          final scaffold = Theme.of(tester.element(find.byType(StepProgress)))
              .scaffoldBackgroundColor;
          final done = _of(tester, StepProgress.segmentKey(1));
          final current = _of(tester, StepProgress.segmentKey(2));
          final upcoming = _of(tester, StepProgress.segmentKey(3));
          expect(done, p.primary);
          expect(current, p.outline);
          expect(upcoming, p.outline);
          // A dark phone showed "filled, gap, grey": every track reads at
          // 3:1 on the surface.
          for (final c in [done, current, upcoming]) {
            expect(contrast(c, p.surface), greaterThanOrEqualTo(3));
            expect(contrast(c, scaffold), greaterThanOrEqualTo(3));
          }
          // Once settled the current segment is filled `primary`.
          expect(_of(tester, StepProgress.fillKey), p.primary);
          expect(
            tester.getSize(find.byKey(StepProgress.fillKey)).width,
            moreOrLessEquals(
              tester.getSize(find.byKey(StepProgress.segmentKey(2))).width,
              epsilon: 0.5,
            ),
          );
        },
      );
    }
  }

  testWidgets('semantics "ধাপ ২, মোট ৩"; 4 dp tall', (tester) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(const StepProgress(step: 2, total: 3)));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('ধাপ ২, মোট ৩'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('step_progress'))).height, 4);
  });
}
