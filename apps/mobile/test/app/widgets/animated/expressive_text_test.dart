import 'package:bhorosha/app/widgets/animated/expressive_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../theme_harness.dart';

void main() {
  testWidgets('DisplayAmountStyle: heavy and tight per locale', (tester) async {
    late TextStyle bn, en;
    await tester.pumpWidget(
      themedApp(
        Builder(
          builder: (c) {
            bn = DisplayAmountStyle(c);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      themedApp(
        Builder(
          builder: (c) {
            en = DisplayAmountStyle(c, size: 48);
            return const SizedBox();
          },
        ),
        locale: const Locale('en'),
      ),
    );
    // The display face for both scripts; the script's text face falls back.
    expect(bn.fontFamily, DisplayAmountStyle.family);
    expect(bn.fontFamilyFallback, contains('SolaimanLipi'));
    expect(en.fontFamily, DisplayAmountStyle.family);
    expect(bn.fontWeight, FontWeight.w800);
    expect(bn.fontVariations, contains(const FontVariation.weight(800)));
    expect(bn.height, 0.95);
    expect(bn.letterSpacing, 0);
    expect(en.fontWeight, FontWeight.w800);
    expect(en.height, 0.9);
    expect(en.fontSize, 48);
    expect(en.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  testWidgets('TabularBangla: equal digit counts, equal widths', (
    tester,
  ) async {
    const style = TextStyle(fontSize: 44);
    await tester.pumpWidget(
      themedApp(
        const Column(
          children: [
            TabularBangla('১১,১১১', style: style, key: Key('a')),
            TabularBangla('৪৪,৪৪৪', style: style, key: Key('b')),
          ],
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('a'))).width,
      tester.getSize(find.byKey(const Key('b'))).width,
    );
    expect(find.bySemanticsLabel('১১,১১১'), findsOneWidget);
  });

  testWidgets('no overflow at 360/412, both themes and locales', (
    tester,
  ) async {
    await pumpEverywhere(
      tester,
      () => Builder(
        // Callers fit big amounts to the width (the test font is wide).
        builder: (c) => FittedBox(
          fit: BoxFit.scaleDown,
          child: TabularBangla('৳ ১,২৩,৪৫৬', style: DisplayAmountStyle(c)),
        ),
      ),
    );
  });
}
