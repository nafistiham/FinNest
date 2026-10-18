// Test doubles for the intervention feature: a scripted `AudioPlayer`, a
// scripted `FlutterTts`, and a localised widget harness. Not a test file.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart' hide AudioEvent;
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/contracts/common.dart';
import 'package:bhorosha/data/contracts/intervene.dart';
import 'package:bhorosha/data/contracts/score.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Records every call; emits `playing` on resume, `stopped` on stop, and
/// `completed` plus `onPlayerComplete` when the test calls [complete].
class FakeAudioPlayer implements AudioPlayer {
  FakeAudioPlayer({this.failResume = false});

  final bool failResume;
  Source? sourceSet;
  PlayerMode? modeSet;
  ReleaseMode? releaseModeSet;
  int resumes = 0;
  int stops = 0;
  bool disposed = false;
  PlayerState _s = PlayerState.stopped;
  final StreamController<PlayerState> _stateCtl = StreamController.broadcast();
  final StreamController<void> _completeCtl = StreamController.broadcast();

  String? get assetPath => switch (sourceSet) {
    AssetSource(:final path) => path,
    _ => null,
  };

  @override
  Stream<PlayerState> get onPlayerStateChanged => _stateCtl.stream;

  @override
  Stream<void> get onPlayerComplete => _completeCtl.stream;

  @override
  PlayerState get state => _s;

  @override
  Future<void> setPlayerMode(PlayerMode m) async => modeSet = m;

  @override
  Future<void> setReleaseMode(ReleaseMode m) async => releaseModeSet = m;

  @override
  Future<void> setSource(Source s) async => sourceSet = s;

  @override
  Future<void> resume() async {
    if (failResume) {
      throw PlatformException(code: 'AndroidAudioError', message: 'boom');
    }
    resumes++;
    _s = PlayerState.playing;
    _stateCtl.add(_s);
  }

  @override
  Future<void> stop() async {
    stops++;
    if (_s != PlayerState.stopped) {
      _s = PlayerState.stopped;
      _stateCtl.add(_s);
    }
  }

  @override
  Future<void> dispose() async => disposed = true;

  /// Simulates the end of the clip (MediaPlayer mode behaviour).
  void complete() {
    _s = PlayerState.completed;
    _stateCtl.add(_s);
    _completeCtl.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeAudioPlayer: ${invocation.memberName}');
}

/// Records spoken text and handler registrations; `speak` fires the start
/// handler and returns [speakResult] (1 = ok, 0 = refused) immediately, like
/// an engine with `awaitSpeakCompletion(true)` on a zero-length utterance.
class FakeFlutterTts implements FlutterTts {
  FakeFlutterTts({this.failSetLanguage = false, this.speakResult = 1});

  final bool failSetLanguage;
  int speakResult;
  String? language;
  bool? awaitCompletion;
  final List<String> spoken = [];
  int stops = 0;
  VoidCallback? onStart;
  VoidCallback? onComplete;
  VoidCallback? onCancel;
  ErrorHandler? onError;

  @override
  Future<dynamic> setLanguage(String l) async {
    if (failSetLanguage) {
      throw MissingPluginException('No implementation for setLanguage');
    }
    language = l;
    return 1;
  }

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async {
    this.awaitCompletion = awaitCompletion;
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    // A refused utterance (0) never starts, so no start callback.
    if (speakResult != 0) onStart?.call();
    return speakResult;
  }

  @override
  Future<dynamic> stop() async {
    stops++;
    return 1;
  }

  @override
  void setStartHandler(VoidCallback callback) => onStart = callback;

  @override
  void setCompletionHandler(VoidCallback callback) => onComplete = callback;

  @override
  void setCancelHandler(VoidCallback callback) => onCancel = callback;

  @override
  void setErrorHandler(ErrorHandler handler) => onError = handler;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeFlutterTts: ${invocation.memberName}');
}

/// Counts every haptic moment so a test can pin the 6.3 map.
class RecordingHaptics extends Haptics {
  RecordingHaptics();
  int keys = 0, selections = 0, lights = 0, successes = 0, warnings = 0;
  int errors = 0;

  @override
  Future<void> key() async => keys++;
  @override
  Future<void> selection() async => selections++;
  @override
  Future<void> light() async => lights++;
  @override
  Future<void> success() async => successes++;
  @override
  Future<void> warning() async => warnings++;
  @override
  Future<void> error() async => errors++;
}

/// A `MaterialApp` in [locale] (Bangla by default) with the app theme around
/// [home], in [brightness] (light by default; dark for the demo phone).
Widget localizedApp(
  Widget home, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('bn'),
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildTheme(brightness),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    ),
  );
}

/// Every string currently rendered by a `Text` widget.
Set<String> visibleTexts(WidgetTester tester) => {
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
}..remove('');

/// Simulates the Android system back button.
Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  await tester.pump();
}

// ---------------------------------------------------------------- fixtures --

const reasonScam = Reason(
  code: 'SCAM_CONVERSATION',
  weight: 0.6,
  textBn: 'কলে কেউ আপনার কাছে কোড চেয়েছে।',
  textEn: 'Someone on the call asked you for a code.',
);

const reasonCall = Reason(
  code: 'CALL_ACTIVE_NON_CONTACT',
  weight: 0.3,
  textBn: 'আপনি এখন একটি অজানা নম্বরের সাথে কলে আছেন।',
  textEn: 'You are on a call with an unknown number.',
);

const holdAction = ActionItem(
  type: 'hold_transaction',
  params: {'minutes': 60},
);
const freezeAction = ActionItem(
  type: 'freeze_pin_reset',
  params: {'minutes': 60},
);
const trustedAction = ActionItem(
  type: 'trusted_contact_check',
  params: {'expires_in_minutes': 30},
);

ScoreResponse holdScore({List<ActionItem>? actions}) => ScoreResponse(
  decision: Decision.hold,
  riskScore: 0.86,
  band: Band.critical,
  reasons: const [reasonScam, reasonCall],
  actions: actions ?? const [holdAction, trustedAction, freezeAction],
  modelVersion: 'rules-v1',
);

const delayScore = ScoreResponse(
  decision: Decision.delay,
  riskScore: 0.55,
  band: Band.high,
  reasons: [
    Reason(
      code: 'NEW_PAYEE_ABOVE_P95',
      weight: 0.5,
      textBn: 'নতুন নম্বরে বড় অঙ্ক।',
      textEn: 'Large amount to a new payee.',
    ),
  ],
  actions: [
    ActionItem(type: 'delay_new_payee', params: {'minutes': 60}),
    trustedAction,
  ],
  modelVersion: 'rules-v1',
);

InterveneResponse served({
  String? audioAssetId = 'apa_hold_call_active',
  String scriptBn = 'আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন। কলে থাকা অবস্থায় পিন বদলানো বা কোড বলা নিরাপদ নয়।',
  List<ActionItem> actions = const [holdAction, trustedAction],
}) => InterveneResponse(
  intervene: true,
  scriptBn: scriptBn,
  scriptEn: 'This is your FinNest Assistant. You are on a call right now.',
  audioAssetId: audioAssetId,
  ui: UiMode.fullscreen,
  actions: actions,
  cooldownS: 600,
);
