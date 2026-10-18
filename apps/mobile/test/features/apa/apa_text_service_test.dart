import 'dart:async';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
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
const none = ApaContextSnapshot();

void main() {
  group('ApaTextService (server stub, last resort)', () {
    test(
      'posts user_id, text_bn and context, returns an apa/text turn',
      () async {
        final api = FakeRiskApi(
          apaTurnResponse: const ApaTurnResponse(
            replyBn: 'টাকা এখনো আপনার হিসাবেই আছে।',
            replyEn: 'The money is still in your account.',
            toolCalls: ['ledger_lookup'],
          ),
        );
        final service = ApaTextService(api, 'rina');

        final turns = await service.ask(
          'টাকা কোথায়?',
          const ApaContext(lastRisk: 0.91, screen: 'result'),
          none,
        );

        final call = api.calls.single;
        expect(call.route, RiskRoutes.apaTurn);
        expect(call.body, {
          'user_id': 'rina',
          'text_bn': 'টাকা কোথায়?',
          'context': {'last_risk': 0.91, 'screen': 'result'},
        });
        final turn = turns.single;
        expect(turn.speaker, ApaTurn.apa);
        expect(turn.path, ApaTurn.text);
        expect(turn.textBn, 'টাকা এখনো আপনার হিসাবেই আছে।');
        expect(turn.textEn, 'The money is still in your account.');
      },
    );

    test('empty reply_en becomes null', () async {
      final api = FakeRiskApi(
        apaTurnResponse: const ApaTurnResponse(
          replyBn: 'ঠিক আছে।',
          replyEn: '',
          toolCalls: [],
        ),
      );
      final turns = await ApaTextService(
        api,
        'rahima',
      ).ask('কী হলো?', const ApaContext(), none);
      expect(turns.single.textEn, isNull);
    });

    test('propagates ApiFailure to the caller', () async {
      final api = FakeRiskApi()
        ..failures[RiskRoutes.apaTurn] = const TimeoutFailure();
      expect(
        () => ApaTextService(
          api,
          'rina',
        ).ask('কী হলো?', const ApaContext(), none),
        throwsA(isA<TimeoutFailure>()),
      );
    });
  });

  group('RuleBasedApaService intents', () {
    final coach = RuleBasedApaService(answers);

    final table = <String, ApaIntent>{
      'আমার ফোন কি নিরাপদ?': ApaIntent.safe,
      'is my phone safe': ApaIntent.safe,
      'টাকা আটকে গেছে কেন': ApaIntent.hold,
      'why was my money held': ApaIntent.hold,
      'একজন কলে আমার ওটিপি চাইছে': ApaIntent.code,
      'someone wants my PIN': ApaIntent.code,
      'পিনটা বলব?': ApaIntent.code,
      'অ্যাপটা নামাতে বলেছে': ApaIntent.app,
      'should I install this app': ApaIntent.app,
      'লোন পাবো কিভাবে': ApaIntent.loan,
      'আপনজন কে?': ApaIntent.trusted,
      'trusted contact': ApaIntent.trusted,
      'লটারি জিতেছি': ApaIntent.lottery,
      'অ্যাকাউন্ট ব্লক হবে বলছে': ApaIntent.blockThreat,
      'হ্যালো': ApaIntent.generic,
      'সকল খবর': ApaIntent.generic,
    };
    for (final MapEntry(key: text, value: intent) in table.entries) {
      test('"$text" → ${intent.name}', () {
        expect(ApaAnswers.intentOf(text), intent);
      });
    }

    test(
      'code intent: hang up and the helpline, offers the scam check',
      () async {
        final turn = (await coach.ask(
          'কেউ কোড চাইছে',
          const ApaContext(),
          none,
        )).single;
        expect(turn.path, ApaTurn.guide);
        expect(turn.textBn, contains(ApaHelpline.bn));
        expect(turn.textEn, contains(ApaHelpline.en));
        expect(turn.textBn, isNot(contains('১৬২৪৭')));
        expect(turn.tone, ApaSeverity.danger);
        expect(turn.action, ApaAction.openApaScamCheck);
      },
    );

    test('hold intent with a held score quotes the reasons exactly', () async {
      final turns = await coach.ask(
        'টাকা আটকাল কেন',
        const ApaContext(),
        const ApaContextSnapshot(lastScore: heldScore),
      );
      expect(turns.first.path, ApaTurn.held);
      expect(turns.first.textBn, heldFirstLineBn);
      expect(turns.first.textEn, heldFirstLineEn);
    });

    test('hold intent with nothing held says so and lists the holds', () async {
      final turns = await coach.ask('আটকে', const ApaContext(), none);
      expect(turns.first.textBn, bn.apaAnswerNothingHeld);
      expect(turns[1].textBn, contains(bn.apaAnswerHoldsIntro));
      expect(turns[1].textBn, contains(ApaContent.embedded.holds.first.bodyBn));
    });

    test('safe intent answers from the verdict, never invents one', () async {
      final unchecked = (await coach.ask(
        'নিরাপদ?',
        const ApaContext(),
        none,
      )).single;
      expect(unchecked.textBn, bn.apaAnswerPhoneUnchecked);
      final blocked = (await coach.ask(
        'নিরাপদ?',
        const ApaContext(),
        blockSnapshot,
      )).single;
      expect(blocked.textBn, contains(blockMessageBn));
      expect(blocked.textBn, contains('TakaNow Loan'));
      expect(blocked.textBn, isNot(contains('com.takanow')));
      expect(blocked.tone, ApaSeverity.danger);
    });

    test('anything else: the generic guide pointing at the buttons', () async {
      final turn = (await coach.ask('হ্যালো', const ApaContext(), none)).single;
      expect(turn.textBn, bn.apaCoachGeneric);
      expect(turn.textEn, en.apaCoachGeneric);
    });
  });

  group('GeminiApaService', () {
    test(
      'answers with the model text, path gemini, CONTEXT in the prompt',
      () async {
        final seen = <({String model, String instruction, String prompt})>[];
        final service = GeminiApaService(
          generate:
              ({
                required model,
                required systemInstruction,
                required prompt,
              }) async {
                seen.add((
                  model: model,
                  instruction: systemInstruction,
                  prompt: prompt,
                ));
                return '**আপনার ফোনে** ঝুঁকিপূর্ণ অ্যাপ আছে।';
              },
          fallback: RuleBasedApaService(answers),
        );
        final turns = await service.ask(
          'ফোন ঠিক আছে?',
          const ApaContext(),
          blockSnapshot,
        );
        expect(turns.single.path, ApaTurn.gemini);
        expect(turns.single.textBn, 'আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে।');
        expect(seen.single.model, GeminiApaService.model);
        expect(seen.single.instruction, contains('Answer in Bangla'));
        expect(seen.single.instruction, contains(ApaHelpline.en));
        expect(seen.single.instruction, isNot(contains('16247')));
        expect(
          seen.single.instruction,
          contains('Only cite the facts in CONTEXT'),
        );
        expect(seen.single.prompt, startsWith('CONTEXT:\n'));
        expect(seen.single.prompt, contains('"verdict":"BLOCK"'));
        expect(seen.single.prompt, contains('TakaNow Loan'));
        expect(seen.single.prompt, endsWith('CUSTOMER:\nফোন ঠিক আছে?'));
      },
    );

    test('English app: the instruction switches language', () async {
      String? instruction;
      final service = GeminiApaService(
        generate:
            ({
              required model,
              required systemInstruction,
              required prompt,
            }) async {
              instruction = systemInstruction;
              return 'Your phone looks safe.';
            },
        fallback: RuleBasedApaService(answers),
      );
      final turns = await service.ask(
        'safe?',
        const ApaContext(),
        const ApaContextSnapshot(locale: 'en'),
      );
      expect(instruction, contains('answer in simple English'));
      expect(turns.single.textEn, 'Your phone looks safe.');
    });

    test('a failing primary model tries the lite model', () async {
      final models = <String>[];
      final service = GeminiApaService(
        generate:
            ({
              required model,
              required systemInstruction,
              required prompt,
            }) async {
              models.add(model);
              if (model == GeminiApaService.model) throw StateError('quota');
              return 'ঠিক আছে।';
            },
        fallback: RuleBasedApaService(answers),
      );
      final turns = await service.ask('x', const ApaContext(), none);
      expect(models, [GeminiApaService.model, GeminiApaService.fallbackModel]);
      expect(turns.single.path, ApaTurn.gemini);
    });

    test('both models fail: the offline guide answers', () async {
      final service = GeminiApaService(
        generate: ({
          required model,
          required systemInstruction,
          required prompt,
        }) => Future.error(StateError('no firebase')),
        fallback: RuleBasedApaService(answers),
      );
      final turns = await service.ask(
        'কেউ পিন চাইছে',
        const ApaContext(),
        none,
      );
      expect(turns.single.path, ApaTurn.guide);
      expect(turns.single.textBn, bn.apaCoachCode(ApaHelpline.bn));
    });

    test('an empty answer falls back too', () async {
      final service = GeminiApaService(
        generate: ({
          required model,
          required systemInstruction,
          required prompt,
        }) async => '  ',
        fallback: RuleBasedApaService(answers),
      );
      final turns = await service.ask('হ্যালো', const ApaContext(), none);
      expect(turns.single.path, ApaTurn.guide);
    });

    test('a timeout goes straight to the guide', () async {
      var calls = 0;
      final service = GeminiApaService(
        generate:
            ({required model, required systemInstruction, required prompt}) {
              calls++;
              return Completer<String?>().future;
            },
        fallback: RuleBasedApaService(answers),
        timeout: const Duration(milliseconds: 20),
      );
      final turns = await service.ask('হ্যালো', const ApaContext(), none);
      expect(calls, 1);
      expect(turns.single.path, ApaTurn.guide);
    });
  });

  group('FallbackApaService', () {
    test('a throwing coach falls back to the server stub', () async {
      final api = FakeRiskApi();
      final service = FallbackApaService(
        _Throwing(),
        ApaTextService(api, 'rina'),
      );
      final turns = await service.ask('x', const ApaContext(), none);
      expect(turns.single.path, ApaTurn.text);
      expect(api.callsTo(RiskRoutes.apaTurn), hasLength(1));
    });
  });

  group('secrets', () {
    test('code-like numbers are masked, amounts and helplines are not', () {
      expect(ApaAnswers.redactSecrets('কোড ১২৩৪৫৬'), ('কোড ••••', true));
      expect(ApaAnswers.redactSecrets('pin 1234 ok'), ('pin •••• ok', true));
      // Spaced, punctuated and spoken codes.
      expect(ApaAnswers.redactSecrets('কোড ১২ ৩৪ ৫৬'), ('কোড ••••', true));
      expect(ApaAnswers.redactSecrets('otp 4.8.2.1'), ('otp ••••', true));
      expect(ApaAnswers.redactSecrets('কোড চার আট দুই নয়'), (
        'কোড ••••',
        true,
      ));
      expect(ApaAnswers.redactSecrets('code forty-eight twenty-one'), (
        'code ••••',
        true,
      ));
      // Any long number is masked now, a phone number included.
      expect(ApaAnswers.redactSecrets('01712345678 থেকে কল'), (
        '•••• থেকে কল',
        true,
      ));
      for (final keep in [
        '৫০০০ টাকা পাঠিয়েছি',
        'Tk 5,000',
        '১০ অক্টোবর',
        '10:30',
        '৯৯৯',
        '*16001#',
        '+880 1320010148',
        ApaHelpline.en,
        ApaHelpline.bn,
      ]) {
        expect(ApaAnswers.redactSecrets(keep), (keep, false));
      }
      expect(ApaAnswers.redactSecrets('৫ টাকা'), ('৫ টাকা', false));
    });
  });
}

class _Throwing implements ApaService {
  @override
  Future<List<ApaTurn>> ask(String t, ApaContext c, ApaContextSnapshot s) =>
      Future.error(StateError('boom'));
}
