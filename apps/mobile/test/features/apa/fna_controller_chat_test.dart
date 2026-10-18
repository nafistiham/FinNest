// ApaController with FNA_VOICE_AGENT on: chips and typed lines go
// to the chat agent, "why held" stays the server's text, nothing is spoken
// until "Hear it", the scam check fills the call summary card.

import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';
import 'fna_logic_fakes.dart';
import 'voice/fna_live_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ApaController controllerOf(ProviderContainer c) =>
      c.read(apaControllerProvider.notifier);
  ApaState stateOf(ProviderContainer c) => c.read(apaControllerProvider);

  group('chips and typed lines', () {
    test(
      'chips go to the agent and different chips get different answers',
      () async {
        final h = FnaLogicHarness();
        final c = h.container();
        final ctrl = controllerOf(c);
        await ctrl.openFor(screen: 'home');

        await ctrl.askPhoneSafe();
        final phone = stateOf(c).turns.last;
        await ctrl.showRules();
        final rules = stateOf(c).turns.last;

        // "Is my phone safe?" in chat is the safety check's own verdict (no
        // model); the rules chip goes to the agent.
        expect(h.chat.requests, hasLength(1));
        expect(phone.path, isNot(ApaTurn.gemini));
        expect(rules.path, ApaTurn.gemini);
        expect(phone.textBn, isNot(rules.textBn));
        expect(h.chat.historyLengths, [0]);
        await ctrl.sendText('কেউ ফোন করে ওটিপি চাইছে');
        expect(h.chat.historyLengths, [
          0,
          2,
        ], reason: 'the next question sees the first exchange');
        expect(stateOf(c).path, ApaTurn.gemini);
      },
    );

    test('a generic topic question goes to the agent', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c).askQuestion('সিম সোয়াপ কী?');
      expect(
        ScriptedChat.messageText(h.chat.requests.single),
        'সিম সোয়াপ কী?',
      );
      expect(stateOf(c).turns.map((t) => t.speaker), [
        ApaTurn.user,
        ApaTurn.apa,
      ]);
    });

    test('offline (no model): phone-safe chip keeps its deterministic answer, '
        'typed questions get the knowledge chunk', () async {
      final h = FnaLogicHarness(withModel: false);
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.showRules();
      expect(stateOf(c).turns.last.path, ApaTurn.guide);

      await ctrl.sendText('লটারি জিতেছি বলে ফি চাইছে');
      final lottery = stateOf(c).turns.last;
      await ctrl.sendText('কেউ ফোন করে ওটিপি চাইছে');
      final otp = stateOf(c).turns.last;
      expect(lottery.path, ApaTurn.guide);
      expect(lottery.textBn, isNot(otp.textBn));
    });

    test(
      'chat answers are not spoken; the held line on open still is',
      () async {
        final h = FnaLogicHarness();
        final c = h.container();
        final ctrl = controllerOf(c);
        await ctrl.openFor(held: heldScore, screen: 'result');
        expect(h.apa.audio.spoken, [heldFirstLineBn]);
        await ctrl.sendText('পাসওয়ার্ড কত বড় হওয়া উচিত?');
        await ctrl.askPhoneSafe();
        expect(h.apa.audio.spoken, [
          heldFirstLineBn,
        ], reason: 'nothing new spoken');
      },
    );

    test('hold-to-talk does nothing with the flag on', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c).holdStart();
      await controllerOf(c).holdEnd();
      expect(h.apa.mic.starts, 0);
      expect(stateOf(c).listening, isFalse);
    });
  });

  group('why held stays the server text (FR-3)', () {
    test(
      'the chip shows the reasons verbatim and the handoff line, no model',
      () async {
        final h = FnaLogicHarness();
        final c = h.container();
        c.read(lastScoreProvider.notifier).state = heldScore;
        await controllerOf(c).openFor(screen: 'home');
        await controllerOf(c).askWhyHeld();
        final turns = stateOf(c).turns;
        expect(
          turns.any(
            (t) => t.path == ApaTurn.held && t.textBn == heldFirstLineBn,
          ),
          isTrue,
        );
        expect(turns.last.textBn, FnaLines.holdHandoffBn);
        expect(h.chat.requests, isEmpty);
      },
    );

    test('a typed "why was it held" is answered the same way', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      c.read(lastScoreProvider.notifier).state = heldScore;
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c).sendText('টাকা কেন আটকাল?');
      await controllerOf(c).sendText('Why was my money held?');
      final held = stateOf(c).turns.where((t) => t.path == ApaTurn.held);
      expect(held, hasLength(2));
      expect(held.every((t) => t.textEn == heldFirstLineEn), isTrue);
      expect(h.chat.requests, isEmpty);
    });

    test('a code question with "hold" in it still goes to the agent', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c)
          .sendText('The caller says hold on and read the OTP');
      expect(h.chat.requests, hasLength(1));
    });
  });

  group('Hear it', () {
    test('plays the turn, a second tap stops it', () async {
      final h = FnaLogicHarness()..lineMaxWait = const Duration(seconds: 60);
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.askPhoneSafe();
      final answer = stateOf(c).turns.last;

      final playing = ctrl.hearIt(answer);
      await flush();
      expect(stateOf(c).hearingTurn, answer);
      expect(h.apa.audio.spoken, [answer.textBn]);

      final stops = h.apa.audio.stopCalls;
      await ctrl.hearIt(answer);
      await playing;
      expect(stateOf(c).hearingTurn, isNull);
      expect(h.apa.audio.stopCalls, greaterThan(stops));
    });

    test('playback finishing clears hearingTurn', () async {
      final h = FnaLogicHarness()..lineMaxWait = const Duration(seconds: 60);
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.askPhoneSafe();
      final playing = ctrl.hearIt(stateOf(c).turns.last);
      await flush();
      expect(stateOf(c).hearingTurn, isNotNull);
      h.apa.audio.finish();
      await playing;
      expect(stateOf(c).hearingTurn, isNull);
    });

    test('the "why held" chip shows the server text quietly; Hear it plays '
        'exactly that text (review item 10)', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      c.read(lastScoreProvider.notifier).state = heldScore;
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      final spokenAtOpen = h.apa.audio.spoken.length;
      await ctrl.askWhyHeld();
      final held = stateOf(c).turns.lastWhere((t) => t.path == ApaTurn.held);
      expect(held.textBn, heldFirstLineBn);
      expect(
        h.apa.audio.spoken,
        hasLength(spokenAtOpen),
        reason: 'the chat is quiet until Hear it',
      );
      await ctrl.hearIt(held);
      expect(h.apa.audio.spoken.last, heldFirstLineBn);
      expect(h.chat.requests, isEmpty, reason: 'no model (FR-3)');
    });

    test('English speaks the English text', () async {
      final h = FnaLogicHarness(
        chat: ScriptedChat(
          answer: (_) async =>
              'A SIM swap moves your number to a new SIM. Call the helpline.',
        ),
      );
      final c = h.container(
        extra: [
          apaSnapshotProvider.overrideWithValue(
            const ApaContextSnapshot(locale: 'en'),
          ),
        ],
      );
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.sendText('What is SIM swap?');
      final answer = stateOf(c).turns.last;
      expect(answer.textEn, isNotEmpty);
      await ctrl.hearIt(answer);
      expect(h.apa.audio.spoken, [answer.textEn]);
    });
  });

  group('call summary', () {
    test('the typed scam check sets the card', () async {
      final h = FnaLogicHarness();
      h.apa.api.scamTurnResponse = scamResponse;
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.startScamCheck();
      await ctrl.sendText('বলছে অ্যাকাউন্ট বন্ধ হবে, কোডটা বলুন');
      final summary = stateOf(c).callSummary;
      expect(summary, isNotNull);
      expect(summary!.evidenceQuote, scamResponse.evidenceQuote);
      expect(c.read(lastEvidenceQuoteProvider), scamResponse.evidenceQuote);
      expect(
        h.chat.requests,
        isEmpty,
        reason: 'caller words never reach the agent',
      );
    });

    test('a replay (or any writer) of lastCallSummaryProvider updates the card '
        'and a risk-session reset clears it', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      await controllerOf(c).openFor(screen: 'home');
      c.read(lastCallSummaryProvider.notifier).state = sampleSummary();
      expect(stateOf(c).callSummary, sampleSummary());
      c.read(riskSessionProvider.notifier).reset();
      await Future<void>.delayed(Duration.zero);
      c.read(lastCallSummaryProvider);
      expect(stateOf(c).callSummary, isNull);
    });

    test('hearCallSummary speaks the fixed template with the quote', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      c.read(lastCallSummaryProvider.notifier).state = sampleSummary();
      await c.read(safetyKnowledgeProvider.future);
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c).hearCallSummary();
      final spoken = h.apa.audio.spoken.single;
      expect(spoken, startsWith('সন্দেহজনক কল।'));
      expect(spoken, contains(scamResponse.evidenceQuote));
      expect(
        spoken,
        contains('পরের বার:'),
        reason: 'the playbook prevent chunk',
      );
      expect(h.chat.requests, isEmpty, reason: 'no model');
    });

    test('hearingSummary: true while it plays, a second tap stops it, the '
        'end of playback clears it', () async {
      final h = FnaLogicHarness()..lineMaxWait = const Duration(seconds: 60);
      final c = h.container();
      c.read(lastCallSummaryProvider.notifier).state = sampleSummary();
      await c.read(safetyKnowledgeProvider.future);
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');

      final first = ctrl.hearCallSummary();
      await flush();
      expect(stateOf(c).hearingSummary, isTrue);
      final stops = h.apa.audio.stopCalls;
      await ctrl.hearCallSummary(); // second tap
      await first;
      expect(stateOf(c).hearingSummary, isFalse);
      expect(h.apa.audio.stopCalls, greaterThan(stops));
      expect(h.apa.audio.spoken, hasLength(1), reason: 'not played again');

      final second = ctrl.hearCallSummary();
      await flush();
      expect(stateOf(c).hearingSummary, isTrue);
      h.apa.audio.finish();
      await second;
      expect(stateOf(c).hearingSummary, isFalse);
    });

    test('flag off: no card in the state', () async {
      final h = FnaLogicHarness(flag: false);
      final c = h.container();
      c.read(lastCallSummaryProvider.notifier).state = sampleSummary();
      await controllerOf(c).openFor(screen: 'home');
      expect(stateOf(c).callSummary, isNull);
    });
  });

  group('review fixes', () {
    test('an online "do not know" gets the helpline button and keeps the '
        'gemini path', () async {
      final h = FnaLogicHarness(
        chat: ScriptedChat(answer: (_) async => FnaLines.dontKnowBn),
      );
      final c = h.container();
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c).sendText('একদম অজানা প্রশ্ন');
      final reply = stateOf(c).turns.last;
      expect(reply.action, ApaAction.callHelpline);
      expect(reply.path, ApaTurn.gemini);
      expect(stateOf(c).path, ApaTurn.gemini);
    });

    test('an ordinary answer has no helpline button', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      await controllerOf(c).openFor(screen: 'home');
      await controllerOf(c).sendText('ওটিপি কী?');
      expect(stateOf(c).turns.last.action, ApaAction.none);
    });

    test('dismissVoiceFallback clears the fallback', () async {
      final h = FnaLogicHarness();
      h.audioIn.granted = false;
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.startVoice();
      await flush();
      expect(stateOf(c).voiceFallback, FnaFallbackReason.micDenied);
      ctrl.dismissVoiceFallback();
      expect(stateOf(c).voiceFallback, isNull);
    });
  });

  group('a masked code in a typed line (second review round, item 9)', () {
    test('the warning shows, then the masked question goes to the agent; '
        'the digits never leave the phone', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.sendText('কেউ আমার ওটিপি 482913 চাইছে, কী করব?');
      final turns = stateOf(c).turns;
      expect(h.chat.requests, hasLength(1));
      final asked = ScriptedChat.messageText(h.chat.requests.single);
      expect(asked, isNot(contains('482913')));
      expect(asked, contains('ওটিপি'));
      expect(turns, hasLength(3));
      expect(turns[0].speaker, ApaTurn.user);
      expect(turns[0].textBn, isNot(contains('482913')));
      expect(turns[1].tone, isNotNull, reason: 'the code warning');
      expect(turns[2].path, ApaTurn.gemini);
    });

    test('only a code: the warning, nothing sent', () async {
      final h = FnaLogicHarness();
      final c = h.container();
      final ctrl = controllerOf(c);
      await ctrl.openFor(screen: 'home');
      await ctrl.sendText('482913');
      expect(h.chat.requests, isEmpty);
      expect(stateOf(c).turns, hasLength(2));
      expect(stateOf(c).turns.last.tone, isNotNull);
    });
  });
}
