import 'dart:async';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/contracts/common.dart';
import 'package:bhorosha/data/contracts/intervene.dart';
import 'package:bhorosha/data/contracts/score.dart';
import 'package:bhorosha/features/intervention/logic/action_labels.dart';
import 'package:bhorosha/features/intervention/logic/apa_voice.dart';
import 'package:bhorosha/features/intervention/logic/asset_catalog.dart';
import 'package:bhorosha/features/intervention/logic/metrics_log.dart';
import 'package:bhorosha/features/intervention/ui/intervention_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intervention_fakes.dart';

/// Everything a test needs after opening the overlay.
class Opened {
  Opened(this.audio, this.metrics, this.intervene);
  final FakeApaAudio audio;
  final MetricsLog metrics;
  final Completer<InterveneResponse?> intervene;
  final List<ActionItem> actions = [];
  int dismissed = 0;
}

/// Merge as Task 7 does it: score actions first, intervene adds new types.
List<ActionItem> mergeActions(ScoreResponse score, InterveneResponse? r) {
  final out = [...score.actions];
  for (final a in r?.actions ?? const <ActionItem>[]) {
    if (!out.any((s) => s.type == a.type)) out.add(a);
  }
  return out;
}

/// Pumps a home screen with an "open" button and taps it.
Future<Opened> openOverlay(
  WidgetTester tester, {
  ScoreResponse? score,
  String predictedAsset = 'apa_hold_call_active',
  bool speak = true,
  int? scoreArrivedAtMs,
  Completer<InterveneResponse?>? completer,
  Brightness brightness = Brightness.light,
  ValueNotifier<bool>? trustedSent,
  Locale locale = const Locale('bn'),
  HeldSummary? held,
  FutureOr<void> Function(ActionItem)? onAction,
  Haptics haptics = const SystemHaptics(),
}) async {
  // A phone (Pixel 6 class) rather than the 800x600 default, so the lazy
  // ListView builds what a user would see.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);

  final s = score ?? holdScore();
  final opened = Opened(FakeApaAudio(), MetricsLog(), completer ?? Completer());
  await tester.pumpWidget(
    localizedApp(
      brightness: brightness,
      locale: locale,
      overrides: [
        apaAudioProvider.overrideWithValue(opened.audio),
        metricsLogProvider.overrideWithValue(opened.metrics),
      ],
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () => InterventionOverlay.show(
                context,
                score: s,
                trigger: 'call_active',
                predictedAsset: predictedAsset,
                intervene: opened.intervene.future,
                actions: (r) => mergeActions(s, r),
                onAction: onAction ?? opened.actions.add,
                haptics: haptics,
                onDismiss: () => opened.dismissed++,
                speak: speak,
                scoreArrivedAtMs:
                    scoreArrivedAtMs ?? DateTime.now().millisecondsSinceEpoch,
                trustedSent: trustedSent,
                held: held,
              ),
              // An icon, not text, so the home screen adds nothing to the
              // "only server strings" census.
              child: const Icon(Icons.open_in_new),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  // The route transition; pumpAndSettle would spin on the waiting indicator.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return opened;
}

Future<void> resolve(
  WidgetTester tester,
  Opened o,
  InterveneResponse? r,
) async {
  o.intervene.complete(r);
  await tester.pump();
  await tester.pump();
}

Future<void> settleAfterResolve(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100));

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  Set<String> allowedStrings(ScoreResponse s, InterveneResponse? r) => {
    for (final reason in s.reasons) reason.textBn,
    if (r != null) ...[r.scriptBn, r.scriptEn],
    for (final a in mergeActions(s, r)) ActionLabels.labelFor(l10n, a),
    l10n.interventionDismiss,
    l10n.interventionHeldTitle,
    l10n.interventionEnglish,
    l10n.interventionWaiting,
    l10n.apaInitial,
    l10n.askApa,
  };

  testWidgets('renders only server strings and ARB labels, before and after', (
    tester,
  ) async {
    final score = holdScore();
    final o = await openOverlay(tester, score: score);

    final before = visibleTexts(tester);
    expect(before, contains(reasonScam.textBn));
    expect(before, contains(reasonCall.textBn));
    expect(before, contains(l10n.interventionWaiting));
    expect(before.difference(allowedStrings(score, null)), isEmpty);

    final r = served();
    await resolve(tester, o, r);
    await settleAfterResolve(tester);

    final after = visibleTexts(tester);
    expect(after, contains(r.scriptBn));
    expect(after, isNot(contains(l10n.interventionWaiting)));
    expect(after.difference(allowedStrings(score, r)), isEmpty);

    // script_bn is Apa's line: 22 sp or larger, above the reasons.
    final script = tester.widget<Text>(
      find.byKey(const ValueKey('intervention_script')),
    );
    expect(script.style?.fontSize, greaterThanOrEqualTo(22));
    final scriptY = tester
        .getTopLeft(find.byKey(const ValueKey('intervention_script')))
        .dy;
    final reasonY = tester.getTopLeft(find.text(reasonScam.textBn)).dy;
    expect(scriptY, lessThan(reasonY));
  });

  testWidgets(
    'plays the predicted clip before the intervene future completes',
    (tester) async {
      final o = await openOverlay(tester);
      expect(o.intervene.isCompleted, isFalse);
      expect(o.audio.scripted, [
        (assetId: 'apa_hold_call_active', scriptBn: ''),
      ]);
      expect(o.audio.played, ['apa_hold_call_active']);
      expect(o.audio.spoken, isEmpty);
    },
  );

  testWidgets(
    'an already resolved intervene still plays the predicted clip first',
    (tester) async {
      final done = Completer<InterveneResponse?>()
        ..complete(served(audioAssetId: 'apa_generic_caution'));
      final o = await openOverlay(tester, completer: done);
      await settleAfterResolve(tester);
      expect(o.audio.played, ['apa_hold_call_active', 'apa_generic_caution']);
      // The warning haptic belongs to the entrance, not to the clip order.
    },
  );

  testWidgets('the entrance fires one warning haptic', (tester) async {
    final haptics = RecordingHaptics();
    await openOverlay(tester, haptics: haptics);
    expect(haptics.warnings, 1);
    expect(haptics.lights, 0);
  });

  testWidgets(
    'trusted contact: a tap burst sends one request; the button is busy '
    'until the caller\'s future completes',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      final o = await openOverlay(
        tester,
        onAction: (a) {
          if (a.type != 'trusted_contact_check') return null;
          calls++;
          return pending.future;
        },
      );
      final button = find.byKey(const ValueKey('action_trusted_contact_check'));
      await tester.tap(button);
      await tester.pump();
      await tester.tap(button, warnIfMissed: false);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);
      expect(
        tester.widget<OutlinedButton>(button).onPressed,
        isNull,
        reason: 'disabled while busy',
      );
      expect(
        find.byKey(const ValueKey('action_trusted_contact_check_busy')),
        findsOneWidget,
      );
      // Other actions still work meanwhile.
      await tester.tap(find.byKey(const ValueKey('action_ask_apa')));
      await tester.pump();
      expect(o.actions, isEmpty, reason: 'custom onAction recorded nothing');

      pending.complete();
      await tester.pump();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      expect(
        find.byKey(const ValueKey('action_trusted_contact_check_busy')),
        findsNothing,
      );
      await tester.tap(button);
      await tester.pump();
      expect(calls, 2, reason: 'a later tap is a new request');
    },
  );

  testWidgets('no language toggle when the server sent one language only', (
    tester,
  ) async {
    final o = await openOverlay(tester);
    await resolve(
      tester,
      o,
      const InterveneResponse(
        intervene: true,
        scriptBn: 'আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন।',
        scriptEn: '',
        audioAssetId: 'apa_hold_call_active',
        ui: UiMode.fullscreen,
        actions: [holdAction],
        cooldownS: 600,
      ),
    );
    await settleAfterResolve(tester);
    expect(find.byKey(const ValueKey('intervention_script')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('intervention_english_toggle')),
      findsNothing,
    );
  });

  testWidgets('a different served asset is queued after the predicted one', (
    tester,
  ) async {
    final o = await openOverlay(tester);
    await resolve(tester, o, served(audioAssetId: 'apa_generic_caution'));
    await settleAfterResolve(tester);
    expect(o.audio.played, ['apa_hold_call_active', 'apa_generic_caution']);
  });

  testWidgets('the same served asset is not replayed', (tester) async {
    final o = await openOverlay(tester);
    await resolve(tester, o, served(audioAssetId: 'apa_hold_call_active'));
    await settleAfterResolve(tester);
    expect(o.audio.played, ['apa_hold_call_active']);
    expect(o.audio.spoken, isEmpty);
  });

  testWidgets('a null served asset plays nothing more', (tester) async {
    final o = await openOverlay(tester);
    await resolve(tester, o, served(audioAssetId: null));
    await settleAfterResolve(tester);
    expect(o.audio.played, ['apa_hold_call_active']);
    expect(o.audio.spoken, isEmpty);
  });

  testWidgets('an unknown served asset with no Gemini stays unspoken: the '
      'hold clip already played, never the phone\'s own voice', (tester) async {
    final o = await openOverlay(tester);
    final r = served(audioAssetId: 'apa_future_clip');
    await resolve(tester, o, r);
    await settleAfterResolve(tester);
    expect(o.audio.played, ['apa_hold_call_active']);
    expect(o.audio.spoken, isEmpty);
  });

  group('session-field lines through ApaVoice', () {
    const dynamicBn = 'এই লোকটি আপনার কাছে কোড চাইছে, কোড কাউকে দেবেন না।';
    InterveneResponse withLines(List<ApaLine> lines) => InterveneResponse(
      intervene: true,
      scriptBn: lines.map((l) => l.textBn).join(' '),
      scriptEn: 'He is asking for your code.',
      ui: UiMode.fullscreen,
      actions: const [holdAction],
      cooldownS: 300,
      lines: lines,
    );

    testWidgets('the bundled clip starts at once; the why plays after it', (
      tester,
    ) async {
      final o = await openOverlay(tester);
      // Before the server answers: the predicted bundled clip, nothing else.
      expect(o.audio.played, ['apa_hold_call_active']);
      expect(o.audio.spoken, isEmpty);
      expect(o.metrics.last(Metrics.holdToAudioMs), isNotNull);

      await resolve(
        tester,
        o,
        withLines(const [ApaLine(role: 'T', textBn: dynamicBn, token: 't')]),
      );
      await settleAfterResolve(tester);
      // Without Firebase or a risk api (this harness) there is no audio for
      // the line, and a warning line is never read by the phone's own engine
      // (2026-10-17): the clip stays the one voice heard and the
      // text is on screen.
      expect(o.audio.played, ['apa_hold_call_active']);
      expect(o.audio.spoken, isEmpty);
      expect(o.metrics.last(ApaVoiceSource.onDevice.metric), isNull);
    });

    testWidgets('a line that is the predicted clip\'s script is not replayed', (
      tester,
    ) async {
      final o = await openOverlay(tester);
      await resolve(
        tester,
        o,
        withLines([
          ApaLine(textBn: AssetCatalog.scripts['apa_hold_call_active']!),
          ApaLine(textBn: AssetCatalog.scripts['apa_delay_new_payee']!),
        ]),
      );
      await settleAfterResolve(tester);
      expect(o.audio.played, ['apa_hold_call_active', 'apa_delay_new_payee']);
      expect(o.audio.spoken, isEmpty);
    });

    testWidgets('speak=false: lines are not spoken either', (tester) async {
      final o = await openOverlay(tester, speak: false);
      await resolve(tester, o, withLines(const [ApaLine(textBn: dynamicBn)]));
      await settleAfterResolve(tester);
      expect(o.audio.played, isEmpty);
      expect(o.audio.spoken, isEmpty);
    });
  });

  testWidgets('an unknown action type is kept behind "আরও উপায়" with the '
      'generic label', (tester) async {
    const weird = ActionItem(type: 'teleport_funds', params: {'to': 'mars'});
    final score = holdScore(actions: const [holdAction, weird]);
    final o = await openOverlay(tester, score: score);
    // Never inline: the one filled button is the hold's own outcome.
    expect(find.byKey(const ValueKey('action_teleport_funds')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('action_more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The generic label only; the raw type is a developer string.
    final label = find.text(l10n.actionUnknown);
    expect(label, findsOneWidget);
    expect(find.byKey(const ValueKey('action_teleport_funds')), findsOneWidget);
    await tester.tap(label);
    await tester.pump(const Duration(milliseconds: 400));
    expect(o.actions, [weird]);
  });

  testWidgets('buttons: one filled primary (the hold) lowest, the trusted '
      'contact outlined above it, FNA a text link under it, the rest behind '
      '"আরও উপায়"; 56 dp', (tester) async {
    final o = await openOverlay(tester);
    await resolve(tester, o, served());
    await settleAfterResolve(tester);

    double top(String type) =>
        tester.getTopLeft(find.byKey(ValueKey('action_$type'))).dy;
    // freeze_pin_reset is the same family as the hold: collapsed by the
    // merge, so it is neither inline nor behind "আরও উপায়".
    expect(find.byKey(const ValueKey('action_freeze_pin_reset')), findsNothing);
    expect(find.byKey(const ValueKey('action_more')), findsNothing);
    expect(top('trusted_contact_check'), lessThan(top('hold_transaction')));
    expect(top('hold_transaction'), lessThan(top('ask_apa')));
    expect(
      tester.widget(find.byKey(const ValueKey('action_hold_transaction'))),
      isA<FilledButton>(),
      reason: 'the one filled button',
    );
    expect(
      tester.widget(find.byKey(const ValueKey('action_trusted_contact_check'))),
      isA<OutlinedButton>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('action_ask_apa'))),
      isA<TextButton>(),
    );
    final filled = find.descendant(
      of: find.byType(InterventionScreen),
      matching: find.byType(FilledButton),
    );
    expect(filled, findsOneWidget);

    for (final type in ['hold_transaction', 'trusted_contact_check']) {
      final size = tester.getSize(find.byKey(ValueKey('action_$type')));
      expect(size.height, greaterThanOrEqualTo(56));
    }
    expect(
      tester.getSize(find.byKey(const ValueKey('action_ask_apa'))).height,
      greaterThanOrEqualTo(48),
    );

    // The primary sits in the lower half of the screen (thumb zone).
    final screen = tester.getSize(find.byType(Scaffold).last);
    expect(top('hold_transaction'), greaterThan(screen.height / 2));
  });

  testWidgets('tapping an action forwards the item; ask Apa sends ask_apa', (
    tester,
  ) async {
    final o = await openOverlay(tester);
    await tester.tap(
      find.byKey(const ValueKey('action_trusted_contact_check')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('action_ask_apa')));
    await tester.pump();
    expect(o.actions, [trustedAction, const ActionItem(type: 'ask_apa')]);
    expect(o.dismissed, 0);
    expect(find.byType(InterventionScreen), findsOneWidget);
  });

  testWidgets(
    'the dismiss button is top-left chrome and calls onDismiss once',
    (tester) async {
      final o = await openOverlay(tester);
      final dismiss = find.byKey(const ValueKey('intervention_dismiss'));
      final pos = tester.getTopLeft(dismiss);
      final screen = tester.getSize(find.byType(Scaffold).last);
      expect(pos.dx, lessThan(screen.width / 3));
      expect(pos.dy, lessThan(screen.height / 4));

      await tester.tap(dismiss);
      await tester.pumpAndSettle();
      expect(o.dismissed, 1);
      expect(find.byType(InterventionScreen), findsNothing);
    },
  );

  testWidgets('system back calls onDismiss and pops; nothing else fires', (
    tester,
  ) async {
    final o = await openOverlay(tester);
    await systemBack(tester);
    await tester.pumpAndSettle();
    expect(o.dismissed, 1);
    expect(o.actions, isEmpty);
    expect(find.byType(InterventionScreen), findsNothing);
    expect(
      o.audio.stopCalls,
      0,
      reason: 'dismiss never clears the hold or the clip',
    );
  });

  testWidgets('speak=false plays nothing, even when the served asset differs', (
    tester,
  ) async {
    final o = await openOverlay(tester, speak: false);
    await resolve(tester, o, served(audioAssetId: 'apa_generic_caution'));
    await settleAfterResolve(tester);
    expect(o.audio.scripted, isEmpty);
    expect(o.audio.played, isEmpty);
    expect(o.audio.spoken, isEmpty);
  });

  testWidgets('records hold_to_audio_ms from the first AudioStarted', (
    tester,
  ) async {
    final arrived = DateTime.now().millisecondsSinceEpoch - 150;
    final o = await openOverlay(tester, scoreArrivedAtMs: arrived);
    await tester.pump();
    final v = o.metrics.last(Metrics.holdToAudioMs);
    expect(v, isNotNull);
    expect(v!, greaterThanOrEqualTo(150));
    expect(v, lessThan(60000));

    // A second clip does not overwrite the first measurement.
    await resolve(tester, o, served(audioAssetId: 'apa_generic_caution'));
    await settleAfterResolve(tester);
    expect(o.metrics.all[Metrics.holdToAudioMs], hasLength(1));
  });

  testWidgets(
    'a failed intervene keeps the reasons and drops the waiting line',
    (tester) async {
      final o = await openOverlay(tester);
      o.intervene.completeError(StateError('timeout'));
      await tester.pump();
      await tester.pumpAndSettle();
      final texts = visibleTexts(tester);
      expect(texts, contains(reasonScam.textBn));
      expect(texts, isNot(contains(l10n.interventionWaiting)));
      expect(find.byKey(const ValueKey('intervention_script')), findsNothing);
      expect(
        find.byKey(const ValueKey('action_hold_transaction')),
        findsOneWidget,
      );
    },
  );

  testWidgets('a null intervene keeps the reasons only', (tester) async {
    final o = await openOverlay(tester);
    await resolve(tester, o, null);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intervention_script')), findsNothing);
    expect(find.text(reasonCall.textBn), findsOneWidget);
    expect(o.audio.played, ['apa_hold_call_active']);
  });

  testWidgets('the English toggle reveals script_en small', (tester) async {
    final o = await openOverlay(tester);
    final r = served();
    await resolve(tester, o, r);
    await settleAfterResolve(tester);
    expect(find.text(r.scriptEn), findsNothing);

    await tester.tap(find.byKey(const ValueKey('intervention_english_toggle')));
    await tester.pump();
    final en = tester.widget<Text>(
      find.byKey(const ValueKey('intervention_script_other')),
    );
    expect(en.data, r.scriptEn);
    expect(en.style!.fontSize!, lessThan(22));
  });

  testWidgets('the route is a fullscreen dialog named intervention', (
    tester,
  ) async {
    await openOverlay(tester);
    final route = ModalRoute.of(
      tester.element(find.byType(InterventionScreen)),
    )!;
    expect(route.settings.name, 'intervention');
    expect((route as PageRoute<void>).fullscreenDialog, isTrue);
    expect(route.opaque, isTrue);
  });

  testWidgets('dark theme: a dark amber (held) strip with light text; actions '
      'on the surface, not a soft fill', (tester) async {
    await openOverlay(tester, brightness: Brightness.dark);
    final context = tester.element(find.byType(InterventionScreen));
    expect(Theme.of(context).brightness, Brightness.dark);
    final p = context.palette;

    // Held is amber everywhere (History, Home, Result, overlay); red is for
    // block only (consistency 2.1).
    final strip = tester.widget<Container>(
      find.byKey(const ValueKey('intervention_strip')),
    );
    expect(strip.color, p.warningContainer);
    expect(strip.color!.computeLuminance(), lessThan(0.2));
    final dismiss = tester.widget<TextButton>(
      find.byKey(const ValueKey('intervention_dismiss')),
    );
    expect(
      dismiss.style?.foregroundColor?.resolve(const <WidgetState>{}),
      p.onWarningContainer,
    );
    final askApa = tester.widget<TextButton>(
      find.byKey(const ValueKey('action_ask_apa')),
    );
    expect(
      askApa.style?.foregroundColor?.resolve(const <WidgetState>{}),
      p.primary,
    );
    // The title on the dark surface takes the dark-theme amber.
    final title = tester.widget<Text>(find.text(l10n.interventionHeldTitle));
    expect(title.style?.color, p.warning);
  });

  testWidgets('a block keeps the red strip', (tester) async {
    const score = ScoreResponse(
      decision: Decision.block,
      riskScore: 0.95,
      band: Band.critical,
      reasons: [reasonScam],
      actions: [ActionItem(type: 'block_transaction')],
      modelVersion: 'rules-v1',
    );
    await openOverlay(tester, score: score, speak: false);
    final context = tester.element(find.byType(InterventionScreen));
    final strip = tester.widget<Container>(
      find.byKey(const ValueKey('intervention_strip')),
    );
    expect(strip.color, context.palette.dangerContainer);
  });

  testWidgets('the held summary shows the amount and the payee (app chrome)', (
    tester,
  ) async {
    await openOverlay(
      tester,
      held: const HeldSummary(
        amountBdt: 5000,
        name: 'মা',
        number: '০১৯XX-XXX৮৮১',
      ),
    );
    expect(find.text(l10n.overlayHeldLabel), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('intervention_held_amount')))
          .data,
      '৳ ৫,০০০',
    );
    expect(find.text('মা-কে · ০১৯XX-XXX৮৮১'), findsOneWidget);
    // Above Apa's title.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('intervention_held'))).dy,
      lessThan(tester.getTopLeft(find.text(l10n.interventionHeldTitle)).dy),
    );
  });

  testWidgets('every server action beyond the primary and the trusted '
      'contact waits behind "আরও উপায়"', (tester) async {
    const stepUp = ActionItem(type: 'step_up_verification');
    const block = ActionItem(type: 'block_transaction');
    final score = holdScore(
      actions: const [holdAction, freezeAction, stepUp, block, trustedAction],
    );
    final o = await openOverlay(tester, score: score);
    expect(
      find.byKey(const ValueKey('action_hold_transaction')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('action_more')), findsOneWidget);
    expect(find.byKey(const ValueKey('action_freeze_pin_reset')), findsNothing);
    expect(
      find.byKey(const ValueKey('action_block_transaction')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsOneWidget,
    );
    // more + trusted (outlined) + hold (filled) = 3 buttons, plus the text
    // link: never more than three buttons on a hold.
    final buttons = find.descendant(
      of: find.byType(InterventionScreen),
      matching: find.byWidgetPredicate(
        (w) => w is FilledButton || w is OutlinedButton,
      ),
    );
    expect(buttons, findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('action_more')));
    // The waiting spinner never settles: pump through the sheet's entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('action_block_transaction')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(o.actions, [block]);
  });

  testWidgets('a sent trusted-contact request replaces the button in place', (
    tester,
  ) async {
    final sent = ValueNotifier(false);
    addTearDown(sent.dispose);
    await openOverlay(tester, trustedSent: sent);
    final slot = tester.getTopLeft(
      find.byKey(const ValueKey('action_trusted_contact_check')),
    );
    sent.value = true;
    await tester.pump();
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsNothing,
    );
    final line = find.byKey(const ValueKey('trusted_request_sent'));
    expect(line, findsOneWidget);
    expect(find.text(l10n.trustedRequestSentLine), findsOneWidget);
    expect(tester.getTopLeft(line).dy, closeTo(slot.dy, 1));
    expect(tester.getSize(line).height, greaterThanOrEqualTo(56));
  });
}
