import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/features/demo_panel/ui/demo_panel_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'theme_harness.dart';

/// Compile-time flags (README "Compile-time flags").
void main() {
  group('App Check provider', () {
    test('debug provider only in a debug build or with APP_CHECK_DEBUG', () {
      expect(AppEnv.appCheckDebugFor(debugBuild: false, flag: false), isFalse);
      expect(AppEnv.appCheckDebugFor(debugBuild: false, flag: true), isTrue);
      expect(AppEnv.appCheckDebugFor(debugBuild: true, flag: false), isTrue);
    });

    test('the dart-define defaults to off, so a release APK built without '
        'it uses Play Integrity', () {
      expect(AppEnv.appCheckDebug, isFalse);
      expect(AppEnv.useAppCheckDebugProvider, kDebugMode);
    });
  });

  group('demo panel', () {
    test('DEMO_PANEL defaults to kDebugMode', () {
      expect(AppEnv.demoPanel, kDebugMode);
    });

    testWidgets('disabled, the logo is just the logo: a long press opens '
        'nothing', (tester) async {
      await tester.pumpWidget(
        themedApp(
          const DemoLongPressTarget(
            enabled: false,
            child: SizedBox(key: Key('logo'), width: 80, height: 80),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(DemoLongPressTarget),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
      await tester.longPress(find.byKey(const Key('logo')));
      await tester.pumpAndSettle();
      expect(find.byType(DemoPanelBody), findsNothing);
    });
  });

  test('the helpline is fictional', () {
    expect(AppEnv.helpline, '09666-123456');
  });
}
