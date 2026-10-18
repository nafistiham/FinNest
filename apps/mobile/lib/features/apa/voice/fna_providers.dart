/// Riverpod wiring of FNA's agent paths: the shared tools, the chat
/// agent, the voice session factory, the greeting and the last flagged call.
///
/// Every dependency the pure classes take as a constructor argument is
/// resolved here, so `ApaController` only reads providers and tests override
/// one provider to swap a part (a fake session factory, a scripted chat).
library;

import 'dart:async';
import 'dart:io';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/logic/fna_voice_lines.dart';
import 'package:bhorosha/features/apa/voice/fna_ai_client.dart';
import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:bhorosha/features/apa/voice/fna_model_context.dart';
import 'package:bhorosha/features/apa/voice/fna_text_agent.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:bhorosha/features/apa/voice/native_fna_audio.dart';
import 'package:bhorosha/features/intervention/logic/apa_voice.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

const _tag = 'fna';

/// `FNA_VOICE_AGENT` as a provider: `AppEnv` flags are compile-time
/// constants, so tests (and the UI) read the flag through this to run both
/// modes. `false` keeps the original sheet behaviour.
final fnaVoiceAgentEnabledProvider = Provider<bool>(
  (_) => AppEnv.fnaVoiceAgent,
);

/// The last flagged call of this app session: written by the scam check
/// (typed or `check_caller_words`) and by the demo panel's scam replay. It
/// resets with the risk session (a persona switch), like the evidence quote.
final lastCallSummaryProvider = StateProvider<FnaCallSummary?>((ref) {
  ref.watch(riskSessionProvider);
  return null;
});

/// "Next time" of the call summary card: the playbook's prevent chunk for
/// the call's scam type, in the app language; `null` while the knowledge
/// base loads or when no playbook matches.
final fnaCallSummaryNextTimeProvider = Provider<String?>((ref) {
  final summary = ref.watch(lastCallSummaryProvider);
  final kb = ref.watch(safetyKnowledgeProvider).value;
  if (summary == null || kb == null) return null;
  final english = ref.watch(apaSnapshotProvider.select((s) => s.english));
  return fnaPreventText(kb, summary, english: english);
});

/// Server scam types whose playbook id differs from the type.
const _playbookOf = {
  'fake_customer_care': 'fake_agent_care_call',
  'customer_care': 'fake_agent_care_call',
  'impersonation': 'fake_agent_care_call',
  'lottery': 'lottery_prize',
  'prize': 'lottery_prize',
};

/// The `__prevent` chunk text for [summary]'s scam: the mapped playbook
/// first, else the best `__prevent` hit for the type and the caller's words.
String? fnaPreventText(
  SafetyKnowledge kb,
  FnaCallSummary summary, {
  required bool english,
}) {
  final type = summary.scamType.trim();
  final direct = kb.byId('${_playbookOf[type] ?? type}__prevent');
  if (direct != null) return kb.textOf(direct, english: english);
  final query = '${type.replaceAll('_', ' ')} ${summary.evidenceQuote}';
  for (final hit in kb.search(query, k: 8)) {
    if (hit.chunk.id.endsWith('__prevent')) {
      return kb.textOf(hit.chunk, english: english);
    }
  }
  return null;
}

/// Whether the phone reaches Google: the voice session asks before it
/// reports a fallback, so "no network" and "voice failed" read differently.
final fnaIsOnlineProvider = Provider<Future<bool> Function()>(
  (_) => () async {
    try {
      final found = await InternetAddress.lookup(
        'firebasevertexai.googleapis.com',
      ).timeout(const Duration(seconds: 3));
      return found.isNotEmpty;
    } on Object {
      return false;
    }
  },
);

/// Longest wait for the greeting to finish before the mic opens.
final fnaSpeechMaxWaitProvider = Provider<Duration>(
  (_) => const Duration(seconds: 15),
);

/// Longest wait for a line the app speaks over voice mode (the server's
/// held text, the call summary, "Hear it") or reads in the chat. Held
/// reasons can be long; the mic stays closed until the line has ended.
final fnaLineMaxWaitProvider = Provider<Duration>(
  (_) => const Duration(seconds: 60),
);

/// How [fnaSpeakAndWait] ended.
enum FnaSpoken {
  /// The line played to its end, or there was nothing to play.
  finished,

  /// [fnaSpeakAndWait]'s `cancel` completed first (Stop, End).
  cancelled,

  /// The line was still playing after `maxWait`: the player was stopped.
  timedOut,
}

/// Speaks [u] and resolves when it has really finished playing: the line is
/// resolved and queued first, then this waits until the player is idle
/// ([ApaAudio.whenIdle]), so the end of an earlier clip never counts as the
/// end of this line. After [maxWait] the player is stopped before this
/// returns, so the caller can open the mic safely. [cancel] ends the wait at
/// once (the caller stops the player itself). Never throws.
Future<FnaSpoken> fnaSpeakAndWait(
  ApaVoice voice,
  ApaAudio audio,
  ApaUtterance u, {
  required Duration maxWait,
  Future<void>? cancel,
}) async {
  var cancelled = false;
  final stopped = cancel?.then((_) => cancelled = true);
  try {
    final queued = voice.speak(u);
    final source = stopped == null
        ? await queued
        : await Future.any([queued, stopped.then((_) => ApaVoiceSource.none)]);
    if (cancelled) return FnaSpoken.cancelled;
    if (source == ApaVoiceSource.none) return FnaSpoken.finished;
    var ended = false;
    final idle = audio.whenIdle().then((_) => ended = true);
    final waits = [idle, ?stopped];
    await Future.any(waits).timeout(maxWait, onTimeout: () => false);
    if (cancelled) return FnaSpoken.cancelled;
    if (ended) return FnaSpoken.finished;
    Log.w(_tag, 'spoken line still playing after $maxWait: stopped');
    await voice.stop();
    return FnaSpoken.timedOut;
  } on Object catch (e) {
    Log.w(_tag, 'spoken line failed', e);
    return FnaSpoken.finished;
  }
}

/// The greeting is full the first time voice mode opens in an app run.
class _GreetingMemory {
  bool greeted = false;
}

final _greetingMemoryProvider = Provider<_GreetingMemory>(
  (_) => _GreetingMemory(),
);

/// Plays the local greeting and waits for it; the session opens the mic
/// only afterwards. Tests override it with an instant one.
final fnaGreetProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final memory = ref.read(_greetingMemoryProvider);
    final english = ref.read(apaSnapshotProvider).english;
    final line = FnaVoiceLines.greeting(
      first: !memory.greeted,
      english: english,
    );
    memory.greeted = true;
    await fnaSpeakAndWait(
      ref.read(apaVoiceProvider),
      ref.read(apaAudioProvider),
      ApaUtterance(
        textBn: english ? '' : line,
        textEn: english ? line : '',
        english: english,
      ),
      maxWait: ref.read(fnaSpeechMaxWaitProvider),
    );
  };
});

/// The five tools over the app's state. The knowledge base loads in the
/// background; until it has, a search finds nothing (FNA then says its
/// fixed "do not know" line rather than guess). The scam check and the held
/// line run in [ApaController], so both chat and voice share one flow.
final fnaToolsProvider = Provider<FnaTools>((ref) {
  SafetyKnowledge? kb;
  ref.listen<AsyncValue<SafetyKnowledge>>(
    safetyKnowledgeProvider,
    (_, next) => kb = next.value ?? kb,
    fireImmediately: true,
  );
  final empty = SafetyKnowledgeBase.empty();
  return FnaTools(
    knowledge: () => kb ?? empty,
    snapshot: () => _read(ref, apaSnapshotProvider, const ApaContextSnapshot()),
    lastCallSummary: () => _read(ref, lastCallSummaryProvider, null),
    checkCallerWords: (words) async {
      // A chat-agent attempt that timed out or failed changes nothing.
      final attempt = FnaAttempt.current;
      if (attempt != null && !attempt.live) return null;
      try {
        return await ref
            .read(apaControllerProvider.notifier)
            .checkCallerWords(words, stillWanted: () => attempt?.live ?? true);
      } on Object catch (e) {
        Log.w(_tag, 'caller check unavailable', e);
        return null;
      }
    },
    showHoldReason: () async {
      final attempt = FnaAttempt.current;
      if (attempt != null && !attempt.live) return;
      try {
        await ref
            .read(apaControllerProvider.notifier)
            .showHoldReason(stillWanted: () => attempt?.live ?? true);
      } on Object catch (e) {
        Log.w(_tag, 'held line unavailable', e);
      }
    },
  );
});

/// `ref.read` that survives a disposed container (a late tool call).
T _read<T>(Ref ref, ProviderListenable<T> p, T fallback) {
  try {
    return ref.read(p);
  } on Object {
    return fallback;
  }
}

/// The chat agent; Gemini only when `fnaTextAiProvider` has a client.
final fnaTextAgentProvider = Provider<FnaTextAgent>((ref) {
  final ai = ref.watch(fnaTextAiProvider);
  return FnaTextAgent(
    tools: ref.watch(fnaToolsProvider),
    knowledge: () async {
      try {
        return await ref.read(safetyKnowledgeProvider.future);
      } on Object {
        return null;
      }
    },
    generate: ai == null ? null : FirebaseFnaChat(ai).call,
  );
});

/// Builds one voice session for one voice mode, or `null` when Gemini Live
/// cannot run (Firebase not configured). [snapshot] is the controller's view
/// of the customer (with the screen), read at every connect. [tapToTalk]
/// (TalkBack) opens the mic for one turn per tap.
typedef FnaVoiceSessionFactory = FnaVoiceSession? Function(
  ApaContextSnapshot Function() snapshot, {
  bool tapToTalk,
});

final fnaVoiceSessionFactoryProvider = Provider<FnaVoiceSessionFactory>((ref) {
  return (snapshot, {tapToTalk = false}) {
    final ai = ref.read(fnaAiProvider);
    if (ai == null) return null;
    final tools = ref.read(fnaToolsProvider);
    return FnaVoiceSession(
      transportFactory: () => FirebaseFnaLiveTransport.forModel(
        ai,
        declarations: tools.declarations,
      ),
      audioIn: ref.read(fnaAudioInProvider),
      audioOut: ref.read(fnaAudioOutProvider),
      tools: tools,
      config: FnaVoiceConfig(
        halfDuplex: AppEnv.fnaHalfDuplex,
        tapToTalk: tapToTalk,
      ),
      context: () => fnaModelContextJson(snapshot()),
      held: () => snapshot().transferPending,
      greet: ref.read(fnaGreetProvider),
      isOnline: ref.read(fnaIsOnlineProvider),
    );
  };
});
