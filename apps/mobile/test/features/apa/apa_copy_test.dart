// Copy consistency of the assistant's own words: one wording for "hang up", ঋণ for loan, and the helpline only
// ever through `AppEnv.helpline`.

import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/intervention/logic/asset_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live `apa*` keys whose Bangla the assistant speaks or shows.
const _ownedKeys = [
  'apaInsightCallTransferBody',
  'apaInsightSimSwapBody',
  'apaActionCallHelpline',
  'apaScamHotline',
  'apaScamDoHangUp',
  'apaCoachCode',
  'apaCoachLoan',
  'apaCoachGeneric',
  'apaCoachApp',
  'apaCoachTrusted',
  'apaCoachLottery',
];

Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

final _realHelpline = RegExp('16247|১৬২৪৭');

void main() {
  group('rules.json', () {
    final raw = File('assets/apa/rules.json').readAsStringSync();

    test('says "কল কেটে দিন", never "কল কাটুন" or "ফোন কেটে"', () {
      expect(raw, isNot(contains('কল কাটুন')));
      expect(raw, isNot(contains('ফোন কেটে')));
      expect(raw, isNot(contains('নম্বরে ফোন কর')));
      expect(raw, contains('কল কেটে দিন'));
    });

    test('says ঋণ, never লোন', () {
      expect(raw, isNot(contains('লোন')));
    });

    test('carries the helpline as a placeholder, never the real number', () {
      expect(_realHelpline.hasMatch(raw), isFalse);
      expect(raw, contains(ApaHelpline.placeholder));
    });

    test('the parsed content fills the placeholder per language', () {
      final c = ApaContent.embedded;
      final all = [...c.rules, ...c.tips, ...c.holds];
      for (final item in all) {
        expect(item.bodyBn, isNot(contains(ApaHelpline.placeholder)));
        expect(item.bodyEn, isNot(contains(ApaHelpline.placeholder)));
      }
      final rule = c.rule('never_share_code')!;
      expect(rule.bodyBn, contains(ApaHelpline.bn));
      expect(rule.bodyEn, contains(ApaHelpline.en));
      expect(rule.bodyBn, isNot(contains(ApaHelpline.en)));
      expect(c.tips.first.bodyBn, contains('${ApaHelpline.bn} নম্বরে কল করুন'));
    });
  });

  group('ARB (owned apa keys)', () {
    final bn = _arb('app_bn.arb');
    final en = _arb('app_en.arb');

    test('one wording for hang up, ঋণ for loan, no real helpline', () {
      for (final key in _ownedKeys) {
        final b = bn[key] as String;
        final e = en[key] as String;
        expect(b, isNot(contains('কল কাটুন')), reason: key);
        expect(b, isNot(contains('ফোন কেটে')), reason: key);
        expect(b, isNot(contains('লোন')), reason: key);
        expect(_realHelpline.hasMatch(b), isFalse, reason: key);
        expect(_realHelpline.hasMatch(e), isFalse, reason: key);
      }
      expect(bn['apaInsightCallTransferBody'], endsWith('আগে কল কেটে দিন।'));
      expect(bn['apaCoachLoan'], startsWith('ঋণ'));
    });

    test('the helpline keys take the {helpline} placeholder', () {
      for (final key in [
        'apaInsightSimSwapBody',
        'apaActionCallHelpline',
        'apaScamHotline',
        'apaCoachCode',
      ]) {
        expect(bn[key], contains('{helpline}'), reason: key);
        expect(en[key], contains('{helpline}'), reason: key);
        expect(bn['@$key'], isNotNull, reason: '$key placeholder meta');
      }
    });
  });

  test('ApaHelpline reads AppEnv.helpline in both digit styles', () {
    expect(ApaHelpline.en, AppEnv.helpline);
    expect(ApaHelpline.bn, isNot(contains(RegExp(r'\d'))));
    expect(ApaHelpline.digitRuns, isNotEmpty);
    for (final run in ApaHelpline.digitRuns) {
      expect(AppEnv.helpline.replaceAll(RegExp(r'\D'), ''), contains(run));
    }
  });

  group('fake server copy', () {
    test('introduces itself exactly and never asserts safety', () {
      expect(
        FakeRiskApi.genericCaution.scriptBn,
        startsWith('আমি ফিননেস্ট সহকারী বলছি।'),
      );
      expect(
        FakeRiskApi.genericCaution.scriptEn,
        startsWith('This is FinNest Assistant.'),
      );
      expect(FakeRiskApi.genericCaution.scriptEn, isNot(contains('FNA')));
      expect(
        FakeRiskApi.apaEcho.replyBn,
        startsWith('আমি ফিননেস্ট সহকারী বলছি।'),
      );
      expect(
        FakeRiskApi.apaEcho.replyEn,
        startsWith('This is FinNest Assistant.'),
      );
      expect(FakeRiskApi.apaEcho.replyBn, isNot(contains('নিরাপদ')));
      expect(FakeRiskApi.apaEcho.replyEn, isNot(contains('safe')));
    });

    test('the stub clip script uses the exact introduction', () {
      expect(
        AssetCatalog.scripts[AssetCatalog.apaTextDefault],
        startsWith('আমি ফিননেস্ট সহকারী বলছি।'),
      );
      expect(
        AssetCatalog.idForScript(
          AssetCatalog.olderScripts[AssetCatalog.apaTextDefault]!,
        ),
        AssetCatalog.apaTextDefault,
        reason: 'the deployed stub text still resolves',
      );
    });
  });
}
