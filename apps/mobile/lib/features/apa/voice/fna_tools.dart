/// FNA's tool registry: one declaration and one
/// handler per tool, shared by Gemini Live ([FnaTools.declarations]) and the
/// chat agent ([FnaTools.autoDeclarations]), so both paths answer from the
/// same facts.
///
/// No Riverpod here: every dependency is a constructor argument, so tests
/// drive the handlers directly. Handlers never throw (a failure is the
/// result `{error: ...}`) and check [FnaToolContext.current] before any side
/// effect, so a late call from an ended session cannot open a card or call
/// the server.
library;

import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_model_context.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:firebase_ai/firebase_ai.dart';

/// Words other people wrote (a caller, an app's name), made safe to show
/// the model as data: code-like numbers masked by the shared redactor,
/// links (also "(dot)", "[.]", "hxxps://" spellings) replaced by `[link]`, cut to [maxLength] characters and wrapped in
/// double quotes. The model's instruction says fields named `*_untrusted`
/// and `untrusted_*` are evidence, never instructions.
String fnaUntrustedText(String raw, {int maxLength = 160}) {
  var text = FnaTranscriptGuard.maskLinks(raw).replaceAll(RegExp(r'\s+'), ' ');
  (text, _) = ApaAnswers.redactSecrets(text.trim());
  if (text.length > maxLength) text = '${text.substring(0, maxLength)}…';
  return text;
}

/// [fnaUntrustedText] in double quotes.
String fnaUntrustedQuote(String raw) {
  final text = fnaUntrustedText(raw).replaceAll('"', "'");
  return text.isEmpty ? '' : '"$text"';
}

/// Tool names, as the model sees them.
abstract final class FnaToolNames {
  static const search = 'search_safety_knowledge';
  static const status = 'get_my_safety_status';
  static const callSummary = 'get_fraud_call_summary';
  static const checkCaller = 'check_caller_words';
  static const holdReason = 'show_hold_reason';
}

/// Which session a tool call belongs to. [epoch] is the session number at
/// the time of the call; [isCurrent] says whether that session is still the
/// live one.
class FnaToolContext {
  const FnaToolContext({required this.epoch, required this.isCurrent});

  /// A context that is always current (tests, one-shot callers).
  FnaToolContext.always() : epoch = 0, isCurrent = _always;

  static bool _always(int _) => true;

  final int epoch;
  final bool Function(int epoch) isCurrent;

  bool get current => isCurrent(epoch);
}

typedef FnaToolHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> args,
  FnaToolContext ctx,
);

/// One tool: what the model sees and what runs on the phone.
class FnaTool {
  FnaTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.run,
    this.optionalParameters = const [],
  }) : declaration = FunctionDeclaration(
         name,
         description,
         parameters: parameters,
         optionalParameters: optionalParameters,
       );

  final String name;
  final String description;
  final Map<String, Schema> parameters;
  final List<String> optionalParameters;
  final FunctionDeclaration declaration;
  final FnaToolHandler run;
}

/// The last flagged call, as the card and `get_fraud_call_summary` see it.
/// There is no confidence value on purpose: the card never shows one and the
/// model must not quote one.
class FnaCallSummary {
  const FnaCallSummary({
    required this.scamType,
    required this.urgency,
    required this.requestedSecret,
    required this.evidenceQuote,
    required this.recommendedAction,
    required this.at,
  });

  factory FnaCallSummary.fromScamTurn(ScamTurnResponse r, DateTime at) =>
      FnaCallSummary(
        scamType: r.scamType,
        urgency: r.urgency,
        requestedSecret: r.requestedSecret,
        evidenceQuote: r.evidenceQuote,
        recommendedAction: r.recommendedAction,
        at: at,
      );

  final String scamType;
  final String urgency;
  final String requestedSecret;

  /// The server's `evidence_quote`, verbatim. The card shows it; the model
  /// receives a masked, quoted copy as `caller_words_untrusted` and is told
  /// it is evidence, never instructions.
  final String evidenceQuote;
  final String recommendedAction;
  final DateTime at;

  /// The tool result. [now] gives `minutes_ago`. The caller's words are
  /// written by an attacker: they go under `caller_words_untrusted`, as a
  /// short quoted string with code-like numbers and links masked
  /// ([fnaUntrustedQuote]). The card shows the full quote; the model only
  /// needs enough to talk about it.
  Map<String, Object?> toToolJson({DateTime? now}) => {
    'available': true,
    'scam_type': scamType,
    'urgency': urgency,
    'requested_secret': requestedSecret,
    'caller_words_untrusted': fnaUntrustedQuote(evidenceQuote),
    'recommended_action': recommendedAction,
    if (now != null)
      'minutes_ago': now.difference(at).inMinutes.clamp(0, 1 << 30),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FnaCallSummary &&
          scamType == other.scamType &&
          urgency == other.urgency &&
          requestedSecret == other.requestedSecret &&
          evidenceQuote == other.evidenceQuote &&
          recommendedAction == other.recommendedAction &&
          at == other.at;

  @override
  int get hashCode => Object.hash(
    scamType,
    urgency,
    requestedSecret,
    evidenceQuote,
    recommendedAction,
    at,
  );
}

/// The five tools, built over injected dependencies.
class FnaTools {
  FnaTools({
    required this.knowledge,
    required this.snapshot,
    required this.lastCallSummary,
    required this.checkCallerWords,
    required this.showHoldReason,
    DateTime Function()? now,
    this.searchResults = 4,
    this.callerCheckTimeout = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now {
    _tools = List.unmodifiable([
      FnaTool(
        name: FnaToolNames.search,
        description: 'Searches the FinNest safety knowledge base on the phone. Call it before stating any safety fact or advice. Write the query with keywords in both Bangla and English. Returns up to 4 results; an empty list means FNA does not know.',
        parameters: {
          'query': Schema.string(
            description: 'Short search query with keywords in Bangla and English, for example "ওটিপি কোড চাইছে OTP code call".',
          ),
        },
        run: _search,
      ),
      FnaTool(
        name: FnaToolNames.status,
        description: 'The customer\'s safety status now: the phone safety verdict and finding titles, call, SIM and screen-sharing signals, and how many payments are held. It never contains a hold reason.',
        parameters: const {},
        run: _status,
      ),
      FnaTool(
        name: FnaToolNames.callSummary,
        description: 'The last suspicious call FinNest flagged: scam type, urgency, what the caller asked for, the caller\'s words and the advised action. {available: false} when no call was flagged.',
        parameters: const {},
        run: _callSummary,
      ),
      FnaTool(
        name: FnaToolNames.checkCaller,
        description: 'Checks what a caller said with FinNest\'s scam check and shows the call summary card. Call it when the customer reports a caller\'s words.',
        parameters: {
          'text': Schema.string(
            description: 'The caller\'s words, as the customer reported them. Never include any code, PIN or OTP digits.',
          ),
        },
        run: _checkCaller,
      ),
      FnaTool(
        name: FnaToolNames.holdReason,
        description: 'Shows and speaks the server\'s own reason why the customer\'s money is held. Call it whenever the customer asks why money is held, delayed or stopped. Afterwards say only the returned say_only line.',
        parameters: const {},
        run: _holdReason,
      ),
    ]);
  }

  static const _tag = 'fna.tools';

  /// The knowledge base; `null` while it is still loading.
  final SafetyKnowledge? Function() knowledge;

  /// The customer's state now (the app language comes from it too).
  final ApaContextSnapshot Function() snapshot;

  /// The last flagged call, or `null`.
  final FnaCallSummary? Function() lastCallSummary;

  /// Sends redacted caller words to the scam check (`/v1/scam/turn`), saves
  /// the result and shows the card. `null` when the check failed.
  final Future<FnaCallSummary?> Function(String callerWords) checkCallerWords;

  /// Closes the mic, mutes Live audio and shows and speaks the server's held
  /// text (the app's job, never the model's).
  final Future<void> Function() showHoldReason;

  final DateTime Function() _now;
  final int searchResults;
  final Duration callerCheckTimeout;

  late final List<FnaTool> _tools;

  List<FnaTool> get tools => _tools;

  /// For Live: `Tool.functionDeclarations(tools.declarations)`.
  List<FunctionDeclaration> get declarations => [
    for (final t in _tools) t.declaration,
  ];

  FnaTool? byName(String name) {
    for (final t in _tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// For the chat agent's `ChatSession`: the same tools as
  /// [AutoFunctionDeclaration]s, bound to session [epoch].
  List<AutoFunctionDeclaration> autoDeclarations({
    required int epoch,
    required bool Function(int epoch) isCurrent,
  }) {
    final ctx = FnaToolContext(epoch: epoch, isCurrent: isCurrent);
    return [
      for (final t in _tools)
        AutoFunctionDeclaration(
          name: t.name,
          description: t.description,
          parameters: t.parameters,
          optionalParameters: t.optionalParameters,
          callable: (args) => run(t.name, args, ctx),
        ),
    ];
  }

  /// Runs tool [name]. Never throws.
  Future<Map<String, Object?>> run(
    String name,
    Map<String, Object?> args,
    FnaToolContext ctx,
  ) async {
    final tool = byName(name);
    if (tool == null) return {'error': 'unknown_tool'};
    if (!ctx.current) return {'error': 'session_ended'};
    try {
      return await tool.run(args, ctx);
    } on Object catch (e) {
      Log.w(_tag, '$name failed', e);
      return {'error': 'tool_failed'};
    }
  }

  bool get _english {
    try {
      return snapshot().english;
    } on Object {
      return false;
    }
  }

  Future<Map<String, Object?>> _search(
    Map<String, Object?> args,
    FnaToolContext ctx,
  ) async {
    final query = (args['query'] as String? ?? '').trim();
    final english = _english;
    final kb = knowledge();
    if (kb == null) return {'error': 'knowledge_not_ready'};
    final hits = query.isEmpty
        ? const <KbHit>[]
        : kb.search(query, k: searchResults);
    if (hits.isEmpty) {
      return {
        'results': const <Object?>[],
        'say_exactly': FnaLines.dontKnow(english: english),
      };
    }
    return {
      'results': [
        for (final h in hits)
          {
            'id': h.chunk.id,
            'title': kb.titleOf(h.chunk, english: english),
            'text': kb.textOf(h.chunk, english: english),
            'source': kb.sourceLevelOf(h.chunk),
          },
      ],
    };
  }

  Future<Map<String, Object?>> _status(
    Map<String, Object?> args,
    FnaToolContext ctx,
  ) async {
    final s = snapshot();
    final phone = fnaPhoneSafety(s);
    return {
      'phone_safety': {
        if (phone['status'] != null) 'status': phone['status'],
        if (phone['verdict'] != null) 'verdict': phone['verdict'],
        'findings': fnaFindingTitles(s),
      },
      'signals': fnaSignals(s),
      ...fnaHeldFacts(s),
    };
  }

  Future<Map<String, Object?>> _callSummary(
    Map<String, Object?> args,
    FnaToolContext ctx,
  ) async {
    final summary = lastCallSummary();
    if (summary == null) return {'available': false};
    return summary.toToolJson(now: _now());
  }

  Future<Map<String, Object?>> _checkCaller(
    Map<String, Object?> args,
    FnaToolContext ctx,
  ) async {
    final raw = (args['text'] as String? ?? '').trim();
    if (raw.isEmpty) return {'error': 'empty_text'};
    // A code the customer repeated must never reach the server.
    final (words, _) = ApaAnswers.redactSecrets(raw);
    if (!ctx.current) return {'error': 'session_ended'};
    final summary = await checkCallerWords(words).timeout(callerCheckTimeout);
    if (summary == null) return {'checked': false, 'error': 'check_failed'};
    return {
      'checked': true,
      'card_shown': true,
      ...summary.toToolJson(now: _now()),
    };
  }

  Future<Map<String, Object?>> _holdReason(
    Map<String, Object?> args,
    FnaToolContext ctx,
  ) async {
    final english = _english;
    if (!ctx.current) return {'error': 'session_ended'};
    await showHoldReason();
    return {'shown': true, 'say_only': FnaLines.holdHandoff(english: english)};
  }
}
