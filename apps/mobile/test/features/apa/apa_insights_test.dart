import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_content_data.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

final bn = lookupAppLocalizations(const Locale('bn'));
final en = lookupAppLocalizations(const Locale('en'));

List<ApaInsight> run(ApaContextSnapshot s, {int tipSeed = 0}) =>
    buildApaInsights(
      s,
      bn: bn,
      en: en,
      content: ApaContent.embedded,
      tipSeed: tipSeed,
    );

List<String> ids(ApaContextSnapshot s) => run(s).map((i) => i.id).toList();

const pendingRecord = ApaHeldItem(
  txnId: 't1',
  reasons: [
    Reason(
      code: 'SIM_CHANGED_24H',
      weight: 0.85,
      textBn: 'গত ২৪ ঘণ্টার মধ্যে আপনার সিম পরিবর্তন হয়েছে।',
      textEn: 'Your SIM changed within the last 24 hours.',
    ),
  ],
  requestId: 'req-9',
  waitingForTrustedContact: true,
);

void main() {
  group('ranking table', () {
    final table = <(String, ApaContextSnapshot, List<String>)>[
      (
        'BLOCK beats held beats sim_swap',
        const ApaContextSnapshot(
          verdict: SafetyVerdict.block,
          held: [pendingRecord],
          simSwap: true,
        ),
        ['app_block', 'held_transfer', 'sim_swap'],
      ),
      (
        'held beats sim_swap',
        const ApaContextSnapshot(
          verdict: SafetyVerdict.safe,
          lastScore: heldScore,
          simSwap: true,
        ),
        ['held_transfer', 'sim_swap'],
      ),
      (
        'active call + pending transfer is danger, not caution',
        const ApaContextSnapshot(
          verdict: SafetyVerdict.safe,
          lastScore: heldScore,
          callActive: true,
        ),
        ['call_transfer'],
      ),
      (
        'active call alone is not an insight',
        const ApaContextSnapshot(verdict: SafetyVerdict.safe, callActive: true),
        ['all_clear', 'tip_hotline'],
      ),
      (
        'scam evidence is danger, after BLOCK',
        const ApaContextSnapshot(
          verdict: SafetyVerdict.block,
          evidenceQuote: 'কোডটা বলুন',
          screenShare: true,
        ),
        ['app_block', 'scam_call', 'screen_share'],
      ),
      (
        'caution verdict before sim_swap',
        const ApaContextSnapshot(verdict: SafetyVerdict.caution, simSwap: true),
        ['app_caution', 'sim_swap'],
      ),
      (
        'all clear: ok plus one tip',
        const ApaContextSnapshot(verdict: SafetyVerdict.safe),
        ['all_clear', 'tip_hotline'],
      ),
      (
        'no verdict yet: never "safe", ask to check',
        const ApaContextSnapshot(),
        ['unchecked', 'tip_hotline'],
      ),
      (
        'allow score is not a hold',
        const ApaContextSnapshot(
          verdict: SafetyVerdict.safe,
          lastScore: ScoreResponse(
            decision: Decision.allow,
            riskScore: 0.1,
            band: Band.low,
            reasons: [],
            actions: [],
            modelVersion: 'rules-v1',
          ),
        ),
        ['all_clear', 'tip_hotline'],
      ),
    ];
    for (final (name, snapshot, expected) in table) {
      test(name, () => expect(ids(snapshot), expected));
    }
  });

  test('BLOCK names the apps to uninstall, never the package', () {
    final i = run(blockSnapshot).first;
    expect(i.severity, ApaSeverity.danger);
    expect(i.titleBn, 'আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে');
    expect(i.bodyBn, startsWith(blockMessageBn));
    expect(i.bodyBn, contains('এগুলো আনইনস্টল করুন: TakaNow Loan'));
    expect(i.bodyEn, startsWith(blockMessageEn));
    expect(i.bodyEn, contains('Uninstall: TakaNow Loan'));
    expect('${i.bodyBn}${i.bodyEn}', isNot(contains('com.takanow')));
    expect(i.action, ApaAction.openSafety);
    expect(i.actionLabelBn, bn.apaActionOpenSafety);
  });

  test('held: the server reasons verbatim in both languages', () {
    final i = run(const ApaContextSnapshot(lastScore: heldScore)).first;
    expect(i.id, 'held_transfer');
    expect(i.severity, ApaSeverity.caution);
    expect(i.bodyBn, heldFirstLineBn);
    expect(i.bodyEn, heldFirstLineEn);
    expect(i.action, ApaAction.openApproveOrHeld);
  });

  test('held record without a score uses its stored reasons', () {
    final i = run(const ApaContextSnapshot(held: [pendingRecord])).first;
    expect(i.bodyBn, pendingRecord.reasons.single.textBn);
  });

  test('scam evidence quotes the caller and says the helpline', () {
    final i = run(const ApaContextSnapshot(evidenceQuote: 'কোডটা বলুন')).first;
    expect(i.id, 'scam_call');
    expect(i.bodyBn, contains('“কোডটা বলুন”'));
    expect(i.bodyBn, contains(ApaHelpline.bn));
    expect(i.bodyEn, contains(ApaHelpline.en));
    expect(i.bodyEn, contains('“কোডটা বলুন”'));
    expect(i.action, ApaAction.callHelpline);
  });

  test('all clear says the agreed sentence and the tip rotates', () {
    final a = run(const ApaContextSnapshot(verdict: SafetyVerdict.safe));
    expect(a.first.titleBn, 'ফোন ও লেনদেন নিরাপদ দেখাচ্ছে');
    expect(a.first.severity, ApaSeverity.ok);
    final tips = {
      for (var seed = 0; seed < 5; seed++)
        run(
          const ApaContextSnapshot(verdict: SafetyVerdict.safe),
          tipSeed: seed,
        )[1].id,
    };
    expect(tips, hasLength(ApaContent.embedded.tips.length));
  });

  test('context JSON carries facts only, in the app language', () {
    final json = const ApaContextSnapshot(
      lastScore: heldScore,
      callActive: true,
      locale: 'en',
      nameBn: 'রিনা',
      nameEn: 'Rina',
    ).toContextJson();
    expect(json['app_language'], 'English');
    expect((json['customer'] as Map)['name'], 'Rina');
    expect((json['last_payment_check'] as Map)['reasons'], [
      'You are on a call right now.',
      'You have never sent money to this number.',
    ]);
    expect((json['signals'] as Map)['on_a_call_now'], isTrue);
    expect((json['phone_safety_check'] as Map)['status'], 'not_checked_yet');
    expect(jsonEncode(json), isNotEmpty);
  });

  group('guide content', () {
    test('the embedded copy equals assets/apa/rules.json', () {
      final disk = jsonDecode(File('assets/apa/rules.json').readAsStringSync());
      expect(jsonDecode(apaContentJson), disk);
    });

    test('five rules, all bilingual, no real brand names', () {
      final c = ApaContent.embedded;
      expect(c.rules, hasLength(5));
      final all = [...c.rules, ...c.tips, ...c.holds];
      for (final r in all) {
        expect(r.bodyBn.trim(), isNotEmpty, reason: r.id);
        expect(r.bodyEn.trim(), isNotEmpty, reason: r.id);
        final text = '${r.titleBn} ${r.titleEn} ${r.bodyBn} ${r.bodyEn}'
            .toLowerCase();
        // Real brand names are kept only so the test can recognise them.
        for (final brand in const [
          'bkash',
          'বিকাশ',
          'nagad',
          'নগদ',
          'rocket',
          'রকেট',
          'grameenphone',
          'robi',
          'banglalink',
          'teletalk',
          'play store',
        ]) {
          expect(text, isNot(contains(brand)), reason: '${r.id}: $brand');
        }
      }
    });
  });
}
