// The post-validation of Gemini replies: an ungrounded or unsafe reply is never shown; the rule
// coach answers the same question instead.

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_gemini_service.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_text_service.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

final bn = lookupAppLocalizations(const Locale('bn'));
final en = lookupAppLocalizations(const Locale('en'));
final answers = ApaAnswers(bn: bn, en: en, content: ApaContent.embedded);

/// A service whose model always answers [reply].
GeminiApaService scripted(String reply) => GeminiApaService(
  generate: ({
    required model,
    required systemInstruction,
    required prompt,
  }) async => reply,
  fallback: RuleBasedApaService(answers),
);

const heldSnapshot = ApaContextSnapshot(
  lastScore: heldScore,
  balanceBdt: 9841,
  nameBn: 'রিনা',
);

void main() {
  group('ApaAnswerGuard.failedCheck', () {
    test('a grounded Bangla reply passes', () {
      expect(
        ApaAnswerGuard.failedCheck(
          'আপনার ব্যালেন্স ৯,৮৪১ টাকা। আপনি এখন একটি কলে আছেন।',
          heldSnapshot,
        ),
        isNull,
      );
    });

    test('an invented amount fails the numbers check', () {
      expect(
        ApaAnswerGuard.failedCheck('আপনার ৫,০০০ টাকা আটকে আছে।', heldSnapshot),
        ApaAnswerGuard.numbers,
      );
    });

    test('the helpline is always an allowed number', () {
      expect(
        ApaAnswerGuard.failedCheck(
          'কল কেটে দিন, তারপর ${ApaHelpline.bn} নম্বরে কল করুন।',
          const ApaContextSnapshot(),
        ),
        isNull,
      );
      expect(
        ApaAnswerGuard.failedCheck(
          'Hang up and call ${ApaHelpline.en}.',
          const ApaContextSnapshot(locale: 'en'),
        ),
        isNull,
      );
    });

    test('a quote must be part of a context fact', () {
      expect(
        ApaAnswerGuard.failedCheck(
          'যাচাই বলেছে: “আপনি এখন একটি কলে আছেন।”',
          heldSnapshot,
        ),
        isNull,
      );
      expect(
        ApaAnswerGuard.failedCheck(
          'যাচাই বলেছে: “আপনার সিম বদলেছে।”',
          heldSnapshot,
        ),
        ApaAnswerGuard.quotes,
      );
    });

    test('asking for a code fails unless negated right after', () {
      expect(
        ApaAnswerGuard.failedCheck('কোডটা বলুন।', heldSnapshot),
        ApaAnswerGuard.secrets,
      );
      expect(
        ApaAnswerGuard.failedCheck('আপনার PIN বলুন।', heldSnapshot),
        ApaAnswerGuard.secrets,
      );
      expect(
        ApaAnswerGuard.failedCheck(
          'Your OTP, send it to me.',
          const ApaContextSnapshot(locale: 'en'),
        ),
        ApaAnswerGuard.secrets,
      );
      // "কোড দিন না" and "do not share your PIN" are the rule itself.
      expect(
        ApaAnswerGuard.failedCheck('কাউকে কোড দিন না।', heldSnapshot),
        isNull,
      );
      expect(
        ApaAnswerGuard.failedCheck(
          'Never share your PIN. Do not tell anyone the OTP.',
          const ApaContextSnapshot(locale: 'en'),
        ),
        isNull,
      );
    });

    test('"send it" style advice fails while something is held', () {
      for (final phrase in ['পাঠিয়ে দিন', 'অনুমোদন করুন']) {
        expect(
          ApaAnswerGuard.failedCheck('টাকাটা $phrase।', heldSnapshot),
          ApaAnswerGuard.proceed,
          reason: phrase,
        );
      }
      for (final phrase in ['go ahead', 'approve it', 'send it']) {
        expect(
          ApaAnswerGuard.failedCheck(
            'You can $phrase now.',
            const ApaContextSnapshot(lastScore: heldScore, locale: 'en'),
          ),
          ApaAnswerGuard.proceed,
          reason: phrase,
        );
      }
      // Nothing held: the phrase is harmless.
      expect(
        ApaAnswerGuard.failedCheck(
          'পাঠিয়ে দিন বলে কেউ তাড়া দিলে থামুন।',
          const ApaContextSnapshot(),
        ),
        isNull,
      );
    });

    test('a Bangla app gets a Bangla reply', () {
      expect(
        ApaAnswerGuard.failedCheck('Your phone looks safe.', heldSnapshot),
        ApaAnswerGuard.language,
      );
      // A few Latin words inside Bangla are fine.
      expect(
        ApaAnswerGuard.failedCheck('আপনার PIN কাউকে দেবেন না।', heldSnapshot),
        isNull,
      );
      expect(
        ApaAnswerGuard.failedCheck(
          'Your phone looks safe.',
          const ApaContextSnapshot(locale: 'en'),
        ),
        isNull,
      );
    });
  });

  group('GeminiApaService with the guard', () {
    test('an invented amount gives the rule coach answer', () async {
      final turns = await scripted('আপনার ৫,০০০ টাকা আটকে আছে, পাঠিয়ে দিন।')
          .ask('টাকা আটকে আছে কেন?', const ApaContext(), heldSnapshot);
      expect(turns.first.path, ApaTurn.held, reason: 'hold intent, coach');
      expect(turns.first.textBn, heldFirstLineBn);
      expect(turns.every((t) => t.path != ApaTurn.gemini), isTrue);
    });

    test('"কোডটা বলুন" gives the rule coach answer', () async {
      final turns = await scripted('কোডটা বলুন।')
          .ask('কেউ কোড চাইছে', const ApaContext(), heldSnapshot);
      expect(turns.single.path, ApaTurn.guide);
      expect(turns.single.textBn, bn.apaCoachCode(ApaHelpline.bn));
    });

    test('a grounded reply is shown as a gemini turn', () async {
      final turns = await scripted('আপনি এখন একটি কলে আছেন, তাই টাকা আটকে আছে।')
          .ask('কী হলো?', const ApaContext(), heldSnapshot);
      expect(turns.single.path, ApaTurn.gemini);
      expect(turns.single.textBn, 'আপনি এখন একটি কলে আছেন, তাই টাকা আটকে আছে।');
      expect(turns.single.textEn, isNull);
    });

    test('in English the reply is textEn only, so Bangla never shows '
        'English', () async {
      final turns = await scripted('Your phone looks safe.').ask(
        'safe?',
        const ApaContext(),
        const ApaContextSnapshot(locale: 'en'),
      );
      expect(turns.single.textEn, 'Your phone looks safe.');
      expect(turns.single.textBn, isEmpty);
    });

    test('the lite model is not consulted after a failed check', () async {
      final models = <String>[];
      final service = GeminiApaService(
        generate:
            ({
              required model,
              required systemInstruction,
              required prompt,
            }) async {
              models.add(model);
              return 'কোডটা বলুন।';
            },
        fallback: RuleBasedApaService(answers),
      );
      await service.ask('হ্যালো', const ApaContext(), heldSnapshot);
      expect(models, [GeminiApaService.model]);
    });
  });
}
