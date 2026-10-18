/// Test doubles for the FNA Live transport and timers.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';

/// A scripted Live connection: records what the session sent and lets a
/// test push server events. Events are delivered synchronously.
class FakeFnaLiveTransport implements FnaLiveTransport {
  FakeFnaLiveTransport(this.index);

  /// 0 for the first transport the factory made, 1 for the next, ...
  final int index;

  final _events = StreamController<FnaLiveEvent>.broadcast(sync: true);

  bool connectCalled = false;
  String? resumeHandle;
  bool closed = false;
  final List<Uint8List> audio = [];
  final List<String> texts = [];
  final List<String> contexts = [];
  final List<List<FunctionResponse>> toolResponses = [];

  void emit(FnaLiveEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void setupComplete() => emit(const FnaSetupComplete());
  void userSays(String text, {bool finished = false}) =>
      emit(FnaInputTranscript(text, finished: finished));
  void modelSays(String text) => emit(FnaOutputTranscript(text));
  void audioChunk([int bytes = 4800]) => emit(FnaAudioChunk(Uint8List(bytes)));
  void turnComplete() => emit(const FnaTurnComplete());

  /// The server closed the connection (not the session).
  void serverClose() {
    emit(const FnaLiveClosed());
    unawaited(_events.close());
  }

  @override
  Stream<FnaLiveEvent> get events => _events.stream;

  @override
  Future<void> connect({String? resumeHandle}) async {
    connectCalled = true;
    this.resumeHandle = resumeHandle;
  }

  @override
  Future<void> sendAudio(Uint8List pcm16k) async => audio.add(pcm16k);

  @override
  Future<void> sendText(String text) async => texts.add(text);

  @override
  Future<void> sendContext(String json) async => contexts.add(json);

  @override
  Future<void> sendToolResponses(List<FunctionResponse> responses) async =>
      toolResponses.add(responses);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    emit(const FnaLiveClosed());
    unawaited(_events.close());
  }
}

/// The session's transport factory: a new fake per connect.
class FakeTransportFactory {
  final List<FakeFnaLiveTransport> made = [];

  FakeFnaLiveTransport get last => made.last;

  FnaLiveTransport call() {
    final t = FakeFnaLiveTransport(made.length);
    made.add(t);
    return t;
  }
}

/// Manual timers and clock: nothing fires until [elapse].
class FakeTimers {
  static final origin = DateTime.utc(2026, 10, 18, 10);

  Duration _elapsed = Duration.zero;
  final List<_FakeTimer> _timers = [];

  DateTime now() => origin.add(_elapsed);

  Timer call(Duration duration, void Function() callback) {
    final t = _FakeTimer(_elapsed + duration, callback);
    _timers.add(t);
    return t;
  }

  /// Active timers due within [d] from now.
  int pendingWithin(Duration d) =>
      _timers.where((t) => t.isActive && t.due <= _elapsed + d).length;

  /// Moves time forward by [d], firing due timers in order.
  void elapse(Duration d) {
    final target = _elapsed + d;
    while (true) {
      final due = _timers.where((t) => t.isActive && t.due <= target).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      final next = due.first;
      _elapsed = next.due;
      next.fire();
    }
    _elapsed = target;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this._callback);

  final Duration due;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() => _active = false;
}

/// Lets queued microtasks and zero-delay futures run.
Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
