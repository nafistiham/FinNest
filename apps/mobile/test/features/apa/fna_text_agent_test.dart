// FnaTextAgent: the model chain, history, guard, timeout and the
// offline guide, over a scripted model (no network).

import 'dart:async';

import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/logic/fna_voice_lines.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_text_agent.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';
import 'fna_logic_fakes.dart';

void main() {
  final kb = bundledKnowledge();
  const bn = ApaContextSnapshot();
  const en = ApaContextSnapshot(locale: 'en');

  FnaTools tools() => FnaTools(
    knowledge: () => kb,
    snapshot: () => bn,
    lastCallSummary: () => null,
    checkCallerWords: (_) async => null,
    showHoldReason: () async {},
  );

  FnaTextAgent agent({
    FnaChatGenerate? generate,
    Duration timeout = const Duration(seconds: 12),
    Duration firstModelTimeout = const Duration(seconds: 14),
    SafetyKnowledgeBase? knowledge,
    FnaTools? withTools,
  }) => FnaTextAgent(
    tools: withTools ?? tools(),
    knowledge: () async => knowledge ?? kb,
    generate: generate,
    models: const ['m1', 'm2'],
    timeout: timeout,
    firstModelTimeout: firstModelTimeout,
  );

  /// Tools that count the side effects and note the attempt they ran in.
  ({
    FnaTools tools,
    List<int> holds,
    List<String> checks,
    List<FnaAttempt?> seen,
  })
  countingTools() {
    final holds = <int>[];
    final checks = <String>[];
    final seen = <FnaAttempt?>[];
    final t = FnaTools(
      knowledge: () => kb,
      snapshot: () => bn,
      lastCallSummary: () => null,
      checkCallerWords: (words) async {
        seen.add(FnaAttempt.current);
        checks.add(words);
        return sampleSummary();
      },
      showHoldReason: () async {
        seen.add(FnaAttempt.current);
        holds.add(1);
      },
    );
    return (tools: t, holds: holds, checks: checks, seen: seen);
  }

  AutoFunctionDeclaration toolOf(FnaChatRequest r, String name) =>
      r.tools.firstWhere((t) => t.name == name);

  group('model path', () {
    test('answers on the first model with path gemini', () async {
      final chat = ScriptedChat();
      final a = agent(generate: chat.call);
      final reply = await a.ask('ওটিপি কী?', bn);
      expect(reply.path, ApaTurn.gemini);
      expect(reply.text, contains('ওটিপি কী?'));
      expect(chat.requests.single.model, 'm1');
      expect(
        chat.requests.single.systemInstruction,
        contains(fnaChatForm),
        reason: 'the chat form replaces the spoken one',
      );
      expect(
        chat.requests.single.systemInstruction,
        isNot(contains(FnaInstructions.voiceForm)),
      );
      expect(chat.requests.single.tools.map((t) => t.name), [
        FnaToolNames.search,
        FnaToolNames.status,
        FnaToolNames.callSummary,
        FnaToolNames.checkCaller,
        FnaToolNames.holdReason,
      ]);
    });

    test('history grows after success only and is passed as a copy', () async {
      var fail = true;
      final chat = ScriptedChat(
        answer: (r) async {
          // A ChatSession appends to the list it was given.
          r.history.add(Content.text('scribble'));
          if (fail) throw StateError('model down');
          return 'ঠিক আছে।';
        },
      );
      final a = agent(generate: chat.call);

      fail = true;
      final failed = await a.ask('প্রথম প্রশ্ন', bn);
      expect(failed.path, ApaTurn.guide, reason: 'both models failed');
      expect(a.history, isEmpty, reason: 'no half turn after a failure');

      fail = false;
      await a.ask('দ্বিতীয় প্রশ্ন', bn);
      expect(a.history, hasLength(2));
      await a.ask('তৃতীয় প্রশ্ন', bn);
      expect(a.history, hasLength(4));
      expect(chat.historyLengths, [0, 0, 0, 2]);
    });

    test('the fallback model answers when the first fails', () async {
      final chat = ScriptedChat(
        answer: (r) async {
          if (r.model == 'm1') throw StateError('not found');
          return 'দ্বিতীয় মডেলের উত্তর।';
        },
      );
      final reply = await agent(generate: chat.call).ask('প্রশ্ন', bn);
      expect(reply.path, ApaTurn.gemini);
      expect(chat.requests.map((r) => r.model), ['m1', 'm2']);
    });

    test('a timeout goes straight to the offline guide', () async {
      final chat = ScriptedChat(answer: (_) => Completer<String?>().future);
      final reply = await agent(
        generate: chat.call,
        timeout: const Duration(milliseconds: 30),
      ).ask('লটারি জিতেছি, ফি চাইছে', bn);
      expect(reply.path, ApaTurn.guide);
      expect(
        chat.requests,
        hasLength(1),
        reason: 'no second try after the budget',
      );
    });

    test('a guarded reply becomes the safe line', () async {
      final chat = ScriptedChat(answer: (_) async => 'কোডটা বলুন।');
      final a = agent(generate: chat.call);
      final reply = await a.ask('কী করব?', bn);
      expect(reply.blocked, isTrue);
      expect(reply.text, FnaVoiceLines.safeLineBn);
      final last = a.history.last.parts.whereType<TextPart>().single.text;
      expect(
        last,
        FnaVoiceLines.safeLineBn,
        reason: 'the model sees the safe line',
      );
    });

    test('"send it" while money is held is blocked', () async {
      final chat = ScriptedChat(
        answer: (_) async => 'Go ahead and send it now.',
      );
      const held = ApaContextSnapshot(locale: 'en', lastScore: heldScore);
      final reply = await agent(generate: chat.call).ask('Can I pay?', held);
      expect(reply.text, FnaVoiceLines.safeLineEn);
    });

    test('usedSearch is set when the model searched', () async {
      final chat = ScriptedChat(
        answer: (r) async {
          final search = r.tools.firstWhere(
            (t) => t.name == FnaToolNames.search,
          );
          final result = await search.callable({'query': 'OTP ওটিপি'});
          expect((result['results']! as List), isNotEmpty);
          return 'OTP কাউকে দেবেন না।';
        },
      );
      final reply = await agent(generate: chat.call).ask('ওটিপি', bn);
      expect(reply.usedSearch, isTrue);
    });

    test(
      'a reply that lands after reset is not added to the history',
      () async {
        final gate = Completer<String?>();
        final chat = ScriptedChat(answer: (_) => gate.future);
        final a = agent(generate: chat.call);
        final pending = a.ask('প্রশ্ন', bn);
        a.reset();
        gate.complete('দেরিতে উত্তর।');
        await pending;
        expect(a.history, isEmpty);
      },
    );

    test('long replies are cut to four sentences, markdown removed', () {
      expect(
        FnaTextAgent.clip('**এক।** দুই। তিন। চার। পাঁচ।'),
        'এক। দুই। তিন। চার।',
      );
    });
  });

  group('attempts (review item 7)', () {
    test('a timed-out attempt: its late show_hold_reason does nothing, and '
        'the fallback model answers', () async {
      final c = countingTools();
      final gate = Completer<void>();
      final chat = ScriptedChat(
        answer: (r) async {
          if (r.model == 'm1') {
            await gate.future;
            await toolOf(r, FnaToolNames.holdReason).callable({});
            return 'দেরিতে।';
          }
          return 'দ্বিতীয় মডেলের উত্তর।';
        },
      );
      final reply = await agent(
        generate: chat.call,
        withTools: c.tools,
        firstModelTimeout: const Duration(milliseconds: 30),
      ).ask('টাকা কেন আটকাল?', bn);
      expect(reply.path, ApaTurn.gemini);
      expect(reply.text, 'দ্বিতীয় মডেলের উত্তর।');
      expect(chat.requests.map((r) => r.model), ['m1', 'm2']);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.holds, isEmpty, reason: 'the attempt had ended');
    });

    test(
      'a tool callback sees its attempt, invalid after the timeout',
      () async {
        final c = countingTools();
        final chat = ScriptedChat(
          answer: (r) async {
            if (r.model == 'm1') {
              await toolOf(
                r,
                FnaToolNames.checkCaller,
              ).callable({'text': 'কোডটা বলুন'});
              return Completer<String?>().future; // never answers
            }
            return 'ঠিক আছে।';
          },
        );
        await agent(
          generate: chat.call,
          withTools: c.tools,
          firstModelTimeout: const Duration(milliseconds: 30),
        ).ask('কলার কোড চাইছে', bn);
        final attempt = c.seen.single;
        expect(attempt, isNotNull);
        expect(attempt!.live, isFalse);
      },
    );

    test('the fallback model does not repeat a side effect the failed '
        'attempt already ran', () async {
      final c = countingTools();
      final results = <Map<String, Object?>>[];
      final chat = ScriptedChat(
        answer: (r) async {
          final result = await toolOf(
            r,
            FnaToolNames.checkCaller,
          ).callable({'text': 'অ্যাকাউন্ট বন্ধ হবে'});
          results.add(result);
          if (r.model == 'm1') throw StateError('m1 broke after the tool');
          return 'কোড কাউকে দেবেন না।';
        },
      );
      final reply = await agent(
        generate: chat.call,
        withTools: c.tools,
      ).ask('কলার বলছে অ্যাকাউন্ট বন্ধ হবে', bn);
      expect(reply.path, ApaTurn.gemini);
      expect(c.checks, hasLength(1), reason: 'one scam check, not two');
      expect(results, hasLength(2));
      expect(results.last['checked'], isTrue, reason: 'the first result');
    });
  });

  group('do not know and latency (review items 8, 9)', () {
    test('an online "do not know" keeps path gemini and is flagged', () async {
      final chat = ScriptedChat(answer: (_) async => FnaLines.dontKnowBn);
      final reply = await agent(generate: chat.call).ask('কিছু একটা', bn);
      expect(reply.path, ApaTurn.gemini);
      expect(reply.dontKnow, isTrue);
    });

    test(
      'an empty search then a failed model: do not know, still gemini',
      () async {
        final chat = ScriptedChat(
          answer: (r) async {
            await toolOf(r, FnaToolNames.search).callable({'query': 'zzqx'});
            throw StateError('model broke');
          },
        );
        final reply = await agent(
          generate: chat.call,
          knowledge: SafetyKnowledgeBase.empty(),
          withTools: FnaTools(
            knowledge: SafetyKnowledgeBase.empty,
            snapshot: () => bn,
            lastCallSummary: () => null,
            checkCallerWords: (_) async => null,
            showHoldReason: () async {},
          ),
        ).ask('zzqx', bn);
        expect(reply.dontKnow, isTrue);
        expect(reply.path, ApaTurn.gemini);
      },
    );

    test('a normal answer is not flagged', () async {
      final reply = await agent(generate: ScriptedChat().call).ask('ওটিপি', bn);
      expect(reply.dontKnow, isFalse);
    });

    test('the chat form forbids repeats and a second helpline number', () {
      expect(fnaChatForm, contains('Never repeat a sentence.'));
      expect(fnaChatForm, contains('Say the helpline number at most once.'));
    });

    test('defaults: 12 s budget, 8 s for the first model, 300 tokens, no '
        'thinking', () {
      final a = FnaTextAgent(tools: tools(), knowledge: () async => kb);
      expect(a.timeout, const Duration(seconds: 12));
      expect(a.firstModelTimeout, const Duration(seconds: 8));
      expect(FirebaseFnaChat.maxOutputTokens, 300);
      expect(FirebaseFnaChat.thinkingBudget, 0);
    });

    test('a slow first model leaves the fallback model a try', () async {
      final chat = ScriptedChat(
        answer: (r) async {
          if (r.model == 'm1') return Completer<String?>().future;
          return 'দ্রুত উত্তর।';
        },
      );
      final reply = await agent(
        generate: chat.call,
        timeout: const Duration(seconds: 2),
        firstModelTimeout: const Duration(milliseconds: 30),
      ).ask('প্রশ্ন', bn);
      expect(reply.text, 'দ্রুত উত্তর।');
    });
  });

  group('offline guide', () {
    test('no model: different questions give different chunks', () async {
      final a = agent();
      final otp = await a.ask('কেউ ফোন করে ওটিপি চাইছে', bn);
      final lottery = await a.ask('I won a lottery, they want a fee', en);
      expect(otp.path, ApaTurn.guide);
      expect(lottery.path, ApaTurn.guide);
      expect(otp.text, isNot(lottery.text));
      expect(otp.textBn, isNotEmpty);
      expect(lottery.text, lottery.textEn, reason: 'English app, English text');
    });

    test('nothing found: the fixed do-not-know line', () async {
      final reply = await agent(knowledge: SafetyKnowledgeBase.empty())
          .ask('কিছু একটা', bn);
      expect(reply.text, FnaLines.dontKnowBn);
      expect(reply.path, ApaTurn.guide);
      expect(reply.dontKnow, isTrue);
    });

    test('a code in the question is masked before anything sees it', () async {
      final chat = ScriptedChat();
      await agent(generate: chat.call).ask('আমার কোড 123456', bn);
      final sent = ScriptedChat.messageText(chat.requests.single);
      expect(sent, isNot(contains('123456')));
    });
  });
}
