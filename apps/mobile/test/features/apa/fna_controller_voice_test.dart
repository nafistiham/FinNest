// ApaController voice mode: session events folded into ApaState,
// over the voice tests' fake transport, audio and timers.

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/logic/fna_voice_lines.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';
import 'fna_logic_fakes.dart';
import 'fna_ui_fakes.dart';
import 'voice/fna_live_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FnaLogicHarness h;
  late ProviderContainer c;

  ApaController ctrl() => c.read(apaControllerProvider.notifier);
  ApaState st() => c.read(apaControllerProvider);

  /// Voice mode open, set up and listening.
  Future<void> listening() async {
    await ctrl().openFor(screen: 'home');
    await ctrl().startVoice();
    await flush();
    h.live.setupComplete();
    await flush();
    expect(st().voicePhase, FnaPhase.listening);
  }

  /// One spoken exchange that finishes normally.
  Future<void> exchange(String user, String model) async {
    h.live.userSays(user, finished: true);
    await flush();
    h.live.modelSays(model);
    h.live.audioChunk();
    await flush();
    h.live.turnComplete();
    h.audioOut.emitDrained();
    await flush();
  }

  setUp(() {
    h = FnaLogicHarness();
    c = h.container();
  });

  test('startVoice: micPermission, connecting, then listening', () async {
    await ctrl().openFor(screen: 'home');
    final start = ctrl().startVoice();
    expect(st().voicePhase, FnaPhase.micPermission);
    await start;
    await flush();
    expect(st().voicePhase, FnaPhase.connecting);
    expect(st().inVoice, isTrue);
    h.live.setupComplete();
    await flush();
    expect(st().voicePhase, FnaPhase.listening);
    expect(h.audioIn.running, isTrue);
  });

  test(
    'captions follow the turn; a finished turn becomes two live bubbles',
    () async {
      await listening();
      h.live.userSays('ওটিপি চাইলে কী করব?', finished: true);
      await flush();
      expect(st().userCaption, 'ওটিপি চাইলে কী করব?');
      expect(st().voicePhase, FnaPhase.thinking);
      h.live.modelSays('কাউকে ওটিপি দেবেন না।');
      h.live.audioChunk();
      await flush();
      expect(st().modelCaption, 'কাউকে ওটিপি দেবেন না।');
      expect(st().voicePhase, FnaPhase.speaking);
      h.live.turnComplete();
      h.audioOut.emitDrained();
      await flush();
      final turns = st().turns;
      expect(turns.map((t) => (t.speaker, t.path)), [
        (ApaTurn.user, ApaTurn.live),
        (ApaTurn.apa, ApaTurn.live),
      ]);
      expect(turns.last.textBn, 'কাউকে ওটিপি দেবেন না।');
      // The finished turn stays readable until the customer speaks again.
      expect(st().userCaption, 'ওটিপি চাইলে কী করব?');
      expect(st().modelCaption, 'কাউকে ওটিপি দেবেন না।');
      expect(st().voicePhase, FnaPhase.listening);
    },
  );

  test('mic level reaches the state', () async {
    await listening();
    h.audioIn.level = 0.4;
    h.audioIn.push(Uint8List(640));
    await flush();
    expect(ctrl().micLevel.value, 0.4);
  });

  test('a heard code: warning bubble, secretBlocked, masked caption', () async {
    await listening();
    h.live.userSays('আমার কোড ১২৩৪৫৬');
    await flush();
    expect(st().secretBlocked, isTrue);
    expect(st().userCaption, isNot(contains('১২৩৪৫৬')));
    expect(
      st().turns.last.tone,
      isNotNull,
      reason: 'the secretRedacted bubble',
    );
    expect(st().turns.any((t) => t.textBn.contains('১২৩৪৫৬')), isFalse);
    // The session restarts clean on a new connection.
    h.live.setupComplete();
    await flush();
    h.live.userSays('ঠিক আছে');
    await flush();
    expect(st().secretBlocked, isFalse, reason: 'cleared by the next caption');
  });

  test('a blocked answer while money is held becomes the safe line', () async {
    c.read(lastScoreProvider.notifier).state = heldScore;
    await listening();
    h.live.userSays('টাকা কি পাঠাব?', finished: true);
    await flush();
    h.live.modelSays('হ্যাঁ, টাকা পাঠিয়ে দিন।');
    await flush();
    expect(st().modelCaption, FnaVoiceLines.safeLineBn);
    h.live.turnComplete();
    await flush();
    expect(st().turns.last.textBn, FnaVoiceLines.safeLineBn);
    expect(st().turns.any((t) => t.textBn.contains('পাঠিয়ে দিন')), isFalse);
  });

  test('mic denied: back to the chat with the fallback reason', () async {
    h.audioIn.granted = false;
    await ctrl().openFor(screen: 'home');
    await ctrl().startVoice();
    await flush();
    expect(st().voicePhase, isNull);
    expect(st().voiceFallback, FnaFallbackReason.micDenied);
    expect(st().error, ApaHint.micDenied);
  });

  test('no setup within 5 s: connectTimeout fallback', () async {
    await ctrl().openFor(screen: 'home');
    await ctrl().startVoice();
    await flush();
    h.timers.elapse(const Duration(seconds: 6));
    await flush();
    expect(st().voicePhase, isNull);
    expect(st().voiceFallback, FnaFallbackReason.connectTimeout);
  });

  test('endVoice closes the session; the voice turns stay', () async {
    await listening();
    await exchange('প্রশ্ন', 'উত্তর।');
    await ctrl().endVoice();
    await flush();
    expect(st().voicePhase, isNull);
    expect(h.live.closed, isTrue);
    expect(h.audioIn.running, isFalse);
    expect(st().turns, hasLength(2));
  });

  test('pause, resume, stop and app hidden reach the session', () async {
    await listening();
    await ctrl().pauseVoice();
    await flush();
    expect(st().voicePhase, FnaPhase.paused);
    await ctrl().resumeVoice();
    await flush();
    expect(st().voicePhase, FnaPhase.listening);

    h.live.modelSays('একটু শুনুন');
    h.live.audioChunk();
    await flush();
    expect(st().voicePhase, FnaPhase.speaking);
    await ctrl().stopSpeaking();
    await flush();
    expect(st().voicePhase, FnaPhase.listening);

    ctrl().onAppHidden();
    await flush();
    expect(st().voicePhase, FnaPhase.paused);
  });

  test('a late event of a closed voice mode is dropped', () async {
    await listening();
    final old = h.live;
    await ctrl().endVoice();
    await flush();
    old.userSays('দেরিতে', finished: true);
    await flush();
    expect(st().userCaption, isEmpty);
    expect(st().voicePhase, isNull);
  });

  test('show_hold_reason: mic closed and audio stopped, server text shown and '
      'spoken by the app, then listening again', () async {
    c.read(lastScoreProvider.notifier).state = heldScore;
    await listening();
    final micStops = h.audioIn.stops;
    final audioStops = h.audioOut.stops;
    h.live.userSays('টাকা কেন আটকাল?', finished: true);
    await flush();
    h.live.emit(
      const FnaToolCalls([FunctionCall(FnaToolNames.holdReason, {}, id: 'c1')]),
    );
    await flush();
    expect(h.audioIn.stops, greaterThan(micStops));
    expect(h.audioOut.stops, greaterThan(audioStops));
    final held = st().turns.where((t) => t.path == ApaTurn.held).single;
    expect(held.textBn, heldFirstLineBn);
    expect(h.apa.audio.spoken, contains(heldFirstLineBn));
    final response = h.live.toolResponses.single.single;
    expect(response.response['shown'], isTrue);
    // The mic is open again; the model's handoff to the tool comes next.
    expect(st().voicePhase, FnaPhase.thinking);
    expect(h.audioIn.running, isTrue);
  });

  test(
    'check_caller_words: the scam check runs and the card appears',
    () async {
      h.apa.api.scamTurnResponse = scamResponse;
      await listening();
      h.live.emit(
        const FnaToolCalls([
          FunctionCall(FnaToolNames.checkCaller, {
            'text': 'অ্যাকাউন্ট বন্ধ হবে, কোডটা বলুন',
          }, id: 'c2'),
        ]),
      );
      await flush();
      expect(st().callSummary?.evidenceQuote, scamResponse.evidenceQuote);
      expect(c.read(lastEvidenceQuoteProvider), scamResponse.evidenceQuote);
      final response = h.live.toolResponses.single.single.response;
      expect(response['checked'], isTrue);
      expect(response.containsKey('confidence'), isFalse);
    },
  );

  test(
    'typing in voice mode goes to the Live session, not the agent',
    () async {
      await listening();
      await ctrl().sendText('ওটিপি কী?');
      expect(h.live.texts, ['ওটিপি কী?']);
      expect(h.chat.requests, isEmpty);
    },
  );

  test(
    'a typed "why held" in voice mode is answered by the app, not Live',
    () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listening();
      await ctrl().sendText('টাকা কেন আটকাল?');
      await flush();
      expect(h.live.texts, isEmpty);
      expect(
        st().turns.where((t) => t.path == ApaTurn.held).single.textBn,
        heldFirstLineBn,
      );
      expect(h.apa.audio.spoken, contains(heldFirstLineBn));
      expect(st().voicePhase, FnaPhase.listening);
    },
  );

  test('micPermanentlyDenied asks the mic port', () async {
    h.audioIn.deniedForGood = true;
    expect(await ctrl().micPermanentlyDenied(), isTrue);
  });

  test('closing the sheet ends voice mode', () async {
    await listening();
    await ctrl().close();
    await flush();
    expect(st().voicePhase, isNull);
    expect(h.live.closed, isTrue);
  });

  group('review fixes', () {
    /// Voice mode listening, with lines spoken over it awaited for real.
    Future<void> listeningLong() async {
      h.lineMaxWait = const Duration(seconds: 60);
      await listening();
    }

    void holdTool() => h.live.emit(
      const FnaToolCalls([FunctionCall(FnaToolNames.holdReason, {}, id: 'h1')]),
    );

    test('chips in voice mode go to Live in the app language, nothing '
        'hidden in the chat', () async {
      await listening();
      final before = st().turns.length;
      await ctrl().askPhoneSafe();
      await ctrl().showRules();
      await ctrl().askQuestion('সিম সোয়াপ কী?');
      expect(h.live.texts, hasLength(3));
      expect(h.live.texts.last, 'সিম সোয়াপ কী?');
      expect(h.chat.requests, isEmpty, reason: 'not the chat agent');
      expect(st().turns, hasLength(before), reason: 'no hidden bubbles');
    });

    test('the code chip in voice mode asks Live and never arms the typed '
        'scam check', () async {
      await listening();
      await ctrl().startScamCheck();
      expect(h.live.texts, [FnaVoiceLines.codeAskedBn]);
      expect(st().scamCheck, isFalse);
    });

    test('the code chip in English voice mode asks in English', () async {
      c = h.container(
        extra: [
          apaSnapshotProvider.overrideWithValue(
            const ApaContextSnapshot(locale: 'en'),
          ),
        ],
      );
      await listening();
      await ctrl().startScamCheck();
      expect(h.live.texts, [FnaVoiceLines.codeAskedEn]);
    });

    test('the why-held chip in voice mode: the server text spoken by the '
        'app, then the handoff; Live never gets it', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listening();
      await ctrl().askWhyHeld();
      await flush();
      expect(h.live.texts, isEmpty);
      expect(h.apa.audio.spoken, contains(heldFirstLineBn));
      expect(st().turns.last.textBn, FnaLines.holdHandoffBn);
      expect(st().voicePhase, FnaPhase.listening);
    });

    test('the held line waits for the real end of playback; the mic stays '
        'closed meanwhile', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listeningLong();
      holdTool();
      await flush();
      expect(h.apa.audio.spoken, contains(heldFirstLineBn));
      expect(st().voicePhase, FnaPhase.speaking);
      expect(h.audioIn.running, isFalse, reason: 'mic closed while it plays');
      expect(h.live.toolResponses, isEmpty, reason: 'still playing');
      // Resume is refused while the line plays.
      await ctrl().resumeVoice();
      await flush();
      expect(h.audioIn.running, isFalse);

      h.apa.audio.finish();
      await flush();
      expect(h.live.toolResponses, hasLength(1));
      // The mic is open again; the model's handoff to the tool comes next.
      expect(st().voicePhase, FnaPhase.thinking);
      expect(h.audioIn.running, isTrue);
    });

    test('a held line that never ends: the player is stopped before the mic '
        'opens', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      h.lineMaxWait = const Duration(milliseconds: 20);
      await listening();
      holdTool();
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await flush();
      expect(h.apa.audio.isPlaying, isFalse, reason: 'stopped on timeout');
      // The mic is open again; the model's handoff to the tool comes next.
      expect(st().voicePhase, FnaPhase.thinking);
    });

    test(
      'Stop during the held line stops it and listens again',
      () async {
        c.read(lastScoreProvider.notifier).state = heldScore;
        await listeningLong();
        holdTool();
        await flush();
        expect(st().voicePhase, FnaPhase.speaking);
        final stops = h.apa.audio.stopCalls;
        await ctrl().stopSpeaking();
        await flush();
        expect(h.apa.audio.stopCalls, greaterThan(stops));
        expect(h.apa.audio.isPlaying, isFalse);
        // The mic is open again; the model's handoff to the tool comes next.
        expect(st().voicePhase, FnaPhase.thinking);
        expect(h.live.toolResponses, hasLength(1));
      },
    );

    test('End during a line spoken over voice stops it', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listeningLong();
      holdTool();
      await flush();
      expect(h.apa.audio.isPlaying, isTrue);
      await ctrl().endVoice();
      await flush();
      expect(h.apa.audio.isPlaying, isFalse);
      expect(st().voicePhase, isNull);
      expect(h.audioIn.running, isFalse);
    });

    test('End stops the greeting too', () async {
      await listening();
      // The greeting is still playing on the app's player.
      await h.apa.audio.speak(FnaVoiceLines.greetingFirstBn);
      final stops = h.apa.audio.stopCalls;
      await ctrl().endVoice();
      expect(h.apa.audio.stopCalls, greaterThan(stops));
      expect(h.apa.audio.isPlaying, isFalse);
    });

    test('a line over a session the customer paused leaves it paused', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listening();
      await ctrl().pauseVoice();
      await flush();
      expect(st().voicePhase, FnaPhase.paused);
      await ctrl().showHoldReason();
      await flush();
      expect(st().voicePhase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
    });

    test('Hear it during the held line: the mic stays closed until both '
        'end, then it listens; never left paused', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listeningLong();
      holdTool();
      await flush();
      expect(st().voicePhase, FnaPhase.speaking);
      final turn = st().turns.last;
      // Hear it cancels the held line's wait: the outer line ends first.
      final hearing = ctrl().hearIt(turn);
      await flush();
      expect(h.audioIn.running, isFalse, reason: 'Hear it still plays');
      expect(st().voicePhase, FnaPhase.speaking);
      final session = h.sessions.single;
      expect(session.pausedByCustomer, isFalse);

      h.apa.audio.finish();
      await hearing;
      await flush();
      expect(session.pausedByCustomer, isFalse);
      expect(session.phase, isNot(FnaPhase.paused));
      expect(st().voicePhase, anyOf(FnaPhase.listening, FnaPhase.thinking));
      expect(h.audioIn.running, isTrue);
    });

    test('Pause pressed during the line keeps the session paused', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listeningLong();
      holdTool();
      await flush();
      await ctrl().pauseVoice();
      h.apa.audio.finish();
      await flush();
      expect(st().voicePhase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
    });

    test('a hidden app is not reopened by a line; onAppVisible allows it '
        'again', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listeningLong();
      holdTool();
      await flush();
      ctrl().onAppHidden();
      h.apa.audio.finish();
      await flush();
      expect(h.audioIn.running, isFalse, reason: 'hidden: stays paused');

      ctrl().onAppVisible();
      await ctrl().resumeVoice();
      await flush();
      h.live.setupComplete();
      await flush();
      expect(st().voicePhase, FnaPhase.listening);
      h.live.emit(
        const FnaToolCalls([
          FunctionCall(FnaToolNames.holdReason, {}, id: 'h2'),
        ]),
      );
      await flush();
      h.apa.audio.finish();
      await flush();
      // The mic is open again; the model's handoff to the tool comes next.
      expect(st().voicePhase, FnaPhase.thinking);
      expect(h.audioIn.running, isTrue);
    });

    test('a typed "why held" in voice mode: closing the sheet during the '
        'line adds no handoff', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listeningLong();
      final typed = ctrl().sendText('টাকা কেন আটকাল?');
      await flush();
      await ctrl().close();
      await typed;
      await flush();
      expect(
        st().turns.where((t) => t.textBn == FnaLines.holdHandoffBn),
        isEmpty,
      );
    });

    test(
      'micLevel is a notifier; the state does not rebuild per level',
      () async {
        await listening();
        var rebuilds = 0;
        c.listen(apaControllerProvider, (_, _) => rebuilds++);
        var heard = 0;
        void onLevel() => heard++;
        ctrl().micLevel.addListener(onLevel);
        h.audioIn.level = 0.7;
        h.audioIn.push(Uint8List(640));
        await flush();
        expect(ctrl().micLevel.value, 0.7);
        expect(heard, greaterThan(0));
        expect(rebuilds, 0);
        ctrl().micLevel.removeListener(onLevel);
        await ctrl().endVoice();
        expect(ctrl().micLevel.value, 0);
      },
    );

    test('tapToTalk reaches the session config', () async {
      await ctrl().openFor(screen: 'home');
      await ctrl().startVoice(tapToTalk: true);
      expect(h.tapToTalkFlags, [true]);
      expect(ctrl().tapToTalk, isTrue);
    });

    test('a code heard in voice mode shows the spoken-code warning', () async {
      await listening();
      h.live.userSays('আমার কোড ১২৩৪৫৬');
      await flush();
      expect(st().turns.last.textBn, contains('কোডের মতো নম্বর'));
    });
  });

  group('second review round', () {
    void holdTool([String id = 'h1']) => h.live.emit(
      FnaToolCalls([FunctionCall(FnaToolNames.holdReason, {}, id: id)]),
    );

    test('a held line of 20 s: the tool response goes on the same '
        'transport and the handoff is spoken', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      h.lineMaxWait = const Duration(seconds: 60);
      await listening();
      holdTool();
      await flush();
      expect(st().voicePhase, FnaPhase.speaking);
      h.timers.elapse(const Duration(seconds: 20));
      await flush();
      expect(h.live.closed, isFalse);

      h.apa.audio.finish();
      await flush();
      expect(h.transports.made, hasLength(1));
      expect(h.live.toolResponses.single.single.id, 'h1');
      final played = h.audioOut.played.length;
      h.live.modelSays(FnaLines.holdHandoffBn);
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played.length, played + 1);
      expect(st().voicePhase, FnaPhase.speaking);
      expect(st().modelCaption, FnaLines.holdHandoffBn);
    });

    test('voice mode that ended while hidden: the next one reopens the mic '
        'after a line', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await listening();
      ctrl().onAppHidden();
      await ctrl().endVoice();
      await flush();
      // No onAppVisible: the view was gone.
      await ctrl().startVoice();
      await flush();
      h.live.setupComplete();
      await flush();
      holdTool('h2');
      await flush();
      expect(h.audioIn.running, isTrue);
      expect(st().voicePhase, isNot(FnaPhase.paused));
    });

    test('a line during the opening leaves no pause behind', () async {
      c.read(lastScoreProvider.notifier).state = heldScore;
      await ctrl().openFor(screen: 'home');
      await ctrl().startVoice();
      await flush();
      expect(st().voicePhase, FnaPhase.connecting);
      await ctrl().showHoldReason();
      await flush();
      h.live.setupComplete();
      await flush();
      expect(st().voicePhase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('a chip during the greeting waits for it and goes to Live, not the '
        'chat agent', () async {
      final greeting = Completer<void>();
      h.greet = () => greeting.future;
      await ctrl().openFor(screen: 'home');
      await ctrl().startVoice();
      await flush();
      h.live.setupComplete();
      await flush();
      final asked = ctrl().askQuestion('ওটিপি কী?');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await flush();
      expect(h.live.texts, isEmpty, reason: 'still greeting');
      greeting.complete();
      await asked;
      await flush();
      expect(h.live.texts, ['ওটিপি কী?']);
      expect(h.chat.requests, isEmpty);
    });

    test('a chip while voice mode fails to open goes to the chat at once', () async {
      final greeting = Completer<void>();
      h.greet = () => greeting.future;
      await ctrl().openFor(screen: 'home');
      await ctrl().startVoice();
      await flush();
      final asked = ctrl().askQuestion('ওটিপি কী?');
      await flush();
      h.timers.elapse(const Duration(seconds: 6)); // the setup timeout
      await flush();
      await asked.timeout(const Duration(seconds: 2));
      expect(h.chat.requests, hasLength(1));
      greeting.complete();
    });

    testWidgets('a route pushed over voice mode pauses it; popping it says '
        'visible again', (tester) async {
      final scripted = ScriptedApaController(
        const ApaState().copyWith(voicePhase: FnaPhase.listening),
      );
      await tester.pumpWidget(fnaApp(scripted));
      await tester.pump();
      final view = find.byKey(const Key('fna_voice_view'));
      expect(view, findsOneWidget);
      unawaited(
        Navigator.of(tester.element(view))
            .push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const Key('fna_voice_view'), skipOffstage: false),
        findsOneWidget,
        reason: 'still mounted under the new route',
      );
      expect(scripted.calls, contains('onAppHidden'));
      Navigator.of(
        tester.element(
          find.byKey(const Key('fna_voice_view'), skipOffstage: false),
        ),
      ).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(scripted.calls.where((c) => c == 'onAppHidden'), hasLength(1));
      expect(scripted.calls.last, 'onAppVisible');
    });
  });
}
