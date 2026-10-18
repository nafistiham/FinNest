/// The Gemini Live transport of FNA voice mode:
/// wraps the `firebase_ai` session and turns server messages into
/// [FnaLiveEvent]s, so [FnaVoiceSession] never sees an SDK type except the
/// tool call and response parts.
///
/// Three SDK behaviours this class works around (architecture review):
/// - `LiveServerSetupComplete` is not exported by `firebase_ai` 5.0.0; it is
///   imported from `src/live_api.dart` (see the import note).
/// - `LiveGenerativeModel.connect()` returns once the WebSocket is open and
///   the setup message is sent, before the server has accepted the setup.
///   [FnaSetupComplete] is emitted only on `LiveServerSetupComplete`.
/// - `LiveSession.resumeSession` reuses the headers of the first connect,
///   so it replays an App Check limited-use token that is already spent, and
///   the session's message stream is closed after `onDone`. A resume here is
///   always a new `connect(sessionResumption: SessionResumptionConfig.resume
///   (handle))` on a new transport.
/// - The SDK parses an `{"error": ...}` frame by throwing inside its socket
///   listener, which reaches us as a stream error. That becomes
///   [FnaLiveError] followed by [FnaLiveClosed].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:firebase_ai/firebase_ai.dart';
// firebase_ai 5.0.0 does not export LiveServerSetupComplete from its public
// library, and "setup accepted" is the one message the session must wait for.
// A runtimeType string check would break under --obfuscate; this import is
// type-checked and pinned by pubspec.lock. Re-check on an SDK upgrade.
// ignore: implementation_imports
import 'package:firebase_ai/src/live_api.dart' show LiveServerSetupComplete;

// ------------------------------------------------------------------ events

/// What the Live server said, in the session's terms.
sealed class FnaLiveEvent {
  const FnaLiveEvent();
}

/// The server accepted the setup: audio may flow now.
class FnaSetupComplete extends FnaLiveEvent {
  const FnaSetupComplete();
}

/// FNA's voice: 16-bit mono PCM.
class FnaAudioChunk extends FnaLiveEvent {
  const FnaAudioChunk(this.bytes, {this.sampleRate = defaultSampleRate});

  static const defaultSampleRate = 24000;

  final Uint8List bytes;
  final int sampleRate;

  /// The rate in an `audio/pcm;rate=24000` mime type, else 24000.
  static int sampleRateOf(String mimeType) {
    final m = RegExp(r'rate=(\d+)').firstMatch(mimeType);
    return int.tryParse(m?.group(1) ?? '') ?? defaultSampleRate;
  }
}

/// A piece of the customer's words (input transcription). Append.
class FnaInputTranscript extends FnaLiveEvent {
  const FnaInputTranscript(this.text, {this.finished = false});
  final String text;
  final bool finished;
}

/// A piece of FNA's words (output transcription). Append.
class FnaOutputTranscript extends FnaLiveEvent {
  const FnaOutputTranscript(this.text, {this.finished = false});
  final String text;
  final bool finished;
}

class FnaToolCalls extends FnaLiveEvent {
  const FnaToolCalls(this.calls);
  final List<FunctionCall> calls;
}

/// The server dropped these calls (the customer interrupted).
class FnaToolCallCancelled extends FnaLiveEvent {
  const FnaToolCallCancelled(this.ids);
  final List<String> ids;
}

/// The customer talked over FNA: stop the player now.
class FnaInterrupted extends FnaLiveEvent {
  const FnaInterrupted();
}

/// The model finished a turn (also after a turn that was only a tool call).
class FnaTurnComplete extends FnaLiveEvent {
  const FnaTurnComplete();
}

/// The server will close the connection soon.
class FnaGoAway extends FnaLiveEvent {
  const FnaGoAway(this.timeLeft);

  /// Parsed from the wire's `"10s"` form; `null` when absent.
  final Duration? timeLeft;

  static Duration? parse(String? wire) {
    final m = RegExp(r'^\s*(\d+(?:\.\d+)?)s\s*$').firstMatch(wire ?? '');
    if (m == null) return null;
    return Duration(milliseconds: (double.parse(m.group(1)!) * 1000).round());
  }
}

/// A new session resumption handle.
class FnaResumptionHandle extends FnaLiveEvent {
  const FnaResumptionHandle(this.handle, {required this.resumable});
  final String? handle;
  final bool resumable;
}

/// The connection failed (connect error, error frame, socket error).
class FnaLiveError extends FnaLiveEvent {
  const FnaLiveError(this.error);
  final Object error;
}

/// The connection is gone. Always the last event of a transport.
class FnaLiveClosed extends FnaLiveEvent {
  const FnaLiveClosed();
}

/// The events one SDK server message stands for, in the order the session
/// must handle them: an interruption first (stop the player before anything
/// else), then transcripts and audio, turn completion last. Unknown messages
/// give none. Text parts of the model turn are ignored: in audio mode they
/// are thoughts, and the caption is the output transcription.
List<FnaLiveEvent> fnaEventsOf(LiveServerMessage message) {
  switch (message) {
    case LiveServerSetupComplete():
      return const [FnaSetupComplete()];
    case LiveServerContent():
      final out = <FnaLiveEvent>[];
      if (message.interrupted ?? false) out.add(const FnaInterrupted());
      final input = message.inputTranscription;
      if (input != null && (input.text ?? '').isNotEmpty) {
        out.add(
          FnaInputTranscript(input.text!, finished: input.finished ?? false),
        );
      }
      for (final part in message.modelTurn?.parts ?? const <Part>[]) {
        if (part is InlineDataPart && part.mimeType.startsWith('audio/')) {
          out.add(
            FnaAudioChunk(
              part.bytes,
              sampleRate: FnaAudioChunk.sampleRateOf(part.mimeType),
            ),
          );
        }
      }
      final output = message.outputTranscription;
      if (output != null && (output.text ?? '').isNotEmpty) {
        out.add(
          FnaOutputTranscript(output.text!, finished: output.finished ?? false),
        );
      }
      if (message.turnComplete ?? false) out.add(const FnaTurnComplete());
      return out;
    case LiveServerToolCall():
      final calls = message.functionCalls ?? const <FunctionCall>[];
      return calls.isEmpty ? const [] : [FnaToolCalls(calls)];
    case LiveServerToolCallCancellation():
      final ids = message.functionIds ?? const <String>[];
      return ids.isEmpty ? const [] : [FnaToolCallCancelled(ids)];
    case GoingAwayNotice():
      return [FnaGoAway(FnaGoAway.parse(message.timeLeft))];
    case SessionResumptionUpdate():
      return [
        FnaResumptionHandle(
          message.newHandle,
          resumable: message.resumable ?? false,
        ),
      ];
    default:
      return const [];
  }
}

// --------------------------------------------------------------- transport

/// One Live connection. [FnaVoiceSession] makes a new transport for every
/// connect (first, resume, fresh restart) so a late event of an old
/// connection can never be mistaken for the new one.
abstract class FnaLiveTransport {
  /// Opens the connection. Never throws: a failure is [FnaLiveError] then
  /// [FnaLiveClosed] on [events]. Ready only after [FnaSetupComplete].
  Future<void> connect({String? resumeHandle});

  /// Broadcast; ends after [FnaLiveClosed].
  Stream<FnaLiveEvent> get events;

  /// One microphone chunk: PCM16 LE mono, 16 kHz.
  Future<void> sendAudio(Uint8List pcm16k);

  /// A typed line from the customer.
  Future<void> sendText(String text);

  /// The CONTEXT JSON, added to the conversation without asking for a reply.
  Future<void> sendContext(String json);

  Future<void> sendToolResponses(List<FunctionResponse> responses);

  /// Idempotent. Emits [FnaLiveClosed] if not closed yet.
  Future<void> close();
}

/// The part of `LiveSession` the transport uses; a seam for tests (the SDK
/// session cannot be built without a socket).
abstract class FnaLiveSocket {
  Stream<LiveServerResponse> receive();
  Future<void> sendAudio(InlineDataPart audio);
  Future<void> sendText(String text);
  Future<void> sendContent(Content content, {required bool turnComplete});
  Future<void> sendToolResponse(List<FunctionResponse> responses);
  Future<void> close();
}

class _SdkLiveSocket implements FnaLiveSocket {
  _SdkLiveSocket(this._session);
  final LiveSession _session;

  @override
  Stream<LiveServerResponse> receive() => _session.receive();

  @override
  Future<void> sendAudio(InlineDataPart audio) =>
      _session.sendAudioRealtime(audio);

  @override
  Future<void> sendText(String text) => _session.sendTextRealtime(text);

  @override
  Future<void> sendContent(Content content, {required bool turnComplete}) =>
      _session.send(input: content, turnComplete: turnComplete);

  @override
  Future<void> sendToolResponse(List<FunctionResponse> responses) =>
      _session.sendToolResponse(responses);

  @override
  Future<void> close() => _session.close();
}

/// Opens a socket with [resumption] in the setup message.
typedef FnaLiveConnector = Future<FnaLiveSocket> Function(
  SessionResumptionConfig resumption,
);

/// [FnaLiveTransport] on `firebase_ai` 5.0.0.
class FirebaseFnaLiveTransport implements FnaLiveTransport {
  FirebaseFnaLiveTransport(this._connector);

  /// The production transport: [ai] from `fnaAiProvider`, audio out with
  /// both transcriptions, automatic activity detection (no start/stop
  /// activity messages), FNA's instruction and tools.
  factory FirebaseFnaLiveTransport.forModel(
    FirebaseAI ai, {
    required List<FunctionDeclaration> declarations,
    String? systemInstruction,
    String model = AppEnv.apaLiveModel,
    String voiceName = defaultVoice,
  }) {
    final live = ai.liveGenerativeModel(
      model: model,
      systemInstruction: Content.system(
        systemInstruction ?? FnaInstructions.system,
      ),
      tools: [Tool.functionDeclarations(declarations)],
      liveGenerationConfig: liveConfig(voiceName: voiceName),
    );
    return FirebaseFnaLiveTransport(
      (resumption) async =>
          _SdkLiveSocket(await live.connect(sessionResumption: resumption)),
    );
  }

  static const _tag = 'fna.live';
  static const defaultVoice = 'Sulafat';
  static const inputMimeType = 'audio/pcm;rate=16000';

  /// The prefix of the CONTEXT message.
  static const contextPrefix = 'CONTEXT:\n';

  static LiveGenerationConfig liveConfig({String voiceName = defaultVoice}) =>
      LiveGenerationConfig(
        responseModalities: [ResponseModalities.audio],
        speechConfig: SpeechConfig(voiceName: voiceName),
        inputAudioTranscription: AudioTranscriptionConfig(),
        outputAudioTranscription: AudioTranscriptionConfig(),
      );

  final FnaLiveConnector _connector;
  final _events = StreamController<FnaLiveEvent>.broadcast();

  FnaLiveSocket? _socket;
  StreamSubscription<LiveServerResponse>? _subscription;
  bool _connectCalled = false;
  bool _closed = false;

  @override
  Stream<FnaLiveEvent> get events => _events.stream;

  @override
  Future<void> connect({String? resumeHandle}) async {
    if (_connectCalled || _closed) return;
    _connectCalled = true;
    final FnaLiveSocket socket;
    try {
      socket = await _connector(
        resumeHandle == null
            ? SessionResumptionConfig()
            : SessionResumptionConfig.resume(resumeHandle),
      );
    } on Object catch (e) {
      Log.w(_tag, 'connect failed', e);
      await _fail(e);
      return;
    }
    if (_closed) {
      // close() ran while the socket was opening.
      unawaited(_quietClose(socket));
      return;
    }
    _socket = socket;
    // Subscribe at once: the SDK stream is broadcast and drops messages
    // that arrive before anyone listens (setupComplete among them).
    _subscription = socket.receive().listen(
      _onResponse,
      onError: (Object e) {
        Log.w(_tag, 'stream error', e);
        unawaited(_fail(e));
      },
      onDone: () {
        if (!_closed) Log.i(_tag, 'closed by server');
        unawaited(close());
      },
      cancelOnError: true,
    );
    Log.i(_tag, resumeHandle == null ? 'socket open' : 'socket open (resume)');
  }

  void _onResponse(LiveServerResponse response) {
    if (_closed) return;
    for (final event in fnaEventsOf(response.message)) {
      _events.add(event);
    }
  }

  Future<void> _fail(Object error) async {
    if (_closed) return;
    _events.add(FnaLiveError(error));
    await close();
  }

  Future<void> _send(
    String what,
    Future<void> Function(FnaLiveSocket) f,
  ) async {
    final socket = _socket;
    if (socket == null || _closed) return;
    try {
      await f(socket);
    } on Object catch (e) {
      // A send on a closed socket throws LiveWebSocketClosedException.
      Log.w(_tag, '$what failed', e);
      await _fail(e);
    }
  }

  @override
  Future<void> sendAudio(Uint8List pcm16k) => pcm16k.isEmpty
      ? Future.value()
      : _send(
          'audio',
          (s) => s.sendAudio(InlineDataPart(inputMimeType, pcm16k)),
        );

  @override
  Future<void> sendText(String text) => text.trim().isEmpty
      ? Future.value()
      : _send('text', (s) => s.sendText(text));

  /// As a client-content turn with `turnComplete: false`, so the model
  /// takes it in without answering it.
  @override
  Future<void> sendContext(String json) => _send(
    'context',
    (s) =>
        s.sendContent(Content.text('$contextPrefix$json'), turnComplete: false),
  );

  @override
  Future<void> sendToolResponses(List<FunctionResponse> responses) =>
      responses.isEmpty
      ? Future.value()
      : _send('tool response', (s) => s.sendToolResponse(responses));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    _events.add(const FnaLiveClosed());
    unawaited(_events.close());
    try {
      await subscription?.cancel();
    } on Object catch (e) {
      Log.w(_tag, 'cancel failed', e);
    }
    if (socket != null) await _quietClose(socket);
  }

  static Future<void> _quietClose(FnaLiveSocket socket) async {
    try {
      await socket.close();
    } on Object catch (e) {
      Log.w(_tag, 'close failed', e);
    }
  }
}
