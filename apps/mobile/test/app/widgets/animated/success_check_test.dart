import 'package:bhorosha/app/widgets/animated/success_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';
import 'animated_harness.dart';

SuccessCheckPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(SuccessCheck),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as SuccessCheckPainter;

void main() {
  testWidgets('draws the circle, then the check; haptic + onDone at the end', (
    tester,
  ) async {
    final haptics = RecordingHaptics();
    var done = 0;
    await tester.pumpWidget(
      themedApp(SuccessCheck(haptics: haptics, onDone: () => done++)),
    );
    await tester.pump(const Duration(milliseconds: 120));
    final early = _painter(tester);
    expect(early.circle, greaterThan(0));
    expect(early.check, 0);
    expect(done, 0);
    expect(haptics.successes, 0);
    await tester.pumpAndSettle();
    expect(_painter(tester).circle, 1);
    expect(_painter(tester).check, 1);
    expect(done, 1);
    expect(haptics.successes, 1);
  });

  testWidgets('reduce motion: final frame, onDone still fires', (tester) async {
    final haptics = RecordingHaptics();
    var done = 0;
    await tester.pumpWidget(
      themedApp(
        SuccessCheck(haptics: haptics, onDone: () => done++),
        disableAnimations: true,
      ),
    );
    expect(_painter(tester).check, 1);
    expect(done, 1);
    expect(haptics.successes, 1);
  });

  testWidgets('AmountConfirm: check first, then the amount rolls in', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(
      themedApp(AmountConfirm(amount: 5000, haptics: RecordingHaptics())),
    );
    expect(find.byKey(AmountConfirm.amountKey), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(AmountConfirm.amountKey), findsOneWidget);
    expect(shownText(tester, find.byKey(AmountConfirm.amountKey)), '৳ ৫,০০০');
  });

  testWidgets('AmountConfirm: reduce motion shows the amount at once', (
    tester,
  ) async {
    await tester.pumpWidget(
      themedApp(
        AmountConfirm(amount: 5000, haptics: RecordingHaptics()),
        disableAnimations: true,
        locale: const Locale('en'),
      ),
    );
    await tester.pump();
    expect(shownText(tester, find.byKey(AmountConfirm.amountKey)), '৳ 5,000');
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(
      tester,
      () => AmountConfirm(amount: 120000, haptics: RecordingHaptics()),
    );
  });
}
