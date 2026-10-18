/// Test doubles for the FNA voice audio ports.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/features/apa/voice/fna_audio.dart';

/// Records every call; [emitDrained] fires [drained].
class FakeFnaAudioOut implements FnaAudioOut {
  /// Recorded `play` chunks, in order (sample rates in [playedRates]).
  final List<Uint8List> played = [];
  final List<int> playedRates = [];

  int stops = 0;
  int enters = 0;
  int exits = 0;

  /// `true` between [enterSession] and [exitSession].
  bool inSession = false;

  final StreamController<void> drainedController =
      StreamController<void>.broadcast();

  /// Simulates the player running empty.
  void emitDrained() => drainedController.add(null);

  Future<void> dispose() => drainedController.close();

  @override
  Future<void> enterSession() async {
    enters++;
    inSession = true;
  }

  @override
  Future<void> exitSession() async {
    exits++;
    inSession = false;
  }

  @override
  Future<void> play(Uint8List pcm16, int sampleRate) async {
    played.add(pcm16);
    playedRates.add(sampleRate);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Stream<void> get drained => drainedController.stream;
}

/// Scripted permission answers and a PCM stream the test pushes into.
class FakeFnaAudioIn implements FnaAudioIn {
  FakeFnaAudioIn({this.granted = true, this.deniedForGood = false});

  /// Returned by [requestPermission].
  bool granted;

  /// Returned by [permanentlyDenied].
  bool deniedForGood;

  @override
  double level = 0;

  int permissionRequests = 0;
  int starts = 0;
  int stops = 0;

  StreamController<Uint8List>? controller;

  /// When set, [start] waits for it (a mic that takes a while to open).
  Completer<void>? startGate;

  /// The next this-many [start] calls return an empty (already done) stream.
  int emptyStarts = 0;

  /// `true` while a stream from [start] is open.
  bool get running => controller != null;

  /// Pushes a chunk into the running stream (no-op when stopped).
  void push(Uint8List chunk) => controller?.add(chunk);

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<bool> permanentlyDenied() async => deniedForGood;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    final gate = startGate;
    if (gate != null) await gate.future;
    if (emptyStarts > 0) {
      emptyStarts--;
      return const Stream<Uint8List>.empty();
    }
    unawaited(controller?.close());
    controller = StreamController<Uint8List>();
    return controller!.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    // Not awaited: `done` never completes once the subscription was cancelled.
    unawaited(controller?.close());
    controller = null;
  }
}
