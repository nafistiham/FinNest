/// Microphone capture for the Live path: 16 kHz, 16-bit, mono PCM chunks.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/core/log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// What the controller needs from the microphone. Implementations never throw
/// to the caller: a failed start resolves to an empty stream and is logged.
abstract class ApaMic {
  /// Asks for `RECORD_AUDIO` when not yet granted; `true` when usable.
  Future<bool> requestPermission();

  /// Starts capture and streams raw PCM16 LE mono at 16 kHz.
  Future<Stream<Uint8List>> start();

  /// Stops capture; idempotent.
  Future<void> stop();

  Future<void> dispose();
}

/// `record` ^7 + `permission_handler` implementation (Android).
///
/// Untested on a device until the Live path can run (Firebase pending); the
/// package API was read from the pub cache: `AudioRecorder.startStream(config)`
/// with `AudioEncoder.pcm16bits`, 16000 Hz, 1 channel returns a byte stream.
class RecordApaMic implements ApaMic {
  RecordApaMic({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  static const _tag = 'apa.mic';
  static const config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
  );

  final AudioRecorder _recorder;

  @override
  Future<bool> requestPermission() async {
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } on Object catch (e) {
      Log.w(_tag, 'permission request failed', e);
      return false;
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    try {
      return await _recorder.startStream(config);
    } on Object catch (e) {
      Log.w(_tag, 'startStream failed', e);
      return const Stream<Uint8List>.empty();
    }
  }

  @override
  Future<void> stop() async {
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } on Object catch (e) {
      Log.w(_tag, 'stop failed', e);
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } on Object catch (e) {
      Log.w(_tag, 'dispose failed', e);
    }
  }
}

/// Test double: scripted permission and a controllable PCM stream.
class FakeApaMic implements ApaMic {
  FakeApaMic({this.granted = true});

  bool granted;
  int permissionRequests = 0;
  int starts = 0;
  int stops = 0;
  StreamController<Uint8List>? _controller;

  /// Pushes a chunk into the running stream (no-op when stopped).
  void emit(Uint8List chunk) => _controller?.add(chunk);

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    _controller = StreamController<Uint8List>();
    return _controller!.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    // Not awaited: `done` never completes once the subscription was cancelled.
    unawaited(_controller?.close());
    _controller = null;
  }

  @override
  Future<void> dispose() => stop();
}

/// Overridden with [FakeApaMic] in tests.
final apaMicProvider = Provider<ApaMic>((ref) {
  final mic = RecordApaMic();
  ref.onDispose(mic.dispose);
  return mic;
});
