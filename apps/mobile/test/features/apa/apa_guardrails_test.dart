// The one guardrail list behind both model instructions: the Gemini text instruction and the Live instruction carry every
// line, so the two personas cannot drift apart.

import 'package:bhorosha/features/apa/logic/apa_gemini_service.dart';
import 'package:bhorosha/features/apa/logic/apa_guardrails.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_live_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final instructions = <String, String>{
    'gemini (bn)': GeminiApaService.systemInstruction(english: false),
    'gemini (en)': GeminiApaService.systemInstruction(english: true),
    'live': FirebaseApaLiveService.systemInstruction,
  };

  test('the list covers every guardrail of the persona table', () {
    expect(ApaGuardrails.lines, hasLength(9));
    final all = ApaGuardrails.lines.join('\n');
    // Name and the exact introduction.
    expect(all, contains('FinNest Assistant'));
    expect(all, contains('"${ApaGuardrails.introBn}"'));
    expect(all, contains('"${ApaGuardrails.introEn}"'));
    expect(ApaGuardrails.introBn, 'আমি ফিননেস্ট সহকারী বলছি');
    // Bangla first, আপনি.
    expect(all, contains('Bangla first'));
    expect(all, contains('আপনি'));
    // Never asks for codes.
    expect(all, contains('Never ask for, accept or repeat an OTP, PIN'));
    // Never moves or approves money.
    expect(all, contains('cannot move, release, send or approve money'));
    // Only known facts.
    expect(all, contains('Only cite the facts in CONTEXT'));
    // Hang-up advice with the helpline, never the real short code.
    expect(all, contains('কল কেটে দিন'));
    expect(all, contains(ApaHelpline.en));
    expect(all, contains(ApaHelpline.bn));
    expect(all, isNot(contains('16247')));
    // Religion, politics and off-topic in one polite line.
    expect(all, contains('Religion, politics'));
    expect(all, contains(ApaGuardrails.deflectBn));
    expect(all, contains(ApaGuardrails.deflectEn));
    // Not a person, no real brands.
    expect(all, contains('not a person'));
    expect(all, contains('Never name any private company other than FinNest'));
    expect(all, contains('Public agencies (Bangladesh Bank, BTRC'));
    // Sentence cap: at most three sentences per answer.
    expect(ApaGuardrails.maxSentences, 3);
    expect(all, contains('At most 3 short sentences'));
  });

  for (final MapEntry(key: name, value: text) in instructions.entries) {
    test('the $name instruction contains every guardrail line', () {
      for (final line in ApaGuardrails.lines) {
        expect(text, contains(line), reason: line);
      }
    });
  }

  test('the language line follows the app locale for text; voice is always '
      'Bangla', () {
    expect(instructions['gemini (bn)'], contains('Answer in Bangla'));
    expect(instructions['gemini (en)'], contains('answer in simple English'));
    expect(instructions['live'], contains('always answer in Bangla'));
    expect(instructions['live'], contains('নিরাপত্তা গাইড'));
    expect(instructions['live'], isNot(contains('নিরাপত্তা সহায়ক')));
  });

  test('no old name reaches a model instruction', () {
    for (final MapEntry(key: name, value: text) in instructions.entries) {
      expect(text, isNot(contains('ভরসা')), reason: name);
      expect(text, isNot(contains('Bhorosha')), reason: name);
      expect(RegExp(r'\bApa\b').hasMatch(text), isFalse, reason: name);
    }
  });
}
