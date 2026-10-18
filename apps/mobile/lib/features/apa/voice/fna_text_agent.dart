/// FNA's chat agent: typed questions
/// and topic chips answered by Gemini with the conversation so far and the
/// same five tools as voice mode, then the offline guide.
///
/// The chain: [AppEnv.fnaTextModel], then [AppEnv.fnaTextFallbackModel],
/// both through `fnaTextAiProvider` (limited-use App Check), inside one 20 s
/// budget; the first model gets at most 14 s of it, so a slow first model
/// still leaves the fallback a try. Any failure, no Firebase, or no network gives the offline guide:
/// the best knowledge chunk for the question, in the app language, so the
/// answers still differ by question. [FnaTextAgent.ask] never throws.
///
/// FR-3: the model sees `fnaModelContext` (a held count, never a reason) and
/// tool results only; why money is held is the app's job
/// (`show_hold_reason`).
library;

import 'dart:async';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/logic/fna_voice_lines.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_model_context.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:firebase_ai/firebase_ai.dart';

/// One chat call: everything a model attempt needs. [history] is a copy the
/// callee may keep or mutate (`ChatSession` appends to it).
class FnaChatRequest {
  const FnaChatRequest({
    required this.model,
    required this.systemInstruction,
    required this.history,
    required this.message,
    required this.tools,
  });

  final String model;
  final String systemInstruction;
  final List<Content> history;
  final Content message;
  final List<AutoFunctionDeclaration> tools;
}

/// The model seam: the reply text, or `null`/throw on failure. Tests pass a
/// scripted one; production uses [FirebaseFnaChat].
typedef FnaChatGenerate = Future<String?> Function(FnaChatRequest request);

/// What the chat shows for one question.
class FnaTextReply {
  const FnaTextReply({
    required this.text,
    required this.path,
    this.usedSearch = false,
    this.textBn,
    this.textEn,
    this.blocked = false,
    this.dontKnow = false,
  });

  /// The answer in the app language.
  final String text;

  /// [ApaTurn.gemini] or [ApaTurn.guide].
  final String path;

  /// The model called `search_safety_knowledge` for this answer.
  final bool usedSearch;

  /// Both languages, when the answer has both (the offline guide's chunk).
  final String? textBn;
  final String? textEn;

  /// The guard replaced the model's answer with the safe line.
  final bool blocked;

  /// The answer is FNA's fixed "do not know" line: the chat shows the
  /// helpline button with it.
  final bool dontKnow;

  @override
  String toString() =>
      'FnaTextReply(path=$path search=$usedSearch blocked=$blocked '
      'dontKnow=$dontKnow '
      '${text.length} chars)';
}

/// The chat agent's standing instruction: the agent rules with the chat form
/// in place of the spoken one, the app language, and the model-facing
/// CONTEXT (no hold reasons, FR-3).
String fnaTextSystemInstruction(ApaContextSnapshot s) => [
  for (final line in FnaInstructions.lines)
    identical(line, FnaInstructions.voiceForm) ? fnaChatForm : line,
  s.english
      ? 'The app is in English: answer in simple English unless the customer writes in Bangla.'
      : 'The app is in Bangla: answer in Bangla (বাংলা) unless the customer writes in English.',
  'CONTEXT:\n${fnaModelContextJson(s)}',
].join('\n');

/// The chat form rule (replaces [FnaInstructions.voiceForm]).
const fnaChatForm =
    'This is a chat on a phone: at most 3 short sentences, then one next step the customer can take. Plain text only: no lists, no markdown, no emoji, no digits of any code. Never repeat a sentence. Say the helpline number at most once.';

/// One model attempt of the chat agent. It is valid until the attempt times
/// out, fails or returns; after that its late tool calls do nothing. The
/// attempt is also the zone value of everything the attempt runs, so the
/// tool callbacks in `fna_providers.dart` can check [FnaAttempt.current]
/// after their own awaits.
class FnaAttempt {
  FnaAttempt._(this.id);

  static int _next = 0;

  /// A new valid attempt.
  factory FnaAttempt.start() => FnaAttempt._(++_next);

  static const _zoneKey = #fnaTextAttempt;

  /// The attempt whose zone runs the caller, or `null` outside the chat
  /// agent (voice mode, tests calling a tool directly).
  static FnaAttempt? get current => Zone.current[_zoneKey] as FnaAttempt?;

  /// `true` when no attempt runs the caller, or the one that does is valid.
  static bool get currentIsLive => current?.live ?? true;

  final int id;
  bool _live = true;

  bool get live => _live;

  void invalidate() => _live = false;

  /// Runs [body] with this attempt as the zone's attempt.
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  @override
  String toString() => 'FnaAttempt($id, live=$_live)';
}

/// Tools with an effect outside the conversation (a server call, a bubble):
/// the fallback model reuses the result of the failed attempt instead of
/// running them twice.
const _sideEffectTools = {FnaToolNames.checkCaller, FnaToolNames.holdReason};

class FnaTextAgent {
  FnaTextAgent({
    required this._tools,
    required this._knowledge,
    this._generate,
    this.models = const [AppEnv.fnaTextModel, AppEnv.fnaTextFallbackModel],
    this.timeout = const Duration(seconds: 12),
    this.firstModelTimeout = const Duration(seconds: 8),
    this.maxHistory = 20,
    this._guard = const FnaTranscriptGuard(),
  });

  static const _tag = 'fna.text';

  /// Most sentences kept from a model reply: 3 short ones plus the next step.
  static const maxSentences = 4;

  final FnaTools _tools;
  final Future<SafetyKnowledge?> Function() _knowledge;

  /// `null` when Firebase is not configured: every answer is the guide.
  final FnaChatGenerate? _generate;
  final FnaTranscriptGuard _guard;

  /// Tried in order, inside [timeout].
  final List<String> models;
  final Duration timeout;

  /// The most the first model may use of [timeout].
  final Duration firstModelTimeout;

  /// Most [Content]s kept (each exchange adds two).
  final int maxHistory;

  final List<Content> _history = [];

  /// Bumped by [reset]: tool calls and replies of an older conversation are
  /// dropped, never applied to the new one.
  int _epoch = 0;

  /// The conversation the next model call sees (a copy).
  List<Content> get history => List.unmodifiable(_history);

  /// A fresh sheet: forget the conversation and cut off calls in flight.
  void reset() {
    _epoch++;
    _history.clear();
  }

  bool _isCurrent(int epoch) => epoch == _epoch;

  /// Answers [question] (already redacted by the caller; redacted again
  /// here). Never throws.
  Future<FnaTextReply> ask(String question, ApaContextSnapshot snapshot) async {
    final (text, _) = ApaAnswers.redactSecrets(question.trim());
    if (text.isEmpty) return _dontKnow(snapshot.english);
    final generate = _generate;
    if (generate != null) {
      final question = _Question();
      try {
        final reply = await _askModels(generate, text, snapshot, question);
        if (reply != null) return reply;
      } on Object catch (e) {
        Log.w(_tag, 'model chain failed', e);
      }
      // The model was reached and its search found nothing: the "do not
      // know" line is an online answer, not the offline guide.
      if (question.searchFoundNothing) {
        return _dontKnow(snapshot.english, path: ApaTurn.gemini);
      }
    }
    return _guide(text, english: snapshot.english);
  }

  Future<FnaTextReply?> _askModels(
    FnaChatGenerate generate,
    String text,
    ApaContextSnapshot snapshot,
    _Question question,
  ) async {
    final epoch = _epoch;
    final instruction = fnaTextSystemInstruction(snapshot);
    final message = Content.text(text);
    final clock = Stopwatch()..start();
    for (final (i, model) in models.indexed) {
      var left = timeout - clock.elapsed;
      if (left <= Duration.zero) break;
      if (i == 0 && left > firstModelTimeout) left = firstModelTimeout;
      var usedSearch = false;
      final attempt = FnaAttempt.start();
      final tools = _recording(
        epoch,
        attempt,
        question,
        () => usedSearch = true,
      );
      try {
        final raw = await attempt
            .run(
              () => generate(
                FnaChatRequest(
                  model: model,
                  systemInstruction: instruction,
                  // A copy: a failed attempt must leave no half turn behind.
                  history: List.of(_history),
                  message: message,
                  tools: tools,
                ),
              ),
            )
            .timeout(left);
        attempt.invalidate();
        final clean = clip(raw);
        if (clean.isEmpty) throw StateError('empty reply');
        return _accept(epoch, message, clean, snapshot, usedSearch);
      } on TimeoutException {
        Log.w(_tag, '$model timed out');
      } on Object catch (e) {
        Log.w(_tag, '$model failed', e);
      } finally {
        // A late tool call of this attempt does nothing from here on.
        attempt.invalidate();
      }
    }
    return null;
  }

  /// Guards [clean], then records the exchange when the conversation is
  /// still the one that asked.
  FnaTextReply _accept(
    int epoch,
    Content message,
    String clean,
    ApaContextSnapshot snapshot,
    bool usedSearch,
  ) {
    final verdict = _guard.checkModel(clean, held: snapshot.transferPending);
    final blocked = verdict != GuardVerdict.ok;
    if (blocked) Log.w(_tag, 'reply blocked: ${verdict.name}');
    final shown = blocked
        ? FnaVoiceLines.safeLine(english: snapshot.english)
        : clean;
    if (_isCurrent(epoch)) {
      // The model sees the line the customer saw, never a blocked answer.
      _history
        ..add(message)
        ..add(Content.model([TextPart(shown)]));
      if (_history.length > maxHistory) {
        _history.removeRange(0, _history.length - maxHistory);
      }
    }
    return FnaTextReply(
      text: shown,
      path: ApaTurn.gemini,
      usedSearch: usedSearch,
      blocked: blocked,
      dontKnow: !blocked && isDontKnow(shown),
    );
  }

  /// [text] is (or starts with) the fixed "do not know" line.
  static bool isDontKnow(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return t.contains(FnaLines.dontKnowBn.trim()) ||
        t.contains(FnaLines.dontKnowEn.trim());
  }

  /// The shared tools bound to this conversation and to [attempt], noting a
  /// knowledge search. A call after the attempt ended does nothing; a
  /// side-effect tool an earlier attempt of the same [question] already ran
  /// returns that result instead of running again.
  List<AutoFunctionDeclaration> _recording(
    int epoch,
    FnaAttempt attempt,
    _Question question,
    void Function() onSearch,
  ) {
    final bound = _tools.autoDeclarations(
      epoch: epoch,
      isCurrent: (e) => attempt.live && _isCurrent(e),
    );
    return [
      for (final t in bound)
        AutoFunctionDeclaration(
          name: t.name,
          description: t.description,
          parameters: _tools.byName(t.name)?.parameters ?? const {},
          optionalParameters:
              _tools.byName(t.name)?.optionalParameters ?? const [],
          callable: (args) async {
            if (!attempt.live) return const {'error': 'attempt_ended'};
            final key = _sideEffectTools.contains(t.name)
                ? '${t.name}|${args['text'] ?? ''}'
                : null;
            final earlier = key == null ? null : question.done[key];
            if (earlier != null) {
              Log.d(_tag, '${t.name} already ran for this question; reused');
              return earlier;
            }
            if (t.name == FnaToolNames.search) onSearch();
            final result = await attempt.run(() => t.callable(args));
            if (attempt.live) {
              if (key != null && !result.containsKey('error')) {
                question.done[key] = result;
              }
              if (t.name == FnaToolNames.search &&
                  (result['results'] as List?)?.isEmpty == true) {
                question.searchFoundNothing = true;
              }
            }
            return result;
          },
        ),
    ];
  }

  /// The offline guide: the best chunk for [text] in both languages, or the
  /// fixed "do not know" line.
  Future<FnaTextReply> _guide(String text, {required bool english}) async {
    SafetyKnowledge? kb;
    try {
      kb = await _knowledge().timeout(const Duration(seconds: 3));
    } on Object catch (e) {
      Log.w(_tag, 'knowledge not ready', e);
    }
    final hits = kb?.search(text, k: 1) ?? const <KbHit>[];
    if (kb == null || hits.isEmpty) return _dontKnow(english);
    final chunk = hits.first.chunk;
    final bn = kb.textOf(chunk, english: false);
    final en = kb.textOf(chunk, english: true);
    return FnaTextReply(
      text: english ? en : bn,
      path: ApaTurn.guide,
      textBn: bn,
      textEn: en,
    );
  }

  FnaTextReply _dontKnow(bool english, {String path = ApaTurn.guide}) =>
      FnaTextReply(
        text: FnaLines.dontKnow(english: english),
        path: path,
        textBn: FnaLines.dontKnowBn,
        textEn: FnaLines.dontKnowEn,
        dontKnow: true,
      );

  static final _markup = RegExp(r'[*_#`]+');
  static final _sentence = RegExp(r'[^.!?।]+[.!?।]*');

  /// [raw] without markdown, cut to [maxSentences] sentences.
  static String clip(String? raw) {
    final plain = (raw ?? '').replaceAll(_markup, '').trim();
    final sentences = [
      for (final m in _sentence.allMatches(plain))
        if (m.group(0)!.trim().isNotEmpty) m.group(0)!.trim(),
    ];
    if (sentences.length <= maxSentences) return plain;
    return sentences.take(maxSentences).join(' ');
  }
}

/// What the attempts of one question share.
class _Question {
  /// Side-effect tool results by tool and argument.
  final Map<String, Map<String, Object?>> done = {};

  /// A search of a valid attempt returned no results.
  bool searchFoundNothing = false;
}

/// [FnaChatGenerate] on `firebase_ai` 5.0.0: a new [ChatSession] per model
/// attempt over the request's history copy, with automatic function calling
/// through the bound tools.
class FirebaseFnaChat {
  FirebaseFnaChat(this._ai);

  final FirebaseAI _ai;

  static const temperature = 0.3;
  static const maxOutputTokens = 300;

  /// No thinking: a measured Bangla answer on Vertex global took 1.2-1.7 s
  /// with a budget of 0 against 5-26 s with the default (2026-10-18), and
  /// both chat models accept a budget of 0.
  static const thinkingBudget = 0;

  /// Tool round trips per question (a search, maybe a status call, the
  /// answer).
  static const maxTurns = 4;

  Future<String?> call(FnaChatRequest r) async {
    final model = _ai.generativeModel(
      model: r.model,
      systemInstruction: Content.system(r.systemInstruction),
      tools: [Tool.functionDeclarations(r.tools)],
      generationConfig: GenerationConfig(
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
        thinkingConfig: ThinkingConfig.withThinkingBudget(thinkingBudget),
      ),
    );
    final chat = model.startChat(history: r.history, maxTurns: maxTurns);
    final response = await chat.sendMessage(r.message);
    return response.text;
  }
}
