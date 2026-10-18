// FNA voice mode: one label and one square shape
// per state, the PIN strip, captions, the hidden-number warning, the
// controls, the lifecycle rule, TalkBack and large text.

import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/ui/fna_voice_view.dart';
import 'package:bhorosha/features/apa/ui/widgets/fna_state_tile.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadAppFonts;
import 'fna_ui_fakes.dart';

/// Pumps a few frames: the shapes animate forever, so no pumpAndSettle.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

ApaState _voice(FnaPhase phase, {ApaState base = const ApaState()}) =>
    base.copyWith(voicePhase: phase);

void main() {
  setUpAll(loadAppFonts);

  const labels = {
    FnaPhase.connecting: ('সংযোগ হচ্ছে…', 'connecting'),
    FnaPhase.reconnecting: ('সংযোগ হচ্ছে…', 'connecting'),
    FnaPhase.micPermission: ('সংযোগ হচ্ছে…', 'connecting'),
    FnaPhase.listening: ('এফএনএ শুনছে', 'listening'),
    FnaPhase.thinking: ('এফএনএ ভাবছে…', 'thinking'),
    FnaPhase.speaking: ('এফএনএ বলছে', 'speaking'),
    FnaPhase.paused: ('বিরতি চলছে · কথা বলতে চাপুন', 'paused'),
    FnaPhase.textFallback: (
      'এখন কথা বলা যাচ্ছে না। লিখে জিজ্ঞাসা করুন, এফএনএ উত্তর পড়ে শোনাবে।',
      'problem',
    ),
    FnaPhase.offline: (
      'ইন্টারনেট নেই। নিচের প্রশ্ন বেছে নিন। উত্তর আপনার ফোনেই আছে।',
      'problem',
    ),
  };

  for (final MapEntry(key: phase, value: (label, shape)) in labels.entries) {
    testWidgets('${phase.name}: label "$label" and the $shape shape', (
      tester,
    ) async {
      final c = ScriptedApaController(_voice(phase));
      await tester.pumpWidget(fnaApp(c));
      await _frames(tester);
      expect(find.byKey(const Key('fna_voice_view')), findsOneWidget);
      expect(find.byKey(const Key('fna_talk')), findsNothing);
      expect(find.byKey(const Key('fna_state_label')), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      expect(find.byKey(Key('fna_shape_$shape')), findsOneWidget);
      final tile = tester.getSize(find.byType(FnaStateTile));
      expect(tile, const Size.square(FnaStateTile.regular));
      // The PIN rule is always on screen.
      expect(
        find.text('পিন বা কোড মুখে বলবেন না, এফএনএ-কেও না।'),
        findsOneWidget,
      );
    });
  }

  testWidgets('the problem tile is neutral, never the danger colour', (
    tester,
  ) async {
    final c = ScriptedApaController(_voice(FnaPhase.offline));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    final box = tester.widget<ColoredBox>(
      find.byKey(const Key('fna_shape_problem')),
    );
    final p = tester.element(find.byType(FnaStateTile)).palette;
    expect(box.color, p.surfaceVariant);
    expect(box.color, isNot(p.dangerContainer));
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('listening: five level bars that follow the level', (
    tester,
  ) async {
    final c = ScriptedApaController(_voice(FnaPhase.listening));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    double middle() =>
        tester.getSize(find.byKey(const Key('fna_level_bar_2'))).height;
    for (var i = 0; i < 5; i++) {
      expect(find.byKey(Key('fna_level_bar_$i')), findsOneWidget);
    }
    final quiet = middle();
    c.micLevel.value = 1;
    await _frames(tester);
    expect(middle(), greaterThan(quiet));
  });

  testWidgets('the microphone level never rebuilds the captions', (
    tester,
  ) async {
    final c = ScriptedApaController(
      _voice(
        FnaPhase.listening,
        base: const ApaState(userCaption: 'ওটিপি কী?', modelCaption: 'উত্তর'),
      ),
    );
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    final before = FnaCaptions.debugBuilds;
    for (final v in [0.2, 0.8, 0.4, 1.0, 0.1]) {
      c.micLevel.value = v;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(FnaCaptions.debugBuilds, before);
    // A phase change does not rebuild them either; a caption does.
    c.emit(c.state.copyWith(voicePhase: FnaPhase.thinking));
    await _frames(tester);
    expect(FnaCaptions.debugBuilds, before);
    c.emit(c.state.copyWith(modelCaption: 'নতুন উত্তর'));
    await _frames(tester);
    expect(FnaCaptions.debugBuilds, before + 1);
  });

  group('controls', () {
    testWidgets('Stop only while FNA speaks', (tester) async {
      final c = ScriptedApaController(_voice(FnaPhase.listening));
      await tester.pumpWidget(fnaApp(c));
      await _frames(tester);
      expect(find.byKey(const Key('fna_stop')), findsNothing);

      c.emit(c.state.copyWith(voicePhase: FnaPhase.speaking));
      await _frames(tester);
      expect(find.byKey(const Key('fna_stop')), findsOneWidget);
      await tester.tap(find.byKey(const Key('fna_stop')));
      await tester.pump();
      expect(c.calls, ['stopSpeaking']);

      c.emit(c.state.copyWith(voicePhase: FnaPhase.thinking));
      await _frames(tester);
      expect(find.byKey(const Key('fna_stop')), findsNothing);
    });

    testWidgets('Pause, then Resume (button and tile)', (tester) async {
      final c = ScriptedApaController(_voice(FnaPhase.listening));
      await tester.pumpWidget(fnaApp(c));
      await _frames(tester);
      await tester.tap(find.byKey(const Key('fna_pause')));
      await tester.pump();
      expect(c.calls, ['pauseVoice']);

      c.emit(c.state.copyWith(voicePhase: FnaPhase.paused));
      await _frames(tester);
      expect(find.byKey(const Key('fna_pause')), findsNothing);
      await tester.tap(find.byKey(const Key('fna_resume')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('fna_tile_resume')));
      await tester.pump();
      expect(c.calls, ['pauseVoice', 'resumeVoice', 'resumeVoice']);
    });

    testWidgets('every control is at least 56 dp', (tester) async {
      final c = ScriptedApaController(_voice(FnaPhase.speaking));
      await tester.pumpWidget(fnaApp(c));
      await _frames(tester);
      for (final key in [
        'fna_stop',
        'fna_pause',
        'fna_type_instead',
        'fna_end',
      ]) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(size.height, greaterThanOrEqualTo(56), reason: key);
        expect(size.width, greaterThanOrEqualTo(56), reason: key);
      }
    });

    testWidgets('End closes voice mode', (tester) async {
      final c = ScriptedApaController(_voice(FnaPhase.listening));
      await tester.pumpWidget(fnaApp(c));
      await _frames(tester);
      await tester.tap(find.byKey(const Key('fna_end')));
      await _frames(tester);
      expect(c.calls, ['endVoice']);
      expect(find.byKey(const Key('fna_voice_view')), findsNothing);
      expect(find.byKey(const Key('fna_talk')), findsOneWidget);
    });

    testWidgets('Type instead ends voice mode and focuses the text field', (
      tester,
    ) async {
      final c = ScriptedApaController(_voice(FnaPhase.listening));
      await tester.pumpWidget(fnaApp(c));
      await _frames(tester);
      await tester.tap(find.byKey(const Key('fna_type_instead')));
      await _frames(tester);
      expect(c.calls, ['endVoice']);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
    });
  });

  testWidgets('captions: the customer in 2 lines, FNA in 3', (tester) async {
    final c = ScriptedApaController(
      _voice(
        FnaPhase.speaking,
        base: const ApaState(
          userCaption: 'ওটিপি কী?',
          modelCaption: 'ওটিপি একটি গোপন কোড। কাউকে বলবেন না।',
        ),
      ),
    );
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    final user = tester.widget<Text>(find.byKey(const Key('fna_caption_user')));
    final fna = tester.widget<Text>(find.byKey(const Key('fna_caption_fna')));
    expect(user.maxLines, 2);
    expect(fna.maxLines, 3);
    expect(find.text('ওটিপি কী?'), findsOneWidget);
  });

  testWidgets('a hidden number: the warning and one heavy haptic', (
    tester,
  ) async {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final c = ScriptedApaController(_voice(FnaPhase.listening));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    expect(find.byKey(const Key('fna_secret_blocked')), findsNothing);

    c.emit(c.state.copyWith(secretBlocked: true, userCaption: '••••'));
    await _frames(tester);
    expect(find.byKey(const Key('fna_secret_blocked')), findsOneWidget);
    expect(
      find.text('একটি নম্বর লুকিয়ে রাখা হয়েছে। কোড কাউকে বলবেন না।'),
      findsOneWidget,
    );
    c.micLevel.value = 0.5;
    await _frames(tester);
    expect(haptics, ['HapticFeedbackType.heavyImpact']);
  });

  testWidgets('the hidden-number warning is a live region and stays 5 s', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final c = ScriptedApaController(_voice(FnaPhase.listening));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    c.emit(c.state.copyWith(secretBlocked: true));
    await _frames(tester);
    expect(
      find.ancestor(
        of: find.byKey(const Key('fna_secret_blocked')),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.liveRegion ?? false),
        ),
      ),
      findsOneWidget,
    );
    // The next caption clears the flag: the warning stays a while.
    c.emit(c.state.copyWith(secretBlocked: false, modelCaption: 'উত্তর'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('fna_secret_blocked')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('fna_secret_blocked')), findsNothing);
    semantics.dispose();
  });

  testWidgets('a long FNA caption opens in full with "Show all"', (
    tester,
  ) async {
    final long = List.filled(
      12,
      'কেউ কোড চাইলে সে প্রতারক, কল কেটে দিন।',
    ).join(' ');
    final c = ScriptedApaController(
      _voice(FnaPhase.speaking, base: ApaState(modelCaption: long)),
    );
    fnaPhone(tester);
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    Text caption() =>
        tester.widget<Text>(find.byKey(const Key('fna_caption_fna')));
    expect(caption().maxLines, 3);
    expect(find.text('পুরোটা দেখুন'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('fna_caption_toggle')));
    await tester.tap(find.byKey(const Key('fna_caption_toggle')));
    await _frames(tester);
    expect(caption().maxLines, isNull);
    expect(find.text('কম দেখুন'), findsOneWidget);
    // Tapping the caption itself folds it again.
    await tester.ensureVisible(find.byKey(const Key('fna_caption_fna')));
    await tester.tap(find.byKey(const Key('fna_caption_fna')));
    await _frames(tester);
    expect(caption().maxLines, 3);
    // A new answer opens folded.
    await tester.ensureVisible(find.byKey(const Key('fna_caption_toggle')));
    await tester.tap(find.byKey(const Key('fna_caption_toggle')));
    await _frames(tester);
    c.emit(c.state.copyWith(modelCaption: '$long নতুন'));
    await _frames(tester);
    expect(caption().maxLines, 3);
  });

  testWidgets('a short FNA caption has no "Show all"', (tester) async {
    final c = ScriptedApaController(
      _voice(FnaPhase.speaking, base: const ApaState(modelCaption: 'ঠিক আছে।')),
    );
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    expect(find.byKey(const Key('fna_caption_toggle')), findsNothing);
  });

  testWidgets('the topic chips stay in voice mode', (tester) async {
    final c = ScriptedApaController(_voice(FnaPhase.speaking));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('apa_quick_rules')));
    await tester.pump();
    expect(c.calls, ['showRules']);
  });

  testWidgets('hidden or paused app: onAppHidden once; inactive: never', (
    tester,
  ) async {
    final c = ScriptedApaController(_voice(FnaPhase.listening));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(c.calls, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(c.calls, ['onAppHidden']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // Back on screen after the hide: onAppVisible once.
    expect(c.calls, ['onAppHidden', 'onAppVisible']);
    // A resume after only `inactive` (the notification shade) says nothing.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(c.calls, ['onAppHidden', 'onAppVisible']);
  });

  testWidgets('TalkBack: the state label is a live region', (tester) async {
    final semantics = tester.ensureSemantics();
    final c = ScriptedApaController(_voice(FnaPhase.thinking));
    await tester.pumpWidget(fnaApp(c));
    await _frames(tester);
    expect(
      tester.getSemantics(find.byKey(const Key('fna_state_label'))),
      isSemantics(isLiveRegion: true, label: 'এফএনএ ভাবছে…'),
    );
    semantics.dispose();
  });

  testWidgets('reduced motion: still frames, so the view settles', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    for (final phase in [
      FnaPhase.connecting,
      FnaPhase.thinking,
      FnaPhase.speaking,
    ]) {
      final c = ScriptedApaController(_voice(phase));
      await tester.pumpWidget(
        KeyedSubtree(key: ValueKey(phase), child: fnaApp(c)),
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse, reason: phase.name);
    }
  });

  group('large text at 360 dp', () {
    for (final phase in [
      FnaPhase.connecting,
      FnaPhase.listening,
      FnaPhase.thinking,
      FnaPhase.speaking,
      FnaPhase.paused,
      FnaPhase.offline,
    ]) {
      testWidgets('${phase.name} at 1.4: no overflow, 72 dp tile', (
        tester,
      ) async {
        fnaPhone(tester, width: 360, height: 640, textScale: 1.4);
        final c = ScriptedApaController(
          _voice(
            phase,
            base: const ApaState(
              userCaption: 'আমার ফোনে কেউ কোড চাইছে, কী করব?',
              modelCaption:
                  'কেউ কোড চাইলে সে প্রতারক। কল কেটে দিন। তারপর নিজে '
                  'হেল্পলাইনে কল করুন।',
              secretBlocked: true,
            ),
          ),
        );
        await tester.pumpWidget(fnaApp(c));
        await _frames(tester);
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(FnaStateTile)),
          const Size.square(FnaStateTile.compact),
        );
        // The topic chips step aside only while FNA listens.
        expect(
          find.byKey(const Key('apa_quick_phone')),
          phase == FnaPhase.listening ? findsNothing : findsOneWidget,
        );
      });
    }
  });
}
