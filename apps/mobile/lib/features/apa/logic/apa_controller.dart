/// State of the Apa sheet: transcript, path and the hold-to-talk machine.
library;

import 'dart:async';

import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/local/local_auth_repo.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_gemini_service.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/logic/apa_live_service.dart';
import 'package:bhorosha/features/apa/logic/apa_mic.dart';
import 'package:bhorosha/features/apa/logic/apa_text_service.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/logic/fna_voice_lines.dart';
import 'package:bhorosha/features/apa/voice/fna_ai_client.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/apa/voice/fna_text_agent.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:bhorosha/features/apa/voice/native_fna_audio.dart';
import 'package:bhorosha/features/intervention/logic/apa_voice.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hint codes in [ApaState.error]; the sheet maps them to ARB strings so no
/// user-visible copy lives here (FR-6).
abstract final class ApaHint {
  /// Firebase absent or the Live session could not open: text path in use.
  static const liveUnavailable = 'live_unavailable';

  /// `RECORD_AUDIO` denied: text path in use.
  static const micDenied = 'mic_denied';

  /// Every text path failed; the user can retry.
  static const textFailed = 'text_failed';

  /// The Live session dropped mid-conversation: text path in use.
  static const liveFailed = 'live_failed';
}

class ApaState {
  const ApaState({
    this.turns = const [],
    this.listening = false,
    this.speaking = false,
    this.liveAvailable = false,
    this.path = ApaTurn.guide,
    this.error,
    this.busy = false,
    this.scamCheck = false,
    this.voicePhase,
    this.userCaption = '',
    this.modelCaption = '',
    this.voiceFallback,
    this.secretBlocked = false,
    this.callSummary,
    this.hearingTurn,
    this.hearingSummary = false,
  });

  final List<ApaTurn> turns;

  /// The microphone is open (button held).
  final bool listening;

  /// Apa is talking (TTS or Live audio).
  final bool speaking;

  /// Firebase is configured and a Live session can be opened.
  final bool liveAvailable;

  /// What the path chip shows: `live`, `gemini` or `guide` (the offline
  /// guide; `text` when the server stub answered last).
  final String path;

  /// One of [ApaHint], or `null`.
  final String? error;

  /// A text turn is in flight.
  final bool busy;

  /// The next typed line is what a caller said: it goes to the scam check.
  final bool scamCheck;

  // ------------------------------------------------ voice mode

  /// `null` while the chat view shows; otherwise voice mode is open and this
  /// is the voice session's phase (the view maps it to six on-screen states).
  final FnaPhase? voicePhase;

  /// Live caption of the customer's current turn (masked when a code was
  /// heard); empty between turns.
  final String userCaption;

  /// Live caption of FNA's current turn; empty between turns.
  final String modelCaption;

  /// Why voice mode fell back to the chat (the view shows the matching
  /// line and, for [FnaFallbackReason.micPermanentlyDenied], "Open settings").
  final FnaFallbackReason? voiceFallback;

  /// A code-like number was heard: the view shows the warning strip with a
  /// haptic. Cleared by the next caption.
  final bool secretBlocked;

  /// The last flagged call, for the call summary card; `null` when no call
  /// was flagged in this app session.
  final FnaCallSummary? callSummary;

  /// The bubble whose "Hear it" is playing, or `null`.
  final ApaTurn? hearingTurn;

  /// The call summary card is being read aloud ([ApaController.
  /// hearCallSummary]; a second tap stops it).
  final bool hearingSummary;

  /// Voice mode is open.
  bool get inVoice => voicePhase != null;

  ApaState copyWith({
    List<ApaTurn>? turns,
    bool? listening,
    bool? speaking,
    bool? liveAvailable,
    String? path,
    Object? error = _unchanged,
    bool? busy,
    bool? scamCheck,
    Object? voicePhase = _unchanged,
    String? userCaption,
    String? modelCaption,
    Object? voiceFallback = _unchanged,
    bool? secretBlocked,
    Object? callSummary = _unchanged,
    Object? hearingTurn = _unchanged,
    bool? hearingSummary,
  }) => ApaState(
    turns: turns ?? this.turns,
    listening: listening ?? this.listening,
    speaking: speaking ?? this.speaking,
    liveAvailable: liveAvailable ?? this.liveAvailable,
    path: path ?? this.path,
    error: identical(error, _unchanged) ? this.error : error as String?,
    busy: busy ?? this.busy,
    scamCheck: scamCheck ?? this.scamCheck,
    voicePhase: identical(voicePhase, _unchanged)
        ? this.voicePhase
        : voicePhase as FnaPhase?,
    userCaption: userCaption ?? this.userCaption,
    modelCaption: modelCaption ?? this.modelCaption,
    voiceFallback: identical(voiceFallback, _unchanged)
        ? this.voiceFallback
        : voiceFallback as FnaFallbackReason?,
    secretBlocked: secretBlocked ?? this.secretBlocked,
    callSummary: identical(callSummary, _unchanged)
        ? this.callSummary
        : callSummary as FnaCallSummary?,
    hearingTurn: identical(hearingTurn, _unchanged)
        ? this.hearingTurn
        : hearingTurn as ApaTurn?,
    hearingSummary: hearingSummary ?? this.hearingSummary,
  );

  static const _unchanged = Object();

  @override
  String toString() =>
      'ApaState(path=$path live=$liveAvailable listening=$listening '
      'speaking=$speaking error=$error scam=$scamCheck turns=${turns.length})';
}

class ApaController extends Notifier<ApaState> {
  static const _tag = 'apa';

  ScoreResponse? _held;
  String _screen = 'home';
  bool _liveStarted = false;
  bool _liveTurnOpen = false;

  /// Bumped by [openFor] and [_teardown]. A text turn captures it before its
  /// await and drops its reply when the sheet session has changed since, so a
  /// late answer never lands in (or is spoken into) the next session.
  int _generation = 0;

  /// The Live connect in flight; a second hold during it awaits the same
  /// future instead of opening a second session or microphone.
  Future<void>? _connecting;

  /// The recorder is starting for a hold; a second hold waits for nothing and
  /// never opens the microphone twice.
  bool _micOpening = false;

  bool _sheetOpen = false;

  /// A modal sheet is opening or open on this controller.
  bool get sheetOpen => _sheetOpen;

  /// Claims the sheet slot; `false` when a sheet is already opening or open.
  bool markSheetOpen() {
    // A sheet that has been "opening" for 15 s is stuck (its open future
    // never finished): release the slot so the assistant can open again.
    final since = _sheetOpenedAt;
    if (_sheetOpen &&
        since != null &&
        DateTime.now().difference(since) < const Duration(seconds: 15)) {
      return false;
    }
    if (_sheetOpen && since == null) return false;
    _sheetOpen = true;
    _sheetOpenedAt = DateTime.now();
    return true;
  }

  void markSheetClosed() {
    _sheetOpen = false;
    _sheetOpenedAt = null;
  }

  /// When the open sheet slot was claimed; cleared once the sheet is
  /// showing ([markSheetShown]) or closed.
  DateTime? _sheetOpenedAt;

  /// The sheet is on screen: the stuck-open release no longer applies.
  void markSheetShown() => _sheetOpenedAt = null;

  /// The finger is down. Set by [holdStart], cleared by [holdEnd] even when
  /// the microphone never opened, so a release during one of holdStart's
  /// awaits (the permission dialog cancels the long press) closes it again.
  bool _holdActive = false;
  StreamSubscription<Uint8List>? _micSubscription;

  // Resolved once in [build] so [_teardown] never touches `ref` after the
  // container is gone (the sheet's dispose can outlive a test's scope). The
  // text service is read per call because its uid follows sign-in.
  late ApaAudio _audio;
  late ApaVoice _voice;
  late ApaLiveService _live;
  late ApaMic _mic;
  late BhoroshaNative _native;

  // ------------------------------------------------ voice flag on

  /// `FNA_VOICE_AGENT`, read once: chat answers come from [FnaTextAgent],
  /// voice mode from [FnaVoiceSession], and the hold-to-talk path is off.
  /// With it off, every method below keeps the original sheet behaviour.
  late bool _fna;

  /// The voice session of the open voice mode, or `null`.
  FnaVoiceSession? _session;
  StreamSubscription<FnaSessionEvent>? _sessionSub;

  /// Bumped whenever voice mode opens or closes: events of an older session
  /// that are still queued are dropped.
  int _voiceEpoch = 0;

  /// The app itself is speaking over voice mode (the held line, the call
  /// summary): the session is paused for that, and the view shows
  /// "speaking", not "paused".
  bool _speakingOverVoice = false;

  /// The customer pressed Pause while the app spoke over voice mode: the
  /// session stays paused after the line.
  bool _pausedDuringLine = false;

  /// How many [_overVoice] lines run now (a "Hear it" during the held
  /// line): only the last one to end listens again or pauses.
  int _lineDepth = 0;

  /// The customer had paused the session when the first of the running
  /// lines began.
  bool _pausedBeforeLine = false;

  /// The app is in the foreground ([onAppHidden] / [onAppVisible]); a line
  /// spoken over voice mode never reopens the mic of a hidden app.
  bool _appVisible = true;

  /// Bumped by every "Hear it", the call summary and [_stopHearing]; the end
  /// of an older line never clears a newer one.
  int _hearToken = 0;

  /// Completes to end the wait for the line the app is speaking now (Stop,
  /// End, a new line); see [_speakAndWait].
  Completer<void>? _lineCancel;

  final ValueNotifier<double> _micLevel = ValueNotifier(0);

  /// Microphone level 0..1 for the level bars of voice mode. Updated many
  /// times a second without rebuilding [ApaState].
  ValueListenable<double> get micLevel => _micLevel;

  /// Voice mode opens in tap-to-talk (TalkBack): one turn per tap.
  bool _tapToTalk = false;

  /// The agent this controller last asked, so [_teardown] can reset its
  /// conversation without touching `ref`.
  FnaTextAgent? _agentUsed;

  @override
  ApaState build() {
    _audio = ref.read(apaAudioProvider);
    _voice = ref.read(apaVoiceProvider);
    _live = ref.read(apaLiveServiceProvider);
    _mic = ref.read(apaMicProvider);
    _native = ref.read(nativeProvider);
    _fna = ref.read(fnaVoiceAgentEnabledProvider);
    ref.onDispose(() => unawaited(_teardown()));
    if (!_fna) return const ApaState();
    // The card follows the last flagged call wherever it was flagged (scam
    // check, voice tool, demo replay) and clears on a persona switch.
    ref.listen<FnaCallSummary?>(
      lastCallSummaryProvider,
      (_, next) => _set(state.copyWith(callSummary: next)),
    );
    return ApaState(callSummary: ref.read(lastCallSummaryProvider));
  }

  FnaTextAgent get _agent {
    final agent = ref.read(fnaTextAgentProvider);
    _agentUsed = agent;
    return agent;
  }

  ApaService get _text => ref.read(apaTextServiceProvider);

  /// Writes [next] unless the provider was disposed during an await (the
  /// sheet closed mid-turn); Riverpod 3 throws on `state` after dispose.
  void _set(ApaState next) {
    if (ref.mounted) state = next;
  }

  ApaContext get _context =>
      ApaContext(lastRisk: _held?.riskScore, screen: _screen);

  ApaAnswers get _answers => ref.read(apaAnswersProvider);

  ApaContextSnapshot get _snapshot =>
      ref.read(apaSnapshotProvider).withScreen(_screen);

  bool get _english => ref.read(apaSnapshotProvider).english;

  /// The path the chip shows when no answer has come yet.
  String _idlePath(bool liveAvailable) {
    if (liveAvailable) return ApaTurn.live;
    return ref.read(apaGeminiEnabledProvider) ? ApaTurn.gemini : ApaTurn.guide;
  }

  /// Resets the transcript for a fresh sheet. With a held [ScoreResponse]
  /// whose `reasons` are non-empty, the first bubble is exactly the reasons'
  /// `text_bn` joined with a space (and `text_en` likewise for English), and
  /// it is spoken; nothing else is composed (FR-3). An [insight] (from the
  /// Home card) follows it, or is the first bubble when nothing is held.
  Future<void> openFor({
    ScoreResponse? held,
    required String screen,
    ApaInsight? insight,
    List<ApaInsight> others = const [],
  }) async {
    await _teardown();
    final generation = _generation;
    _held = held;
    _screen = screen;
    final liveAvailable = await _live.available();
    if (generation != _generation) return; // reopened or closed meanwhile
    final turns = <ApaTurn>[];
    final reasons = held?.reasons ?? const <Reason>[];
    if (reasons.isNotEmpty) {
      turns.add(
        ApaTurn(
          speaker: ApaTurn.apa,
          textBn: reasons.map((r) => r.textBn).join(' '),
          textEn: reasons.map((r) => r.textEn).join(' '),
          path: ApaTurn.held,
          source: ApaSource.server,
        ),
      );
    }
    // The held/call insights repeat the held line: skip the duplicate.
    const heldInsights = {'held_transfer', 'call_transfer'};
    if (insight != null &&
        !(reasons.isNotEmpty && heldInsights.contains(insight.id))) {
      turns.add(_answers.insightTurn(insight));
    }
    for (final other in others) {
      if (reasons.isNotEmpty && heldInsights.contains(other.id)) continue;
      turns.add(_answers.insightTurn(other));
    }
    _set(
      ApaState(
        turns: turns,
        liveAvailable: liveAvailable,
        path: _idlePath(liveAvailable),
        callSummary: _fna && ref.mounted
            ? ref.read(lastCallSummaryProvider)
            : null,
      ),
    );
    if (turns.isNotEmpty) await _speakTurn(turns.first);
  }

  /// A typed line: to the scam check when it is armed, otherwise to the
  /// text path (Gemini, else the offline guide, else the server stub).
  /// Code-like digit runs are masked first and never sent anywhere.
  Future<void> sendText(String input) async {
    final raw = input.trim();
    if (raw.isEmpty || state.busy) return;
    if (state.scamCheck) return _submitScamCheck(raw);
    if (_fna) return _sendTextFna(raw);
    final (text, redacted) = ApaAnswers.redactSecrets(raw);
    final user = ApaTurn(
      speaker: ApaTurn.user,
      textBn: text,
      textEn: text,
      path: ApaTurn.guide,
    );
    if (redacted) {
      final warn = _answers.secretRedacted();
      _set(state.copyWith(turns: [...state.turns, user, warn], error: null));
      await _speakTurn(warn);
      return;
    }
    _set(
      state.copyWith(turns: [...state.turns, user], error: null, busy: true),
    );
    final generation = _generation;
    try {
      final replies = await _text.ask(text, _context, _snapshot);
      if (generation != _generation) {
        Log.d(_tag, 'text reply arrived after the sheet closed; dropped');
        return;
      }
      if (replies.isEmpty) throw StateError('no answer');
      _set(
        state.copyWith(
          turns: [...state.turns, ...replies],
          busy: false,
          path: state.path == ApaTurn.live ? null : replies.last.path,
        ),
      );
      await _speakTurn(replies.first);
    } on Object catch (e) {
      if (generation != _generation) return;
      Log.w(_tag, 'text turn failed', e);
      _set(state.copyWith(error: ApaHint.textFailed, busy: false));
    }
  }

  // ------------------------------------------------------- quick actions

  /// Appends [user] and [replies]. Spoken only with the flag off: with it
  /// on, chat answers stay quiet until "Hear it" (cost, quiet places).
  Future<void> _answer(ApaTurn user, List<ApaTurn> replies) async {
    if (state.busy) return;
    _set(
      state.copyWith(
        turns: [...state.turns, user, ...replies],
        error: null,
        scamCheck: false,
      ),
    );
    if (replies.isNotEmpty && !_fna) await _speakTurn(replies.first);
  }

  /// "আমার ফোন কি নিরাপদ?": the verdict and findings. With the flag on the
  /// chat agent answers (it reads the status tool); offline, the same
  /// deterministic verdict as before.
  Future<void> askPhoneSafe() async {
    final user = _answers.userLabel((l) => l.apaQuickPhoneSafe);
    // Chat: the phone safety check's own verdict and findings, at once and
    // with no model (a model once called a phone with findings "safe", and
    // the round trip was slow). Voice mode asks Live, which reads the same
    // verdict through get_my_safety_status.
    if (!_fna || !state.inVoice) {
      return _answer(user, _answers.phoneSafe(_snapshot));
    }
    if (await _askLive(_labelText(user))) return;
    return _answer(user, _answers.phoneSafe(_snapshot));
  }

  /// "টাকা কেন আটকাল?": the server's reasons only (FR-3), never a model.
  /// With the flag on, the fixed handoff line follows the reasons; in voice
  /// mode the app speaks the server's text itself (the mic closed).
  Future<void> askWhyHeld() async {
    final user = _answers.userLabel((l) => l.apaQuickWhyHeld);
    if (_fna && state.inVoice && _session != null) {
      return _voiceWhyHeld(_labelText(user));
    }
    return _answer(user, _fna ? _heldAnswer() : _answers.whyHeld(_snapshot));
  }

  /// "নিরাপদ থাকার ৫ নিয়ম": one bubble per rule; with the flag on the chat
  /// agent answers from the knowledge base, the rules as its offline answer.
  Future<void> showRules() async {
    final user = _answers.userLabel((l) => l.apaQuickRules);
    if (!_fna) return _answer(user, _answers.rules());
    if (await _askLive(_labelText(user))) return;
    return _askAgent(user, _labelText(user), offline: _answers.rules);
  }

  /// A topic chip with free [question] text. Same as a
  /// typed line, except it never goes to an armed scam check.
  Future<void> askQuestion(String question) async {
    if (state.scamCheck) _set(state.copyWith(scamCheck: false));
    await sendText(question);
  }

  /// "কেউ ফোনে কোড চাইছে": asks for the caller's words and arms the check.
  /// In voice mode the question goes to Live, which answers aloud and can
  /// run `check_caller_words`; the typed check is never armed there.
  Future<void> startScamCheck() async {
    if (state.busy) return;
    if (_fna && state.inVoice && _session != null) {
      final question = FnaVoiceLines.codeAsked(english: _english);
      if (await _askLive(question)) return;
      // Live cannot take it: the chat agent answers the same question.
      return _askAgent(
        ApaTurn(
          speaker: ApaTurn.user,
          textBn: question,
          textEn: question,
          path: ApaTurn.guide,
        ),
        question,
      );
    }
    await _answer(_answers.userLabel((l) => l.apaQuickCodeAsked), [
      _answers.scamPrompt(),
    ]);
    _set(state.copyWith(scamCheck: true));
  }

  void cancelScamCheck() {
    if (state.scamCheck) _set(state.copyWith(scamCheck: false));
  }

  /// In-sheet effect of a bubble or card action (navigation and dialling
  /// are the UI's).
  Future<void> runAction(ApaAction action) => switch (action) {
    ApaAction.openApaScamCheck => startScamCheck(),
    ApaAction.learnRules => showRules(),
    ApaAction.openApproveOrHeld => askWhyHeld(),
    _ => Future<void>.value(),
  };

  /// Posts the caller's words to `/v1/scam/turn` and explains the answer.
  /// A non-benign result stores the `evidence_quote` for the next transfer
  /// (`/v1/intervene` carries it) and raises the session's scam score.
  Future<void> _submitScamCheck(String raw) async {
    final (text, redacted) = ApaAnswers.redactSecrets(raw);
    final user = ApaTurn(
      speaker: ApaTurn.user,
      textBn: text,
      textEn: text,
      path: ApaTurn.guide,
    );
    _set(
      state.copyWith(
        turns: [...state.turns, user, if (redacted) _answers.secretRedacted()],
        error: null,
        busy: true,
        scamCheck: false,
      ),
    );
    final generation = _generation;
    ApaTurn reply;
    try {
      final response = await _postScamTurn(text);
      if (!ref.mounted || generation != _generation) return;
      final (keep, _) = await _keepScamResult(response);
      reply = _answers.scamResult(response, saved: keep);
    } on Object catch (e) {
      if (generation != _generation) return;
      Log.w(_tag, 'scam check failed', e);
      reply = _answers.scamFailed();
    }
    if (generation != _generation) return;
    _set(state.copyWith(turns: [...state.turns, reply], busy: false));
    if (!_fna) await _speakTurn(reply);
  }

  /// `check_caller_words` (voice mode and the chat agent): the same scam
  /// check as a typed line, without a bubble; the call summary card shows
  /// the result. [words] are already redacted. `null` when the check failed
  /// or the sheet session changed meanwhile.
  Future<FnaCallSummary?> checkCallerWords(
    String words, {
    bool Function()? stillWanted,
  }) async {
    if (stillWanted != null && !stillWanted()) return null;
    final generation = _generation;
    try {
      final response = await _postScamTurn(words);
      if (!ref.mounted || generation != _generation) return null;
      // A chat attempt that timed out meanwhile stores nothing.
      if (stillWanted != null && !stillWanted()) return null;
      final (_, summary) = await _keepScamResult(response);
      return summary ?? FnaCallSummary.fromScamTurn(response, DateTime.now());
    } on Object catch (e) {
      Log.w(_tag, 'caller check failed', e);
      return null;
    }
  }

  /// One caller line to `/v1/scam/turn` with the scam check's request shape.
  Future<ScamTurnResponse> _postScamTurn(String text) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return ref
        .read(riskApiProvider)
        .postScamTurn(
          ScamTurnRequest(
            sessionId: ref.read(sessionRepoProvider).sessionId,
            turns: [Turn(speaker: Turn.callerSpeaker, text: text, ts: now)],
            pendingAction: scamPendingAction,
          ),
        );
  }

  /// A non-benign result with a quote stores the `evidence_quote` for the
  /// next transfer and raises the session's scam score (`keep`); any
  /// non-benign result becomes the last flagged call (`summary`).
  Future<(bool, FnaCallSummary?)> _keepScamResult(ScamTurnResponse r) async {
    final quote = r.evidenceQuote.trim();
    final benign = ApaAnswers.isBenign(r);
    final keep = !benign && quote.isNotEmpty;
    if (keep) {
      ref.read(lastEvidenceQuoteProvider.notifier).state = quote;
      await _raiseScamScore(r.rollingScore);
    }
    if (benign || !ref.mounted) return (keep, null);
    final summary = FnaCallSummary.fromScamTurn(r, DateTime.now());
    ref.read(lastCallSummaryProvider.notifier).state = summary;
    return (keep, summary);
  }

  /// `pending_action` of the scam check: the customer is about to pay.
  static const scamPendingAction = 'send_money';

  /// Writes [score] as the session's `scam_score` when higher, so the next
  /// `/v1/risk/score` sees the conversation (the demo replay does the same).
  Future<void> _raiseScamScore(double score) async {
    final uid = ref.read(currentUserProvider).value?.uid;
    if (uid == null) return;
    try {
      final current = ref.read(demoStateProvider).value ?? DemoState.initial;
      if (score <= current.scamScore) return;
      await ref
          .read(demoStateRepoProvider)
          .write(uid, current.copyWith(scamScore: score));
    } on Object catch (e) {
      Log.w(_tag, 'could not store the scam score', e);
    }
  }

  /// The hold-to-talk button went down. Live when available and the
  /// microphone is granted; otherwise a hint that the text path is in use.
  Future<void> holdStart() async {
    if (_fna) return; // voice mode replaces hold-to-talk
    if (state.listening) return;
    _holdActive = true;
    if (!state.liveAvailable) {
      _set(
        state.copyWith(error: ApaHint.liveUnavailable, path: _idlePath(false)),
      );
      return;
    }
    if (!await _mic.requestPermission()) {
      _set(state.copyWith(error: ApaHint.micDenied, path: _idlePath(false)));
      return;
    }
    if (!_holdActive) return; // released while the permission dialog was up
    if (!_liveStarted) {
      _liveStarted = true;
      _connecting = _live
          .start(
            _context,
            onAudio: _onLiveAudio,
            onTranscript: _onLiveTranscript,
            onTurnComplete: _onLiveTurnComplete,
            onError: _onLiveError,
          )
          .whenComplete(() => _connecting = null);
    }
    // One connect for every hold pressed while it is in flight.
    final connecting = _connecting;
    if (connecting != null) await connecting;
    if (!_liveStarted) return; // start failed and reported
    // Released while the session opened: keep it for the next hold (as
    // after any turn) but never open the microphone.
    if (!_holdActive) return;
    // Another hold is already opening (or holds) the microphone.
    if (_micOpening || _micSubscription != null) return;
    _micOpening = true;
    try {
      await _audio.stop();
      await _native.stopPcm();
      if (!_holdActive) return;
      final stream = await _mic.start();
      if (!_holdActive || !ref.mounted) {
        // Released while the recorder was starting: close it at once.
        Log.d(_tag, 'hold released during mic start, closing the mic');
        await _mic.stop();
        return;
      }
      _micSubscription = stream.listen(
        (chunk) => unawaited(_live.sendPcm16k(chunk)),
        onError: (Object e) => Log.w(_tag, 'mic stream error', e),
      );
    } finally {
      _micOpening = false;
    }
    _set(
      state.copyWith(
        listening: true,
        speaking: false,
        error: null,
        path: ApaTurn.live,
      ),
    );
  }

  /// The button went up: close the microphone and let Apa answer.
  Future<void> holdEnd() async {
    if (_fna) return;
    _holdActive = false;
    if (!state.listening) return;
    // Not awaited: cancel() resolves on the root zone, which never progresses
    // under FakeAsync in widget tests; nothing downstream depends on it.
    unawaited(_micSubscription?.cancel());
    _micSubscription = null;
    await _mic.stop();
    _liveTurnOpen = false;
    _set(state.copyWith(listening: false, speaking: true));
    await _live.endTurn();
  }

  // ------------------------------------------------ contract
  // The UI slice codes against these; every one is a no-op with the flag
  // off.

  /// Opens voice mode (the "Talk" button): mic permission, Live session,
  /// greeting. Falls back to the chat with [ApaState.voiceFallback] set.
  /// [tapToTalk] (TalkBack): the mic opens for one turn per tap on the tile
  /// ([resumeVoice]) instead of listening hands-free.
  Future<void> startVoice({bool tapToTalk = false}) async {
    if (!_fna || state.inVoice || !ref.mounted) return;
    _tapToTalk = tapToTalk;
    // A voice mode that ended while the app was hidden never got its
    // onAppVisible: read the real state now.
    _appVisible = _appInForeground();
    final FnaVoiceSession? session;
    try {
      session = ref.read(fnaVoiceSessionFactoryProvider)(
        () => _snapshot,
        tapToTalk: tapToTalk,
      );
    } on Object catch (e) {
      Log.w(_tag, 'voice session could not be built', e);
      _voiceUnavailable();
      return;
    }
    if (session == null) {
      _voiceUnavailable();
      return;
    }
    final epoch = ++_voiceEpoch;
    _session = session;
    _pausedDuringLine = false;
    _lineDepth = 0;
    _sessionSub = session.events.listen((e) => _onVoiceEvent(epoch, e));
    // On screen at once (the tap's feedback), before any await.
    _set(
      state.copyWith(
        voicePhase: FnaPhase.micPermission,
        voiceFallback: null,
        error: null,
        scamCheck: false,
        userCaption: '',
        modelCaption: '',
        secretBlocked: false,
      ),
    );
    _micLevel.value = 0;
    // Nothing else may talk over the greeting or be heard by the mic.
    await _stopHearing();
    await _voice.stop();
    if (epoch != _voiceEpoch) return; // closed meanwhile
    await session.start();
  }

  /// Voice mode was opened with `tapToTalk`.
  bool get tapToTalk => _tapToTalk;

  /// Closes voice mode and returns to the chat; the voice turns stay in the
  /// transcript.
  Future<void> endVoice() async {
    if (!_fna) return;
    await _endVoiceSession();
  }

  /// Mic off, session kept (the Pause control). Pressed while the app
  /// speaks over voice mode, it keeps the session paused after that line.
  Future<void> pauseVoice() async {
    if (_speakingOverVoice) {
      _pausedDuringLine = true;
      return;
    }
    await _session?.pause();
  }

  /// Mic on again after [pauseVoice]; in tap-to-talk mode the tile's tap
  /// (one turn). Never while the app speaks over voice mode: the mic stays
  /// closed until that line has ended.
  Future<void> resumeVoice() async {
    if (_speakingOverVoice) {
      _pausedDuringLine = false;
      return;
    }
    await _session?.resume();
  }

  /// Stops FNA's speech now (the Stop control): the Live answer in voice
  /// mode, a line the app speaks over voice mode (the held line, the call
  /// summary), and a "Hear it" line anywhere.
  Future<void> stopSpeaking() async {
    if (!_fna) return;
    await _stopHearing();
    if (_speakingOverVoice) {
      // The held line: stop it and let [_overVoice] listen again now.
      _cancelLine();
      await _voice.stop();
      return;
    }
    final session = _session;
    if (session != null) {
      await session.stopSpeaking();
      return;
    }
    // The chat: whatever the app is saying.
    _cancelLine();
    await _voice.stop();
    _set(state.copyWith(speaking: false));
  }

  /// The app went to the background (or an in-app screen covers voice
  /// mode): voice mode pauses (never on inactive), and whatever the app says
  /// over it (the greeting, a held line) stops.
  void onAppHidden() {
    _appVisible = false;
    final session = _session;
    if (session == null) return;
    unawaited(session.onAppHidden());
    unawaited(_stopHearing());
    _cancelLine();
    unawaited(_voice.stop());
  }

  /// `true` unless the app is hidden or paused now. `null` (no frame yet,
  /// plain tests) and `inactive` (a system dialog) count as visible.
  static bool _appInForeground() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s != AppLifecycleState.hidden && s != AppLifecycleState.paused;
    } on Object {
      return true;
    }
  }

  /// The app is in the foreground again. Voice mode stays paused until the
  /// customer resumes it; this only lets a later line reopen the mic.
  void onAppVisible() => _appVisible = true;

  /// Clears the voice fallback after the chat has shown it.
  void dismissVoiceFallback() {
    if (state.voiceFallback != null) {
      _set(state.copyWith(voiceFallback: null));
    }
  }

  /// Plays [turn] aloud ("Hear it") in the app language (Bangla `textBn`,
  /// English `textEn`); a second tap on the same turn stops it. In voice
  /// mode the session pauses while the line plays, so the mic never hears
  /// it, and listens again afterwards.
  Future<void> hearIt(ApaTurn turn) async {
    if (!_fna) return;
    if (state.hearingTurn == turn) {
      await _stopHearing();
      return;
    }
    await _stopHearing();
    final utterance = _utteranceOf(turn);
    if (utterance == null) return;
    final token = ++_hearToken;
    _set(state.copyWith(hearingTurn: turn, speaking: true));
    if (state.inVoice && _session != null) {
      await _overVoice(() => _speakAndWait(utterance));
    } else {
      await _speakAndWait(utterance);
    }
    if (token == _hearToken) _clearHearing();
  }

  /// Reads the call summary card aloud (fixed spoken template, not the
  /// model); a second tap stops it. [ApaState.hearingSummary] is `true`
  /// while it plays. In voice mode the session pauses for it and listens
  /// again afterwards.
  Future<void> hearCallSummary() async {
    if (!_fna) return;
    if (state.hearingSummary) {
      await _stopHearing();
      return;
    }
    final summary = state.callSummary;
    if (summary == null) return;
    await _stopHearing();
    final english = _english;
    final text = callSummarySpeech(summary, english: english);
    final utterance = ApaUtterance(
      textBn: english ? '' : text,
      textEn: english ? text : '',
      english: english,
    );
    final token = ++_hearToken;
    _set(state.copyWith(hearingSummary: true, speaking: true));
    if (state.inVoice && _session != null) {
      await _overVoice(() => _speakAndWait(utterance));
    } else {
      await _speakAndWait(utterance);
    }
    if (token == _hearToken) _clearHearing();
  }

  /// `true` when the mic permission is denied for good.
  Future<bool> micPermanentlyDenied() async {
    try {
      return await ref.read(fnaAudioInProvider).permanentlyDenied();
    } on Object catch (e) {
      Log.w(_tag, 'mic permission status unavailable', e);
      return false;
    }
  }

  /// `show_hold_reason` (voice mode and the chat agent): the server's held
  /// text, built exactly like the first bubble of [openFor] (FR-3), then
  /// the handoff the model says. In voice mode Live audio is muted and the
  /// mic closed (the session pauses) while the app speaks the line itself,
  /// until the line has really finished playing; in the chat the line is
  /// shown, not spoken. [stillWanted] (the chat agent's attempt) is checked
  /// before anything changes. Never throws.
  Future<void> showHoldReason({bool Function()? stillWanted}) async {
    if (!_fna || !ref.mounted) return;
    if (stillWanted != null && !stillWanted()) return;
    final generation = _generation;
    final turns = _heldLineTurns();
    if (turns.isEmpty) return;
    if (!state.inVoice || _session == null) {
      _set(state.copyWith(turns: [...state.turns, ...turns]));
      return;
    }
    await _overVoice(() async {
      if (generation != _generation) return;
      _set(state.copyWith(turns: [...state.turns, ...turns]));
      final utterance = _utteranceOf(turns.first);
      if (utterance != null) await _speakAndWait(utterance);
    });
  }

  /// The spoken call summary: what the card shows, as one fixed template in
  /// the app language. The caller's words are read as the server quoted
  /// them, with any code-like digits masked (never read a code aloud).
  String callSummarySpeech(FnaCallSummary s, {required bool english}) {
    final secret = _answers.secretLabel(s.requestedSecret, english: english);
    final (quote, _) = ApaAnswers.redactSecrets(s.evidenceQuote.trim());
    final advice = _answers.scamAdvice(
      ScamTurnResponse(
        scamType: s.scamType,
        urgency: s.urgency,
        requestedSecret: s.requestedSecret,
        confidence: 0,
        evidenceQuote: s.evidenceQuote,
        recommendedAction: s.recommendedAction,
        rollingScore: 0,
      ),
      english: english,
    );
    final kb = ref.mounted ? ref.read(safetyKnowledgeProvider).value : null;
    final next = kb == null ? null : fnaPreventText(kb, s, english: english);
    final l = english
        ? (
            title: FnaVoiceLines.summaryTitleEn,
            asked: FnaVoiceLines.summaryAskedEn,
            words: FnaVoiceLines.summaryWordsEn,
            now: FnaVoiceLines.summaryNowEn,
            next: FnaVoiceLines.summaryNextEn,
            stop: '.',
          )
        : (
            title: FnaVoiceLines.summaryTitleBn,
            asked: FnaVoiceLines.summaryAskedBn,
            words: FnaVoiceLines.summaryWordsBn,
            now: FnaVoiceLines.summaryNowBn,
            next: FnaVoiceLines.summaryNextBn,
            stop: '।',
          );
    return [
      l.title,
      if (secret != null) '${l.asked} $secret${l.stop}',
      if (quote.isNotEmpty) '${l.words} "$quote"${l.stop}',
      '${l.now} $advice',
      if (next != null && next.trim().isNotEmpty) '${l.next} ${next.trim()}',
    ].join(' ');
  }

  /// Clears the hint after the user has seen it.
  void dismissError() {
    if (state.error != null) _set(state.copyWith(error: null));
  }

  /// The sheet closed: stop everything that makes sound.
  Future<void> close() async {
    await _teardown();
    if (!_fna) return;
    // Voice mode and "Hear it" are over; the transcript stays until the
    // next [openFor].
    _set(
      state.copyWith(
        voicePhase: null,
        userCaption: '',
        modelCaption: '',
        hearingTurn: null,
        hearingSummary: false,
        speaking: false,
      ),
    );
    _micLevel.value = 0;
  }

  // ------------------------------------------------------------- internals

  /// Speaks a turn's Bangla line. Apa's voice is Bangla (bn-BD TTS and the
  /// bundled clips), so in English only the server's held line is spoken.
  Future<void> _speakTurn(ApaTurn turn) async {
    if (_english && turn.path != ApaTurn.held) return;
    await _speak(turn.textBn, textEn: turn.textEn ?? '');
  }

  Future<void> _speak(String textBn, {String textEn = ''}) async {
    _set(state.copyWith(speaking: true));
    try {
      // A bundled clip when the text is one, else the dynamic voices
      // (server audio, Gemini TTS, the phone's own voice).
      // The spoken line follows the app language.
      await _voice.speak(
        ApaUtterance(textBn: textBn, textEn: textEn, english: _english),
      );
    } on Object catch (e) {
      Log.w(_tag, 'speak failed', e);
    }
    // ApaAudio implementations never throw; `speaking` is cleared by the next
    // user action or when the audio events say so.
    if (!_audio.isPlaying) _set(state.copyWith(speaking: false));
  }

  void _onLiveAudio(Uint8List pcm24k) {
    if (!state.speaking) _set(state.copyWith(speaking: true));
    unawaited(_native.playPcm(pcm24k, FirebaseApaLiveService.outputSampleRate));
  }

  void _onLiveTranscript(String text) {
    final turns = [...state.turns];
    if (_liveTurnOpen &&
        turns.isNotEmpty &&
        turns.last.isApa &&
        turns.last.path == ApaTurn.live) {
      final last = turns.removeLast();
      turns.add(last.copyWith(textBn: '${last.textBn}$text'));
    } else {
      turns.add(
        ApaTurn(speaker: ApaTurn.apa, textBn: text, path: ApaTurn.live),
      );
      _liveTurnOpen = true;
    }
    _set(state.copyWith(turns: turns));
  }

  void _onLiveTurnComplete() {
    _liveTurnOpen = false;
    _set(state.copyWith(speaking: false));
  }

  void _onLiveError(Object error) {
    Log.w(_tag, 'live failed, falling back to text', error);
    _liveStarted = false;
    unawaited(_micSubscription?.cancel());
    _micSubscription = null;
    unawaited(_mic.stop());
    unawaited(_live.stop());
    _set(
      state.copyWith(
        listening: false,
        speaking: false,
        path: _idlePath(false),
        error: ApaHint.liveFailed,
      ),
    );
  }

  // ------------------------------------------------ chat internals

  /// A chip in voice mode: [question] goes to the Live session, which
  /// answers aloud. `false` when voice mode is not open or the session
  /// cannot take text now (the chat path answers instead).
  Future<bool> _askLive(String question) async {
    final session = _session;
    if (!_fna || !state.inVoice || session == null) return false;
    if (state.scamCheck) _set(state.copyWith(scamCheck: false));
    await _stopLineForCustomer();
    return _sendToLive(session, question);
  }

  /// Longest wait for a paused session to reconnect before a chip or typed
  /// line goes to the chat agent instead.
  static const _reconnectWait = Duration(seconds: 6);

  /// The same while voice mode is still opening: the greeting (at most
  /// [fnaSpeechMaxWaitProvider]) plus the setup timeout.
  Duration get _openingWait =>
      (ref.mounted
          ? ref.read(fnaSpeechMaxWaitProvider)
          : const Duration(seconds: 15)) +
      (_session?.config.setupTimeout ?? const Duration(seconds: 5)) +
      const Duration(seconds: 1);

  /// Sends [text] to Live. A paused session may have closed its connection
  /// (silence, the app hidden, Pause): then it is resumed (it reconnects)
  /// and the line is sent once more when it listens again. `false` when it
  /// still cannot take the line.
  Future<bool> _sendToLive(FnaVoiceSession session, String text) async {
    if (await session.sendText(text)) return true;
    if (session.phase != FnaPhase.paused &&
        session.phase != FnaPhase.reconnecting &&
        session.phase != FnaPhase.connecting) {
      return false;
    }
    final epoch = _voiceEpoch;
    final opening = session.phase == FnaPhase.connecting;
    final ready = Completer<void>();
    void done() {
      if (!ready.isCompleted) ready.complete();
    }

    final sub = session.events.listen((e) {
      // Listening again, or voice mode is over (then the chat answers).
      if (e is FnaPhaseChanged &&
          (e.phase == FnaPhase.listening ||
              e.phase == FnaPhase.ended ||
              e.phase == FnaPhase.textFallback ||
              e.phase == FnaPhase.offline)) {
        done();
      }
    }, onDone: done);
    try {
      await session.resume();
      if (session.phase != FnaPhase.listening) {
        await ready.future.timeout(opening ? _openingWait : _reconnectWait);
      }
    } on Object catch (e) {
      Log.w(_tag, 'voice session did not come back for a typed line', e);
      return false;
    } finally {
      unawaited(sub.cancel());
    }
    if (epoch != _voiceEpoch || !identical(_session, session)) return false;
    return session.sendText(text);
  }

  /// The customer talks (a chip, a typed line) while the app speaks over
  /// voice mode: the app's line stops first.
  Future<void> _stopLineForCustomer() async {
    await _stopHearing();
    if (_speakingOverVoice) {
      _cancelLine();
      await _voice.stop();
    }
  }

  /// "Why is my money held?" in voice mode (a chip or a typed line): the
  /// customer's words, then the server's text spoken by the app with the mic
  /// closed (FR-3), then the handoff line. The model never gets the
  /// question.
  Future<void> _voiceWhyHeld(String said) async {
    final generation = _generation;
    _set(
      state.copyWith(
        turns: [
          ...state.turns,
          ApaTurn(
            speaker: ApaTurn.user,
            textBn: said,
            textEn: said,
            path: ApaTurn.live,
          ),
        ],
        scamCheck: false,
      ),
    );
    await _stopLineForCustomer();
    await showHoldReason();
    if (generation != _generation || !ref.mounted) return;
    _set(state.copyWith(turns: [...state.turns, _handoffTurn()]));
  }

  /// A typed line with the flag on. In voice mode ("Type instead") it goes
  /// to the Live session; otherwise: codes masked and warned about, a "why
  /// is my money held" question answered from the server's reasons (FR-3),
  /// everything else to the chat agent.
  Future<void> _sendTextFna(String raw) async {
    final session = _session;
    final (text, redacted) = ApaAnswers.redactSecrets(raw);
    if (state.inVoice && session != null) {
      if (!redacted && ApaAnswers.asksWhyHeld(text)) {
        // Typed in voice mode: the app answers with the server's text and
        // speaks it itself; the model never gets the question (FR-3).
        await _voiceWhyHeld(text);
        return;
      }
      await _stopLineForCustomer();
      if (await _sendToLive(session, raw)) return;
    }
    final user = ApaTurn(
      speaker: ApaTurn.user,
      textBn: text,
      textEn: text,
      path: ApaTurn.guide,
    );
    if (redacted) {
      final warn = _answers.secretRedacted();
      if (!_hasWords(text)) {
        _set(state.copyWith(turns: [...state.turns, user, warn], error: null));
        return;
      }
      // The warning first, then the masked question to the agent: the model
      // never sees the digits, and the customer still gets an answer.
      await _askAgent(user, text, warning: warn);
      return;
    }
    if (ApaAnswers.asksWhyHeld(text)) {
      _set(
        state.copyWith(
          turns: [...state.turns, user, ..._heldAnswer()],
          error: null,
        ),
      );
      return;
    }
    await _askAgent(user, text);
  }

  /// Shows [user], asks the chat agent [question] with the conversation so
  /// far, and appends its answer (not spoken). When the agent could only
  /// give the offline guide and the chip has a better deterministic answer,
  /// [offline] gives it.
  Future<void> _askAgent(
    ApaTurn user,
    String question, {
    List<ApaTurn> Function()? offline,
    ApaTurn? warning,
  }) async {
    if (state.busy) return;
    _set(
      state.copyWith(
        turns: [...state.turns, user, ?warning],
        error: null,
        busy: true,
        scamCheck: false,
      ),
    );
    final generation = _generation;
    try {
      final reply = await _agent.ask(question, _snapshot);
      if (generation != _generation) {
        Log.d(_tag, 'agent reply arrived after the sheet closed; dropped');
        return;
      }
      final replies = reply.path == ApaTurn.guide && offline != null
          ? offline()
          : [_replyTurn(reply)];
      if (replies.isEmpty) throw StateError('no answer');
      _set(
        state.copyWith(
          turns: [...state.turns, ...replies],
          busy: false,
          path: state.path == ApaTurn.live ? null : replies.last.path,
        ),
      );
    } on Object catch (e) {
      if (generation != _generation) return;
      Log.w(_tag, 'agent turn failed', e);
      _set(state.copyWith(error: ApaHint.textFailed, busy: false));
    }
  }

  static final _letter = RegExp(r'\p{L}', unicode: true);

  /// [masked] still has a word besides the masks (worth asking about).
  static bool _hasWords(String masked) =>
      _letter.hasMatch(masked.replaceAll(FnaTranscriptGuard.mask, ' '));

  /// A chip label as the customer would type it, in the app language.
  String _labelText(ApaTurn label) =>
      _english ? (label.textEn ?? label.textBn) : label.textBn;

  /// The agent's answer as a bubble. A model answer is in the app language
  /// only (like the old Gemini path); a guide chunk carries both.
  ApaTurn _replyTurn(FnaTextReply reply) {
    final english = _english;
    return ApaTurn(
      speaker: ApaTurn.apa,
      textBn: reply.textBn ?? (english ? '' : reply.text),
      textEn: reply.textEn ?? (english ? reply.text : null),
      path: reply.path,
      source: reply.path == ApaTurn.gemini ? ApaSource.ai : ApaSource.rules,
      // "I do not know": the helpline is the next step.
      action: reply.dontKnow ? ApaAction.callHelpline : ApaAction.none,
    );
  }

  /// "Why is my money held?" with the flag on: the server's reasons and the
  /// next step (as before), then the fixed handoff line when a reason was
  /// shown. No model is involved (FR-3).
  List<ApaTurn> _heldAnswer() {
    final snapshot = _snapshot;
    return [
      ..._answers.whyHeld(snapshot),
      if (snapshot.transferPending && snapshot.heldReasons.isNotEmpty)
        _handoffTurn(),
    ];
  }

  ApaTurn _handoffTurn() => const ApaTurn(
    speaker: ApaTurn.apa,
    textBn: FnaLines.holdHandoffBn,
    textEn: FnaLines.holdHandoffEn,
    path: ApaTurn.guide,
    source: ApaSource.rules,
  );

  /// The held line for `show_hold_reason`: the reasons [openFor] was given,
  /// else the snapshot's, joined exactly like the first bubble of [openFor];
  /// with nothing held, the deterministic "nothing is held" answer.
  List<ApaTurn> _heldLineTurns() {
    final given = _held?.reasons ?? const <Reason>[];
    final reasons = given.isNotEmpty ? given : _snapshot.heldReasons;
    if (reasons.isEmpty) return _answers.whyHeld(_snapshot);
    return [
      ApaTurn(
        speaker: ApaTurn.apa,
        textBn: reasons.map((r) => r.textBn).join(' '),
        textEn: reasons.map((r) => r.textEn).join(' '),
        path: ApaTurn.held,
        source: ApaSource.server,
      ),
    ];
  }

  static final _bangla = RegExp('[ঀ-৿]');

  /// What "Hear it" says for [turn]: the app language's text (the other
  /// one when it is empty), in the voice of the language it is written in.
  ApaUtterance? _utteranceOf(ApaTurn turn) {
    final en = (turn.textEn ?? '').trim();
    final bn = turn.textBn.trim();
    final text = _english
        ? (en.isNotEmpty ? en : bn)
        : (bn.isNotEmpty ? bn : en);
    if (text.isEmpty) return null;
    final english = !_bangla.hasMatch(text);
    return ApaUtterance(
      textBn: english ? '' : text,
      textEn: english ? text : '',
      english: english,
    );
  }

  /// Speaks [u] and waits until it has really finished playing (at most
  /// [fnaLineMaxWaitProvider]; then the player is stopped). Stop, End and a
  /// new line end the wait at once through [_cancelLine].
  Future<FnaSpoken> _speakAndWait(ApaUtterance u) {
    _cancelLine();
    final cancel = _lineCancel = Completer<void>();
    return fnaSpeakAndWait(
      _voice,
      _audio,
      u,
      maxWait: ref.mounted
          ? ref.read(fnaLineMaxWaitProvider)
          : const Duration(seconds: 60),
      cancel: cancel.future,
    ).whenComplete(() {
      if (identical(_lineCancel, cancel)) _lineCancel = null;
    });
  }

  /// Ends the wait of the line the app is speaking, if any.
  void _cancelLine() {
    final cancel = _lineCancel;
    _lineCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Runs [speak] with the voice session paused for an app line (mic
  /// closed, Live audio stopped and muted, the connection kept open so a
  /// tool call still gets its response), then listens again only when the
  /// session is still the open one, the customer had not paused it (before
  /// or during the line) and the app is in the foreground. The view shows
  /// "speaking" meanwhile. A line that starts while another one runs
  /// ("Hear it" during the held line) shares that pause: only the last one
  /// to end listens again, so the app's own pause is never taken for the
  /// customer's.
  Future<void> _overVoice(Future<void> Function() speak) async {
    final session = _session;
    final epoch = _voiceEpoch;
    if (_lineDepth == 0) {
      _pausedBeforeLine = session?.pausedByCustomer ?? false;
      _pausedDuringLine = false;
    }
    _lineDepth++;
    _speakingOverVoice = true;
    try {
      await session?.pauseForAppLine();
      if (epoch == _voiceEpoch && state.inVoice) {
        _set(state.copyWith(voicePhase: FnaPhase.speaking));
      }
      await speak();
    } on Object catch (e) {
      Log.w(_tag, 'line over voice mode failed', e);
    } finally {
      if (_lineDepth > 0) _lineDepth--;
      if (_lineDepth == 0) await _afterLines(session, epoch);
    }
  }

  /// The last line over voice mode has ended: listen again, or keep the
  /// customer's pause, or close for the background.
  Future<void> _afterLines(FnaVoiceSession? session, int epoch) async {
    _speakingOverVoice = false;
    final wasPaused = _pausedBeforeLine;
    final pausedDuring = _pausedDuringLine;
    _pausedBeforeLine = false;
    _pausedDuringLine = false;
    if (session != null && epoch == _voiceEpoch) {
      if (!_appVisible) {
        // Hidden: everything closes now (also an app-line pause).
        await session.onAppHidden();
      } else if (wasPaused || pausedDuring) {
        // The customer's pause: it closes on its own timer.
        await session.pause();
      } else {
        // Listens again; also clears a pause asked for during the setup.
        await session.resumeAfterAppLine();
      }
      if (session.phase == FnaPhase.paused &&
          epoch == _voiceEpoch &&
          ref.mounted) {
        // Stays paused: show it so (not "speaking").
        _set(state.copyWith(voicePhase: FnaPhase.paused, speaking: false));
      }
    }
  }

  /// Stops a "Hear it" line or the spoken call summary, if one plays.
  Future<void> _stopHearing() async {
    _hearToken++;
    if (state.hearingTurn == null && !state.hearingSummary) return;
    _cancelLine();
    await _voice.stop();
    _clearHearing();
  }

  void _clearHearing() {
    if (state.hearingTurn != null || state.hearingSummary) {
      _set(
        state.copyWith(
          hearingTurn: null,
          hearingSummary: false,
          speaking: false,
        ),
      );
    }
  }

  // ----------------------------------------------- voice internals

  /// No Live client (Firebase not configured): the chat answers.
  void _voiceUnavailable() {
    _set(
      state.copyWith(
        voicePhase: null,
        voiceFallback: FnaFallbackReason.liveFailed,
        error: ApaHint.liveUnavailable,
      ),
    );
  }

  /// Folds one session event into the state. Events of an older voice mode
  /// are dropped; nothing here throws into the session's stream.
  void _onVoiceEvent(int epoch, FnaSessionEvent e) {
    if (epoch != _voiceEpoch || !ref.mounted) return;
    try {
      switch (e) {
        case FnaPhaseChanged():
          _onVoicePhase(e.phase);
        case FnaUserCaption():
          // A new customer turn replaces the last answer kept on screen.
          _set(
            state.copyWith(
              userCaption: e.text,
              modelCaption: state.voicePhase == FnaPhase.listening
                  ? ''
                  : state.modelCaption,
              secretBlocked: false,
            ),
          );
        case FnaModelCaption():
          _set(state.copyWith(modelCaption: e.text, secretBlocked: false));
        case FnaTurnFinished():
          _onVoiceTurn(e);
        case FnaSecretBlocked():
          _set(
            state.copyWith(
              turns: [...state.turns, _secretSpokenTurn()],
              userCaption: e.maskedText,
              modelCaption: '',
              secretBlocked: true,
            ),
          );
        case FnaModelBlocked():
          _set(state.copyWith(modelCaption: _safeLine));
        case FnaToolEvent():
          // The call summary card follows lastCallSummaryProvider; the other
          // tools show nothing of their own.
          break;
        case FnaFallback():
          _onVoiceFallback(e.reason);
        case FnaLevel():
          // Many per second: a notifier, never a state rebuild.
          _micLevel.value = e.level;
      }
    } on Object catch (err, st) {
      Log.e(_tag, 'voice event fold failed', err, st);
    }
  }

  String get _safeLine => FnaVoiceLines.safeLine(english: _english);

  /// The warning bubble for a code heard in voice mode.
  ApaTurn _secretSpokenTurn() => ApaTurn(
    speaker: ApaTurn.apa,
    textBn: ref.read(apaL10nBnProvider).fnaSecretSpoken,
    textEn: ref.read(apaL10nEnProvider).fnaSecretSpoken,
    path: ApaTurn.guide,
    tone: ApaSeverity.danger,
    source: ApaSource.rules,
  );

  void _onVoicePhase(FnaPhase phase) {
    switch (phase) {
      case FnaPhase.ended || FnaPhase.textFallback || FnaPhase.offline:
        _detachVoice();
        _micLevel.value = 0;
        _set(
          state.copyWith(
            voicePhase: null,
            userCaption: '',
            modelCaption: '',
            speaking: false,
          ),
        );
      case FnaPhase.paused when _speakingOverVoice:
        _set(state.copyWith(voicePhase: FnaPhase.speaking));
      default:
        if (phase != FnaPhase.listening) _micLevel.value = 0;
        _set(
          state.copyWith(
            voicePhase: phase,
            speaking: phase == FnaPhase.speaking,
          ),
        );
    }
  }

  /// A finished exchange becomes two bubbles: the customer's words (codes
  /// masked) and FNA's answer, or the safe line when the guard stopped it.
  void _onVoiceTurn(FnaTurnFinished e) {
    final (said, _) = ApaAnswers.redactSecrets(e.userText.trim());
    final answer = e.blocked ? _safeLine : e.modelText.trim();
    _set(
      state.copyWith(
        turns: [
          ...state.turns,
          if (said.isNotEmpty)
            ApaTurn(
              speaker: ApaTurn.user,
              textBn: said,
              textEn: said,
              path: ApaTurn.live,
            ),
          if (answer.isNotEmpty)
            ApaTurn(
              speaker: ApaTurn.apa,
              textBn: answer,
              textEn: answer,
              path: ApaTurn.live,
              source: e.blocked ? ApaSource.rules : ApaSource.ai,
            ),
        ],
        // The finished turn stays on screen: the
        // customer can read what FNA just said until they speak again.
        userCaption: said,
        modelCaption: answer,
      ),
    );
  }

  void _onVoiceFallback(FnaFallbackReason reason) {
    _detachVoice();
    _micLevel.value = 0;
    _set(
      state.copyWith(
        voicePhase: null,
        voiceFallback: reason,
        error: switch (reason) {
          FnaFallbackReason.micDenied ||
          FnaFallbackReason.micPermanentlyDenied => ApaHint.micDenied,
          FnaFallbackReason.offline => ApaHint.liveUnavailable,
          FnaFallbackReason.connectTimeout ||
          FnaFallbackReason.liveFailed => ApaHint.liveFailed,
        },
        userCaption: '',
        modelCaption: '',
        speaking: false,
      ),
    );
  }

  /// Forgets the session without ending it (it ended itself).
  FnaVoiceSession? _detachVoice() {
    final session = _session;
    _session = null;
    _voiceEpoch++;
    final sub = _sessionSub;
    _sessionSub = null;
    unawaited(sub?.cancel());
    return session;
  }

  /// Ends the open voice mode, if any; the transcript stays. Whatever the
  /// app says (the greeting, a held line, a "Hear it" line) stops too.
  Future<void> _endVoiceSession() async {
    final session = _detachVoice();
    _micLevel.value = 0;
    if (state.inVoice) {
      _set(
        state.copyWith(
          voicePhase: null,
          userCaption: '',
          modelCaption: '',
          speaking: false,
        ),
      );
    }
    await _stopHearing();
    _cancelLine();
    await _voice.stop();
    if (session == null) return;
    try {
      await session.end();
    } on Object catch (e) {
      Log.w(_tag, 'voice session end failed', e);
    }
  }

  Future<void> _teardown() async {
    _generation++;
    _holdActive = false;
    if (_fna) {
      // Fields only: this runs from `ref.onDispose`, where neither `ref` nor
      // `state` may be touched. [openFor] and [close] reset the state.
      _hearToken++;
      _cancelLine();
      _speakingOverVoice = false;
      _pausedDuringLine = false;
      _lineDepth = 0;
      _agentUsed?.reset();
      final session = _detachVoice();
      if (session != null) {
        try {
          await session.end();
        } on Object catch (e) {
          Log.w(_tag, 'voice session end failed', e);
        }
      }
    }
    unawaited(_micSubscription?.cancel());
    _micSubscription = null;
    _liveTurnOpen = false;
    if (_liveStarted) {
      _liveStarted = false;
      await _live.stop();
    }
    await _mic.stop();
    await _native.stopPcm();
    await _voice.stop();
  }
}

/// The signed-in uid for `ApaTurnRequest.user_id`; the demo uid while
/// signed out (mirrors the `X-Demo-User` fallback).
final apaUserIdProvider = Provider<String>(
  (ref) =>
      ref.watch(currentUserProvider.select((u) => u.value?.uid)) ??
      LocalAuthRepo.signedOutUid,
);

/// Gemini text answers are on only when Firebase is configured.
final apaGeminiEnabledProvider = Provider<bool>(
  (ref) => ref.watch(firebaseStatusProvider) == FirebaseStatus.configured,
);

/// The Gemini call; tests override it with a scripted or failing one.
final apaGeminiGeneratorProvider = Provider<ApaGenerate>((ref) {
  // The shared client (limited-use App Check), read at the first call.
  final generator = FirebaseApaGenerator(ai: () => ref.read(fnaTextAiProvider));
  return generator.call;
});

final apaAnswersProvider = Provider<ApaAnswers>(
  (ref) => ApaAnswers(
    bn: ref.watch(apaL10nBnProvider),
    en: ref.watch(apaL10nEnProvider),
    content: ref.watch(apaContentSyncProvider),
  ),
);

/// The text path: Gemini (when configured) → the offline guide → the
/// `/v1/apa/turn` stub as the last resort. Tests override `riskApiProvider`
/// with `FakeRiskApi` and `apaGeminiGeneratorProvider` as needed.
final apaTextServiceProvider = Provider<ApaService>((ref) {
  final offline = FallbackApaService(
    RuleBasedApaService(ref.watch(apaAnswersProvider)),
    ApaTextService(ref.watch(riskApiProvider), ref.watch(apaUserIdProvider)),
  );
  if (!ref.watch(apaGeminiEnabledProvider)) return offline;
  return GeminiApaService(
    generate: ref.watch(apaGeminiGeneratorProvider),
    fallback: offline,
  );
});

/// Gemini Live only when Firebase is configured;
/// [DisabledApaLiveService] otherwise, so the sheet never touches
/// `firebase_ai` on today's emulator.
final apaLiveServiceProvider = Provider<ApaLiveService>((ref) {
  if (ref.watch(firebaseStatusProvider) != FirebaseStatus.configured) {
    return const DisabledApaLiveService();
  }
  // The shared client (limited-use App Check); see fna_ai_client.dart.
  final service = FirebaseApaLiveService(ai: ref.watch(fnaAiProvider));
  ref.onDispose(() => unawaited(service.stop()));
  return service;
});

final apaControllerProvider = NotifierProvider<ApaController, ApaState>(
  ApaController.new,
);
