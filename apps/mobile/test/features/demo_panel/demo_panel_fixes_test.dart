// Demo panel fixes and the bounded "প্রাপক সন্দেহভাজন" story.
import 'dart:async';

import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/choice_tile.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/demo_panel/logic/demo_panel_controller.dart';
import 'package:bhorosha/features/demo_panel/ui/demo_panel_screen.dart';
import 'package:bhorosha/features/demo_panel/ui/demo_panel_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_panel_test_support.dart';

/// A demo-state repo whose writes never answer (a dead network).
class _HangingRepo implements DemoStateRepo {
  final _states = StreamController<DemoState>.broadcast();
  int writes = 0;

  @override
  Stream<DemoState> watch(String uid) async* {
    yield DemoState.initial;
    yield* _states.stream;
  }

  @override
  Future<void> write(String uid, DemoState s) {
    writes++;
    return Completer<void>().future;
  }

  @override
  Future<void> reset(String uid) => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final Finder _list = find
    .descendant(
      of: find.byType(DemoPanelBody),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _reveal(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
    await tester.drag(_list, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every behaviour mode has its muted helper line', (
    tester,
  ) async {
    await pumpDemo(
      tester,
      harness: DemoPanelHarness(),
      child: const DemoPanelScreen(),
    );
    const expected = {
      BehaviourMode.live: 'এই ফোনের আসল স্পর্শ যায়',
      BehaviourMode.off: 'আচরণ সংকেত বন্ধ: সার্ভার আচরণ দেখবে না',
      BehaviourMode.replayStranger:
          'সিমুলেটেড: অন্য কারও হাতের ধরন; সার্ভার আটকে রাখবে',
      BehaviourMode.replayTapPattern: 'সিমুলেটেড: ট্যাপের ধরন বদলানো।',
      BehaviourMode.replayShaking: 'সিমুলেটেড: কাঁপা হাত, অন্যভাবে ধরা ফোন।',
      BehaviourMode.replayCoached: 'সিমুলেটেড: কেউ বলে দিচ্ছে, ধীরে টাইপ।',
    };
    for (final m in BehaviourMode.values) {
      final help = find.byKey(Key('demo_behaviour_help_${m.name}'));
      await _reveal(tester, help);
      final text = tester.widget<Text>(help);
      expect(text.data, expected[m], reason: m.name);
      expect(text.style?.color, tester.element(help).palette.mutedText);
      expect(
        find.descendant(
          of: find.byKey(DemoPanelBody.behaviourModeOptionKey(m)),
          matching: help,
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('an off switch has an outline thumb in dark, an on switch the '
      'primary', (tester) async {
    await pumpDemo(
      tester,
      harness: DemoPanelHarness(),
      child: const DemoPanelScreen(),
      brightness: Brightness.dark,
    );
    final sw = find.byKey(DemoPanelBody.switchKey('sim_swap'));
    await _reveal(tester, sw);
    final theme = Theme.of(tester.element(sw));
    final thumb = theme.switchTheme.thumbColor!;
    expect(thumb.resolve(const {}), theme.colorScheme.outline);
    expect(
      thumb.resolve(const {WidgetState.selected}),
      theme.colorScheme.primary,
    );
    expect(theme.colorScheme.outline, isNot(theme.colorScheme.primary));
  });

  testWidgets('a voice preview reads "চলছে…" with a stop while it plays, '
      'and the second tap stops it', (tester) async {
    final audio = FakeApaAudio();
    await pumpDemo(
      tester,
      harness: DemoPanelHarness(),
      child: const DemoPanelScreen(),
      extraOverrides: [apaAudioProvider.overrideWithValue(audio)],
    );
    final button = find.byKey(DemoPanelBody.previewAudioKey);
    await _reveal(tester, button);
    expect(
      find.descendant(of: button, matching: find.text('চলছে…')),
      findsNothing,
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(audio.played, ['apa_hold_call_active']);
    expect(
      find.descendant(of: button, matching: find.text('চলছে…')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: button, matching: find.byIcon(Icons.stop)),
      findsOneWidget,
    );
    // The other preview waits its turn.
    final gemini = find.byKey(DemoPanelBody.previewGeminiKey);
    expect(
      tester
          .widget<OutlinedButton>(
            find.descendant(of: gemini, matching: find.byType(OutlinedButton)),
          )
          .onPressed,
      isNull,
    );
    // The snackbar still names the source.
    expect(find.textContaining('ডেমো: শেষ অডিও এসেছে:'), findsOneWidget);

    // The clip ends: the label comes back.
    audio.finish('apa_hold_call_active');
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: button, matching: find.text('চলছে…')),
      findsNothing,
    );

    // Play, then stop with the same button.
    await tester.tap(button);
    await tester.pumpAndSettle();
    final stops = audio.stopCalls;
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(audio.stopCalls, stops + 1);
    expect(
      find.descendant(of: button, matching: find.text('চলছে…')),
      findsNothing,
    );
  });

  testWidgets('"ফোন যাচাইয়ের ফল · ডেমো", and persona and verdict share one '
      'selected style', (tester) async {
    await pumpDemo(
      tester,
      harness: DemoPanelHarness(),
      child: const DemoPanelScreen(),
    );
    expect(find.text('ফোন যাচাইয়ের ফল (ডেমো)'), findsNothing);
    await _reveal(tester, find.byKey(DemoPanelBody.integrityKey));
    expect(find.text('ফোন যাচাইয়ের ফল · ডেমো'), findsOneWidget);
    ChoiceTile tile(String label) => tester.widget<ChoiceTile>(
      find.ancestor(of: find.text(label), matching: find.byType(ChoiceTile)),
    );
    await _reveal(tester, find.byKey(DemoPanelBody.personaKey));
    expect(
      find.descendant(
        of: find.byKey(DemoPanelBody.personaKey),
        matching: find.byType(ChoiceTile),
      ),
      findsNWidgets(2),
    );
    expect(tile('রিনা').selected, isTrue);
    expect(tile('রহিমা').selected, isFalse);
    expect(tile('স্বয়ংক্রিয়').selected, isTrue);
  });

  testWidgets('"প্রাপক সন্দেহভাজন" closes the sheet and navigates even when '
      'the demo-state write never answers', (tester) async {
    final repo = _HangingRepo();
    final went = <String>[];
    await pumpDemo(
      tester,
      harness: DemoPanelHarness(),
      extraOverrides: [demoStateRepoProvider.overrideWithValue(repo)],
      child: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open_panel'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SizedBox(
                  height: 700,
                  child: DemoPanelBody(navigate: went.add),
                ),
              ),
              child: const Icon(Icons.tune),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_panel')));
    await tester.pumpAndSettle();
    final story = find.byKey(DemoPanelBody.storySuspectKey);
    await _reveal(tester, story);
    await tester.tap(story);
    await tester.pump();
    expect(repo.writes, greaterThan(0));
    expect(went, isEmpty, reason: 'waiting on the bounded write');
    await tester.pump(DemoPanelController.writeBudget);
    await tester.pumpAndSettle();
    expect(went, [DemoPanelBody.suspectPayeeLocation]);
    expect(find.byType(DemoPanelBody), findsNothing, reason: 'sheet closed');
  });
}
