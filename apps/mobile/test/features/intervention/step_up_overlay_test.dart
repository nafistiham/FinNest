import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/contracts/common.dart';
import 'package:bhorosha/data/contracts/intervene.dart';
import 'package:bhorosha/data/contracts/score.dart';
import 'package:bhorosha/features/intervention/logic/action_labels.dart';
import 'package:bhorosha/features/intervention/logic/metrics_log.dart';
import 'package:bhorosha/features/intervention/ui/intervention_overlay.dart';
import 'package:bhorosha/features/intervention/ui/intervention_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadBanglaFont;
import 'intervention_fakes.dart';

const mismatch = Reason(
  code: 'ATO_BEHAVIOUR_MISMATCH',
  weight: 1,
  textBn: 'নিরাপত্তার জন্য একবার আপনার পরিচয় নিশ্চিত করতে চাই। এটি একটি যাচাই, কোনো অভিযোগ নয়।',
  textEn: 'For your safety we want to confirm it is you. This is a check.',
);

const riskyApp = Reason(
  code: 'APP_SAFETY_BLOCK',
  weight: 0.95,
  textBn: 'আপনার ফোনে একটি ঝুঁকিপূর্ণ অ্যাপ আছে।',
  textEn: 'A risky app is on your phone.',
);

ScoreResponse behaviourHold() => const ScoreResponse(
  decision: Decision.hold,
  riskScore: 1,
  band: Band.critical,
  reasons: [mismatch],
  actions: [holdAction, trustedAction],
  modelVersion: 'rules-v1',
  signalSources: SignalSources(),
);

const stepUpAction = ActionItem(type: ActionLabels.biometricStepUp);

/// Pumps the overlay body directly; [offer] adds the client step-up action
/// as the PIN pad does when the policy offers it.
Future<List<ActionItem>> pumpOverlay(
  WidgetTester tester, {
  ScoreResponse? score,
  bool offer = false,
  ValueNotifier<bool>? stepUpFailed,
  String? simulatedTag,
  double textScale = 1,
  Size size = const Size(1080, 2400),
  double dpr = 2.625,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  final s = score ?? behaviourHold();
  final tapped = <ActionItem>[];
  await tester.pumpWidget(
    localizedApp(
      overrides: [
        apaAudioProvider.overrideWithValue(FakeApaAudio()),
        metricsLogProvider.overrideWithValue(MetricsLog()),
      ],
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: InterventionScreen(
            score: s,
            trigger: 'behaviour_mismatch',
            predictedAsset: 'apa_generic_caution',
            intervene: Future<InterveneResponse?>.value(),
            actions: (_) => [...s.actions, if (offer) stepUpAction],
            onAction: tapped.add,
            onDismiss: () {},
            speak: false,
            scoreArrivedAtMs: 0,
            stepUpFailed: stepUpFailed,
            simulatedTag: simulatedTag,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tapped;
}

Finder get stepUpButton =>
    find.byKey(const ValueKey('action_${ActionLabels.biometricStepUp}'));

void main() {
  // The real SolaimanLipi metrics: the 1.4x check measures the real label.
  setUpAll(loadBanglaFont);

  testWidgets('no step-up action unless offered', (tester) async {
    await pumpOverlay(tester);
    expect(stepUpButton, findsNothing);
    expect(find.text('এটা আপনিই?'), findsNothing);
    expect(find.text('হ্যাঁ, আঙুলের ছাপ দিয়ে নিশ্চিত করুন'), findsNothing);
  });

  testWidgets('offered: outlined under "এটা আপনিই?", above the filled '
      'primary; the trusted contact waits behind it', (tester) async {
    final tapped = await pumpOverlay(tester, offer: true);
    expect(stepUpButton, findsOneWidget);
    expect(
      find.descendant(of: stepUpButton, matching: find.byType(FilledButton)),
      findsNothing,
    );
    expect(tester.widget(stepUpButton), isA<OutlinedButton>());
    expect(find.text('হ্যাঁ, আঙুলের ছাপ দিয়ে নিশ্চিত করুন'), findsOneWidget);
    final chrome = tester.getRect(find.text('এটা আপনিই?'));
    final button = tester.getRect(stepUpButton);
    final primary = tester.getRect(
      find.byKey(const ValueKey('action_hold_transaction')),
    );
    expect(chrome.bottom, lessThanOrEqualTo(button.top));
    expect(button.bottom, lessThanOrEqualTo(primary.top));
    expect(button.height, greaterThanOrEqualTo(56));
    expect(
      tester.widget(find.byKey(const ValueKey('action_hold_transaction'))),
      isA<FilledButton>(),
      reason: 'the one filled button is the outcome the server chose',
    );
    // One question at a time: the trusted contact appears when the
    // fingerprint fails (the fail line names it), not beside it.
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsNothing,
    );

    await tester.tap(stepUpButton);
    await tester.pump();
    expect(tapped.map((a) => a.type), [ActionLabels.biometricStepUp]);
  });

  testWidgets('a failed step-up swaps the button for the fail line; the '
      'trusted contact stays', (tester) async {
    final failed = ValueNotifier(false);
    await pumpOverlay(tester, offer: true, stepUpFailed: failed);
    failed.value = true;
    await tester.pump();
    expect(stepUpButton, findsNothing);
    expect(find.byType(StepUpFailedLine), findsOneWidget);
    expect(find.text('যাচাই হয়নি। আপনজনের মত নিন।'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsOneWidget,
    );
  });

  testWidgets('simulated: one warning tag with the mode, no second note', (
    tester,
  ) async {
    await pumpOverlay(tester, simulatedTag: 'সিমুলেটেড: অন্য কারও হাতের ধরন');
    final tag = find.byKey(const ValueKey('intervention_simulated'));
    expect(tag, findsOneWidget);
    expect(tester.widget<StatusTag>(tag).status, BhStatus.warning);
    expect(find.text('সিমুলেটেড: অন্য কারও হাতের ধরন'), findsOneWidget);
    expect(find.text('সিমুলেটেড'), findsNothing);
  });

  testWidgets('1.4x text at 360 dp: the step-up label is whole and nothing '
      'overflows', (tester) async {
    // 360 x 780 dp at 3x.
    await pumpOverlay(
      tester,
      offer: true,
      textScale: 1.4,
      size: const Size(1080, 2340),
      dpr: 3,
    );
    expect(tester.takeException(), isNull);
    final label = find.descendant(
      of: stepUpButton,
      matching: find.text('হ্যাঁ, আঙুলের ছাপ দিয়ে নিশ্চিত করুন'),
    );
    expect(label, findsOneWidget);
    final painter = tester.renderObject<RenderParagraph>(label);
    expect(painter.didExceedMaxLines, isFalse);
    expect(
      tester.getRect(label).bottom,
      lessThanOrEqualTo(tester.getRect(stepUpButton).bottom),
    );
  });

  for (final (name, reasons) in [
    ('risky app', const [riskyApp, reasonCall]),
    ('call active', const [reasonCall, reasonScam]),
  ]) {
    testWidgets('$name hold: the first reason line is the server\'s first '
        'reason, no step-up', (tester) async {
      await pumpOverlay(
        tester,
        score: ScoreResponse(
          decision: Decision.hold,
          riskScore: 0.9,
          band: Band.critical,
          reasons: reasons,
          actions: const [holdAction, trustedAction],
          modelVersion: 'rules-v1',
        ),
      );
      final lines = tester.widgetList<ReasonLine>(find.byType(ReasonLine));
      expect(lines.first.text, reasons.first.textBn);
      expect(stepUpButton, findsNothing);
    });
  }
}
