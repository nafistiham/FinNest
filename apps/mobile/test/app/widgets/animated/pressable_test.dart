import 'package:bhorosha/app/widgets/animated/pressable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';
import 'animated_harness.dart';

Widget _tile(VoidCallback onTap, {FocusNode? focus}) => Pressable(
  onTap: onTap,
  focusNode: focus,
  semanticLabel: 'Send money',
  child: const SizedBox(height: 104, width: 104, child: Text('Send')),
);

void main() {
  final root = find.byType(Pressable);

  testWidgets('scales to 0.97 while held, back on release; taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(themedApp(_tile(() => taps++)));
    await tester.pump(); // the first frame of the test app is not hittable
    final g = await tester.startGesture(tester.getCenter(root));
    await tester.pump(const Duration(milliseconds: 150)); // tap-down delay
    await tester.pump(const Duration(milliseconds: 100)); // 80 ms press-in
    expect(scaleUnder(tester, root), closeTo(0.97, 0.001));
    await g.up();
    await tester.pumpAndSettle();
    expect(scaleUnder(tester, root), 1);
    expect(taps, 1);
  });

  testWidgets('keyboard Enter activates; it is a labelled button', (
    tester,
  ) async {
    var taps = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(themedApp(_tile(() => taps++, focus: focus)));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(
      tester.getSemantics(root),
      isSemantics(label: 'Send money', isButton: true, hasTapAction: true),
    );
  });

  testWidgets('reduce motion: no scale', (tester) async {
    await tester.pumpWidget(themedApp(_tile(() {}), disableAnimations: true));
    await tester.pump();
    final g = await tester.startGesture(tester.getCenter(root));
    await tester.pump(const Duration(milliseconds: 150)); // tap-down delay
    await tester.pump(const Duration(milliseconds: 100)); // 80 ms press-in
    expect(scaleUnder(tester, root), 1);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(tester, () => _tile(() {}));
  });
}
