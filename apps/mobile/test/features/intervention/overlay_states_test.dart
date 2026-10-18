// One state per overlay, the simulated tag
// under the amount line, and reason bullets coloured by kind.
import 'package:bhorosha/app/l10n.dart';
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
import 'package:flutter_test/flutter_test.dart';

import 'intervention_fakes.dart';

const _identity = Reason(
  code: 'ATO_BEHAVIOUR_MISMATCH',
  weight: 0.6,
  textBn: 'নিরাপত্তার জন্য একবার আপনার পরিচয় নিশ্চিত করতে চাই।',
  textEn: 'For your safety we want to confirm it is you.',
);

const _appSafety = Reason(
  code: 'APP_SAFETY_BLOCK',
  weight: 0.95,
  textBn: 'আপনার ফোনে একটি ঝুঁকিপূর্ণ অ্যাপ আছে।',
  textEn: 'A risky app is on your phone.',
);

const _held = HeldSummary(amountBdt: 500, name: 'মা', number: '০১৯XX-XXX৮৮১');

class _Pumped {
  final tapped = <ActionItem>[];
  int dismissed = 0;
}

Future<_Pumped> _pump(
  WidgetTester tester,
  ScoreResponse score, {
  List<ActionItem>? actions,
  String? simulatedTag,
  HeldSummary? held = _held,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final out = _Pumped();
  await tester.pumpWidget(
    localizedApp(
      overrides: [
        apaAudioProvider.overrideWithValue(FakeApaAudio()),
        metricsLogProvider.overrideWithValue(MetricsLog()),
      ],
      InterventionScreen(
        score: score,
        trigger: 'x',
        predictedAsset: 'apa_generic_caution',
        intervene: Future<InterveneResponse?>.value(),
        actions: (_) => actions ?? score.actions,
        onAction: out.tapped.add,
        onDismiss: () => out.dismissed++,
        speak: false,
        scoreArrivedAtMs: 0,
        simulatedTag: simulatedTag,
        held: held,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return out;
}

Color _bullet(WidgetTester tester, String code) => tester
    .widget<ReasonLine>(find.byKey(ValueKey('intervention_reason_$code')))
    .color;

BhPalette _palette(WidgetTester tester) =>
    tester.element(find.byType(InterventionScreen)).palette;

void main() {
  late AppLocalizations l10n;
  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  testWidgets('a block reads "আটকানো হয়েছে", keeps the decision title and '
      'offers "ঠিক আছে" instead of a cancel', (tester) async {
    final o = await _pump(
      tester,
      const ScoreResponse(
        decision: Decision.block,
        riskScore: 0.99,
        band: Band.critical,
        reasons: [reasonScam],
        actions: [
          ActionItem(type: ActionLabels.blockTransaction),
          trustedAction,
        ],
        modelVersion: 'fake',
      ),
    );
    expect(find.text('আটকানো হয়েছে'), findsOneWidget);
    expect(find.text(l10n.overlayHeldLabel), findsNothing);
    expect(find.text(l10n.interventionBlockedTitle), findsOneWidget);
    expect(find.text(l10n.actionBlock), findsNothing);
    expect(
      find.byKey(const ValueKey('action_block_transaction')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsNothing,
    );
    final ok = find.byKey(const ValueKey('action_acknowledge'));
    expect(find.descendant(of: ok, matching: find.text('ঠিক আছে')), findsOne);
    // The money line under the amount, with no row behind it yet.
    expect(find.text('টাকা পাঠানো হয়নি, আপনার কাছেই আছে।'), findsOneWidget);

    await tester.tap(ok);
    await tester.pump();
    expect(o.dismissed, 1, reason: '"ঠিক আছে" is the dismiss');
    expect(o.tapped, isEmpty);
  });

  testWidgets('a hold led by the app-safety reason is shown as a block', (
    tester,
  ) async {
    await _pump(
      tester,
      const ScoreResponse(
        decision: Decision.hold,
        riskScore: 0.95,
        band: Band.critical,
        reasons: [_appSafety, _identity],
        actions: [holdAction, trustedAction],
        modelVersion: 'fake',
      ),
    );
    expect(find.text('আটকানো হয়েছে'), findsOneWidget);
    expect(find.byKey(const ValueKey('action_acknowledge')), findsOneWidget);
    final p = _palette(tester);
    // Finding 3: the app-safety bullet is red, the identity bullet amber.
    expect(_bullet(tester, 'APP_SAFETY_BLOCK'), p.statusFill(BhStatus.danger));
    expect(
      _bullet(tester, 'ATO_BEHAVIOUR_MISMATCH'),
      p.statusFill(BhStatus.warning),
    );
  });

  testWidgets('a hold keeps "আটকে রাখা হয়েছে", its actions, the money line '
      'and amber bullets for every kind', (tester) async {
    await _pump(tester, holdScore());
    expect(find.text(l10n.overlayHeldLabel), findsOneWidget);
    expect(find.text('আটকানো হয়েছে'), findsNothing);
    expect(find.text(l10n.interventionHeldTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('action_acknowledge')), findsNothing);
    expect(
      find.byKey(const ValueKey('action_hold_transaction')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('action_trusted_contact_check')),
      findsOneWidget,
    );
    expect(find.text('টাকা পাঠানো হয়নি, আপনার কাছেই আছে।'), findsOneWidget);
    final amber = _palette(tester).statusFill(BhStatus.warning);
    expect(_bullet(tester, 'SCAM_CONVERSATION'), amber);
    expect(_bullet(tester, 'CALL_ACTIVE_NON_CONTACT'), amber);
  });

  testWidgets('an identity hold without the biometric offer keeps '
      '"আপনজনের মত নিন" even when the server sent no trusted action', (
    tester,
  ) async {
    final o = await _pump(
      tester,
      const ScoreResponse(
        decision: Decision.hold,
        riskScore: 1,
        band: Band.critical,
        reasons: [_identity],
        actions: [holdAction],
        modelVersion: 'fake',
      ),
    );
    final trusted = find.byKey(const ValueKey('action_trusted_contact_check'));
    expect(trusted, findsOneWidget);
    expect(
      find.descendant(of: trusted, matching: find.text('আপনজনের মত নিন')),
      findsOneWidget,
      reason: 'no invented minutes',
    );
    await tester.tap(trusted);
    await tester.pump();
    expect(o.tapped.single.type, ActionLabels.trustedContactCheck);
  });

  testWidgets('the simulated tag sits under the amount line, in amber', (
    tester,
  ) async {
    await _pump(
      tester,
      holdScore(),
      simulatedTag: 'সিমুলেটেড: অন্য কারও হাতের ধরন',
    );
    final tag = find.byKey(const ValueKey('intervention_simulated'));
    expect(tester.widget<StatusTag>(tag).status, BhStatus.warning);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('intervention_held')),
        matching: tag,
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(tag).dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey('intervention_held_amount')),
            )
            .dy,
      ),
    );
    expect(
      tester.getBottomLeft(tag).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('intervention_title'))).dy,
      ),
    );
  });
}
