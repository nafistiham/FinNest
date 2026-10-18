import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const t = '00000000-0000-4000-8000-000000000000';

  group('fixed App Check debug token', () {
    test('APP_CHECK_DEBUG_TOKEN defaults to empty, so no fixed token is used',
        () {
      expect(AppEnv.appCheckDebugToken, isEmpty);
      expect(AppEnv.fixedAppCheckDebugToken, isNull);
    });

    test('a fixed token is used only with the debug provider', () {
      expect(AppEnv.appCheckDebugTokenFor(debugProvider: true, token: t), t);
      expect(
        AppEnv.appCheckDebugTokenFor(debugProvider: true, token: '  $t\n'),
        t,
      );
      expect(
        AppEnv.appCheckDebugTokenFor(debugProvider: false, token: t),
        isNull,
      );
      expect(
        AppEnv.appCheckDebugTokenFor(debugProvider: true, token: '   '),
        isNull,
      );
    });
  });

  group('androidProviderFor', () {
    test('Play Integrity when the debug provider is off, even with a token',
        () {
      expect(
        FirebaseBootstrap.androidProviderFor(debug: false, debugToken: t),
        isA<AndroidPlayIntegrityProvider>(),
      );
    });

    test('the debug provider carries the fixed token to the native SDK', () {
      final p = FirebaseBootstrap.androidProviderFor(debug: true, debugToken: t);
      expect((p as AndroidDebugProvider).debugToken, t);
    });

    test('without a token the SDK makes its own (random per install)', () {
      final p = FirebaseBootstrap.androidProviderFor(debug: true);
      expect((p as AndroidDebugProvider).debugToken, isNull);
    });
  });
}
