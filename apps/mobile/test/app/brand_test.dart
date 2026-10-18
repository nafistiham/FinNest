import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'theme_harness.dart';

/// Old brand names that must not reach a customer screen after the FinNest
/// rebrand: the bank ভরসা / Bhorosha and the guide আপা / Apa as a word
/// (with its case endings), never a substring such as আপাতত.
final _oldNames = <RegExp>[
  RegExp('ভরসা'),
  RegExp('Bhorosha', caseSensitive: false),
  RegExp(r'(?<![ঀ-৿])আপা(?:কে|কেও|র|ও)?(?![ঀ-৿])'),
  RegExp(r'\bApa\b'),
];

Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('rebrand', () {
    for (final file in ['app_bn.arb', 'app_en.arb']) {
      test('no user-facing value in $file names Bhorosha or Apa', () {
        final arb = _arb(file);
        final hits = <String>[
          for (final e in arb.entries)
            if (!e.key.startsWith('@') && e.value is String)
              for (final re in _oldNames)
                if (re.hasMatch(e.value as String)) '${e.key}: ${e.value}',
        ];
        expect(hits, isEmpty);
      });
    }

    test('the guide is FinNest Assistant, FNA for short', () {
      final bn = _arb('app_bn.arb');
      final en = _arb('app_en.arb');
      expect(bn['appName'], 'ফিননেস্ট');
      expect(en['appName'], 'FinNest');
      expect(bn['apaSheetTitle'], 'ফিননেস্ট সহকারী');
      expect(en['apaSheetTitle'], 'FinNest Assistant');
      expect(bn['apa'], 'এফএনএ');
      expect(en['apa'], 'FNA');
      expect(bn['apaSays'], 'এফএনএ বলছে');
      expect(en['apaSays'], 'FNA says');
      // Product rule: a Bangla self-introduction is exactly this phrase.
      expect(bn['apaCoachGeneric'], startsWith('আমি ফিননেস্ট সহকারী বলছি।'));
    });

    test('the bundled rules name FinNest, not Bhorosha', () {
      final rules = File('assets/apa/rules.json').readAsStringSync();
      for (final re in _oldNames) {
        expect(re.hasMatch(rules), isFalse, reason: re.pattern);
      }
    });

    test('no bundled demo asset names Bhorosha or Apa (the scam script is '
        'quoted on screen as evidence)', () {
      final files = Directory('assets/demo')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      expect(files, isNotEmpty);
      for (final f in files) {
        final text = f.readAsStringSync();
        for (final re in _oldNames) {
          expect(
            re.hasMatch(text),
            isFalse,
            reason: '${f.path}: ${re.pattern}',
          );
        }
      }
      final script = File('assets/demo/scam_script.json').readAsStringSync();
      expect(script, contains('ফিননেস্ট কাস্টমার কেয়ার'));
    });

    test('cash-in codes carry the FinNest initials, not BH-', () {
      final rules = File('lib/features/pay/logic/pay_rules.dart')
          .readAsStringSync();
      expect(rules, contains("cashInCodePrefix = 'FN'"));
      expect(rules, isNot(contains("StringBuffer('BH-')")));
    });
  });

  group('no real helpline number', () {
    // 16247 is a real Bangladeshi provider's hotline. The app's helpline is
    // AppEnv.helpline (fictional), reached through `{helpline}` in the ARBs
    // and rules.json and interpolated at load time.
    final realHotline = RegExp('16247|১৬২৪৭');
    const textExtensions = {'.dart', '.arb', '.json', '.tsv', '.txt', '.md'};

    List<String> hitsUnder(String dir) => [
      for (final f in Directory(dir).listSync(recursive: true))
        if (f is File &&
            textExtensions.any(f.path.endsWith) &&
            realHotline.hasMatch(f.readAsStringSync()))
          f.path,
    ];

    for (final file in ['app_bn.arb', 'app_en.arb']) {
      test('no ARB value in $file carries it', () {
        final arb = _arb(file);
        final hits = <String>[
          for (final e in arb.entries)
            if (e.value is String && realHotline.hasMatch(e.value as String))
              e.key,
        ];
        expect(hits, isEmpty);
      });
    }

    test('no file under lib/ carries it', () {
      expect(hitsUnder('lib'), isEmpty);
    });

    test('no text asset carries it', () {
      expect(hitsUnder('assets'), isEmpty);
    });
  });

  group('BrandLockup', () {
    for (final b in Brightness.values) {
      testWidgets('mark above the two-tone wordmark ($b)', (tester) async {
        await tester.pumpWidget(themedApp(const BrandLockup(), brightness: b));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(find.byKey(const Key('brand_mark')), findsOneWidget);
        expect(find.byKey(const Key('brand_mark_fallback')), findsNothing);
        expect(find.text('FinNest'), findsOneWidget);
        final rich = tester.widget<Text>(find.text('FinNest'));
        final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
        final p = BhPalette.of(BhPreset.teal, b);
        expect(spans.first.style?.color, p.brandLeaf);
        expect(spans.last.style?.color, p.brandNavy);
        // Display-size text: at least 3:1 on the surface in both modes.
        expect(contrast(p.brandLeaf, p.surface), greaterThanOrEqualTo(3));
        expect(contrast(p.brandNavy, p.surface), greaterThanOrEqualTo(4.5));
        expect(
          tester.getSemantics(find.byType(BrandLockup)),
          isSemantics(label: 'ফিননেস্ট', isHeader: true),
        );
      });
    }

    testWidgets('falls back to the wordmark alone without the asset', (
      tester,
    ) async {
      await tester.pumpWidget(
        themedApp(const BrandLockup(asset: 'assets/brand/missing.png')),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('brand_mark_fallback')), findsOneWidget);
      expect(find.text('FinNest'), findsOneWidget);
    });
  });
}
