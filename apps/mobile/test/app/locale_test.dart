import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/language_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screen_harness.dart';

Widget _localized(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('localeProvider', () {
    test('defaults to Bangla when nothing is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(localeProvider), const Locale('bn'));
      await c.read(localeProvider.notifier).restore();
      expect(c.read(localeProvider), const Locale('bn'));
    });

    test('restores the saved language', () async {
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(localeProvider.notifier).restore();
      expect(c.read(localeProvider), const Locale('en'));
    });

    test('an unknown saved value keeps Bangla', () async {
      SharedPreferences.setMockInitialValues({'locale': 'fr'});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(localeProvider.notifier).restore();
      expect(c.read(localeProvider), const Locale('bn'));
    });

    test('set switches at once and persists under "locale"', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(localeProvider.notifier).set(const Locale('en'));
      expect(c.read(localeProvider), const Locale('en'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LocaleNotifier.prefsKey), 'en');

      // A fresh container (the next app start) reads it back.
      final next = ProviderContainer(
        overrides: [
          initialLocaleProvider.overrideWithValue(await LocaleNotifier.load()),
        ],
      );
      addTearDown(next.dispose);
      expect(next.read(localeProvider), const Locale('en'));

      await c.read(localeProvider.notifier).toggle();
      expect(c.read(localeProvider), const Locale('bn'));
      expect(prefs.getString(LocaleNotifier.prefsKey), 'bn');
    });

    test(
      'a choice made before the restore finishes is not overwritten',
      () async {
        SharedPreferences.setMockInitialValues({'locale': 'en'});
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final notifier = c.read(localeProvider.notifier);
        final restoring = notifier.restore();
        await notifier.set(const Locale('bn'));
        await restoring;
        expect(c.read(localeProvider), const Locale('bn'));
      },
    );
  });

  group('digits follow the locale', () {
    testWidgets('context.taka: ৳ ৫,০০০ in Bangla', (tester) async {
      await tester.pumpWidget(
        _localized(
          const Locale('bn'),
          Builder(builder: (c) => Text(c.taka(5000))),
        ),
      );
      expect(find.text('৳ ৫,০০০'), findsOneWidget);
      expect(find.text('৳ 5,000'), findsNothing);
    });

    testWidgets('context.taka: ৳ 5,000 in English, lakh grouping kept', (
      tester,
    ) async {
      await tester.pumpWidget(
        _localized(
          const Locale('en'),
          Builder(
            builder: (c) =>
                Column(children: [Text(c.taka(5000)), Text(c.taka(100000))]),
          ),
        ),
      );
      expect(find.text('৳ 5,000'), findsOneWidget);
      expect(find.text('৳ 1,00,000'), findsOneWidget);
      expect(find.text('৳ ৫,০০০'), findsNothing);
    });

    testWidgets('context.digits converts either way', (tester) async {
      late BuildContext bn;
      late BuildContext en;
      await tester.pumpWidget(
        _localized(
          const Locale('bn'),
          Builder(
            builder: (c) {
              bn = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(bn.digits('09:59'), '০৯:৫৯');
      expect(bn.taka(7900), '৳ ৭,৯০০');
      await tester.pumpWidget(
        _localized(
          const Locale('en'),
          Builder(
            builder: (c) {
              en = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(en.digits('০৯:৫৯'), '09:59');
      expect(en.taka(7900), '৳ 7,900');
      expect(en.localName('রিনা', 'Rina'), 'Rina');
      expect(en.localName('রিনা', ''), 'রিনা');
    });
  });

  group('LanguageToggle', () {
    testWidgets('on Login: switches the whole app to English and persists', (
      tester,
    ) async {
      final h = ScreenHarness();
      final c = await pumpApp(tester, harness: h, persona: null);
      expect(locationOf(c), Routes.login);
      expect(find.byType(LanguageToggle), findsOneWidget);
      expect(find.text('আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন'), findsOneWidget);

      // A 32 dp pill inside a 48 dp tap area, top-right of the body.
      final toggle = tester.getRect(find.byType(LanguageToggle));
      expect(toggle.height, LanguageToggle.touchHeight);
      expect(
        tester.getSize(find.byKey(const Key('language_segment_bn'))).height,
        LanguageToggle.height,
      );
      expect(
        toggle.right,
        greaterThan(tester.getSize(find.byType(MaterialApp)).width - 40),
      );

      await tester.tap(find.byKey(LanguageToggle.englishKey));
      await tester.pumpAndSettle();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.locale, const Locale('en'));
      expect(find.text('Log in with fingerprint or face'), findsOneWidget);
      expect(find.text('আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন'), findsNothing);
      // The demo banner follows too.
      expect(find.textContaining('Demo mode'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('locale'), 'en');

      await tester.tap(find.byKey(LanguageToggle.banglaKey));
      await tester.pumpAndSettle();
      expect(find.text('আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন'), findsOneWidget);
      expect(prefs.getString('locale'), 'bn');
      expect(tester.takeException(), isNull);
    });

    testWidgets('on Home: the app-bar chip switches the whole screen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final h = ScreenHarness();
      final c = await pumpApp(tester, harness: h, location: Routes.home);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(LanguageToggle),
        ),
        findsOneWidget,
      );
      // Amounts render in digit slots; the spoken label carries the value.
      expect(find.bySemanticsLabel(RegExp('৯,৮৪১')), findsWidgets);

      await tester.tap(find.byKey(LanguageToggle.englishKey));
      await tester.pumpAndSettle();

      expect(c.read(localeProvider), const Locale('en'));
      expect(find.text('Send money'), findsWidgets);
      expect(find.textContaining('Welcome, Rina'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('9,841')), findsWidgets);

      await tester.tap(find.byKey(LanguageToggle.banglaKey));
      await tester.pumpAndSettle();
      expect(find.text('টাকা পাঠান'), findsWidgets);
      expect(find.text('Send money'), findsNothing);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('the numpad keys show the active digits', (tester) async {
      final h = ScreenHarness();
      final c = await pumpApp(tester, harness: h, location: Routes.pin);
      expect(find.text('৭'), findsOneWidget);
      await c.read(localeProvider.notifier).set(const Locale('en'));
      await tester.pumpAndSettle();
      expect(find.text('7'), findsOneWidget);
      expect(find.text('৭'), findsNothing);
    });
  });
}
