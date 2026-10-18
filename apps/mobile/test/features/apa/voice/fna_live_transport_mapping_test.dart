// The Live transport: SDK server messages to FnaLiveEvents (built with the
// SDK's public constructors), and the transport's connect, setup, error and
// close behaviour over a fake socket.

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';
// The setup-complete message is not exported by firebase_ai 5.0.0 (see
// fna_live_transport.dart).
// ignore: implementation_imports
import 'package:firebase_ai/src/live_api.dart' show LiveServerSetupComplete;
import 'package:flutter_test/flutter_test.dart';

class _FakeSocket implements FnaLiveSocket {
  final server = StreamController<LiveServerResponse>.broadcast(sync: true);
  final audio = <InlineDataPart>[];
  final texts = <String>[];
  final contents = <(Content, bool)>[];
  final tools = <List<FunctionResponse>>[];
  bool closed = false;
  Object? throwOnSend;

  void push(LiveServerMessage m) => server.add(LiveServerResponse(message: m));

  void _maybeThrow() {
    final e = throwOnSend;
    if (e != null) throw e;
  }

  @override
  Stream<LiveServerResponse> receive() => server.stream;

  @override
  Future<void> sendAudio(InlineDataPart audio) async {
    _maybeThrow();
    this.audio.add(audio);
  }

  @override
  Future<void> sendText(String text) async {
    _maybeThrow();
    texts.add(text);
  }

  @override
  Future<void> sendContent(
    Content content, {
    required bool turnComplete,
  }) async {
    _maybeThrow();
    contents.add((content, turnComplete));
  }

  @override
  Future<void> sendToolResponse(List<FunctionResponse> responses) async {
    _maybeThrow();
    tools.add(responses);
  }

  @override
  Future<void> close() async => closed = true;
}

Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('fnaEventsOf', () {
    test('setup complete', () {
      expect(
        fnaEventsOf(LiveServerSetupComplete()).single,
        isA<FnaSetupComplete>(),
      );
    });

    test(
      'content: interrupted first, transcripts and audio, turn end last',
      () {
        final events = fnaEventsOf(
          LiveServerContent(
            interrupted: true,
            inputTranscription: const Transcription(
              text: 'ওটিপি',
              finished: true,
            ),
            modelTurn: Content.model([
              const TextPart('thinking...'),
              InlineDataPart('audio/pcm;rate=24000', Uint8List(4)),
              InlineDataPart('audio/pcm', Uint8List(2)),
              InlineDataPart('image/png', Uint8List(1)),
            ]),
            outputTranscription: const Transcription(text: 'কল কেটে দিন'),
            turnComplete: true,
          ),
        );
        expect(events.map((e) => e.runtimeType), [
          FnaInterrupted,
          FnaInputTranscript,
          FnaAudioChunk,
          FnaAudioChunk,
          FnaOutputTranscript,
          FnaTurnComplete,
        ]);
        final input = events[1] as FnaInputTranscript;
        expect(input.text, 'ওটিপি');
        expect(input.finished, isTrue);
        expect((events[2] as FnaAudioChunk).sampleRate, 24000);
        expect((events[2] as FnaAudioChunk).bytes, hasLength(4));
        expect(
          (events[3] as FnaAudioChunk).sampleRate,
          24000,
          reason: 'default',
        );
        expect((events[4] as FnaOutputTranscript).text, 'কল কেটে দিন');
      },
    );

    test('empty transcripts give no event', () {
      expect(
        fnaEventsOf(
          LiveServerContent(
            inputTranscription: const Transcription(text: ''),
            outputTranscription: const Transcription(),
          ),
        ),
        isEmpty,
      );
    });

    test('sample rate from the mime type', () {
      expect(FnaAudioChunk.sampleRateOf('audio/pcm;rate=16000'), 16000);
      expect(FnaAudioChunk.sampleRateOf('audio/pcm'), 24000);
    });

    test('tool calls keep their ids', () {
      final e =
          fnaEventsOf(
                LiveServerToolCall(
                  functionCalls: const [
                    FunctionCall('search_safety_knowledge', {
                      'query': 'otp',
                    }, id: 'f1'),
                  ],
                ),
              ).single
              as FnaToolCalls;
      expect(e.calls.single.id, 'f1');
      expect(e.calls.single.args, {'query': 'otp'});
      expect(fnaEventsOf(LiveServerToolCall()), isEmpty);
    });

    test('cancellation', () {
      final e =
          fnaEventsOf(LiveServerToolCallCancellation(functionIds: ['f1', 'f2']))
                  .single
              as FnaToolCallCancelled;
      expect(e.ids, ['f1', 'f2']);
    });

    test('going away with the time left', () {
      final e =
          fnaEventsOf(const GoingAwayNotice(timeLeft: '10s')).single
              as FnaGoAway;
      expect(e.timeLeft, const Duration(seconds: 10));
      expect(FnaGoAway.parse('1.5s'), const Duration(milliseconds: 1500));
      expect(FnaGoAway.parse(null), isNull);
      expect(FnaGoAway.parse('soon'), isNull);
    });

    test('resumption handle', () {
      final e =
          fnaEventsOf(SessionResumptionUpdate(newHandle: 'h', resumable: true))
                  .single
              as FnaResumptionHandle;
      expect(e.handle, 'h');
      expect(e.resumable, isTrue);
      final none =
          fnaEventsOf(SessionResumptionUpdate()).single as FnaResumptionHandle;
      expect(none.resumable, isFalse);
    });
  });

  group('FirebaseFnaLiveTransport', () {
    late _FakeSocket socket;
    late List<SessionResumptionConfig> configs;
    late FirebaseFnaLiveTransport transport;
    late List<FnaLiveEvent> events;

    setUp(() {
      socket = _FakeSocket();
      configs = [];
      transport = FirebaseFnaLiveTransport((config) async {
        configs.add(config);
        return socket;
      });
      events = [];
      transport.events.listen(events.add);
    });

    test('a new resumable session, or a resume with the handle', () async {
      await transport.connect();
      expect(configs.single.handle, isNull);
      expect(configs.single.toJson(), isEmpty);

      final other = FirebaseFnaLiveTransport((config) async {
        configs.add(config);
        return _FakeSocket();
      });
      await other.connect(resumeHandle: 'h9');
      expect(configs.last.handle, 'h9');
    });

    test('connect returning is not ready: only setupComplete is', () async {
      await transport.connect();
      await _flush();
      expect(events, isEmpty);
      socket.push(LiveServerSetupComplete());
      await _flush();
      expect(events.single, isA<FnaSetupComplete>());
    });

    test('a connect error: LiveError then Closed, never a throw', () async {
      final failing = FirebaseFnaLiveTransport(
        (_) async => throw StateError('no socket'),
      );
      final seen = <FnaLiveEvent>[];
      failing.events.listen(seen.add);
      await failing.connect();
      await _flush();
      expect(seen.map((e) => e.runtimeType), [FnaLiveError, FnaLiveClosed]);
    });

    test('an error frame (stream error): LiveError then Closed', () async {
      await transport.connect();
      socket.server.addError(ServerException('quota'));
      await _flush();
      expect(events.map((e) => e.runtimeType), [FnaLiveError, FnaLiveClosed]);
      expect((events.first as FnaLiveError).error, isA<ServerException>());
      expect(socket.closed, isTrue);
    });

    test('server close: Closed once', () async {
      await transport.connect();
      await socket.server.close();
      await _flush();
      expect(events.whereType<FnaLiveClosed>(), hasLength(1));
      await transport.close();
      expect(events.whereType<FnaLiveClosed>(), hasLength(1));
    });

    test('what goes out', () async {
      await transport.connect();
      await transport.sendAudio(Uint8List(3));
      await transport.sendAudio(Uint8List(0));
      await transport.sendText('হ্যালো');
      await transport.sendText('  ');
      await transport.sendContext('{"a":1}');
      await transport.sendToolResponses([
        const FunctionResponse('get_my_safety_status', {'ok': true}, id: 'c1'),
      ]);
      expect(socket.audio.single.mimeType, 'audio/pcm;rate=16000');
      expect(socket.texts, ['হ্যালো']);
      final (content, turnComplete) = socket.contents.single;
      expect((content.parts.single as TextPart).text, 'CONTEXT:\n{"a":1}');
      expect(turnComplete, isFalse);
      expect(socket.tools.single.single.id, 'c1');
    });

    test('a failed send closes the transport instead of throwing', () async {
      await transport.connect();
      socket.throwOnSend = StateError('closed socket');
      await transport.sendAudio(Uint8List(2));
      await _flush();
      expect(events.map((e) => e.runtimeType), [FnaLiveError, FnaLiveClosed]);
      // Later sends are no-ops.
      await transport.sendText('x');
      expect(socket.texts, isEmpty);
    });

    test('close before connect finishes closes the late socket', () async {
      final gate = Completer<FnaLiveSocket>();
      final slow = FirebaseFnaLiveTransport((_) => gate.future);
      unawaited(slow.connect());
      await slow.close();
      gate.complete(socket);
      await _flush();
      expect(socket.closed, isTrue);
    });

    test('the live config: audio out, both transcriptions, Sulafat', () {
      final config = FirebaseFnaLiveTransport.liveConfig();
      expect(config.responseModalities, [ResponseModalities.audio]);
      expect(config.inputAudioTranscription, isNotNull);
      expect(config.outputAudioTranscription, isNotNull);
      expect(config.speechConfig?.voiceName, 'Sulafat');
      // Automatic activity detection: no realtime input config.
      expect(config.realtimeInputConfig, isNull);
    });
  });
}
