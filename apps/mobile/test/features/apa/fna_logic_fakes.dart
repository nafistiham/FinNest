/// Shared set-up of the voice-assistant logic tests: the controller with
/// `FNA_VOICE_AGENT` on, a scripted chat model, the bundled knowledge base
/// and a voice session over the voice tests' fake transport and audio.
library;

import 'dart:io';

import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/voice/fna_model_context.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/apa/voice/fna_text_agent.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:bhorosha/features/apa/voice/native_fna_audio.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';
import 'voice/fna_audio_fakes.dart';
import 'voice/fna_live_fakes.dart';

/// The bundled knowledge base, parsed from the asset file.
SafetyKnowledgeBase bundledKnowledge() => SafetyKnowledgeBase.parse(
  File(SafetyKnowledgeBase.assetPath).readAsStringSync(),
);

/// A chat model that answers from a script and records every request.
class ScriptedChat {
  ScriptedChat({this.answer});

  /// Builds the reply for a request; default: a short answer naming the
  /// question, so different questions give different answers.
  final Future<String?> Function(FnaChatRequest r)? answer;

  final List<FnaChatRequest> requests = [];

  /// Snapshot of each request's history length at call time.
  final List<int> historyLengths = [];

  Future<String?> call(FnaChatRequest r) async {
    requests.add(r);
    historyLengths.add(r.history.length);
    final custom = answer;
    if (custom != null) return custom(r);
    return 'উত্তর: ${messageText(r)}। সন্দেহ হলে হেল্পলাইনে কল করুন।';
  }

  static String messageText(FnaChatRequest r) =>
      r.message.parts.whereType<TextPart>().map((p) => p.text).join();
}

/// Everything a flag-on controller test needs.
class FnaLogicHarness {
  FnaLogicHarness({
    ScriptedChat? chat,
    this.withModel = true,
    this.flag = true,
    SafetyKnowledge? knowledge,
  }) : chat = chat ?? ScriptedChat(),
       knowledge = knowledge ?? bundledKnowledge();

  final apa = ApaHarness();
  final ScriptedChat chat;
  final bool withModel;
  final bool flag;
  final SafetyKnowledge knowledge;

  final timers = FakeTimers();
  final transports = FakeTransportFactory();
  final audioIn = FakeFnaAudioIn();
  final audioOut = FakeFnaAudioOut();

  /// The sessions the factory built, in order.
  final List<FnaVoiceSession> sessions = [];

  /// The `tapToTalk` each session was built with.
  final List<bool> tapToTalkFlags = [];

  /// How long the controller waits for a line it speaks over voice mode;
  /// zero by default (the fake player never finishes on its own).
  Duration lineMaxWait = Duration.zero;

  /// The CONTEXT JSON each session was given at connect.
  final List<String> contexts = [];

  /// The greeting the next session plays (none by default).
  Future<void> Function()? greet;

  FakeFnaLiveTransport get live => transports.last;

  List<Override> get overrides => [
    ...apa.overrides,
    fnaVoiceAgentEnabledProvider.overrideWithValue(flag),
    safetyKnowledgeProvider.overrideWith((_) async => knowledge),
    fnaSpeechMaxWaitProvider.overrideWithValue(Duration.zero),
    fnaLineMaxWaitProvider.overrideWith((_) => lineMaxWait),
    fnaGreetProvider.overrideWithValue(() async {}),
    fnaIsOnlineProvider.overrideWithValue(() async => true),
    fnaAudioInProvider.overrideWithValue(audioIn),
    fnaAudioOutProvider.overrideWithValue(audioOut),
    fnaTextAgentProvider.overrideWith(
      (ref) => FnaTextAgent(
        tools: ref.watch(fnaToolsProvider),
        knowledge: () async => knowledge,
        generate: withModel ? chat.call : null,
      ),
    ),
    fnaVoiceSessionFactoryProvider.overrideWith(
      (ref) => (snapshot, {tapToTalk = false}) {
        final tools = ref.read(fnaToolsProvider);
        tapToTalkFlags.add(tapToTalk);
        final session = FnaVoiceSession(
          config: FnaVoiceConfig(tapToTalk: tapToTalk),
          transportFactory: transports.call,
          audioIn: ref.read(fnaAudioInProvider),
          audioOut: ref.read(fnaAudioOutProvider),
          tools: tools,
          context: () {
            final json = fnaModelContextJson(snapshot());
            contexts.add(json);
            return json;
          },
          held: () => snapshot().transferPending,
          greet: greet,
          isOnline: () async => true,
          timer: timers.call,
          now: timers.now,
        );
        sessions.add(session);
        return session;
      },
    ),
  ];

  ProviderContainer container({List<Override> extra = const []}) {
    final c = ProviderContainer(overrides: [...overrides, ...extra]);
    addTearDown(c.dispose);
    // Load the knowledge base before the first question.
    c.listen(safetyKnowledgeProvider, (_, _) {});
    return c;
  }
}

/// A [FnaCallSummary] like the scam check stores for [scamResponse].
FnaCallSummary sampleSummary() => FnaCallSummary.fromScamTurn(
  scamResponse,
  DateTime.utc(2026, 10, 18, 9, 30),
);
