import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/language_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme_harness.dart';

Container _segment(WidgetTester tester, String code) =>
    tester.widget<Container>(find.byKey(Key('language_segment_$code')));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final b in Brightness.values) {
    testWidgets('a 32 dp pill in a 48 dp tap area, selected filled, one '
        'hairline, no outer box (${b.name})', (tester) async {
      useViewport(tester);
      await tester.pumpWidget(
        themedApp(
          const Align(
            alignment: Alignment.topRight,
            child: LanguageToggle(compact: true),
          ),
          brightness: b,
        ),
      );
      await tester.pumpAndSettle();
      final p = BhPalette.of(BhPreset.teal, b);
      expect(
        tester.getSize(find.byType(LanguageToggle)).height,
        LanguageToggle.touchHeight,
      );
      final bn = tester.getRect(find.byKey(const Key('language_segment_bn')));
      final en = tester.getRect(find.byKey(const Key('language_segment_en')));
      expect(bn.height, LanguageToggle.height);
      expect(en.height, LanguageToggle.height);
      // The two halves touch: one divider, no gap and no outer frame (the
      // only decorated boxes are the two segments themselves).
      expect(en.left, moreOrLessEquals(bn.right, epsilon: 0.5));
      expect(
        find.descendant(
          of: find.byType(LanguageToggle),
          matching: find.byType(DecoratedBox),
        ),
        findsNWidgets(2),
      );

      final bnBox = _segment(tester, 'bn').decoration! as BoxDecoration;
      final enBox = _segment(tester, 'en').decoration! as BoxDecoration;
      expect(bnBox.color, p.primary);
      expect(enBox.color, Colors.transparent);
      expect(bnBox.border!.top.width, 1);
      expect(bnBox.border!.top.color, p.outline);
      expect((enBox.border! as Border).left, BorderSide.none);
      expect((bnBox.border! as Border).left.width, 1);

      // Tapping the other half switches and fills it.
      await tester.tap(find.byKey(LanguageToggle.englishKey));
      await tester.pumpAndSettle();
      final after = _segment(tester, 'en').decoration! as BoxDecoration;
      expect(after.color, p.primary);
      expect(
        (_segment(tester, 'bn').decoration! as BoxDecoration).color,
        Colors.transparent,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('locale'), 'en');
    });
  }

  testWidgets('expanded (Settings): both halves share the width', (
    tester,
  ) async {
    useViewport(tester);
    await tester.pumpWidget(themedApp(const LanguageToggle(expanded: true)));
    await tester.pumpAndSettle();
    final bn = tester.getRect(find.byKey(const Key('language_segment_bn')));
    final en = tester.getRect(find.byKey(const Key('language_segment_en')));
    expect(bn.width, moreOrLessEquals(en.width, epsilon: 1));
    expect(bn.width + en.width, moreOrLessEquals(360 - 32, epsilon: 1));
    expect(find.bySemanticsLabel('বাংলা'), findsOneWidget);
    expect(find.bySemanticsLabel('English'), findsOneWidget);
    expect(
      ProviderScope.containerOf(tester.element(find.byType(LanguageToggle)))
          .read(localeProvider),
      const Locale('bn'),
    );
  });
}
