/// The Live path of the Apa sheet: Gemini Live over Firebase AI Logic.
/// Isolated behind [ApaLiveService] because it cannot run
/// until Firebase is configured; [DisabledApaLiveService] is used otherwise.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_guardrails.dart';
import 'package:bhorosha/features/apa/voice/fna_ai_client.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_core/firebase_core.dart';

/// Streaming voice session with Apa.
///
/// Lifecycle: [start] once per sheet, then for every hold-to-talk press a run
/// of [sendPcm16k] chunks closed by [endTurn]; [stop] when the sheet closes.
/// Implementations never throw to the caller: failures reach `onError`.
abstract class ApaLiveService {
  /// `true` only when a session can be opened right now (Firebase
  /// configured). The microphone permission is checked by the controller.
  Future<bool> available();

  /// Opens the session and sends [ctx] as the first (silent) text turn.
  ///
  /// [onAudio] receives 16-bit PCM at 24 kHz as the model speaks;
  /// [onTranscript] receives Apa's words as they arrive (output
  /// transcription, cumulative per turn is not guaranteed: append);
  /// [onTurnComplete] fires when Apa has finished a reply.
  Future<void> start(
    ApaContext ctx, {
    required void Function(Uint8List pcm24k) onAudio,
    required void Function(String text) onTranscript,
    required void Function(Object error) onError,
    void Function()? onTurnComplete,
  });

  /// One microphone chunk: PCM16 LE mono, 16 kHz.
  Future<void> sendPcm16k(Uint8List chunk);

  /// The user released the button: Apa may answer now.
  Future<void> endTurn();

  /// Closes the session; idempotent.
  Future<void> stop();
}

/// Used whenever `firebaseStatusProvider != configured` (today, emulator).
class DisabledApaLiveService implements ApaLiveService {
  const DisabledApaLiveService();

  @override
  Future<bool> available() async => false;

  @override
  Future<void> start(
    ApaContext ctx, {
    required void Function(Uint8List pcm24k) onAudio,
    required void Function(String text) onTranscript,
    required void Function(Object error) onError,
    void Function()? onTurnComplete,
  }) async {}

  @override
  Future<void> sendPcm16k(Uint8List chunk) async {}

  @override
  Future<void> endTurn() async {}

  @override
  Future<void> stop() async {}
}

/// Real implementation on `firebase_ai` 5.0.0. **Untested**: Firebase is not
/// configured on this project yet, so it compiles against the installed API
/// but has never opened a socket.
///
/// How the installed API differs from the team note:
/// - `FirebaseAI.vertexAI()` does not exist in 5.0.0. The Vertex-backed
///   entrypoint is `FirebaseAI.agentPlatform(location:)` (WebSocket to
///   `LlmBidiService/BidiGenerateContent/locations/<location>`); the other
///   entrypoint is `FirebaseAI.googleAI()`. This class uses `agentPlatform`.
/// - Audio in: `LiveSession.sendAudioRealtime(InlineDataPart('audio/pcm;
///   rate=16000', bytes))`. Audio out: `LiveServerContent.modelTurn.parts`
///   holding `InlineDataPart`s (24 kHz PCM per the Live API docs).
/// - Hold-to-talk is a manual turn: automatic activity detection is disabled
///   and the hold is bracketed by `sendStartActivityRealtime()` /
///   `sendStopActivityRealtime()`.
/// - Transcript text comes from `LiveGenerationConfig(outputAudioTranscription:
///   AudioTranscriptionConfig())` → `LiveServerContent.outputTranscription`.
class FirebaseApaLiveService implements ApaLiveService {
  FirebaseApaLiveService({
    FirebaseAI? ai,
    this.model = AppEnv.apaLiveModel,
    this.location = AppEnv.apaLiveLocation,
  }) : _ai = ai; // ignore: prefer_initializing_formals

  static const _tag = 'apa.live';
  static const defaultModel = 'gemini-3.8-live';

  /// The standing instruction: the same guardrails as the text path
  /// ([ApaGuardrails.lines], so the two personas never drift), then the Live
  /// specifics: voice is always Bangla, and the first text turn is the JSON
  /// context the facts come from.
  static final String systemInstruction = [
    ...ApaGuardrails.lines,
    'This is a voice session: always answer in Bangla (বাংলা), never switch language, and keep every reply short enough to be heard in one breath.',
    'The first text message of the session is CONTEXT as JSON; nothing else is known about the customer.',
    'তুমি ফিননেস্ট সহকারী (এফএনএ), ফিননেস্ট ব্যাংকের অ্যাপের নিরাপত্তা গাইড। নিজের পরিচয় দিলে ঠিক এভাবে বলো: "${ApaGuardrails.introBn}"। সবসময় বাংলায়, ছোট ও সহজ বাক্যে উত্তর দাও; গ্রাহককে "আপনি" বলো।',
  ].join('\n');

  static const inputMimeType = 'audio/pcm;rate=16000';
  static const outputSampleRate = 24000;

  final FirebaseAI? _ai;
  final String model;
  final String location;

  LiveSession? _session;
  StreamSubscription<LiveServerResponse>? _subscription;
  bool _activityOpen = false;

  @override
  Future<bool> available() async {
    try {
      return Firebase.apps.isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> start(
    ApaContext ctx, {
    required void Function(Uint8List pcm24k) onAudio,
    required void Function(String text) onTranscript,
    required void Function(Object error) onError,
    void Function()? onTurnComplete,
  }) async {
    if (_session != null) return;
    try {
      final ai = _ai ?? fnaAgentPlatform(location);
      final live = ai.liveGenerativeModel(
        model: model,
        systemInstruction: Content.system(systemInstruction),
        liveGenerationConfig: LiveGenerationConfig(
          responseModalities: [ResponseModalities.audio],
          outputAudioTranscription: AudioTranscriptionConfig(),
          realtimeInputConfig: RealtimeInputConfig(
            automaticActivityDetection: ActivityDetectionConfig.disabled(),
          ),
        ),
      );
      final session = await live.connect();
      _session = session;
      _subscription = session.receive().listen(
        (response) =>
            _onMessage(response, onAudio, onTranscript, onTurnComplete),
        onError: (Object e) {
          Log.w(_tag, 'session error', e);
          onError(e);
        },
        onDone: () async {
          Log.i(_tag, 'session closed by server ($model @ $location)');
          // Diagnostic: a send on a closed socket surfaces the close code and
          // reason from firebase_ai's LiveSession; nothing reaches the server.
          try {
            await session.send(input: Content.text('.'));
          } on Object catch (e) {
            Log.w(_tag, 'close detail', e);
          }
          onError(StateError('live session closed'));
        },
      );
      // Context as the first text turn, without asking for a reply.
      await session.send(input: Content.text(jsonEncode(ctx.toJson())));
      Log.i(_tag, 'session open ($model)');
    } on Object catch (e) {
      Log.w(_tag, 'start failed', e);
      await stop();
      onError(e);
    }
  }

  @override
  Future<void> sendPcm16k(Uint8List chunk) async {
    final session = _session;
    if (session == null || chunk.isEmpty) return;
    try {
      if (!_activityOpen) {
        await session.sendStartActivityRealtime();
        _activityOpen = true;
      }
      await session.sendAudioRealtime(InlineDataPart(inputMimeType, chunk));
    } on Object catch (e) {
      Log.w(_tag, 'sendAudioRealtime failed', e);
    }
  }

  @override
  Future<void> endTurn() async {
    final session = _session;
    if (session == null || !_activityOpen) return;
    _activityOpen = false;
    try {
      await session.sendStopActivityRealtime();
    } on Object catch (e) {
      Log.w(_tag, 'sendStopActivityRealtime failed', e);
    }
  }

  @override
  Future<void> stop() async {
    final session = _session;
    _session = null;
    _activityOpen = false;
    await _subscription?.cancel();
    _subscription = null;
    if (session != null) {
      try {
        await session.close();
      } on Object catch (e) {
        Log.w(_tag, 'close failed', e);
      }
    }
  }

  void _onMessage(
    LiveServerResponse response,
    void Function(Uint8List) onAudio,
    void Function(String) onTranscript,
    void Function()? onTurnComplete,
  ) {
    final message = response.message;
    switch (message) {
      case LiveServerContent():
        for (final part in message.modelTurn?.parts ?? const <Part>[]) {
          if (part is InlineDataPart && part.mimeType.startsWith('audio/')) {
            onAudio(part.bytes);
          } else if (part is TextPart && part.text.isNotEmpty) {
            onTranscript(part.text);
          }
        }
        final transcript = message.outputTranscription?.text;
        if (transcript != null && transcript.isNotEmpty) {
          onTranscript(transcript);
        }
        if (message.turnComplete ?? false) onTurnComplete?.call();
      case GoingAwayNotice():
        Log.w(_tag, 'server going away in ${message.timeLeft}');
      default:
        // Tool calls, resumption updates and unknown messages are ignored.
        break;
    }
  }
}
