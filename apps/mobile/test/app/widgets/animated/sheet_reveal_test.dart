import 'package:bhorosha/app/widgets/animated/sheet_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';

double _dy(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find.byType(SlideFadeIn),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .getTranslation()
    .y;

void main() {
  testWidgets('slides up and fades in; tappable while it slides', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      themedApp(
        SlideFadeIn(
          child: TextButton(onPressed: () => taps++, child: const Text('OK')),
        ),
      ),
    );
    expect(_dy(tester), closeTo(32, 0.01));
    // One frame in (the test app's very first frame is not hittable), the
    // content is still sliding and already takes taps.
    await tester.pump(const Duration(milliseconds: 16));
    expect(_dy(tester), greaterThan(8));
    await tester.tap(find.text('OK'));
    expect(taps, 1);
    await tester.pumpAndSettle();
    expect(_dy(tester), closeTo(0, 0.01));
  });

  testWidgets('firm (hold / block) never overshoots', (tester) async {
    await tester.pumpWidget(
      themedApp(const SlideFadeIn(firm: true, child: Text('Held'))),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(_dy(tester), greaterThanOrEqualTo(-0.001));
    }
    await tester.pumpAndSettle();
  });

  testWidgets('scrim fades in behind the content', (tester) async {
    await tester.pumpWidget(
      themedApp(
        const SizedBox(
          height: 600,
          child: SlideFadeIn(scrim: Color(0x99000000), child: Text('Overlay')),
        ),
      ),
    );
    Color scrim() => tester
        .widget<ColoredBox>(
          find
              .descendant(
                of: find.byType(SlideFadeIn),
                matching: find.byType(ColoredBox),
              )
              .first,
        )
        .color;
    expect(scrim().a, 0);
    await tester.pumpAndSettle();
    expect(scrim().a, closeTo(0x99 / 255, 0.01));
  });

  testWidgets('reduce motion: in place at once', (tester) async {
    await tester.pumpWidget(
      themedApp(
        const Column(
          children: [
            SheetHandleReveal(),
            SlideFadeIn(child: Text('Sheet')),
          ],
        ),
        disableAnimations: true,
      ),
    );
    expect(_dy(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);
    final handle = find.descendant(
      of: find.byType(SheetHandleReveal),
      matching: find.byType(ColoredBox),
    );
    expect(tester.getSize(handle).width, 32);
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(
      tester,
      () => const Column(
        children: [
          SheetHandleReveal(),
          SlideFadeIn(child: Text('Sheet')),
        ],
      ),
    );
  });
}
