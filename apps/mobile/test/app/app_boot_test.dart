import 'package:bhorosha/app/app.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/pin_pad/ui/pin_pad_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_harness.dart';

void main() {
  testWidgets('boots to the login route in Bangla', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BhoroshaApp()));
    await tester.pumpAndSettle();

    expect(find.text('FinNest'), findsWidgets);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, const Locale('bn'));
  });

  testWidgets('theme uses square corners and SolaimanLipi', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BhoroshaApp()));
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.textTheme.bodyMedium?.fontFamily, 'SolaimanLipi');
    expect(theme.textTheme.bodyMedium?.fontSize, 18);
    final shape = theme.cardTheme.shape as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.zero);
  });

  test('snackbar text follows the inverse surface in both brightnesses', () {
    for (final b in Brightness.values) {
      final theme = buildTheme(b);
      expect(
        theme.snackBarTheme.contentTextStyle?.color,
        theme.colorScheme.onInverseSurface,
        reason: '$b',
      );
    }
  });

  test('status text colours follow the brightness', () {
    final light = buildTheme(Brightness.light).colorScheme;
    final dark = buildTheme(Brightness.dark).colorScheme;
    expect(light.dangerText, BhColors.danger);
    expect(light.cautionText, BhColors.cautionInk);
    expect(light.okText, BhColors.ok);
    expect(dark.dangerText, BhColors.dangerOnDark);
    expect(dark.cautionText, BhColors.cautionOnDark);
    expect(dark.okText, BhColors.okOnDark);
    expect(
      dark.mutedText,
      buildTheme(Brightness.dark).textTheme.bodySmall?.color,
    );
  });

  testWidgets('the demo banner sits above every route (shell)', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, location: Routes.pin);
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(find.byKey(const Key('demo_banner')), findsOneWidget);
    // Above the screen, not inside it.
    final bannerY = tester
        .getBottomLeft(find.byKey(const Key('demo_banner')))
        .dy;
    final appBarY = tester.getTopLeft(find.byType(AppBar)).dy;
    expect(bannerY, lessThanOrEqualTo(appBarY));

    routerOf(c).go('${Routes.result}?state=done&amount=500');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demo_banner')), findsOneWidget);
  });
}
