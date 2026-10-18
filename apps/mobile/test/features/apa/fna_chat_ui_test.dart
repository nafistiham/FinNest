// FNA chat view: the Home bar's chat icon, the "Talk" button with
// the microphone explanation, "Hear it" on answers, the fallback strips and
// the flag-off sheet.

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadAppFonts;
import 'apa_test_doubles.dart';
import 'fna_ui_fakes.dart';

Widget _bar(bool flag) => ProviderScope(
  overrides: [
    ...ApaHarness().overrides,
    initialLocaleProvider.overrideWithValue(const Locale('bn')),
    apaTipSeedProvider.overrideWithValue(0),
    fnaVoiceAgentEnabledProvider.overrideWithValue(flag),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: const Locale('bn'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: const Scaffold(
      bottomNavigationBar: BhBottomBar.apa(apaScreen: 'home'),
    ),
  ),
);

void main() {
  setUpAll(loadAppFonts);

  group('Home bar', () {
    testWidgets('flag on: chat bubble icon, same label', (tester) async {
      await tester.pumpWidget(_bar(true));
      await tester.pump();
      expect(find.byKey(const Key('apa_bar_icon_chat')), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.byKey(const Key('apa_bar_icon_mic')), findsNothing);
      expect(find.text('এফএনএ-কে জিজ্ঞাসা করুন'), findsOneWidget);
    });

    testWidgets('flag off: the microphone icon as before', (tester) async {
      await tester.pumpWidget(_bar(false));
      await tester.pump();
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
    });
  });

  group('Talk', () {
    testWidgets('replaces hold-to-talk; granted mic starts voice at once', (
      tester,
    ) async {
      final c = ScriptedApaController(const ApaState());
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apa_hold_to_talk')), findsNothing);
      final talk = find.byKey(const Key('fna_talk'));
      expect(find.text('কথা বলুন'), findsOneWidget);
      expect(tester.getSize(talk).height, greaterThanOrEqualTo(BhSize.touch));
      await tester.tap(talk);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fna_mic_rationale')), findsNothing);
      expect(c.calls, ['startVoice']);
      expect(c.tapToTalkCalls, [false]);
    });

    testWidgets('TalkBack on: voice starts in tap-to-talk mode', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final c = ScriptedApaController(const ApaState());
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fna_talk')));
      await tester.pumpAndSettle();
      expect(c.tapToTalkCalls, [true]);
    });

    testWidgets('mic not granted: the explanation shows before the dialog', (
      tester,
    ) async {
      final c = ScriptedApaController(const ApaState());
      final platform = FnaPlatformLog()..micGranted = false;
      await tester.pumpWidget(fnaApp(c, platform: platform));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fna_talk')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fna_mic_rationale')), findsOneWidget);
      expect(
        find.text(
          'এফএনএ-র সাথে কথা বলতে মাইক্রোফোন লাগবে। এফএনএ শুধু এই স্ক্রিন '
          'খোলা থাকলে শোনে। আপনার ফোনকল কখনো শোনে না।',
        ),
        findsOneWidget,
      );
      expect(c.calls, isEmpty, reason: 'no permission request yet');
      await tester.tap(find.byKey(const Key('fna_mic_turn_on')));
      await tester.pumpAndSettle();
      expect(c.calls, ['startVoice']);
    });

    testWidgets('"Type instead" on the explanation focuses the text field', (
      tester,
    ) async {
      final c = ScriptedApaController(const ApaState());
      final platform = FnaPlatformLog()..micGranted = false;
      await tester.pumpWidget(fnaApp(c, platform: platform));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fna_talk')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fna_mic_type_instead')));
      await tester.pumpAndSettle();
      expect(c.calls, isEmpty);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('denied for good: the button reads "Open settings"', (
      tester,
    ) async {
      final c = ScriptedApaController(
        const ApaState(),
        permanentlyDenied: true,
      );
      final platform = FnaPlatformLog();
      await tester.pumpWidget(fnaApp(c, platform: platform));
      await tester.pumpAndSettle();
      expect(find.text('সেটিংস খুলুন'), findsOneWidget);
      expect(find.text('কথা বলুন'), findsNothing);
      await tester.tap(find.byKey(const Key('fna_talk')));
      await tester.pumpAndSettle();
      expect(platform.settingsOpened, 1);
      expect(c.calls, isEmpty);
    });
  });

  group('Hear it', () {
    testWidgets('on FNA answers only; calls hearIt; stop while playing', (
      tester,
    ) async {
      final c = ScriptedApaController(
        const ApaState(turns: [fnaQuestion, fnaAnswer]),
      );
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      Finder inBubble(int i, String key) => find.descendant(
        of: find.byKey(Key('apa_bubble_$i')),
        matching: find.byKey(Key(key)),
      );
      expect(inBubble(0, 'fna_hear'), findsNothing);
      expect(inBubble(1, 'fna_hear'), findsOneWidget);
      expect(find.text('শুনুন'), findsOneWidget);
      // TalkBack names the answer the button reads.
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(inBubble(1, 'fna_hear')),
        isSemantics(isButton: true, label: 'শুনুন: কেউ কোড চাইলে কল কেটে দিন।'),
      );
      semantics.dispose();

      await tester.tap(inBubble(1, 'fna_hear'));
      await tester.pump();
      expect(c.calls, ['hearIt']);
      expect(c.heard.single, same(fnaAnswer));

      c.emit(c.state.copyWith(hearingTurn: fnaAnswer));
      await tester.pump();
      expect(inBubble(1, 'fna_hear_stop'), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      await tester.tap(inBubble(1, 'fna_hear_stop'));
      await tester.pump();
      expect(c.calls, ['hearIt', 'hearIt'], reason: 'hearIt toggles off');
    });
  });

  group('fallback strips', () {
    for (final (reason, text) in [
      (
        FnaFallbackReason.connectTimeout,
        'এখন কথা বলা যাচ্ছে না। লিখে জিজ্ঞাসা করুন, এফএনএ উত্তর পড়ে শোনাবে।',
      ),
      (
        FnaFallbackReason.liveFailed,
        'এখন কথা বলা যাচ্ছে না। লিখে জিজ্ঞাসা করুন, এফএনএ উত্তর পড়ে শোনাবে।',
      ),
      (
        FnaFallbackReason.offline,
        'ইন্টারনেট নেই। নিচের প্রশ্ন বেছে নিন। উত্তর আপনার ফোনেই আছে।',
      ),
    ]) {
      testWidgets('${reason.name}: the matching line', (tester) async {
        final c = ScriptedApaController(ApaState(voiceFallback: reason));
        await tester.pumpWidget(fnaApp(c));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('fna_fallback_${reason.name}')), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(find.byKey(const Key('fna_fallback_mic')), findsNothing);
      });
    }

    testWidgets('micDenied: the denied line and "Turn on microphone"', (
      tester,
    ) async {
      final c = ScriptedApaController(
        const ApaState(voiceFallback: FnaFallbackReason.micDenied),
      );
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fna_fallback_micDenied')), findsOneWidget);
      // Not the explanation again: it was read before the dialog.
      expect(
        find.text('মাইক্রোফোনের অনুমতি নেই। লিখে জিজ্ঞাসা করুন।'),
        findsOneWidget,
      );
      expect(find.textContaining('মাইক্রোফোন লাগবে'), findsNothing);
      expect(find.text('মাইক্রোফোন চালু করুন'), findsOneWidget);
      await tester.tap(find.byKey(const Key('fna_fallback_mic')));
      await tester.pump();
      expect(c.calls, ['startVoice']);
    });

    testWidgets('Close dismisses the strip', (tester) async {
      final c = ScriptedApaController(
        const ApaState(voiceFallback: FnaFallbackReason.liveFailed),
      );
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      final close = find.byKey(const Key('fna_fallback_close'));
      expect(tester.getSize(close).height, greaterThanOrEqualTo(BhSize.touch));
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(c.calls, ['dismissVoiceFallback']);
      expect(find.byKey(const Key('fna_fallback_liveFailed')), findsNothing);
    });

    testWidgets('the old hint does not repeat the fallback line', (
      tester,
    ) async {
      final c = ScriptedApaController(
        const ApaState(
          voiceFallback: FnaFallbackReason.liveFailed,
          error: ApaHint.liveFailed,
        ),
      );
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apa_hint')), findsNothing);
    });
  });

  group('About the last call', () {
    testWidgets('no call yet: the empty line and the caller check', (
      tester,
    ) async {
      final c = ScriptedApaController(const ApaState());
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apa_quick_summary')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'এখনো কোনো সন্দেহজনক কল ধরা পড়েনি। কেউ কোড চাইলে, কলার কী বলছে '
          'এফএনএ-কে বলুন।',
        ),
        findsOneWidget,
      );
      expect(c.calls, isEmpty);
      await tester.tap(find.byKey(const Key('fna_no_call_check')));
      await tester.pumpAndSettle();
      expect(c.calls, ['startScamCheck']);
      expect(find.byKey(const Key('fna_no_call')), findsNothing);
    });

    testWidgets('with a call: FNA reads the card', (tester) async {
      final c = ScriptedApaController(ApaState(callSummary: fnaSummary));
      await tester.pumpWidget(fnaApp(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apa_quick_summary')));
      await tester.pump();
      expect(c.calls, ['hearCallSummary']);
    });
  });

  testWidgets('flag off: the old sheet, hold-to-talk and no FNA extras', (
    tester,
  ) async {
    final c = ScriptedApaController(
      ApaState(
        turns: const [fnaQuestion, fnaAnswer],
        callSummary: fnaSummary,
        voiceFallback: FnaFallbackReason.offline,
        voicePhase: FnaPhase.listening,
      ),
    );
    await tester.pumpWidget(fnaApp(c, flag: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apa_hold_to_talk')), findsOneWidget);
    expect(find.text('চেপে ধরে বলুন'), findsOneWidget);
    for (final key in [
      'fna_talk',
      'fna_hear',
      'fna_call_summary_card',
      'fna_fallback_offline',
      'fna_voice_view',
      'apa_quick_summary',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
  });

  testWidgets('chat at 360 dp and text size 1.4: no overflow', (tester) async {
    fnaPhone(tester, width: 360, height: 640, textScale: 1.4);
    final c = ScriptedApaController(
      ApaState(
        turns: const [fnaQuestion, fnaAnswer],
        callSummary: fnaSummary,
        voiceFallback: FnaFallbackReason.micDenied,
      ),
    );
    await tester.pumpWidget(fnaApp(c));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('fna_talk')), findsOneWidget);
  });
}
