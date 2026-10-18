/// The FNA voice session: a pure Dart state
/// machine between the Live transport, the microphone, the player and the
/// tools. No Riverpod, no widgets: `ApaController` owns one per voice mode
/// and folds its [events] into bubbles.
///
/// Every connection gets a new session number ([epoch]) and every exchange
/// a turn number ([turnId]); both ride on every event, and an event of an
/// old connection or an interrupted turn is dropped. Nothing here throws to
/// the caller: failures become phase changes and [FnaFallback] events.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/voice/fna_audio.dart';
import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:firebase_ai/firebase_ai.dart';

/// Inner states. The view shows six of them.
enum FnaPhase {
  idle,
  micPermission,
  connecting,
  listening,
  thinking,
  speaking,
  paused,
  reconnecting,
  textFallback,
  offline,
  ended,
}

/// Why voice mode handed over to text.
enum FnaFallbackReason {
  /// No setup within [FnaVoiceConfig.setupTimeout].
  connectTimeout,
  micDenied,

  /// "Don't ask again": the view offers "Open settings".
  micPermanentlyDenied,

  /// The connection failed and the one resume failed too.
  liveFailed,

  /// The connection failed and the phone has no network.
  offline,
}

// ------------------------------------------------------------------ events

sealed class FnaSessionEvent {
  const FnaSessionEvent({required this.epoch, required this.turnId});

  /// The connection the event belongs to.
  final int epoch;

  /// The exchange (customer words plus FNA's answer) it belongs to.
  final int turnId;
}

class FnaPhaseChanged extends FnaSessionEvent {
  const FnaPhaseChanged(
    this.phase,
    this.previous, {
    required super.epoch,
    required super.turnId,
  });
  final FnaPhase phase;
  final FnaPhase previous;
}

/// The customer's words so far in turn [turnId] (replace, do not append).
class FnaUserCaption extends FnaSessionEvent {
  const FnaUserCaption(
    this.text, {
    required this.isFinal,
    required super.epoch,
    required super.turnId,
  });
  final String text;
  final bool isFinal;
}

/// FNA's words so far in turn [turnId] (replace, do not append).
class FnaModelCaption extends FnaSessionEvent {
  const FnaModelCaption(
    this.text, {
    required super.epoch,
    required super.turnId,
  });
  final String text;
}

/// Turn [turnId] is over: the final texts for the transcript.
class FnaTurnFinished extends FnaSessionEvent {
  const FnaTurnFinished({
    required this.userText,
    required this.modelText,
    required this.interrupted,
    required this.blocked,
    required super.epoch,
    required super.turnId,
  });
  final String userText;
  final String modelText;

  /// The customer talked over FNA, typed, paused or tapped Stop.
  final bool interrupted;

  /// The guard stopped FNA's answer ([FnaModelBlocked] came first).
  final bool blocked;
}

/// The customer said a code. The session ended that connection, dropped its
/// resumption handle and is starting a clean one. [maskedText] replaces the
/// caption; the view shows the warning with a haptic.
class FnaSecretBlocked extends FnaSessionEvent {
  const FnaSecretBlocked(
    this.maskedText, {
    required super.epoch,
    required super.turnId,
  });
  final String maskedText;
}

/// The guard stopped FNA's answer: audio is stopped; replace the bubble with
/// the safe line.
class FnaModelBlocked extends FnaSessionEvent {
  const FnaModelBlocked(
    this.reason, {
    required super.epoch,
    required super.turnId,
  });
  final GuardVerdict reason;
}

/// A tool started (or was cancelled by the server), for UI hints. A
/// cancelled call must have its UI additions removed.
class FnaToolEvent extends FnaSessionEvent {
  const FnaToolEvent(
    this.name, {
    this.callId,
    this.cancelled = false,
    required super.epoch,
    required super.turnId,
  });
  final String name;
  final String? callId;
  final bool cancelled;
}

/// Voice mode is over; the chat answers from here.
class FnaFallback extends FnaSessionEvent {
  const FnaFallback(this.reason, {required super.epoch, required super.turnId});
  final FnaFallbackReason reason;
}

/// Microphone level 0..1, for the level bars.
class FnaLevel extends FnaSessionEvent {
  const FnaLevel(this.level, {required super.epoch, required super.turnId});
  final double level;
}

// ------------------------------------------------------------------ config

class FnaVoiceConfig {
  const FnaVoiceConfig({
    this.halfDuplex = false,
    this.tapToTalk = false,
    this.silenceTimeout = const Duration(seconds: 30),
    this.maxSession = const Duration(minutes: 10),
    this.setupTimeout = const Duration(seconds: 5),
    this.thinkingTimeout = const Duration(seconds: 15),
    this.drainSlack = const Duration(milliseconds: 300),
    this.interruptGrace = const Duration(milliseconds: 250),
    this.voiceLevel = 0.04,
    this.pauseCloseDelay = const Duration(seconds: 5),
    this.appLineCloseDelay = const Duration(seconds: 90),
    this.levelInterval = const Duration(milliseconds: 67),
    this.levelStep = 0.02,
  });

  /// Mic closed (nothing sent) while FNA speaks (`FNA_HALF_DUPLEX`).
  final bool halfDuplex;

  /// TalkBack mode: the mic opens only for one turn after [FnaVoiceSession.
  /// resume] ("tap to talk"). After the setup (and the greeting) and after
  /// each answer the session goes to [FnaPhase.paused] with the mic closed.
  final bool tapToTalk;

  /// Listening this long with no voice: pause (and close the connection).
  /// In [tapToTalk] mode also how long a between-turns pause keeps the
  /// connection open.
  final Duration silenceTimeout;

  /// The whole voice session; then it ends.
  final Duration maxSession;

  /// connect to setupComplete.
  final Duration setupTimeout;

  /// Thinking this long with no answer: back to listening.
  final Duration thinkingTimeout;

  /// Added to the computed play time when the player never says "drained".
  final Duration drainSlack;

  /// Audio this soon after an interruption is still the old turn's: drop it
  /// (unless the customer's words arrived in between).
  final Duration interruptGrace;

  /// A mic level above this counts as the customer speaking (resets the
  /// silence timer).
  final double voiceLevel;

  /// The Pause button keeps the Live connection open this long (Live bills
  /// per second while open); then it closes and [FnaVoiceSession.resume]
  /// reconnects with the resumption handle.
  final Duration pauseCloseDelay;

  /// A pause for a line the app speaks ([FnaVoiceSession.pauseForAppLine])
  /// keeps the connection open, so a tool call can still get its response.
  /// This is only a safety limit for a line that never ends: then the
  /// connection closes as after any pause.
  final Duration appLineCloseDelay;

  /// [FnaLevel] events come at most once per this interval (about 15 Hz).
  final Duration levelInterval;

  /// ... and only when the level moved by at least this much.
  final double levelStep;
}

/// Makes a timer; tests pass a fake one.
typedef FnaTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

/// Why the session pauses.
enum _PauseKind {
  /// The Pause button: the connection closes after
  /// [FnaVoiceConfig.pauseCloseDelay].
  manual,

  /// 30 s of silence: the connection closes now.
  silence,

  /// The app went to the background: the connection closes now.
  hidden,

  /// Tap-to-talk between turns: the audio session stays, the connection
  /// closes after [FnaVoiceConfig.silenceTimeout].
  turnEnd,

  /// The app speaks a line itself (the held line, the call summary, "Hear
  /// it"): mic and player closed, the connection stays open (a tool call in
  /// flight still gets its response) until
  /// [FnaVoiceConfig.appLineCloseDelay].
  appLine;

  bool get closesNow => this == silence || this == hidden;
}

// ----------------------------------------------------------------- session

class FnaVoiceSession {
  FnaVoiceSession({
    required this._transportFactory,
    required this._audioIn,
    required this._audioOut,
    required this._tools,
    this._guard = const FnaTranscriptGuard(),
    this.config = const FnaVoiceConfig(),
    this._context,
    bool Function()? held,
    this._greet,
    this._isOnline,
    FnaTimerFactory? timer,
    DateTime Function()? now,
  }) : _held = held ?? _never,
       _timer = timer ?? Timer.new,
       _now = now ?? DateTime.now;

  static const _tag = 'fna.voice';
  static const _terminal = {
    FnaPhase.ended,
    FnaPhase.textFallback,
    FnaPhase.offline,
  };
  static const _setupPhases = {
    FnaPhase.micPermission,
    FnaPhase.connecting,
    FnaPhase.reconnecting,
  };
  static bool _never() => false;

  final FnaLiveTransport Function() _transportFactory;
  final FnaAudioIn _audioIn;
  final FnaAudioOut _audioOut;
  final FnaTools _tools;
  final FnaTranscriptGuard _guard;
  final FnaVoiceConfig config;

  /// The model-facing CONTEXT JSON (`fnaModelContextJson`), sent after the
  /// setup of every connection that does not resume.
  final String Function()? _context;

  /// A payment is held now (for the guard's "send it" check).
  final bool Function() _held;

  /// Plays the local greeting; the mic opens only after it finishes.
  final Future<void> Function()? _greet;
  final Future<bool> Function()? _isOnline;
  final FnaTimerFactory _timer;
  final DateTime Function() _now;

  final _events = StreamController<FnaSessionEvent>.broadcast();

  FnaPhase _phase = FnaPhase.idle;
  int _epoch = 0;
  int _turnId = 0;
  bool _ended = false;

  // Connection.
  FnaLiveTransport? _transport;
  StreamSubscription<FnaLiveEvent>? _transportSub;
  bool _setupDone = false;
  bool _resumedConnection = false;
  String? _handle;
  bool _reconnectOnResume = false;

  /// A spoken code is tearing the connection down; words are dropped.
  bool _restarting = false;

  /// A going-away or close reconnect is running.
  bool _reconnecting = false;

  // Audio session.
  bool _audioSessionOn = false;

  // Greeting, pause and mic.
  bool _greetDone = true;

  /// A pause asked for while the connection was being set up.
  _PauseKind? _pendingPause;

  /// Why the session is in [FnaPhase.paused] now.
  _PauseKind? _pausedKind;

  /// Tap-to-talk: the customer asked for the mic during a setup.
  bool _talkRequested = false;
  StreamSubscription<Uint8List>? _micSub;
  bool _micStarting = false;
  Future<void>? _micStopping;

  /// Bumped by [_stopMic]: a start that resolves under an older value is
  /// stale and stops the mic again.
  int _micGen = 0;

  /// Restarts after the mic stream ended on its own (reset by a chunk).
  int _micRestarts = 0;

  // Level bars.
  DateTime? _levelAt;
  double _levelSent = 0;

  // Player.
  StreamSubscription<void>? _drainSub;
  bool _drainedSinceLastPlay = true;
  bool _awaitingDrain = false;

  // Timers.
  Timer? _setupTimer;
  Timer? _silenceTimer;
  Timer? _maxTimer;
  Timer? _drainTimer;
  Timer? _thinkingTimer;
  Timer? _pauseCloseTimer;

  // The current turn.
  String _userText = '';
  String _pendingUserText = '';
  String _modelText = '';
  bool _turnHadAudio = false;
  double _turnAudioSeconds = 0;
  DateTime? _firstAudioAt;
  bool _turnBlocked = false;
  bool _turnUsedTools = false;
  bool _muteUntilTurnEnd = false;
  DateTime? _interruptedAt;

  // Tools.
  int _toolsRunning = 0;
  final Set<String> _cancelledCalls = {};
  final Map<String, String> _callNames = {};

  /// Broadcast; listen before [start].
  Stream<FnaSessionEvent> get events => _events.stream;
  FnaPhase get phase => _phase;
  int get epoch => _epoch;
  int get turnId => _turnId;

  /// `true` while the session is paused by the customer or for them (the
  /// Pause button, the background, silence, tap-to-talk between turns), not
  /// for a line the app speaks ([pauseForAppLine]).
  bool get pausedByCustomer =>
      _phase == FnaPhase.paused && _pausedKind != _PauseKind.appLine;

  /// `true` while [epoch] is the live connection of a running session.
  bool isCurrent(int epoch) => !_ended && epoch == _epoch;

  // ------------------------------------------------------------- commands

  /// Asks for the mic, enters the audio session, plays the greeting and
  /// connects. Call once.
  Future<void> start() async {
    if (_phase != FnaPhase.idle || _ended) return;
    _maxTimer = _timer(config.maxSession, () {
      Log.i(_tag, 'max session reached');
      unawaited(end());
    });
    _setPhase(FnaPhase.micPermission);
    final granted = await _guarded(_audioIn.requestPermission, false);
    if (_ended) return;
    if (!granted) {
      final forGood = await _guarded(_audioIn.permanentlyDenied, false);
      await _fallback(
        forGood
            ? FnaFallbackReason.micPermanentlyDenied
            : FnaFallbackReason.micDenied,
        checkNetwork: false,
      );
      return;
    }
    // Hidden during the permission dialog: no call mode in the background.
    if (!(_pendingPause?.closesNow ?? false)) await _enterAudioSession();
    if (_ended) return;
    _drainSub = _audioOut.drained.listen((_) => _onDrained());
    _setPhase(FnaPhase.connecting);
    final greet = _greet;
    if (greet != null) {
      _greetDone = false;
      unawaited(_runGreeting(greet));
    }
    await _connect(resumeHandle: null);
  }

  /// The Pause button. The connection closes after
  /// [FnaVoiceConfig.pauseCloseDelay]; [resume] reconnects.
  Future<void> pause() => _pause(_PauseKind.manual);

  /// The app speaks a line itself (the held line, the call summary, "Hear
  /// it"): mic closed and Live audio stopped and muted, but the connection
  /// stays open and keeps its session number, so a tool call that waits for
  /// the line still gets its response. No-op when already paused for
  /// another reason. [resumeAfterAppLine] listens again.
  Future<void> pauseForAppLine() => _pause(_PauseKind.appLine);

  /// The line of [pauseForAppLine] has ended: listen again (thinking while
  /// a tool still runs). Only undoes that pause: a pause of the customer,
  /// the silence or the background stays.
  Future<void> resumeAfterAppLine() async {
    if (_ended) return;
    if (_setupPhases.contains(_phase)) {
      if (_pendingPause != _PauseKind.appLine) return;
      _pendingPause = null;
      if (_phase != FnaPhase.micPermission) {
        await _enterAudioSession();
        await _maybeOpenMic();
      }
      return;
    }
    if (_phase != FnaPhase.paused || _pausedKind != _PauseKind.appLine) {
      return;
    }
    _pauseCloseTimer?.cancel();
    if (_reconnectOnResume || _transport == null) {
      // The connection closed during the line (going away): reconnect.
      await resume();
      return;
    }
    if (_toolsRunning > 0) {
      // The model answers the tool next (the handoff).
      _setPhase(FnaPhase.thinking);
    } else {
      _enterListening();
    }
    await _enterAudioSession();
    await _startMic();
  }

  /// The app went to the background: pause, leave the audio session and
  /// close the connection now. An "inactive" app (the Android permission
  /// dialog) must not call this: only "hidden".
  Future<void> onAppHidden() => _pause(_PauseKind.hidden);

  /// "Tap to talk" after a pause. In [FnaVoiceConfig.tapToTalk] mode it
  /// opens the mic for one turn.
  Future<void> resume() async {
    if (_ended) return;
    if (_setupPhases.contains(_phase)) {
      // Not set up yet: forget a pending pause and listen once ready.
      _pendingPause = null;
      _talkRequested = true;
      if (_phase != FnaPhase.micPermission) {
        unawaited(_enterAudioSession().then((_) => _maybeOpenMic()));
      }
      return;
    }
    if (_phase != FnaPhase.paused) return;
    _pauseCloseTimer?.cancel();
    _talkRequested = true;
    if (_reconnectOnResume || _transport == null) {
      _reconnectOnResume = false;
      _setPhase(FnaPhase.reconnecting);
      await _enterAudioSession();
      if (_ended) return;
      await _connect(resumeHandle: _handle);
      return;
    }
    _talkRequested = false;
    _enterListening();
    await _enterAudioSession();
    await _startMic();
  }

  /// The Stop button while FNA speaks: silence now, listen again. The rest
  /// of this answer is dropped as it arrives. A no-op in any other phase.
  Future<void> stopSpeaking() async {
    if (_ended || _phase != FnaPhase.speaking) return;
    _cutOffAnswer();
    _awaitingDrain = false;
    _drainTimer?.cancel();
    await _guarded(_audioOut.stop, null);
    if (_phase == FnaPhase.speaking) await _afterTurn();
  }

  /// A typed line in voice mode. Code-like digits are masked before the line
  /// leaves the phone. `false` when the session cannot take it now.
  Future<bool> sendText(String text) async {
    if (_ended || !_isLive || !_setupDone || _restarting) return false;
    final (line, _) = ApaAnswers.redactSecrets(text.trim());
    if (line.isEmpty) return false;
    if (_phase == FnaPhase.speaking) {
      _awaitingDrain = false;
      _drainTimer?.cancel();
      await _guarded(_audioOut.stop, null);
    }
    _cutOffAnswer();
    if (_phase == FnaPhase.speaking) _setPhase(FnaPhase.listening);
    if (_phase == FnaPhase.paused) {
      _pauseCloseTimer?.cancel();
      _setPhase(FnaPhase.listening);
      unawaited(_enterAudioSession().then((_) => _startMic()));
    }
    _userText = _userText.isEmpty ? line : '$_userText $line';
    _emit(
      FnaUserCaption(
        FnaTranscriptGuard.maskDigits(_userText),
        isFinal: true,
        epoch: _epoch,
        turnId: _turnId,
      ),
    );
    _setPhase(FnaPhase.thinking);
    await _transport?.sendText(line);
    return true;
  }

  /// End, the 10-minute limit or the sheet closing. Idempotent.
  Future<void> end() => _shutdown(FnaPhase.ended);

  // ----------------------------------------------------------- connection

  /// Claims a new [epoch] before its first await, so a second call (or an
  /// event of the old connection) can never leave two sockets open.
  Future<void> _connect({required String? resumeHandle}) async {
    if (_ended) return;
    final epoch = ++_epoch;
    _setupDone = false;
    _resumedConnection = resumeHandle != null;
    _cancelledCalls.clear();
    _callNames.clear();
    // A new or resumed socket never replays the old answer: nothing to mute.
    _muteUntilTurnEnd = false;
    _interruptedAt = null;
    _setupTimer?.cancel();
    await _closeTransport();
    if (!isCurrent(epoch)) return;
    final FnaLiveTransport transport;
    try {
      transport = _transportFactory();
    } on Object catch (e) {
      Log.w(_tag, 'transport factory failed', e);
      await _onConnectionLost(epoch);
      return;
    }
    _transport = transport;
    _transportSub = transport.events.listen((e) => _onLiveEvent(epoch, e));
    _setupTimer = _timer(config.setupTimeout, () => _onSetupTimeout(epoch));
    Log.i(_tag, 'connect #$epoch${resumeHandle == null ? '' : ' (resume)'}');
    try {
      await transport.connect(resumeHandle: resumeHandle);
    } on Object catch (e) {
      Log.w(_tag, 'connect threw', e);
      if (isCurrent(epoch)) await _onConnectionLost(epoch);
    }
  }

  /// Stops the current connection's events now (synchronously); the socket
  /// itself is closed by the next [_closeTransport].
  void _detachTransportEvents() {
    final sub = _transportSub;
    _transportSub = null;
    unawaited(sub?.cancel());
  }

  Future<void> _closeTransport() async {
    _setupTimer?.cancel();
    final sub = _transportSub;
    final transport = _transport;
    _transportSub = null;
    _transport = null;
    _setupDone = false;
    await sub?.cancel();
    if (transport != null) {
      try {
        await transport.close();
      } on Object catch (e) {
        Log.w(_tag, 'transport close failed', e);
      }
    }
  }

  void _onSetupTimeout(int epoch) {
    if (!isCurrent(epoch) || _setupDone) return;
    Log.w(_tag, 'setup timeout #$epoch');
    unawaited(
      _fallback(
        _phase == FnaPhase.reconnecting
            ? FnaFallbackReason.liveFailed
            : FnaFallbackReason.connectTimeout,
      ),
    );
  }

  /// The connection [epoch] closed without us closing it.
  Future<void> _onConnectionLost(int epoch) async {
    if (!isCurrent(epoch) || _restarting) return;
    _setupTimer?.cancel();
    final wasReady = _setupDone;
    _setupDone = false;
    if (!wasReady) {
      // Never got past setup: the first connect or the one resume failed.
      await _fallback(FnaFallbackReason.liveFailed);
      return;
    }
    await _reconnect();
  }

  /// Going-away notice or an unexpected close: one new connect with the last
  /// resumable handle. A failure of that connect goes to text. While paused
  /// it only closes; [resume] reconnects.
  Future<void> _reconnect() async {
    if (_ended || _restarting || _reconnecting) return;
    if (_phase == FnaPhase.paused) {
      // Reconnect when the customer comes back, not in the background.
      _pauseCloseTimer?.cancel();
      _reconnectOnResume = true;
      await _closeTransport();
      return;
    }
    if (_phase == FnaPhase.reconnecting) {
      await _fallback(FnaFallbackReason.liveFailed);
      return;
    }
    _reconnecting = true;
    try {
      // Everything before the first await: a second notice (GoAway, then
      // the close) must find the old connection gone.
      _detachTransportEvents();
      _setupDone = false;
      _talkRequested = _phase == FnaPhase.listening;
      if (_hasModelOutput) _finishTurn(interrupted: true);
      _awaitingDrain = false;
      _drainTimer?.cancel();
      _setPhase(FnaPhase.reconnecting);
      await _guarded(_audioOut.stop, null);
      if (_ended) return;
      final connecting = _connect(resumeHandle: _handle);
      _reconnecting = false;
      await connecting;
    } finally {
      _reconnecting = false;
    }
  }

  // --------------------------------------------------------------- events

  void _onLiveEvent(int epoch, FnaLiveEvent event) {
    if (!isCurrent(epoch)) return;
    try {
      switch (event) {
        case FnaSetupComplete():
          _onSetupComplete(epoch);
        case FnaAudioChunk():
          _onAudio(event);
        case FnaInputTranscript():
          _onUserWords(event.text, finished: event.finished);
        case FnaOutputTranscript():
          _onModelWords(event.text);
        case FnaToolCalls():
          _onToolCalls(epoch, event.calls);
        case FnaToolCallCancelled():
          _onToolsCancelled(event.ids);
        case FnaInterrupted():
          _onInterrupted();
        case FnaTurnComplete():
          _onTurnComplete();
        case FnaGoAway():
          Log.i(_tag, 'going away #$epoch');
          unawaited(_reconnect());
        case FnaResumptionHandle():
          final handle = event.handle;
          if (event.resumable && handle != null && handle.isNotEmpty) {
            _handle = handle;
          }
        case FnaLiveError():
          Log.w(_tag, 'live error #$epoch', event.error);
        case FnaLiveClosed():
          unawaited(_onConnectionLost(epoch));
      }
    } on Object catch (e, st) {
      Log.e(_tag, 'event handler failed', e, st);
    }
  }

  void _onSetupComplete(int epoch) {
    _setupTimer?.cancel();
    _setupDone = true;
    Log.i(_tag, 'setup complete #$epoch');
    final context = _context;
    if (!_resumedConnection && context != null) {
      try {
        unawaited(_transport?.sendContext(context()));
      } on Object catch (e) {
        Log.w(_tag, 'context failed', e);
      }
    }
    unawaited(_maybeOpenMic());
  }

  Future<void> _runGreeting(Future<void> Function() greet) async {
    try {
      await greet();
    } on Object catch (e) {
      Log.w(_tag, 'greeting failed', e);
    }
    _greetDone = true;
    await _maybeOpenMic();
  }

  /// Listening starts only when the server accepted the setup and the
  /// greeting has finished, so FNA never hears its own greeting.
  Future<void> _maybeOpenMic() async {
    if (_ended || !_setupDone) return;
    if (_phase != FnaPhase.connecting && _phase != FnaPhase.reconnecting) {
      return;
    }
    final pending = _pendingPause;
    if (pending != null && (_greetDone || pending.closesNow)) {
      await _enterPaused(pending);
      return;
    }
    if (!_greetDone) return;
    if (config.tapToTalk && !_talkRequested) {
      await _enterPaused(_PauseKind.turnEnd);
      return;
    }
    _talkRequested = false;
    _enterListening();
    await _startMic();
  }

  void _onAudio(FnaAudioChunk chunk) {
    if (_turnBlocked || _muteUntilTurnEnd) return;
    if (!_isLive || _phase == FnaPhase.paused) return;
    final interruptedAt = _interruptedAt;
    if (interruptedAt != null) {
      if (_now().difference(interruptedAt) < config.interruptGrace) return;
      _interruptedAt = null;
    }
    if (_phase != FnaPhase.speaking) _setPhase(FnaPhase.speaking);
    // A new answer while the last one drains: this one decides.
    _awaitingDrain = false;
    _drainTimer?.cancel();
    _turnHadAudio = true;
    _firstAudioAt ??= _now();
    _turnAudioSeconds += chunk.bytes.length / (chunk.sampleRate * 2);
    _drainedSinceLastPlay = false;
    unawaited(
      _guarded(() => _audioOut.play(chunk.bytes, chunk.sampleRate), null),
    );
  }

  void _onUserWords(String text, {required bool finished}) {
    if (_restarting || !_isLive || _phase == FnaPhase.paused) return;
    _interruptedAt = null;
    _resetSilence();
    // Words after FNA began answering belong to the next turn.
    final nextTurn = _hasModelOutput;
    final turn = nextTurn ? _turnId + 1 : _turnId;
    final words = nextTurn ? _pendingUserText + text : _userText + text;
    if (_guard.checkUser(words) != GuardVerdict.ok) {
      _onSecret(FnaTranscriptGuard.maskDigits(words), turn);
      return;
    }
    if (nextTurn) {
      _pendingUserText = words;
    } else {
      _userText = words;
    }
    _emit(
      FnaUserCaption(
        FnaTranscriptGuard.maskDigits(words.trim()),
        isFinal: finished,
        epoch: _epoch,
        turnId: turn,
      ),
    );
    if (finished && !nextTurn && _phase == FnaPhase.listening) {
      _setPhase(FnaPhase.thinking);
    }
  }

  void _onModelWords(String text) {
    if (_turnBlocked || _muteUntilTurnEnd) return;
    if (!_isLive || _phase == FnaPhase.paused) return;
    _modelText += text;
    // Interim: a last word the next chunk may negate ("পাঠাবেন" + " না")
    // waits; [_onTurnComplete] checks the whole turn.
    final verdict = _guard.checkModel(_modelText, held: _held(), partial: true);
    if (verdict != GuardVerdict.ok) {
      unawaited(_blockModel(verdict));
      return;
    }
    _emit(
      FnaModelCaption(
        FnaTranscriptGuard.maskDigits(_modelText.trim()),
        epoch: _epoch,
        turnId: _turnId,
      ),
    );
    if (_phase == FnaPhase.listening) _setPhase(FnaPhase.thinking);
  }

  Future<void> _blockModel(GuardVerdict reason) async {
    _turnBlocked = true;
    Log.w(_tag, 'model turn blocked: ${reason.name}');
    _awaitingDrain = false;
    _drainTimer?.cancel();
    await _guarded(_audioOut.stop, null);
    _emit(FnaModelBlocked(reason, epoch: _epoch, turnId: _turnId));
    if (_phase == FnaPhase.speaking || _phase == FnaPhase.thinking) {
      await _afterTurn();
    }
  }

  /// [_blockModel] for the final check at the turn's end: the state and
  /// the event change now, before the turn closes.
  void _blockAtTurnEnd(GuardVerdict reason) {
    _turnBlocked = true;
    Log.w(_tag, 'model turn blocked at turn end: ${reason.name}');
    _awaitingDrain = false;
    _drainTimer?.cancel();
    unawaited(_guarded(_audioOut.stop, null));
    _emit(FnaModelBlocked(reason, epoch: _epoch, turnId: _turnId));
  }

  /// The customer said a code. Runs at most once per connection: the state
  /// changes before the first await, so the next transcript piece (still in
  /// flight) is dropped and only one clean connection is made.
  void _onSecret(String masked, int turn) {
    if (_restarting || _ended) return;
    _restarting = true;
    Log.w(_tag, 'code heard; restarting clean');
    _detachTransportEvents();
    _setupDone = false;
    // The handle holds the code in the server's context: never resume it.
    _handle = null;
    _reconnectOnResume = false;
    _emit(FnaSecretBlocked(masked, epoch: _epoch, turnId: turn));
    _awaitingDrain = false;
    _drainTimer?.cancel();
    _turnId = turn + 1;
    _resetTurn();
    _pendingUserText = '';
    _muteUntilTurnEnd = false;
    _interruptedAt = null;
    // The warning is the greeting of the new connection.
    _greetDone = true;
    _talkRequested = false;
    _setPhase(FnaPhase.connecting);
    unawaited(_restartClean());
  }

  Future<void> _restartClean() async {
    try {
      await _guarded(_audioOut.stop, null);
      await _stopMic();
      if (_ended) return;
      final connecting = _connect(resumeHandle: null);
      _restarting = false;
      await connecting;
    } finally {
      _restarting = false;
    }
  }

  void _onToolCalls(int epoch, List<FunctionCall> calls) {
    if (_phase == FnaPhase.listening) _setPhase(FnaPhase.thinking);
    _turnUsedTools = true;
    for (final c in calls) {
      if (c.id != null) _callNames[c.id!] = c.name;
      _emit(FnaToolEvent(c.name, callId: c.id, epoch: epoch, turnId: _turnId));
    }
    unawaited(_runTools(epoch, calls));
  }

  /// All calls of one message run together and are answered in one message,
  /// each response carrying its call's id. Cancelled calls get no answer.
  Future<void> _runTools(int epoch, List<FunctionCall> calls) async {
    _toolsRunning++;
    final ctx = FnaToolContext(epoch: epoch, isCurrent: isCurrent);
    final results = await Future.wait([
      for (final c in calls)
        _tools
            .run(c.name, c.args, ctx)
            .catchError(
              (Object _) => <String, Object?>{'error': 'tool_failed'},
            ),
    ]);
    _toolsRunning--;
    if (!isCurrent(epoch)) return;
    final responses = <FunctionResponse>[
      for (var i = 0; i < calls.length; i++)
        if (calls[i].id == null || !_cancelledCalls.contains(calls[i].id))
          FunctionResponse(calls[i].name, results[i], id: calls[i].id),
    ];
    if (responses.isEmpty) return;
    await _transport?.sendToolResponses(responses);
    if (_phase == FnaPhase.thinking) _restartThinkingTimer();
  }

  void _onToolsCancelled(List<String> ids) {
    _cancelledCalls.addAll(ids);
    for (final id in ids) {
      _emit(
        FnaToolEvent(
          _callNames[id] ?? '',
          callId: id,
          cancelled: true,
          epoch: _epoch,
          turnId: _turnId,
        ),
      );
    }
  }

  void _onInterrupted() {
    // Half duplex: the customer interrupts with the Stop button only. The
    // server's voice detection can still hear room noise in the moment the
    // mic was open, so its interruption is ignored while FNA thinks or
    // speaks (device test 2026-10-18: a fan kept cancelling the answers).
    if (config.halfDuplex &&
        (_phase == FnaPhase.thinking || _phase == FnaPhase.speaking)) {
      Log.i(_tag, 'interrupted ignored (half duplex)');
      return;
    }
    Log.i(_tag, 'interrupted');
    unawaited(_guarded(_audioOut.stop, null));
    _awaitingDrain = false;
    _drainTimer?.cancel();
    _muteUntilTurnEnd = false;
    if (_hasModelOutput || _userText.isNotEmpty) {
      _finishTurn(interrupted: true);
      _interruptedAt = _now();
    }
    // The customer is talking over FNA: keep listening, also in tap-to-talk.
    if (_phase == FnaPhase.speaking || _phase == FnaPhase.thinking) {
      _enterListening();
    }
  }

  void _onTurnComplete() {
    if (_muteUntilTurnEnd) {
      // The end of an answer the customer already cut off.
      _muteUntilTurnEnd = false;
      if (_phase == FnaPhase.speaking) unawaited(_afterTurn());
      return;
    }
    if (!_turnBlocked && _modelText.isNotEmpty) {
      // The final check of the whole answer: the interim checks let a last
      // open word wait for the next chunk. Its audio may have played
      // already; the bubble becomes the safe line.
      final verdict = _guard.checkModel(_modelText, held: _held());
      if (verdict != GuardVerdict.ok) _blockAtTurnEnd(verdict);
    }
    if (_turnBlocked) {
      _finishTurn(interrupted: false);
      if (_phase == FnaPhase.speaking || _phase == FnaPhase.thinking) {
        unawaited(_afterTurn());
      }
      return;
    }
    if (!_turnHadAudio) {
      // A turn that was only a tool call: the spoken answer comes next.
      if (_turnUsedTools || _toolsRunning > 0) {
        if (_phase == FnaPhase.thinking) _restartThinkingTimer();
        return;
      }
      if (_hasModelOutput || _userText.isNotEmpty) {
        _finishTurn(interrupted: false);
      }
      if (_phase == FnaPhase.thinking) unawaited(_afterTurn());
      return;
    }
    // Spoken answer complete: listen once the player has really finished.
    final played = _firstAudioAt == null
        ? Duration.zero
        : _now().difference(_firstAudioAt!);
    final total = Duration(microseconds: (_turnAudioSeconds * 1e6).round());
    final left = total - played;
    _finishTurn(interrupted: false);
    if (_phase != FnaPhase.speaking) return;
    if (_drainedSinceLastPlay) {
      unawaited(_afterTurn());
      return;
    }
    _awaitingDrain = true;
    _drainTimer?.cancel();
    _drainTimer = _timer(
      (left.isNegative ? Duration.zero : left) + config.drainSlack,
      _onPlaybackDone,
    );
  }

  void _onDrained() {
    _drainedSinceLastPlay = true;
    if (_awaitingDrain) _onPlaybackDone();
  }

  void _onPlaybackDone() {
    if (_ended || !_awaitingDrain) return;
    _awaitingDrain = false;
    _drainTimer?.cancel();
    if (_phase == FnaPhase.speaking) unawaited(_afterTurn());
  }

  /// FNA's answer is over: listen again, or in tap-to-talk mode close the
  /// mic until the next tap.
  Future<void> _afterTurn() async {
    if (_ended) return;
    if (config.tapToTalk) {
      await _enterPaused(_PauseKind.turnEnd);
    } else {
      _enterListening();
    }
  }

  // ----------------------------------------------------------------- pause

  Future<void> _pause(_PauseKind kind) async {
    if (_ended) return;
    if (_setupPhases.contains(_phase)) {
      // Applied when the setup completes ([_maybeOpenMic]).
      final pending = _pendingPause;
      if (pending == null ||
          kind.closesNow ||
          (pending == _PauseKind.appLine && kind != _PauseKind.appLine)) {
        _pendingPause = kind;
      }
      _talkRequested = false;
      // A reconnect keeps the mic open for the next turn: close it now.
      await _stopMic();
      if (kind.closesNow) {
        // The background: leave call mode now, not when the setup ends.
        await _exitAudioSession();
        unawaited(_maybeOpenMic());
      }
      return;
    }
    if (_phase == FnaPhase.paused) {
      if (kind.closesNow) {
        // Already paused: the background closes everything now.
        _pausedKind = kind;
        await _releaseWhilePaused();
      } else if (_pausedKind == _PauseKind.appLine &&
          kind != _PauseKind.appLine) {
        // The customer's pause during an app line: it becomes theirs (the
        // connection closes on its timer).
        await _enterPaused(kind);
      }
      return;
    }
    if (!_isLive) return;
    await _enterPaused(kind);
  }

  /// Every pause: mic closed and player stopped. The state changes before
  /// the first await, so a mic start or an event in flight sees "paused".
  Future<void> _enterPaused(_PauseKind kind) async {
    if (_ended) return;
    _pendingPause = null;
    _talkRequested = false;
    _cutOffAnswer();
    _awaitingDrain = false;
    _drainTimer?.cancel();
    _pauseCloseTimer?.cancel();
    _pausedKind = kind;
    _setPhase(FnaPhase.paused);
    await _stopMic();
    await _guarded(_audioOut.stop, null);
    if (_ended || _phase != FnaPhase.paused || _pausedKind != kind) return;
    switch (kind) {
      case _PauseKind.silence:
      case _PauseKind.hidden:
        await _releaseWhilePaused();
      case _PauseKind.manual:
        await _exitAudioSession();
        _schedulePauseClose(config.pauseCloseDelay, exitSession: false);
      case _PauseKind.turnEnd:
        _schedulePauseClose(config.silenceTimeout, exitSession: true);
      case _PauseKind.appLine:
        await _exitAudioSession();
        _schedulePauseClose(config.appLineCloseDelay, exitSession: false);
    }
  }

  void _schedulePauseClose(Duration after, {required bool exitSession}) {
    _pauseCloseTimer?.cancel();
    _pauseCloseTimer = _timer(after, () {
      if (_ended || _phase != FnaPhase.paused) return;
      Log.i(_tag, 'paused too long; closing the connection');
      unawaited(exitSession ? _releaseWhilePaused() : _closeWhilePaused());
    });
  }

  /// Leaves the audio session and closes the connection (the handle stays
  /// for [resume]).
  Future<void> _releaseWhilePaused() async {
    _pauseCloseTimer?.cancel();
    await _exitAudioSession();
    await _closeWhilePaused();
  }

  Future<void> _closeWhilePaused() async {
    if (_ended || _phase != FnaPhase.paused) return;
    if (_transport == null) return;
    _reconnectOnResume = true;
    await _closeTransport();
  }

  // --------------------------------------------------------- audio session

  Future<void> _enterAudioSession() async {
    if (_audioSessionOn || _ended) return;
    _audioSessionOn = true;
    await _guarded(_audioOut.enterSession, null);
  }

  Future<void> _exitAudioSession() async {
    if (!_audioSessionOn) return;
    _audioSessionOn = false;
    await _guarded(_audioOut.exitSession, null);
  }

  // ------------------------------------------------------------------- mic

  Future<void> _startMic() async {
    if (_micSub != null || _micStarting || _ended || !_wantsMic) return;
    _micStarting = true;
    var stale = false;
    try {
      final stopping = _micStopping;
      if (stopping != null) await stopping;
      final gen = _micGen;
      if (_ended || !_wantsMic) return;
      final stream = await _audioIn.start();
      if (_ended || !_wantsMic || gen != _micGen) {
        stale = gen != _micGen;
        await _guarded(_audioIn.stop, null);
        return;
      }
      late final StreamSubscription<Uint8List> sub;
      sub = stream.listen(
        (Uint8List chunk) {
          _micRestarts = 0;
          _onMicChunk(chunk);
        },
        onError: (Object e) {
          Log.w(_tag, 'mic error', e);
        },
        onDone: () => _onMicDone(sub),
      );
      _micSub = sub;
    } on Object catch (e) {
      Log.w(_tag, 'mic start failed', e);
    } finally {
      _micStarting = false;
      // A stop and a new start came while this start was in flight.
      if (stale && !_ended && _wantsMic && _micSub == null) {
        unawaited(_startMic());
      }
    }
  }

  /// The mic stream ended on its own (or was empty from the start): restart
  /// once, then pause rather than "listen" with no mic.
  void _onMicDone(StreamSubscription<Uint8List> sub) {
    if (!identical(_micSub, sub)) return;
    _micSub = null;
    if (_ended || !_wantsMic) return;
    if (_micRestarts < 1) {
      _micRestarts++;
      Log.w(_tag, 'mic stream ended; restarting');
      unawaited(_startMic());
      return;
    }
    Log.w(_tag, 'mic unavailable; pausing');
    _micRestarts = 0;
    unawaited(_enterPaused(_PauseKind.manual));
  }

  Future<void> _stopMic() {
    _micGen++;
    final sub = _micSub;
    _micSub = null;
    final stopping = () async {
      await sub?.cancel();
      await _guarded(_audioIn.stop, null);
    }();
    _micStopping = stopping;
    return stopping.whenComplete(() {
      if (identical(_micStopping, stopping)) _micStopping = null;
    });
  }

  bool get _wantsMic =>
      _phase == FnaPhase.listening ||
      _phase == FnaPhase.thinking ||
      _phase == FnaPhase.speaking ||
      (_phase == FnaPhase.reconnecting && _pendingPause == null);

  bool get _sendsAudio =>
      _setupDone &&
      (_phase == FnaPhase.listening ||
          // Half duplex sends audio only while listening: noise sent while
          // FNA thinks makes the server cancel the answer it is preparing.
          (!config.halfDuplex &&
              (_phase == FnaPhase.thinking || _phase == FnaPhase.speaking)));

  void _onMicChunk(Uint8List chunk) {
    if (_ended) return;
    double level;
    try {
      level = _audioIn.level;
    } on Object {
      level = 0;
    }
    if (_phase == FnaPhase.listening) _emitLevel(level);
    if (level > config.voiceLevel) _resetSilence();
    if (_sendsAudio) unawaited(_transport?.sendAudio(chunk));
  }

  /// At most one [FnaLevel] per [FnaVoiceConfig.levelInterval], and only
  /// when the level moved by [FnaVoiceConfig.levelStep].
  void _emitLevel(double level, {bool force = false}) {
    final now = _now();
    if (!force) {
      final at = _levelAt;
      if (at != null && now.difference(at) < config.levelInterval) return;
      if ((level - _levelSent).abs() < config.levelStep && at != null) return;
    }
    _levelAt = now;
    _levelSent = level;
    _emit(FnaLevel(level, epoch: _epoch, turnId: _turnId));
  }

  // ----------------------------------------------------------------- turns

  bool get _hasModelOutput => _turnHadAudio || _modelText.isNotEmpty;

  /// The customer cut FNA off while its answer was still streaming: close
  /// the turn and drop the rest of that answer as it arrives (until the
  /// server's turn end or interruption). An answer that already completed
  /// (only draining in the player) needs no mute.
  void _cutOffAnswer() {
    if (!_hasModelOutput) return;
    _muteUntilTurnEnd = true;
    _finishTurn(interrupted: true);
  }

  void _finishTurn({required bool interrupted}) {
    final hasContent = _hasModelOutput || _userText.isNotEmpty;
    if (hasContent) {
      _emit(
        FnaTurnFinished(
          userText: FnaTranscriptGuard.maskDigits(_userText.trim()),
          modelText: FnaTranscriptGuard.maskDigits(_modelText.trim()),
          interrupted: interrupted,
          blocked: _turnBlocked,
          epoch: _epoch,
          turnId: _turnId,
        ),
      );
    }
    _turnId++;
    _resetTurn();
    _userText = _pendingUserText;
    _pendingUserText = '';
  }

  void _resetTurn() {
    _userText = '';
    _modelText = '';
    _turnHadAudio = false;
    _turnAudioSeconds = 0;
    _firstAudioAt = null;
    _turnBlocked = false;
    _turnUsedTools = false;
  }

  // ----------------------------------------------------------- phases etc.

  bool get _isLive =>
      _phase == FnaPhase.listening ||
      _phase == FnaPhase.thinking ||
      _phase == FnaPhase.speaking ||
      _phase == FnaPhase.paused;

  void _enterListening() {
    _setPhase(FnaPhase.listening);
    _resetSilence();
  }

  void _setPhase(FnaPhase next) {
    if (_phase == next) return;
    // An await that resolves after end() must not bring the session back.
    if (_ended && !_terminal.contains(next)) return;
    if (_terminal.contains(_phase)) return;
    final previous = _phase;
    _phase = next;
    Log.i(_tag, 'phase ${previous.name} -> ${next.name}');
    if (next != FnaPhase.listening) _silenceTimer?.cancel();
    if (next != FnaPhase.paused) _pauseCloseTimer?.cancel();
    if (next == FnaPhase.thinking) {
      _restartThinkingTimer();
    } else {
      _thinkingTimer?.cancel();
    }
    _emit(FnaPhaseChanged(next, previous, epoch: _epoch, turnId: _turnId));
    // The level bars fall back to zero when the session stops listening.
    if (previous == FnaPhase.listening && _levelSent > 0) {
      _emitLevel(0, force: true);
    }
  }

  void _resetSilence() {
    _silenceTimer?.cancel();
    if (_phase != FnaPhase.listening || _ended) return;
    _silenceTimer = _timer(config.silenceTimeout, () {
      if (_phase == FnaPhase.listening && !_ended) {
        Log.i(_tag, 'silence timeout');
        unawaited(_pause(_PauseKind.silence));
      }
    });
  }

  void _restartThinkingTimer() {
    _thinkingTimer?.cancel();
    _thinkingTimer = _timer(config.thinkingTimeout, () {
      if (_phase != FnaPhase.thinking || _ended) return;
      Log.w(_tag, 'no answer; listening again');
      _finishTurn(interrupted: false);
      unawaited(_afterTurn());
    });
  }

  Future<void> _fallback(
    FnaFallbackReason reason, {
    bool checkNetwork = true,
  }) async {
    if (_ended) return;
    var why = reason;
    final isOnline = _isOnline;
    if (checkNetwork && isOnline != null) {
      final online = await _guarded(isOnline, true);
      if (!online) why = FnaFallbackReason.offline;
    }
    if (_ended) return;
    Log.w(_tag, 'fallback: ${why.name}');
    _emit(FnaFallback(why, epoch: _epoch, turnId: _turnId));
    await _shutdown(
      why == FnaFallbackReason.offline
          ? FnaPhase.offline
          : FnaPhase.textFallback,
    );
  }

  Future<void> _shutdown(FnaPhase last) async {
    if (_ended) return;
    _ended = true;
    for (final t in [
      _setupTimer,
      _silenceTimer,
      _maxTimer,
      _drainTimer,
      _thinkingTimer,
      _pauseCloseTimer,
    ]) {
      t?.cancel();
    }
    _setPhase(last);
    await _stopMic();
    await _guarded(_audioOut.stop, null);
    // Always (idempotent on the platform side): never leave call mode on.
    _audioSessionOn = false;
    await _guarded(_audioOut.exitSession, null);
    await _drainSub?.cancel();
    _drainSub = null;
    // _closeTransport ignores _ended.
    await _closeTransport();
    await _events.close();
  }

  void _emit(FnaSessionEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  /// Runs [f]; logs and returns [fallback] on any error.
  static Future<T> _guarded<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } on Object catch (e) {
      Log.w(_tag, 'call failed', e);
      return fallback;
    }
  }
}
