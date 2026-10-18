// FnaVoiceSession: every row of the spec's state table (section 06), driven
// by a fake transport, fake audio and manual timers.

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fna_audio_fakes.dart';
import 'fna_live_fakes.dart';

class _Harness {
  _Harness({
    FnaVoiceConfig config = const FnaVoiceConfig(),
    bool withGreeting = false,
    Future<FnaCallSummary?> Function(String)? checkCaller,
    Future<void> Function()? showHold,
    this.isOnlineAnswer = true,
  }) {
    tools = FnaTools(
      knowledge: () => null,
      snapshot: () => const ApaContextSnapshot(),
      lastCallSummary: () => null,
      checkCallerWords: checkCaller ?? (_) async => null,
      showHoldReason: showHold ?? () async {},
      now: timers.now,
    );
    if (withGreeting) greeting = Completer<void>();
    session = FnaVoiceSession(
      transportFactory: factory.call,
      audioIn: audioIn,
      audioOut: audioOut,
      tools: tools,
      config: config,
      context: () => '{"app_language":"Bangla"}',
      held: () => held,
      greet: withGreeting ? () => greeting!.future : null,
      isOnline: () async => isOnlineAnswer,
      timer: timers.call,
      now: timers.now,
    );
    session.events.listen(events.add);
  }

  final timers = FakeTimers();
  final factory = FakeTransportFactory();
  final audioIn = FakeFnaAudioIn();
  final audioOut = FakeFnaAudioOut();
  final events = <FnaSessionEvent>[];
  late final FnaTools tools;
  late final FnaVoiceSession session;
  Completer<void>? greeting;
  bool held = false;
  bool isOnlineAnswer;

  FakeFnaLiveTransport get live => factory.last;

  List<T> of<T extends FnaSessionEvent>() => events.whereType<T>().toList();

  List<FnaPhase> get phases => [for (final e in of<FnaPhaseChanged>()) e.phase];

  /// Started, set up and listening.
  Future<void> startListening() async {
    await session.start();
    await flush();
    live.setupComplete();
    await flush();
    expect(session.phase, FnaPhase.listening);
  }

  Future<void> mic({double level = 0.2, int bytes = 640}) async {
    audioIn.level = level;
    audioIn.push(Uint8List(bytes));
    await flush();
  }
}

void main() {
  group('start', () {
    test('mic denied goes to text with micDenied', () async {
      final h = _Harness();
      h.audioIn.granted = false;
      await h.session.start();
      await flush();
      expect(h.phases, [FnaPhase.micPermission, FnaPhase.textFallback]);
      expect(h.of<FnaFallback>().single.reason, FnaFallbackReason.micDenied);
      expect(h.factory.made, isEmpty);
    });

    test('mic denied for good says so (Open settings)', () async {
      final h = _Harness();
      h.audioIn
        ..granted = false
        ..deniedForGood = true;
      await h.session.start();
      expect(
        h.of<FnaFallback>().single.reason,
        FnaFallbackReason.micPermanentlyDenied,
      );
    });

    test(
      'granted: connecting, then listening only after setupComplete',
      () async {
        final h = _Harness();
        await h.session.start();
        await flush();
        expect(h.session.phase, FnaPhase.connecting);
        expect(h.audioOut.enters, 1);
        expect(h.live.connectCalled, isTrue);
        expect(h.live.resumeHandle, isNull);
        // connect() returned, but the mic stays closed until setup completes.
        expect(h.audioIn.running, isFalse);
        h.live.setupComplete();
        await flush();
        expect(h.session.phase, FnaPhase.listening);
        expect(h.audioIn.running, isTrue);
        expect(h.live.contexts, ['{"app_language":"Bangla"}']);
        expect(h.phases, [
          FnaPhase.micPermission,
          FnaPhase.connecting,
          FnaPhase.listening,
        ]);
      },
    );

    test('the mic opens only after the greeting finished', () async {
      final h = _Harness(withGreeting: true);
      await h.session.start();
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.connecting);
      expect(h.audioIn.running, isFalse);
      h.greeting!.complete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('no setup in 5 s: connectTimeout fallback and teardown', () async {
      final h = _Harness();
      await h.session.start();
      h.timers.elapse(const Duration(seconds: 5));
      await flush();
      expect(
        h.of<FnaFallback>().single.reason,
        FnaFallbackReason.connectTimeout,
      );
      expect(h.session.phase, FnaPhase.textFallback);
      expect(h.live.closed, isTrue);
      expect(h.audioOut.exits, 1);
    });

    test('no setup and no network: offline', () async {
      final h = _Harness(isOnlineAnswer: false);
      await h.session.start();
      h.timers.elapse(const Duration(seconds: 5));
      await flush();
      expect(h.of<FnaFallback>().single.reason, FnaFallbackReason.offline);
      expect(h.session.phase, FnaPhase.offline);
    });

    test('connection error before setup: liveFailed', () async {
      final h = _Harness();
      await h.session.start();
      h.live
        ..emit(FnaLiveError(StateError('x')))
        ..serverClose();
      await flush();
      expect(h.of<FnaFallback>().single.reason, FnaFallbackReason.liveFailed);
    });
  });

  group('one turn', () {
    test('listening, thinking, speaking, then listening after drain', () async {
      final h = _Harness();
      await h.startListening();
      await h.mic();
      expect(h.live.audio, hasLength(1));
      expect(h.of<FnaLevel>().last.level, 0.2);

      h.live.userSays('ওটিপি ');
      h.live.userSays('চাইছে', finished: true);
      await flush();
      expect(h.of<FnaUserCaption>().last.text, 'ওটিপি চাইছে');
      expect(h.session.phase, FnaPhase.thinking);

      h.live.audioChunk(48000);
      h.live.modelSays('কল কেটে দিন।');
      await flush();
      expect(h.session.phase, FnaPhase.speaking);
      expect(h.audioOut.played, hasLength(1));
      expect(h.audioOut.playedRates.single, 24000);
      expect(h.of<FnaModelCaption>().last.text, 'কল কেটে দিন।');

      h.live.turnComplete();
      await flush();
      final done = h.of<FnaTurnFinished>().single;
      expect(done.turnId, 0);
      expect(done.userText, 'ওটিপি চাইছে');
      expect(done.modelText, 'কল কেটে দিন।');
      expect(done.interrupted, isFalse);
      // Still speaking until the player has played it all.
      expect(h.session.phase, FnaPhase.speaking);
      h.audioOut.emitDrained();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.session.turnId, 1);
    });

    test('drain fallback: 48000 bytes per second plus 300 ms', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..audioChunk(48000)
        ..turnComplete();
      await flush();
      h.timers.elapse(const Duration(milliseconds: 1200));
      expect(h.session.phase, FnaPhase.speaking);
      h.timers.elapse(const Duration(milliseconds: 150));
      expect(h.session.phase, FnaPhase.listening);
    });

    test('a turn with no audio and no tool goes back to listening', () async {
      final h = _Harness();
      await h.startListening();
      h.live.userSays('হ্যালো', finished: true);
      await flush();
      h.live.turnComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.of<FnaTurnFinished>().single.userText, 'হ্যালো');
    });

    test('thinking with no answer for 15 s: listening again', () async {
      final h = _Harness();
      await h.startListening();
      h.live.userSays('কী', finished: true);
      await flush();
      expect(h.session.phase, FnaPhase.thinking);
      h.timers.elapse(const Duration(seconds: 15));
      expect(h.session.phase, FnaPhase.listening);
    });
  });

  group('tools', () {
    test('one tool turn: answered with matching id, stays thinking', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(
        const FnaToolCalls([FunctionCall(FnaToolNames.status, {}, id: 'c1')]),
      );
      await flush();
      expect(h.session.phase, FnaPhase.thinking);
      expect(h.of<FnaToolEvent>().single.name, FnaToolNames.status);
      final sent = h.live.toolResponses.single;
      expect(sent.single.id, 'c1');
      expect(sent.single.name, FnaToolNames.status);
      expect(sent.single.response, contains('held_count'));

      // The turn that only held the tool call completes: keep thinking.
      h.live.turnComplete();
      await flush();
      expect(h.session.phase, FnaPhase.thinking);
      expect(h.of<FnaTurnFinished>(), isEmpty);

      h.live
        ..audioChunk()
        ..turnComplete();
      await flush();
      expect(h.session.phase, FnaPhase.speaking);
      expect(h.of<FnaTurnFinished>(), hasLength(1));
    });

    test('several calls run together and go back in one message', () async {
      final caller = Completer<FnaCallSummary?>();
      final h = _Harness(checkCaller: (_) => caller.future);
      await h.startListening();
      h.live.emit(
        const FnaToolCalls([
          FunctionCall(FnaToolNames.checkCaller, {'text': 'কোড দিন'}, id: 'a'),
          FunctionCall(FnaToolNames.callSummary, {}, id: 'b'),
        ]),
      );
      await flush();
      expect(h.live.toolResponses, isEmpty);
      caller.complete(null);
      await flush();
      final ids = [for (final r in h.live.toolResponses.single) r.id];
      expect(ids, ['a', 'b']);
    });

    test('a cancelled call gets no late response', () async {
      final caller = Completer<FnaCallSummary?>();
      final h = _Harness(checkCaller: (_) => caller.future);
      await h.startListening();
      h.live.emit(
        const FnaToolCalls([
          FunctionCall(FnaToolNames.checkCaller, {'text': 'x'}, id: 'a'),
        ]),
      );
      await flush();
      h.live.emit(const FnaToolCallCancelled(['a']));
      await flush();
      final cancelled = h.of<FnaToolEvent>().last;
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.name, FnaToolNames.checkCaller);
      caller.complete(null);
      await flush();
      expect(h.live.toolResponses, isEmpty);
    });

    test('a tool result of an ended connection is dropped', () async {
      final caller = Completer<FnaCallSummary?>();
      final h = _Harness(checkCaller: (_) => caller.future);
      await h.startListening();
      final first = h.live;
      first.emit(
        const FnaToolCalls([
          FunctionCall(FnaToolNames.checkCaller, {'text': 'x'}, id: 'a'),
        ]),
      );
      await flush();
      first.emit(const FnaGoAway(Duration(seconds: 5)));
      await flush();
      caller.complete(null);
      await flush();
      expect(first.toolResponses, isEmpty);
      expect(h.live.toolResponses, isEmpty);
    });
  });

  group('interruptions', () {
    test('interrupted: stop at once, new turn, old audio dropped', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..userSays('প্রশ্ন', finished: true)
        ..audioChunk()
        ..modelSays('উত্তর');
      await flush();
      expect(h.session.phase, FnaPhase.speaking);
      final stopsBefore = h.audioOut.stops;

      h.live.emit(const FnaInterrupted());
      await flush();
      expect(h.audioOut.stops, stopsBefore + 1);
      expect(h.session.phase, FnaPhase.listening);
      expect(h.session.turnId, 1);
      final done = h.of<FnaTurnFinished>().single;
      expect(done.interrupted, isTrue);
      expect(done.modelText, 'উত্তর');

      // A chunk right after the interruption is the old turn's: dropped.
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played, hasLength(1));
      // After the grace window a new answer plays.
      h.timers.elapse(const Duration(milliseconds: 300));
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played, hasLength(2));
    });

    test(
      'the customer\'s words after FNA began belong to the next turn',
      () async {
        final h = _Harness();
        await h.startListening();
        h.live
          ..userSays('এক প্রশ্ন', finished: true)
          ..audioChunk()
          ..userSays('থামুন');
        await flush();
        final caption = h.of<FnaUserCaption>().last;
        expect(caption.turnId, 1);
        expect(caption.text, 'থামুন');
        h.live.emit(const FnaInterrupted());
        await flush();
        expect(h.of<FnaTurnFinished>().single.userText, 'এক প্রশ্ন');
      },
    );

    test('Stop: silence now and drop the rest of that answer', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('অনেক কথা');
      await flush();
      await h.session.stopSpeaking();
      expect(h.session.phase, FnaPhase.listening);
      h.live
        ..audioChunk()
        ..modelSays(' আরও');
      await flush();
      expect(h.audioOut.played, hasLength(1));
      h.live.turnComplete();
      await flush();
      // The next answer plays again.
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played, hasLength(2));
    });
  });

  group('guard', () {
    test('a spoken code ends the connection and starts a clean one', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaResumptionHandle('h1', resumable: true));
      final first = h.live;
      final epoch = h.session.epoch;
      first.userSays('আমার কোড ১২৩');
      first.userSays('৪');
      await flush();
      final blocked = h.of<FnaSecretBlocked>().single;
      expect(blocked.maskedText, 'আমার কোড ••••');
      // The unmasked four digits never reached a caption.
      expect(
        h.of<FnaUserCaption>().any((c) => c.text.contains('১২৩৪')),
        isFalse,
      );
      expect(first.closed, isTrue);
      expect(h.factory.made, hasLength(2));
      expect(h.live.resumeHandle, isNull, reason: 'handle discarded');
      expect(h.session.epoch, epoch + 1);
      expect(h.session.phase, FnaPhase.connecting);
      expect(h.audioIn.running, isFalse);
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
      expect(h.live.contexts, hasLength(1));
    });

    test(
      '"send it" while money is held stops audio and blocks the turn',
      () async {
        final h = _Harness()..held = true;
        await h.startListening();
        h.live
          ..userSays('কী করব', finished: true)
          ..audioChunk()
          ..modelSays('টাকা পাঠিয়ে দিন।');
        await flush();
        final blocked = h.of<FnaModelBlocked>().single;
        expect(blocked.reason, GuardVerdict.proceedWhileHeld);
        expect(h.audioOut.stops, greaterThan(0));
        expect(
          h.of<FnaModelCaption>().any((c) => c.text.contains('পাঠিয়ে')),
          isFalse,
        );
        expect(h.session.phase, FnaPhase.listening);
        h.live
          ..audioChunk()
          ..turnComplete();
        await flush();
        expect(h.audioOut.played, hasLength(1));
        expect(h.of<FnaTurnFinished>().single.blocked, isTrue);
      },
    );

    test('send wording is blocked even with nothing held (guardrail)', () async {
      // FNA never tells anyone to send, release or approve money, held or not.
      final h = _Harness();
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('টাকা পাঠিয়ে দিন।');
      await flush();
      expect(h.of<FnaModelBlocked>(), hasLength(1));
    });

    test('a negation in the next chunk: "পাঠাবেন" + " না" is not blocked', () async {
      final h = _Harness()..held = true;
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('যাচাই না করে টাকা পাঠাবেন');
      await flush();
      expect(h.of<FnaModelBlocked>(), isEmpty);
      h.live.modelSays(' না।');
      await flush();
      h.live.turnComplete();
      await flush();
      expect(h.of<FnaModelBlocked>(), isEmpty);
      expect(h.of<FnaTurnFinished>().single.blocked, isFalse);
    });

    test('a negation in the next chunk: "পিন বলবেন" + " না" is not blocked', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('কাউকে আপনার পিন বলবেন');
      await flush();
      expect(h.of<FnaModelBlocked>(), isEmpty);
      h.live
        ..modelSays(' না।')
        ..turnComplete();
      await flush();
      expect(h.of<FnaModelBlocked>(), isEmpty);
      expect(h.of<FnaTurnFinished>().single.blocked, isFalse);
    });

    test('"টাকা পাঠিয়ে দিন।" in chunks is blocked', () async {
      final h = _Harness()..held = true;
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('টাকা পাঠিয়ে')
        ..modelSays(' দিন।');
      await flush();
      expect(
        h.of<FnaModelBlocked>().single.reason,
        GuardVerdict.proceedWhileHeld,
      );
    });

    test('an open last word never negated: blocked at the turn end', () async {
      final h = _Harness()..held = true;
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('যাচাই না করে টাকা পাঠাবেন');
      await flush();
      expect(h.of<FnaModelBlocked>(), isEmpty);
      h.live.turnComplete();
      await flush();
      expect(
        h.of<FnaModelBlocked>().single.reason,
        GuardVerdict.proceedWhileHeld,
      );
      expect(h.of<FnaTurnFinished>().single.blocked, isTrue);
      expect(h.audioOut.stops, greaterThan(0));
    });

    test('ordinary advice with nothing held passes', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..audioChunk()
        ..modelSays('কল কেটে দিন এবং হেল্পলাইনে ফোন করুন।');
      await flush();
      expect(h.of<FnaModelBlocked>(), isEmpty);
    });
  });

  group('half duplex', () {
    test('the mic sends nothing while FNA speaks', () async {
      final h = _Harness(config: const FnaVoiceConfig(halfDuplex: true));
      await h.startListening();
      await h.mic();
      h.live.audioChunk();
      await flush();
      await h.mic();
      expect(h.live.audio, hasLength(1));
      h.live.turnComplete();
      h.audioOut.emitDrained();
      await flush();
      await h.mic();
      expect(h.live.audio, hasLength(2));
    });

    test('room noise cannot cancel an answer (device test)', () async {
      final h = _Harness(config: const FnaVoiceConfig(halfDuplex: true));
      await h.startListening();
      h.live
        ..userSays('ওটিপি কী?', finished: true)
        ..audioChunk()
        ..emit(const FnaInterrupted());
      await flush();
      expect(h.session.phase, FnaPhase.speaking);
      expect(h.audioOut.stops, 0, reason: 'the server interruption is ignored');
      await h.mic();
      expect(h.live.audio, isEmpty, reason: 'no audio while FNA speaks');
    });

    test('full duplex keeps sending (barge-in)', () async {
      final h = _Harness();
      await h.startListening();
      h.live.audioChunk();
      await flush();
      await h.mic();
      expect(h.live.audio, hasLength(1));
    });
  });

  group('pause and lifecycle', () {
    test('pause and resume', () async {
      final h = _Harness();
      await h.startListening();
      await h.session.pause();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
      await h.session.resume();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('app hidden while speaking: paused, player stopped', () async {
      final h = _Harness();
      await h.startListening();
      h.live.audioChunk();
      await flush();
      await h.session.onAppHidden();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioOut.stops, greaterThan(0));
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played, hasLength(1));
    });

    test('30 s of silence pauses; a voice level resets the timer', () async {
      final h = _Harness();
      await h.startListening();
      h.timers.elapse(const Duration(seconds: 20));
      await h.mic(level: 0.3);
      h.timers.elapse(const Duration(seconds: 20));
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      await h.mic(level: 0.0);
      h.timers.elapse(const Duration(seconds: 10));
      await flush();
      expect(h.session.phase, FnaPhase.paused);
    });

    test('hidden while connecting: paused and closed once set up', () async {
      final h = _Harness();
      await h.session.start();
      await h.session.onAppHidden();
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
      expect(h.live.closed, isTrue, reason: 'Live bills while open');
      expect(h.audioOut.inSession, isFalse);
      await h.session.resume();
      await flush();
      expect(h.factory.made, hasLength(2));
      expect(h.audioOut.inSession, isTrue);
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('closed while paused: reconnect on resume, with the handle', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaResumptionHandle('h2', resumable: true));
      await h.session.pause();
      h.live.serverClose();
      await flush();
      expect(h.factory.made, hasLength(1));
      await h.session.resume();
      await flush();
      expect(h.factory.made, hasLength(2));
      expect(h.live.resumeHandle, 'h2');
      expect(h.session.phase, FnaPhase.reconnecting);
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
    });

    test('10 minutes: ended and torn down', () async {
      final h = _Harness();
      await h.startListening();
      h.timers.elapse(const Duration(minutes: 10));
      await flush();
      expect(h.session.phase, FnaPhase.ended);
      expect(h.live.closed, isTrue);
      expect(h.audioOut.exits, 1);
      expect(h.audioIn.running, isFalse);
    });

    test('end is idempotent and releases everything', () async {
      final h = _Harness();
      await h.startListening();
      await h.session.end();
      await h.session.end();
      expect(h.session.phase, FnaPhase.ended);
      expect(h.phases.where((p) => p == FnaPhase.ended), hasLength(1));
      expect(h.audioOut.exits, 1);
      expect(h.live.closed, isTrue);
      expect(h.audioIn.running, isFalse);
    });
  });

  group('reconnect', () {
    test('going away: a new connect with the last resumable handle', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..emit(const FnaResumptionHandle('old', resumable: true))
        ..emit(const FnaResumptionHandle('', resumable: false))
        ..emit(const FnaResumptionHandle('h3', resumable: true))
        ..emit(const FnaGoAway(Duration(seconds: 10)));
      await flush();
      expect(h.session.phase, FnaPhase.reconnecting);
      expect(h.factory.made, hasLength(2));
      expect(h.factory.made.first.closed, isTrue);
      expect(h.live.resumeHandle, 'h3');
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.live.contexts, isEmpty, reason: 'a resumed session keeps it');
    });

    test('events of the old connection are dropped', () async {
      final h = _Harness();
      await h.startListening();
      final old = h.live;
      old.emit(const FnaGoAway(null));
      await flush();
      old
        ..audioChunk()
        ..userSays('পুরনো');
      await flush();
      expect(h.audioOut.played, isEmpty);
      expect(h.of<FnaUserCaption>(), isEmpty);
    });

    test(
      'error frame then close: resume once; a second failure goes to text',
      () async {
        final h = _Harness();
        await h.startListening();
        h.live
          ..emit(FnaLiveError(StateError('frame')))
          ..serverClose();
        await flush();
        expect(h.session.phase, FnaPhase.reconnecting);
        expect(h.factory.made, hasLength(2));
        h.live.serverClose();
        await flush();
        expect(h.of<FnaFallback>().single.reason, FnaFallbackReason.liveFailed);
        expect(h.session.phase, FnaPhase.textFallback);
        expect(h.factory.made, hasLength(2));
      },
    );

    test('a resume that never sets up fails after 5 s', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaGoAway(null));
      await flush();
      h.timers.elapse(const Duration(seconds: 5));
      await flush();
      expect(h.of<FnaFallback>().single.reason, FnaFallbackReason.liveFailed);
    });
  });

  group('typed lines', () {
    test('masked before they leave the phone, then thinking', () async {
      final h = _Harness();
      await h.startListening();
      final ok = await h.session.sendText('আমার ওটিপি ৪৪৫৫৬৬');
      expect(ok, isTrue);
      expect(h.live.texts.single, 'আমার ওটিপি ••••');
      expect(h.of<FnaUserCaption>().last.text, 'আমার ওটিপি ••••');
      expect(h.of<FnaUserCaption>().last.isFinal, isTrue);
      expect(h.session.phase, FnaPhase.thinking);
    });

    test('refused before setup', () async {
      final h = _Harness();
      await h.session.start();
      expect(await h.session.sendText('হ্যালো'), isFalse);
    });
  });

  group('review fixes', () {
    final digit = RegExp('[0-9০-৯]');

    test('a code in three pieces: one warning, one new connection', () async {
      final h = _Harness();
      await h.startListening();
      final first = h.live;
      first
        ..userSays('কোড ১২')
        ..userSays('৩৪')
        ..userSays('৫৬');
      await flush();
      expect(h.of<FnaSecretBlocked>(), hasLength(1));
      expect(h.factory.made, hasLength(2));
      expect(first.closed, isTrue);
      expect(h.session.phase, FnaPhase.connecting);
      expect(h.of<FnaUserCaption>().single.text, 'কোড ••');
      expect(
        h.of<FnaUserCaption>().any((c) => c.text.contains(digit)),
        isFalse,
      );
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.factory.made, hasLength(2));
    });

    test('going away, then the close: one new connection', () async {
      final h = _Harness();
      await h.startListening();
      final first = h.live;
      first
        ..emit(const FnaGoAway(Duration(seconds: 5)))
        ..serverClose();
      await flush();
      expect(h.factory.made, hasLength(2));
      expect(h.of<FnaFallback>(), isEmpty);
      expect(h.session.phase, FnaPhase.reconnecting);
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
    });

    test('two going-away notices at once: one new connection', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..emit(const FnaGoAway(null))
        ..emit(const FnaGoAway(null));
      await flush();
      expect(h.factory.made, hasLength(2));
      expect(h.of<FnaFallback>(), isEmpty);
    });

    test('going away while paused: closes, mic stays shut', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaResumptionHandle('hp', resumable: true));
      final first = h.live;
      await h.session.pause();
      first.emit(const FnaGoAway(null));
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
      expect(first.closed, isTrue);
      expect(h.factory.made, hasLength(1));
      await h.session.resume();
      await flush();
      expect(h.factory.made, hasLength(2));
      expect(h.live.resumeHandle, 'hp');
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('pause while asking for the mic: paused once set up', () async {
      final h = _Harness();
      final starting = h.session.start();
      await h.session.pause();
      await starting;
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
    });

    test('pause while the mic is starting: the mic ends closed', () async {
      final h = _Harness();
      final gate = Completer<void>();
      h.audioIn.startGate = gate;
      await h.session.start();
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.starts, 1);
      await h.session.pause();
      expect(h.session.phase, FnaPhase.paused);
      gate.complete();
      await flush();
      expect(h.audioIn.running, isFalse);
      h.audioIn.startGate = null;
      await h.session.resume();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('pause then resume while the mic is starting: mic open', () async {
      final h = _Harness();
      final gate = Completer<void>();
      h.audioIn.startGate = gate;
      await h.session.start();
      h.live.setupComplete();
      await flush();
      await h.session.pause();
      h.audioIn.startGate = null;
      await h.session.resume();
      gate.complete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
      await h.mic();
      expect(h.live.audio, hasLength(1));
    });

    test('an empty mic stream: one retry, then paused (never deaf)', () async {
      final h = _Harness();
      h.audioIn.emptyStarts = 1;
      await h.startListening();
      expect(h.audioIn.running, isTrue);
      expect(h.audioIn.starts, 2);

      final h2 = _Harness();
      h2.audioIn.emptyStarts = 2;
      await h2.session.start();
      await flush();
      h2.live.setupComplete();
      await flush();
      expect(h2.session.phase, FnaPhase.paused);
      expect(h2.audioIn.running, isFalse);
    });

    test('silence closes the connection; resume uses the handle', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaResumptionHandle('h5', resumable: true));
      final first = h.live;
      h.timers.elapse(const Duration(seconds: 30));
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(first.closed, isTrue);
      expect(h.audioOut.inSession, isFalse);
      await h.session.resume();
      await flush();
      expect(h.factory.made, hasLength(2));
      expect(h.live.resumeHandle, 'h5');
      expect(h.audioOut.inSession, isTrue);
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.live.contexts, isEmpty);
    });

    test('the Pause button closes the connection after 5 s', () async {
      final h = _Harness();
      await h.startListening();
      final first = h.live;
      await h.session.pause();
      await flush();
      expect(first.closed, isFalse);
      expect(h.audioOut.inSession, isFalse);
      h.timers.elapse(const Duration(seconds: 5));
      await flush();
      expect(first.closed, isTrue);
      await h.session.resume();
      await flush();
      expect(h.factory.made, hasLength(2));
    });

    test('hidden: exits the audio session; resume enters it again', () async {
      final h = _Harness();
      await h.startListening();
      expect(h.audioOut.enters, 1);
      await h.session.onAppHidden();
      await flush();
      expect(h.audioOut.exits, 1);
      expect(h.audioOut.inSession, isFalse);
      expect(h.live.closed, isTrue);
      await h.session.onAppHidden();
      expect(h.audioOut.exits, 1, reason: 'idempotent');
      await h.session.resume();
      await flush();
      expect(h.audioOut.enters, 2);
      expect(h.audioOut.inSession, isTrue);
    });

    test('Stop while paused is a no-op', () async {
      final h = _Harness();
      await h.startListening();
      await h.session.pause();
      final stops = h.audioOut.stops;
      await h.session.stopSpeaking();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioOut.stops, stops);
    });

    test('level: only while listening, about 15 Hz, real changes', () async {
      final h = _Harness();
      await h.startListening();
      await h.mic(level: 0.2);
      await h.mic(level: 0.5);
      expect(h.of<FnaLevel>(), hasLength(1), reason: 'throttled');
      h.timers.elapse(const Duration(milliseconds: 100));
      await h.mic(level: 0.21);
      expect(h.of<FnaLevel>(), hasLength(1), reason: 'too small a change');
      h.timers.elapse(const Duration(milliseconds: 100));
      await h.mic(level: 0.5);
      expect(h.of<FnaLevel>(), hasLength(2));
      h.live.userSays('কী', finished: true);
      await flush();
      expect(h.of<FnaLevel>().last.level, 0, reason: 'bars drop');
      final n = h.of<FnaLevel>().length;
      h.timers.elapse(const Duration(milliseconds: 100));
      await h.mic(level: 0.9);
      expect(h.of<FnaLevel>(), hasLength(n), reason: 'not listening');
    });

    test('captions mask code digits and keep public numbers', () async {
      final h = _Harness();
      await h.startListening();
      h.live
        ..userSays('৪৮২')
        ..audioChunk()
        ..modelSays('জরুরি হলে ৯৯৯');
      await flush();
      expect(h.of<FnaUserCaption>().single.text, '•••');
      // Public numbers (999) stay readable; only code-like runs are masked.
      expect(h.of<FnaModelCaption>().single.text, 'জরুরি হলে ৯৯৯');
    });

    group('tap to talk', () {
      const tap = FnaVoiceConfig(tapToTalk: true);

      test('paused after setup; one turn per tap', () async {
        final h = _Harness(config: tap);
        await h.session.start();
        await flush();
        h.live.setupComplete();
        await flush();
        expect(h.session.phase, FnaPhase.paused);
        expect(h.audioIn.running, isFalse);
        expect(h.audioOut.inSession, isTrue);

        await h.session.resume();
        await flush();
        expect(h.session.phase, FnaPhase.listening);
        expect(h.audioIn.running, isTrue);

        h.live.userSays('হ্যালো', finished: true);
        await flush();
        h.live
          ..audioChunk()
          ..turnComplete();
        await flush();
        expect(h.session.phase, FnaPhase.speaking);
        h.audioOut.emitDrained();
        await flush();
        expect(h.session.phase, FnaPhase.paused);
        expect(h.audioIn.running, isFalse);
        expect(h.of<FnaTurnFinished>(), hasLength(1));
        expect(h.live.closed, isFalse);

        await h.session.resume();
        await flush();
        expect(h.session.phase, FnaPhase.listening);
      });

      test('the greeting first, then paused', () async {
        final h = _Harness(config: tap, withGreeting: true);
        await h.session.start();
        h.live.setupComplete();
        await flush();
        expect(h.session.phase, FnaPhase.connecting);
        h.greeting!.complete();
        await flush();
        expect(h.session.phase, FnaPhase.paused);
      });

      test('a tap during setup listens once ready', () async {
        final h = _Harness(config: tap);
        await h.session.start();
        await h.session.resume();
        h.live.setupComplete();
        await flush();
        expect(h.session.phase, FnaPhase.listening);
      });

      test('silence while listening pauses and closes', () async {
        final h = _Harness(config: tap);
        await h.session.start();
        h.live.setupComplete();
        await flush();
        await h.session.resume();
        await flush();
        h.timers.elapse(const Duration(seconds: 30));
        await flush();
        expect(h.session.phase, FnaPhase.paused);
        expect(h.live.closed, isTrue);
      });

      test('a long gap between turns closes the connection', () async {
        final h = _Harness(config: tap);
        await h.session.start();
        h.live.setupComplete();
        await flush();
        expect(h.live.closed, isFalse);
        h.timers.elapse(const Duration(seconds: 30));
        await flush();
        expect(h.live.closed, isTrue);
        expect(h.audioOut.inSession, isFalse);
      });
    });
  });

  group('second review round', () {
    test('a cut-off answer is not muted after a hide and a resume', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaResumptionHandle('r1', resumable: true));
      h.live.userSays('ওটিপি কী?', finished: true);
      h.live.modelSays('ওটিপি হলো');
      h.live.audioChunk();
      await flush();
      expect(h.session.phase, FnaPhase.speaking);
      await h.session.onAppHidden();
      await flush();
      expect(h.live.closed, isTrue, reason: 'hidden: socket closed');

      await h.session.resume();
      await flush();
      expect(h.live.resumeHandle, 'r1');
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      final played = h.audioOut.played.length;
      h.live.userSays('আবার বলুন', finished: true);
      h.live.modelSays('কাউকে কোড দেবেন না।');
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played.length, played + 1);
      expect(h.session.phase, FnaPhase.speaking);
      expect(h.of<FnaModelCaption>().last.text, 'কাউকে কোড দেবেন না।');
    });

    test('an app line of 20 s keeps the connection: the tool response goes '
        'on the same transport and the handoff is spoken', () async {
      late _Harness h;
      final line = Completer<void>();
      h = _Harness(
        showHold: () async {
          await h.session.pauseForAppLine();
          await line.future;
          await h.session.resumeAfterAppLine();
        },
      );
      await h.startListening();
      h.live.emit(
        const FnaToolCalls([
          FunctionCall(FnaToolNames.holdReason, {}, id: 'h1'),
        ]),
      );
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
      h.timers.elapse(const Duration(seconds: 20));
      await flush();
      expect(h.live.closed, isFalse, reason: 'no 5 s pause close');
      expect(h.factory.made, hasLength(1));

      line.complete();
      await flush();
      expect(h.factory.made, hasLength(1));
      expect(h.live.toolResponses.single.single.id, 'h1');
      expect(h.session.phase, FnaPhase.thinking);
      expect(h.audioIn.running, isTrue);
      final played = h.audioOut.played.length;
      h.live.modelSays('আর কিছু জানতে চান?');
      h.live.audioChunk();
      await flush();
      expect(h.audioOut.played.length, played + 1);
      expect(h.session.phase, FnaPhase.speaking);
    });

    test('pausedByCustomer: the customer\'s pause, never the app line\'s', () async {
      final h = _Harness();
      await h.startListening();
      expect(h.session.pausedByCustomer, isFalse);
      await h.session.pauseForAppLine();
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.session.pausedByCustomer, isFalse);
      await h.session.pause();
      await flush();
      expect(h.session.pausedByCustomer, isTrue);
    });

    test('an app line that never ends closes the connection after the '
        'safety limit', () async {
      final h = _Harness();
      await h.startListening();
      await h.session.pauseForAppLine();
      await flush();
      h.timers.elapse(const FnaVoiceConfig().appLineCloseDelay);
      await flush();
      expect(h.live.closed, isTrue);
    });

    test('Pause during an app line becomes the customer\'s pause: the '
        'connection closes on its 5 s timer', () async {
      final h = _Harness();
      await h.startListening();
      await h.session.pauseForAppLine();
      await h.session.pause();
      await flush();
      h.timers.elapse(const Duration(seconds: 6));
      await flush();
      expect(h.live.closed, isTrue);
      // The line's end does not reopen the mic.
      await h.session.resumeAfterAppLine();
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
    });

    test('an app line during the greeting leaves no pause behind', () async {
      final h = _Harness(withGreeting: true);
      await h.session.start();
      await flush();
      await h.session.pauseForAppLine();
      h.live.setupComplete();
      await flush();
      await h.session.resumeAfterAppLine();
      h.greeting!.complete();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('an app line that ends after the setup completed listens again', () async {
      final h = _Harness();
      await h.session.start();
      await flush();
      await h.session.pauseForAppLine();
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      await h.session.resumeAfterAppLine();
      await flush();
      expect(h.session.phase, FnaPhase.listening);
      expect(h.audioIn.running, isTrue);
    });

    test('hidden during a going-away reconnect: mic stopped and audio '
        'session left at once', () async {
      final h = _Harness();
      await h.startListening();
      h.live.emit(const FnaResumptionHandle('g1', resumable: true));
      h.live.emit(const FnaGoAway(null));
      await flush();
      expect(h.session.phase, FnaPhase.reconnecting);
      await h.session.onAppHidden();
      await flush();
      expect(h.audioIn.running, isFalse);
      expect(h.audioOut.inSession, isFalse);
      // The setup completes in the background: it pauses and closes.
      h.live.setupComplete();
      await flush();
      expect(h.session.phase, FnaPhase.paused);
      expect(h.audioIn.running, isFalse);
      expect(h.live.closed, isTrue);
    });
  });
}
