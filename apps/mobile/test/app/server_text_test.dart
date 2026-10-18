import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/server_text.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _bn = Locale('bn');
const _en = Locale('en');

void main() {
  group('pickServerText', () {
    test('Bangla picks bn, English picks en', () {
      expect(pickServerText(_bn, 'বাংলা', 'English'), 'বাংলা');
      expect(pickServerText(_en, 'বাংলা', 'English'), 'English');
    });

    test('an empty preferred field falls back to the other', () {
      expect(pickServerText(_en, 'বাংলা', ''), 'বাংলা');
      expect(pickServerText(_bn, '', 'English'), 'English');
    });

    test('a blank (whitespace only) preferred field falls back too', () {
      expect(pickServerText(_en, 'বাংলা', '   '), 'বাংলা');
      expect(pickServerText(_bn, ' \n', 'English'), 'English');
    });

    test('both empty gives the empty preferred field', () {
      expect(pickServerText(_bn, '', ''), '');
      expect(pickServerText(_en, '', ''), '');
    });

    test('every locale but English prefers Bangla', () {
      expect(pickServerText(const Locale('fr'), 'বাংলা', 'English'), 'বাংলা');
      expect(
        pickServerText(const Locale('en', 'US'), 'বাংলা', 'English'),
        'English',
      );
    });
  });

  group('context.serverText and the contract accessors', () {
    const reason = Reason(
      code: 'X',
      weight: 0.5,
      textBn: 'কারণ বাংলায়',
      textEn: 'Reason in English',
    );

    Future<BuildContext> pumpIn(WidgetTester tester, Locale? locale) async {
      late BuildContext captured;
      final probe = Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      );
      await tester.pumpWidget(
        locale == null
            ? Directionality(textDirection: TextDirection.ltr, child: probe)
            : Localizations(
                locale: locale,
                delegates: AppLocalizations.localizationsDelegates,
                child: probe,
              ),
      );
      return captured;
    }

    testWidgets('follows the Localizations locale', (tester) async {
      var context = await pumpIn(tester, _en);
      expect(context.serverText('বাং', 'Eng'), 'Eng');
      expect(reason.text(context), 'Reason in English');
      context = await pumpIn(tester, _bn);
      expect(context.serverText('বাং', 'Eng'), 'বাং');
      expect(reason.text(context), 'কারণ বাংলায়');
    });

    testWidgets('Bangla when there is no Localizations above', (tester) async {
      final context = await pumpIn(tester, null);
      expect(context.serverText('বাং', 'Eng'), 'বাং');
    });

    testWidgets('otherScript is the language not shown', (tester) async {
      const r = InterveneResponse(
        intervene: true,
        scriptBn: 'আমি ফিননেস্ট সহকারী বলছি।',
        scriptEn: 'This is your FinNest Assistant.',
        ui: UiMode.fullscreen,
        actions: [],
        cooldownS: 0,
      );
      var context = await pumpIn(tester, _en);
      expect(r.script(context), 'This is your FinNest Assistant.');
      expect(r.otherScript(context), 'আমি ফিননেস্ট সহকারী বলছি।');
      context = await pumpIn(tester, _bn);
      expect(r.script(context), 'আমি ফিননেস্ট সহকারী বলছি।');
      expect(r.otherScript(context), 'This is your FinNest Assistant.');
    });
  });
}
