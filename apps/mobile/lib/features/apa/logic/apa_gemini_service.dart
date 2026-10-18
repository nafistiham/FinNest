/// Free-text answers from Gemini through Firebase AI Logic.
///
/// Used only when `firebaseStatusProvider == configured`. The model sees a
/// standing system instruction (the shared [ApaGuardrails] plus the language
/// line) and a CONTEXT block built from the customer's [ApaContextSnapshot].
/// Every reply is checked by [ApaAnswerGuard] before it is shown; any failure
/// (no Firebase, network, timeout, empty, blocked or ungrounded answer) falls
/// back to [fallback], the offline guide.
library;

import 'dart:async';
import 'dart:convert';

import 'package:bhorosha/app/l10n.dart' show asciiDigits;
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_guardrails.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_text_service.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/voice/fna_ai_client.dart';
import 'package:firebase_ai/firebase_ai.dart';

/// One generation call: the reply text, or `null`/throw on failure.
typedef ApaGenerate = Future<String?> Function({
  required String model,
  required String systemInstruction,
  required String prompt,
});

/// Post-validation of a model reply against the context it was given
/// [failedCheck] names the first check that fails, or
/// returns `null` when the reply may be shown. Pure; the names are logged,
/// never shown.
abstract final class ApaAnswerGuard {
  static const numbers = 'numbers';
  static const quotes = 'quotes';
  static const secrets = 'secrets';
  static const proceed = 'proceed';
  static const language = 'language';

  static final _digitRun = RegExp(r'\d+');
  static final _quoted = RegExp(r'[“"]([^”"]{1,200})[”"]');
  static final _secretAsk = RegExp(
    r'(পিন|ওটিপি|কোড|পাসওয়ার্ড|OTP|PIN|code|password)\S*\s+'
    r'(বলুন|দিন|পাঠান|লিখুন|share|tell|send)',
    caseSensitive: false,
  );
  static final _negation = RegExp(r'না|not|never', caseSensitive: false);
  static const _proceedPhrases = [
    'পাঠিয়ে দিন',
    'অনুমোদন করুন',
    'go ahead',
    'approve it',
    'send it',
  ];
  static final _bangla = RegExp(r'[ঀ-৿]');
  static final _latin = RegExp(r'[A-Za-z]');

  /// Every string value in the context JSON, the facts a quote may cite.
  static List<String> _facts(Object? node, [List<String>? out]) {
    final acc = out ?? <String>[];
    switch (node) {
      case final String s:
        if (s.trim().isNotEmpty) acc.add(s);
      case final Map<String, dynamic> m:
        for (final v in m.values) {
          _facts(v, acc);
        }
      case final List<dynamic> l:
        for (final v in l) {
          _facts(v, acc);
        }
      default:
        break;
    }
    return acc;
  }

  static String? failedCheck(String reply, ApaContextSnapshot s) {
    final context = s.toContextJson();
    final contextText = asciiDigits(jsonEncode(context));
    final facts = _facts(context);

    // Numbers: every digit run (ASCII, commas removed) must be in the context
    // or be the helpline.
    final plain = asciiDigits(reply).replaceAll(',', '');
    for (final m in _digitRun.allMatches(plain)) {
      final run = m.group(0)!;
      if (ApaHelpline.digitRuns.contains(run)) continue;
      if (!contextText.contains(run)) return numbers;
    }

    // Quotes: a quoted span must be part of a context fact.
    for (final m in _quoted.allMatches(reply)) {
      final span = m.group(1)!.trim();
      if (span.isEmpty) continue;
      if (!facts.any((f) => f.contains(span))) return quotes;
    }

    // Secrets: "কোডটা বলুন" fails unless negated right after.
    for (final m in _secretAsk.allMatches(reply)) {
      final tail = reply.substring(m.end, (m.end + 8).clamp(0, reply.length));
      if (!_negation.hasMatch(tail)) return secrets;
    }

    // Proceed: never "send it" or "approve it" while something is held.
    if (s.transferPending) {
      final lower = reply.toLowerCase();
      if (_proceedPhrases.any(lower.contains)) return proceed;
    }

    // Language: a Bangla app gets a Bangla reply.
    if (!s.english) {
      final bangla = _bangla.allMatches(reply).length;
      final latin = _latin.allMatches(reply).length;
      if (bangla == 0 || latin > bangla) return language;
    }
    return null;
  }
}

class GeminiApaService implements ApaService {
  GeminiApaService({
    required this.generate,
    required this.fallback,
    this.timeout = const Duration(seconds: 12),
  });

  static const _tag = 'apa.gemini';
  static const model = 'gemini-3.8-flash';
  static const fallbackModel = 'gemini-3.5-flash-lite';
  static const temperature = 0.3;
  static const maxOutputTokens = 300;

  final ApaGenerate generate;
  final ApaService fallback;

  /// Budget for both model attempts together.
  final Duration timeout;

  /// The standing instruction: the shared guardrails, then the language line
  /// (follows the app locale) and the four buttons the customer can tap.
  static String systemInstruction({required bool english}) {
    final language = english
        ? 'The app is in English: answer in simple English.'
        : 'Answer in Bangla (বাংলা) only. Do not switch language.';
    final buttons = english
        ? '"Is my phone safe?", "Why was my money held?", '
              '"Someone on the phone wants a code", "5 rules to stay safe"'
        : '"আমার ফোন কি নিরাপদ?", "টাকা কেন আটকাল?", '
              '"কেউ ফোনে কোড চাইছে", "নিরাপদ থাকার ৫ নিয়ম"';
    return [
      ...ApaGuardrails.lines,
      language,
      'The app has four buttons the customer can tap: $buttons.',
    ].join('\n');
  }

  /// The user turn: CONTEXT JSON, then the question.
  static String prompt(String text, ApaContextSnapshot snapshot) =>
      'CONTEXT:\n${jsonEncode(snapshot.toContextJson())}\n\nCUSTOMER:\n$text';

  @override
  Future<List<ApaTurn>> ask(
    String text,
    ApaContext ctx,
    ApaContextSnapshot snapshot,
  ) async {
    final english = snapshot.english;
    final instruction = systemInstruction(english: english);
    final input = prompt(text, snapshot);
    final clock = Stopwatch()..start();
    for (final name in const [model, fallbackModel]) {
      final left = timeout - clock.elapsed;
      if (left <= Duration.zero) break;
      try {
        final reply = await generate(
          model: name,
          systemInstruction: instruction,
          prompt: input,
        ).timeout(left);
        final clean = _clean(reply);
        if (clean.isEmpty) throw StateError('empty reply');
        final failed = ApaAnswerGuard.failedCheck(clean, snapshot);
        if (failed != null) {
          // Ungrounded or unsafe: the rule coach answers the same question.
          Log.w(_tag, '$name reply failed the "$failed" check; rule coach');
          return await fallback.ask(text, ctx, snapshot);
        }
        return [
          ApaTurn(
            speaker: ApaTurn.apa,
            // The reply is in the app language: an English reply is `textEn`
            // only, so a later switch to Bangla never shows English as Bangla
            // (pickServerText falls back to the non-empty field).
            textBn: english ? '' : clean,
            textEn: english ? clean : null,
            path: ApaTurn.gemini,
            source: ApaSource.ai,
          ),
        ];
      } on TimeoutException catch (e) {
        Log.w(_tag, '$name timed out', e);
        break;
      } on Object catch (e) {
        Log.w(_tag, '$name failed', e);
      }
    }
    return fallback.ask(text, ctx, snapshot);
  }

  /// Strips markdown emphasis and stray whitespace.
  static String _clean(String? reply) =>
      (reply ?? '').replaceAll(RegExp(r'[*_#`]+'), '').trim();
}

/// [ApaGenerate] on `firebase_ai` 5.0 (`FirebaseAI.agentPlatform`). One
/// [GenerativeModel] per (model, instruction), created on first use, so a
/// missing Firebase app throws inside the call and reaches the fallback.
///
/// [ai] is read at the first call: the app passes `fnaAiProvider`'s client
/// so this path shares the limited-use App Check flag with Live and the
/// chat agent (a bare `agentPlatform` call that runs first would turn the
/// flag off for every caller of the location, see `fna_ai_client.dart`).
/// `null` from it means Firebase is not configured: the call throws and the
/// service falls back, as before. Without [ai] the old entry point is used.
class FirebaseApaGenerator {
  FirebaseApaGenerator({this.location = 'us-central1', this.ai});

  final String location;
  final FirebaseAI? Function()? ai;
  final Map<String, GenerativeModel> _models = {};

  FirebaseAI _client() {
    final read = ai;
    if (read == null) return fnaAgentPlatform(location);
    final client = read();
    if (client == null) throw StateError('Firebase AI is not configured');
    return client;
  }

  Future<String?> call({
    required String model,
    required String systemInstruction,
    required String prompt,
  }) async {
    final generative = _models.putIfAbsent(
      '$model\n$systemInstruction',
      () => _client().generativeModel(
        model: model,
        systemInstruction: Content.system(systemInstruction),
        generationConfig: GenerationConfig(
          temperature: GeminiApaService.temperature,
          maxOutputTokens: GeminiApaService.maxOutputTokens,
        ),
      ),
    );
    final response = await generative.generateContent([Content.text(prompt)]);
    return response.text;
  }
}
