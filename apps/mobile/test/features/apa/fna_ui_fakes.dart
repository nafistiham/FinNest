// Shared fakes of the FNA UI tests: a scripted ApaController and
// the app shell. Not a test file itself.

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:bhorosha/features/apa/ui/fna_ui_flags.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// An [ApaController] that returns [initial], lets the test [emit] states and
/// records every UI call by name.
class ScriptedApaController extends ApaController {
  ScriptedApaController(this.initial, {this.permanentlyDenied = false});

  final ApaState initial;
  bool permanentlyDenied;
  final List<String> calls = [];
  final List<ApaTurn> heard = [];

  /// The `tapToTalk` of every `startVoice` call.
  final List<bool> tapToTalkCalls = [];

  /// The microphone level the voice view's bars follow.
  @override
  final ValueNotifier<double> micLevel = ValueNotifier(0);

  @override
  ApaState build() => initial;

  void emit(ApaState next) => state = next;

  @override
  Future<void> startVoice({bool tapToTalk = false}) async {
    calls.add('startVoice');
    tapToTalkCalls.add(tapToTalk);
  }

  @override
  void dismissVoiceFallback() {
    calls.add('dismissVoiceFallback');
    state = state.copyWith(voiceFallback: null);
  }

  @override
  void onAppVisible() => calls.add('onAppVisible');
  @override
  Future<void> endVoice() async {
    calls.add('endVoice');
    state = state.copyWith(voicePhase: null);
  }

  @override
  Future<void> pauseVoice() async => calls.add('pauseVoice');
  @override
  Future<void> resumeVoice() async => calls.add('resumeVoice');
  @override
  Future<void> stopSpeaking() async => calls.add('stopSpeaking');
  @override
  void onAppHidden() => calls.add('onAppHidden');
  @override
  Future<void> hearIt(ApaTurn turn) async {
    calls.add('hearIt');
    heard.add(turn);
  }

  @override
  Future<void> hearCallSummary() async => calls.add('hearCallSummary');
  @override
  Future<bool> micPermanentlyDenied() async => permanentlyDenied;
  @override
  Future<void> sendText(String input) async => calls.add('sendText');
  @override
  Future<void> askPhoneSafe() async => calls.add('askPhoneSafe');
  @override
  Future<void> askWhyHeld() async => calls.add('askWhyHeld');
  @override
  Future<void> showRules() async => calls.add('showRules');
  @override
  Future<void> startScamCheck() async => calls.add('startScamCheck');
  @override
  void dismissError() => calls.add('dismissError');
  @override
  Future<void> close() async {}
}

/// Records what the platform hooks were asked.
class FnaPlatformLog {
  bool micGranted = true;
  int settingsOpened = 0;
}

const fnaAnswer = ApaTurn(
  speaker: ApaTurn.apa,
  textBn: 'কেউ কোড চাইলে কল কেটে দিন।',
  textEn: 'If anyone asks for a code, hang up.',
  path: ApaTurn.gemini,
);

const fnaQuestion = ApaTurn(
  speaker: ApaTurn.user,
  textBn: 'ওটিপি কী?',
  path: ApaTurn.gemini,
);

final fnaSummary = FnaCallSummary(
  scamType: 'fake_customer_care',
  urgency: 'high',
  requestedSecret: 'otp',
  evidenceQuote: 'আপনার অ্যাকাউন্ট বন্ধ হয়ে যাবে, এখনই কোডটা বলুন',
  recommendedAction: 'hold_and_warn',
  at: DateTime.utc(2026, 10, 18, 8, 30),
);

const fnaNextTime = 'কেউ ফোনে কোড চাইলে কল কেটে দিন।';

/// The sheet body (or [home]) in a phone-sized app with [controller].
Widget fnaApp(
  ScriptedApaController controller, {
  bool flag = true,
  FnaPlatformLog? platform,
  String locale = 'bn',
  String? nextTime = fnaNextTime,
  Widget? home,
  List<Override> extra = const [],
}) {
  final log = platform ?? FnaPlatformLog();
  return ProviderScope(
    overrides: [
      apaControllerProvider.overrideWith(() => controller),
      fnaVoiceAgentEnabledProvider.overrideWithValue(flag),
      fnaCallSummaryNextTimeProvider.overrideWithValue(nextTime),
      fnaMicGrantedProvider.overrideWithValue(() async => log.micGranted),
      fnaOpenSettingsProvider.overrideWithValue(() async {
        log.settingsOpened++;
        return true;
      }),
      ...extra,
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: Locale(locale),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home ?? const Scaffold(body: SafeArea(child: ApaSheetBody())),
    ),
  );
}

/// Sets a [width] x [height] dp phone with [textScale].
void fnaPhone(
  WidgetTester tester, {
  double width = 412,
  double height = 915,
  double textScale = 1,
}) {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
