import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/demo_note.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/home/ui/home_screen.dart';
import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:bhorosha/features/login/ui/login_screen.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/screen_harness.dart';
import '../../app/theme_harness.dart';
import '../intervention/intervention_fakes.dart';
import 'biometric_fakes.dart';

void main() {
  _layoutTests();
  testWidgets('strong biometrics: one prompt signs Rina in to Home', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, persona: null);

    expect(locationOf(c), Routes.login);
    expect(find.text('FinNest'), findsOneWidget);
    expect(find.text('আপনার টাকার নিরাপদ ঘর'), findsOneWidget);
    expect(find.text('আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
    expect(find.byKey(const Key('password_login_link')), findsOneWidget);
    expect(find.byKey(const Key('login_password')), findsNothing);
    expect(find.byKey(const Key('biometric_fallback_line')), findsNothing);
    expect(find.text('লগইন'), findsNothing, reason: 'passkeys are off');
    // The demo is announced by the note, not by the button label (8.1).
    expect(find.textContaining('এটি ডেমো লগইন'), findsOneWidget);
    expect(find.text('রিনা আক্তার'), findsOneWidget);
    expect(find.text('রহিমা বেগম'), findsOneWidget);
    expect(find.text('গাজীপুর'), findsOneWidget);
    expect(find.text('ভোলা'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('demo_login'))).height,
      greaterThanOrEqualTo(BhSize.touch),
    );
    // The FNA square is as tall as the login button beside it (the owner's
    // 2026-10-17 note: the two were different heights).
    expect(
      tester.getSize(find.byKey(const Key('apa_button_login'))).height,
      tester.getSize(find.byKey(const Key('demo_login'))).height,
    );

    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();

    expect(h.biometric.authenticateCalls, 1);
    expect(
      h.biometric.lastReason,
      'ফিননেস্টে লগইন করতে আপনার পরিচয় যাচাই করুন',
    );
    expect(locationOf(c), Routes.home);
    expect(find.byType(HomeScreen), findsOneWidget);
    // Home's own copy belongs to its package; the greeting names Rina.
    expect(find.textContaining('স্বাগতম, রিনা'), findsOneWidget);
    expect(c.read(authRepoProvider).current?.uid, 'rina');
  });

  testWidgets('picking Rahima signs her in', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, persona: null);
    await tester.tap(find.byKey(const Key('persona_rahima')));
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(const Key('persona_rahima'))),
      isSemantics(isSelected: true),
    );
    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();
    expect(find.textContaining('স্বাগতম, রহিমা'), findsOneWidget);
    expect(c.read(authRepoProvider).current?.uid, 'rahima');
  });

  testWidgets('signed out, a deep route redirects to login', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(
      tester,
      harness: h,
      persona: null,
      location: Routes.home,
    );
    expect(locationOf(c), Routes.login);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('passkeys on: primary is লগইন, unavailable shows its line', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final h = ScreenHarness();
    await tester.runAsync(h.preloadAssets);
    await tester.pumpWidget(
      localizedApp(
        overrides: h.overrides,
        const LoginScreen(passkeysEnabled: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('passkey_login')), findsOneWidget);
    expect(find.text('লগইন'), findsOneWidget);
    expect(find.text('ডেমো লগইন'), findsOneWidget);

    await tester.tap(find.byKey(const Key('passkey_login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('passkey_unavailable_line')), findsOneWidget);
    expect(find.text('পাসকি লগইন এখন চালু নেই'), findsOneWidget);
    // The labelled demo login is still there below it.
    expect(find.byKey(const Key('demo_login')), findsOneWidget);
  });

  testWidgets('a failed demo login says so and offers a retry', (tester) async {
    usePhoneViewport(tester);
    final auth = _FailingAuth();
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          authRepoProvider.overrideWithValue(auth),
          biometricAuthProvider.overrideWithValue(FakeBiometricAuth()),
        ],
        const LoginScreen(passkeysEnabled: false),
      ),
    );
    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_failed')), findsOneWidget);
    expect(find.text('লগইন হয়নি। আবার চেষ্টা করুন।'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('login_retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('login_retry')));
    await tester.pumpAndSettle();
    expect(auth.attempts, 2);
  });

  testWidgets('a cancelled prompt stays on Login with the password link', (
    tester,
  ) async {
    final h = ScreenHarness(
      biometric: FakeBiometricAuth(outcome: const BiometricCancelled()),
    );
    final c = await pumpApp(tester, harness: h, persona: null);
    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();
    expect(h.biometric.authenticateCalls, 1);
    expect(locationOf(c), Routes.login);
    expect(find.byKey(const Key('password_login_link')), findsOneWidget);
    expect(find.byKey(const Key('biometric_failed')), findsNothing);
    expect(find.byKey(const Key('login_failed')), findsNothing);
    expect(c.read(authRepoProvider).current, isNull);
  });

  testWidgets('a failed prompt says so and keeps the biometric button', (
    tester,
  ) async {
    final h = ScreenHarness(
      biometric: FakeBiometricAuth(outcome: const BiometricFailed()),
    );
    final c = await pumpApp(tester, harness: h, persona: null);
    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const Key('biometric_failed')));
    expect(find.byKey(const Key('biometric_failed')), findsOneWidget);
    expect(find.text('যাচাই হয়নি, আবার চেষ্টা করুন।'), findsOneWidget);
    expect(find.text('আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন'), findsOneWidget);
    expect(locationOf(c), Routes.login);
  });

  testWidgets('biometrics found unusable at the prompt fall to the password', (
    tester,
  ) async {
    final h = ScreenHarness(
      biometric: FakeBiometricAuth(
        outcome: const BiometricUnavailable('NotEnrolled'),
      ),
    );
    await pumpApp(tester, harness: h, persona: null);
    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_password')), findsOneWidget);
    expect(
      find.text(
        'এই ফোনে আঙুলের ছাপ বা মুখ সেট করা নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the password link opens the password path and back', (
    tester,
  ) async {
    final h = ScreenHarness();
    await pumpApp(tester, harness: h, persona: null);
    await tester.tap(find.byKey(const Key('password_login_link')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_password')), findsOneWidget);
    expect(find.byKey(const Key('password_login')), findsOneWidget);
    expect(find.byKey(const Key('biometric_fallback_line')), findsNothing);
    expect(find.textContaining('ডেমো পাসওয়ার্ড: finnest'), findsOneWidget);
    await tester.tap(find.byKey(const Key('biometric_login_link')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_password')), findsNothing);
    expect(find.byKey(const Key('demo_login')), findsOneWidget);
  });

  for (final (strength, line) in const [
    (
      BiometricStrength.notEnrolled,
      'এই ফোনে আঙুলের ছাপ বা মুখ সেট করা নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।',
    ),
    (
      BiometricStrength.weakOnly,
      'এই ফোনের বায়োমেট্রিক যথেষ্ট নিরাপদ নয়, তাই পাসওয়ার্ড দিয়ে লগইন করুন।',
    ),
    (
      BiometricStrength.unsupported,
      'এই ফোনে বায়োমেট্রিক নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।',
    ),
  ]) {
    testWidgets('${strength.name}: the password path shows directly', (
      tester,
    ) async {
      final h = ScreenHarness(
        biometric: FakeBiometricAuth(strengthValue: strength),
      );
      await pumpApp(tester, harness: h, persona: null);
      expect(find.byKey(const Key('login_password')), findsOneWidget);
      expect(find.byKey(const Key('biometric_fallback_line')), findsOneWidget);
      expect(find.text(line), findsOneWidget);
      expect(find.byKey(const Key('demo_login')), findsNothing);
      expect(find.byKey(const Key('password_login_link')), findsNothing);
      expect(find.byIcon(Icons.fingerprint), findsNothing);
      expect(find.text('পাসওয়ার্ড দিয়ে লগইন করুন'), findsOneWidget);
      expect(find.textContaining('ডেমো পাসওয়ার্ড: finnest'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('login_password')),
      );
      expect(field.obscureText, isTrue);
      expect(field.textInputAction, TextInputAction.done);
      expect(field.autofillHints, contains(AutofillHints.password));
    });
  }

  testWidgets('a wrong password says so and keeps the field focused', (
    tester,
  ) async {
    final h = ScreenHarness(
      biometric: FakeBiometricAuth(
        strengthValue: BiometricStrength.notEnrolled,
      ),
    );
    final c = await pumpApp(tester, harness: h, persona: null);
    await tester.enterText(find.byKey(const Key('login_password')), 'nope');
    await tester.tap(find.byKey(const Key('password_login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('password_wrong')), findsOneWidget);
    expect(find.text('পাসওয়ার্ড মেলেনি। আবার চেষ্টা করুন।'), findsOneWidget);
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
    expect(locationOf(c), Routes.login);
    expect(h.biometric.authenticateCalls, 0);

    // The eye shows what was typed.
    expect(field.obscureText, isTrue);
    await tester.tap(find.byKey(const Key('password_eye')));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).obscureText,
      isFalse,
    );
  });

  testWidgets('the right password signs the selected persona in', (
    tester,
  ) async {
    final h = ScreenHarness(
      biometric: FakeBiometricAuth(
        strengthValue: BiometricStrength.unsupported,
      ),
    );
    final c = await pumpApp(tester, harness: h, persona: null);
    await tester.tap(find.byKey(const Key('persona_rahima')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('login_password')), 'finnest');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(c.read(authRepoProvider).current?.uid, 'rahima');
  });

  testWidgets('the no-OTP trust line shows on both paths', (tester) async {
    for (final strength in [
      BiometricStrength.strong,
      BiometricStrength.notEnrolled,
    ]) {
      final h = ScreenHarness(
        biometric: FakeBiometricAuth(strengthValue: strength),
      );
      await pumpApp(tester, harness: h, persona: null);
      await _reveal(tester, find.byKey(const Key('login_no_otp_line')));
      expect(find.byKey(const Key('login_no_otp_line')), findsOneWidget);
      expect(
        find.text(
          'আমরা ওটিপি চাই না: ওটিপি শেয়ার করা যায়, আপনার আঙুলের ছাপ বা মুখ যায় না।',
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('demo login starts a fresh session: no score, cooldown or '
      'evidence from before', (tester) async {
    final h = ScreenHarness();
    final c = await pumpApp(tester, harness: h, persona: null);
    final session = c.read(sessionRepoProvider).sessionId;
    final cooldown = c.read(cooldownProvider)..arm('call_active', 60);
    c.read(lastEvidenceQuoteProvider.notifier).state = 'কোডটা বলুন';
    c.read(lastScoreProvider.notifier).state = holdScore();

    await tester.tap(find.byKey(const Key('demo_login')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(c.read(sessionRepoProvider).sessionId, isNot(session));
    expect(cooldown.shouldSpeak('call_active'), isTrue);
    expect(c.read(lastScoreProvider), isNull);
    expect(c.read(lastEvidenceQuoteProvider), isNull);
  });
}

void _layoutTests() {
  testWidgets('fits 360 and 412 dp in both brightnesses and languages', (
    tester,
  ) async {
    final h = ScreenHarness();
    await tester.runAsync(h.preloadAssets);
    for (final strength in [
      BiometricStrength.strong,
      BiometricStrength.notEnrolled,
    ]) {
      h.biometric.strengthValue = strength;
      for (final width in [360.0, 412.0]) {
        for (final b in Brightness.values) {
          for (final l in const [Locale('bn'), Locale('en')]) {
            useViewport(tester, width: width, height: 760);
            // A fresh scope and list: the strength is read again and the
            // list starts at the top.
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpWidget(
              themedApp(
                const LoginScreen(passkeysEnabled: false),
                brightness: b,
                locale: l,
                overrides: h.overrides,
                scaffold: false,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$strength $width $b $l',
            );
            final logo = tester.widget<Text>(
              find.descendant(
                of: find.byKey(const Key('login_logo')),
                matching: find.byType(Text),
              ),
            );
            final spans = (logo.textSpan! as TextSpan).children!
                .cast<TextSpan>();
            final palette = BhPalette.of(BhPreset.teal, b);
            expect(spans.map((s) => s.text), ['Fin', 'Nest']);
            expect(spans.first.style?.color, palette.brandLeaf);
            expect(spans.last.style?.color, palette.brandNavy);
            expect(find.byKey(const Key('brand_mark')), findsOneWidget);
            await _reveal(tester, find.byType(DemoNote));
            expect(find.byType(DemoNote), findsOneWidget);
            // Last: scrolling may drop the logo from the lazy list.
            await _reveal(tester, find.byKey(const Key('login_no_otp_line')));
            expect(tester.takeException(), isNull);
          }
        }
      }
    }
  });
}

/// Scrolls Login's list until [finder] is built and on screen.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

class _FailingAuth implements AuthRepo {
  int attempts = 0;

  @override
  Future<UserProfile> demoLogin(Persona p) async {
    attempts++;
    throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
