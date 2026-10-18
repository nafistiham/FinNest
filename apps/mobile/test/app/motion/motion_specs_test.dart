import 'package:bhorosha/app/motion/motion_specs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../theme_harness.dart';

List<Widget> _items() => [
  for (var i = 0; i < 7; i++)
    SizedBox(height: 40, child: Text('item $i', key: ValueKey(i))),
];

double _opacityOf(WidgetTester tester, int i) {
  final o = find.ancestor(
    of: find.byKey(ValueKey(i)),
    matching: find.byType(Opacity),
  );
  if (o.evaluate().isEmpty) return 1;
  return tester.widget<Opacity>(o.first).opacity;
}

void main() {
  testWidgets('Motion.of: brief values, zero under reduce motion', (
    tester,
  ) async {
    late Motion full, reduced;
    await tester.pumpWidget(
      themedApp(
        Builder(
          builder: (c) {
            full = Motion.of(c);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      themedApp(
        Builder(
          builder: (c) {
            reduced = Motion.of(c);
            return const SizedBox();
          },
        ),
        disableAnimations: true,
      ),
    );
    expect(full.reduced, isFalse);
    expect(full.enter, const Duration(milliseconds: 240));
    expect(full.exit, const Duration(milliseconds: 200));
    // One token source: the library names are the theme tokens.
    expect(identical(Motion.standard, BhMotion.standard), isTrue);
    expect(full.emphasis, const Duration(milliseconds: 400));
    expect(full.counter, const Duration(milliseconds: 600));
    expect(full.checkDraw, const Duration(milliseconds: 480));
    expect(full.stagger, const Duration(milliseconds: 40));
    expect(reduced.reduced, isTrue);
    expect(reduced.enter, Duration.zero);
    expect(reduced.counter, Duration.zero);
    expect(reduced.stagger, Duration.zero);
    // The emphasis curve overshoots a little, never by much.
    final peak = [
      for (var t = 0.0; t <= 1; t += 0.01) MotionCurves.emphasis.transform(t),
    ].reduce((a, b) => a > b ? a : b);
    expect(peak, greaterThan(1.0));
    expect(peak, lessThan(1.06));
  });

  testWidgets('StaggeredReveal reveals every child, leading first', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(StaggeredReveal(children: _items())));
    // The start is decided at the end of the first frame (afterRouteEntrance)
    // and the ticker counts from its first tick.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_opacityOf(tester, 0), greaterThan(_opacityOf(tester, 4)));
    await tester.pumpAndSettle();
    for (var i = 0; i < 7; i++) {
      expect(find.text('item $i'), findsOneWidget);
      expect(_opacityOf(tester, i), 1.0);
    }
    // One-shot: a rebuild does not replay.
    await tester.pumpWidget(themedApp(StaggeredReveal(children: _items())));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_opacityOf(tester, 0), 1.0);
  });

  testWidgets('StaggeredReveal waits for the pushed route to enter', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(
      themedApp(
        Builder(
          builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    Material(child: StaggeredReveal(children: _items())),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    // Mid-transition: nothing has started, so the cascade is not lost under
    // the push.
    await tester.pump(const Duration(milliseconds: 150));
    expect(_opacityOf(tester, 0), 0);
    // After the 450 ms transition the leading child is on its way.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_opacityOf(tester, 0), greaterThan(0));
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 6), 1.0);
  });

  testWidgets('StaggeredReveal: delay holds the start; spacers take no beat', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(
      themedApp(
        const StaggeredReveal(
          delay: Duration(milliseconds: 200),
          children: [
            SizedBox(height: 40, child: Text('a', key: ValueKey(0))),
            SizedBox(height: 8),
            SizedBox(height: 40, child: Text('b', key: ValueKey(1))),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_opacityOf(tester, 0), 0);
    expect(_opacityOf(tester, 1), 0);
    // 200 ms delay, then a at 0 ms and b one 40 ms beat later (not two).
    await tester.pump(const Duration(milliseconds: 160));
    final a = _opacityOf(tester, 0);
    final b = _opacityOf(tester, 1);
    expect(a, greaterThan(0));
    expect(b, greaterThan(0));
    expect(a, greaterThan(b));
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 1), 1.0);
  });

  testWidgets('StaggeredReveal: reduce motion renders at once', (tester) async {
    await tester.pumpWidget(
      themedApp(StaggeredReveal(children: _items()), disableAnimations: true),
    );
    for (var i = 0; i < 7; i++) {
      expect(_opacityOf(tester, i), 1.0);
    }
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('StaggeredReveal: no overflow at 360/412, both themes', (
    tester,
  ) async {
    await pumpEverywhere(tester, () => StaggeredReveal(children: _items()));
  });
}
