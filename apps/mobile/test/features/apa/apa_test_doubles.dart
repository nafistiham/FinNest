import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/providers.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_live_service.dart';
import 'package:bhorosha/features/apa/logic/apa_mic.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// Scripted Live session: records what the controller sent and lets a test
/// push audio, transcript and errors back.
class FakeApaLiveService implements ApaLiveService {
  FakeApaLiveService({this.isAvailable = true});

  bool isAvailable;
  ApaContext? startedWith;
  int starts = 0;
  int endTurns = 0;
  int stops = 0;
  final List<Uint8List> chunks = [];

  void Function(Uint8List)? _onAudio;
  void Function(String)? _onTranscript;
  void Function(Object)? _onError;
  void Function()? _onTurnComplete;

  void pushAudio(Uint8List pcm) => _onAudio?.call(pcm);
  void pushTranscript(String text) => _onTranscript?.call(text);
  void pushTurnComplete() => _onTurnComplete?.call();
  void pushError(Object e) => _onError?.call(e);

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<void> start(
    ApaContext ctx, {
    required void Function(Uint8List pcm24k) onAudio,
    required void Function(String text) onTranscript,
    required void Function(Object error) onError,
    void Function()? onTurnComplete,
  }) async {
    starts++;
    startedWith = ctx;
    _onAudio = onAudio;
    _onTranscript = onTranscript;
    _onError = onError;
    _onTurnComplete = onTurnComplete;
  }

  @override
  Future<void> sendPcm16k(Uint8List chunk) async => chunks.add(chunk);

  @override
  Future<void> endTurn() async => endTurns++;

  @override
  Future<void> stop() async => stops++;
}

/// [FakeApaLiveService] whose `start` waits on [connect], so a test can press
/// hold-to-talk again while the session is still opening.
class GatedApaLiveService extends FakeApaLiveService {
  final Completer<void> connect = Completer<void>();

  @override
  Future<void> start(
    ApaContext ctx, {
    required void Function(Uint8List pcm24k) onAudio,
    required void Function(String text) onTranscript,
    required void Function(Object error) onError,
    void Function()? onTurnComplete,
  }) async {
    await super.start(
      ctx,
      onAudio: onAudio,
      onTranscript: onTranscript,
      onError: onError,
      onTurnComplete: onTurnComplete,
    );
    await connect.future;
  }
}

/// [FakeApaMic] whose permission prompt and recorder start wait on gates, so
/// a test can lift the finger while `holdStart` is still awaiting them.
class GatedApaMic extends FakeApaMic {
  final Completer<bool> permission = Completer<bool>();
  final Completer<void> started = Completer<void>();

  @override
  Future<bool> requestPermission() async {
    await super.requestPermission();
    return permission.future;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    final stream = await super.start();
    await started.future;
    return stream;
  }
}

/// Everything the Apa feature touches, faked.
class ApaHarness {
  ApaHarness({ApaLiveService? live, FakeApaMic? mic})
    : live = live ?? const DisabledApaLiveService(),
      mic = mic ?? FakeApaMic();

  final api = FakeRiskApi();
  final audio = FakeApaAudio();
  final native = FakeBhoroshaNative();
  final ApaLiveService live;
  final FakeApaMic mic;

  List<Override> get overrides => [
    riskApiProvider.overrideWithValue(api),
    apaAudioProvider.overrideWithValue(audio),
    nativeProvider.overrideWithValue(native),
    apaLiveServiceProvider.overrideWithValue(live),
    apaMicProvider.overrideWithValue(mic),
  ];
}

const heldScore = ScoreResponse(
  decision: Decision.hold,
  riskScore: 0.91,
  band: Band.critical,
  reasons: [
    Reason(
      code: 'CALL_ACTIVE',
      weight: 0.6,
      textBn: 'আপনি এখন একটি কলে আছেন।',
      textEn: 'You are on a call right now.',
    ),
    Reason(
      code: 'NEW_PAYEE',
      weight: 0.3,
      textBn: 'এই নম্বরে আগে কখনো টাকা পাঠাননি।',
      textEn: 'You have never sent money to this number.',
    ),
  ],
  actions: [ActionItem(type: 'hold_transaction')],
  modelVersion: 'rules-v1',
);

const heldFirstLineBn =
    'আপনি এখন একটি কলে আছেন। এই নম্বরে আগে কখনো টাকা পাঠাননি।';
const heldFirstLineEn =
    'You are on a call right now. You have never sent money to this number.';

const blockMessageBn =
    'আপনার ফোনে একটি ঝুঁকিপূর্ণ অ্যাপ আছে যা স্ক্রিন দেখতে পারে।';
const blockMessageEn = 'A risky app on your phone can see your screen.';

const blockSnapshot = ApaContextSnapshot(
  verdict: SafetyVerdict.block,
  safetyMessageBn: blockMessageBn,
  safetyMessageEn: blockMessageEn,
  uninstallTargets: [
    UninstallTarget(
      package: 'com.takanow.loan',
      label: 'TakaNow Loan',
      primarySignal: 'accessibility',
      deepLink: 'package:com.takanow.loan',
    ),
  ],
  resolution: 'UNINSTALL_AND_RECHECK',
);

/// A classification of "your account will be blocked, read me the code".
const scamResponse = ScamTurnResponse(
  scamType: 'fake_customer_care',
  urgency: 'high',
  requestedSecret: 'otp',
  confidence: 0.85,
  evidenceQuote: 'আপনার অ্যাকাউন্ট বন্ধ হয়ে যাবে, এখনই কোডটা বলুন',
  recommendedAction: 'hold_and_warn',
  rollingScore: 0.85,
);
