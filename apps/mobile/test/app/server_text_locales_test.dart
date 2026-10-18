/// Server copy follows the app language (FR-3 still holds: only server fields
/// render, the app just picks `*_en` in English and `*_bn` in Bangla). Every
/// fixture carries distinct Bangla and English strings, so finding one and
/// not the other is unambiguous.
library;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';
import 'package:bhorosha/features/approve/ui/approve_screen.dart';
import 'package:bhorosha/features/intervention/logic/metrics_log.dart';
import 'package:bhorosha/features/intervention/ui/intervention_overlay.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/safety/ui/safety_screen.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_badge.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/approve/approve_test_support.dart' as approve;
import '../features/intervention/intervention_fakes.dart';
import '../features/safety/safety_test_support.dart';
import 'screen_harness.dart' show ScreenHarness, pumpApp;

/// The string for [locale] and the one that must not show.
({String shown, String hidden}) pick(Locale locale, String bn, String en) =>
    locale.languageCode == 'en'
    ? (shown: en, hidden: bn)
    : (shown: bn, hidden: en);

void expectLine(Locale locale, String bn, String en) {
  final p = pick(locale, bn, en);
  expect(find.text(p.shown), findsOneWidget, reason: '"${p.shown}"');
  expect(find.text(p.hidden), findsNothing, reason: '"${p.hidden}"');
}

void main() {
  for (final locale in LocaleNotifier.supported) {
    final lang = locale.languageCode;
    final english = lang == 'en';

    group('in $lang', () {
      testWidgets('safety badge shows user_message_$lang', (tester) async {
        final h = SafetyHarness(response: blockResponse);
        final c = await pumpSafety(
          tester,
          harness: h,
          locale: locale,
          child: const Scaffold(body: SafetyBadge()),
        );
        await c.read(safetyControllerProvider.notifier).refresh();
        await tester.pumpAndSettle();

        expect(find.text(english ? 'Unsafe' : 'ঝুঁকিপূর্ণ'), findsOneWidget);
        expectLine(
          locale,
          blockResponse.userMessageBn,
          blockResponse.userMessageEn,
        );
      });

      testWidgets('safety screen: message, finding titles and explanations', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.reset);
        final h = SafetyHarness(response: blockResponse);
        await pumpSafety(
          tester,
          harness: h,
          locale: locale,
          child: const SafetyScreen(blocked: false),
        );
        await tester.pumpAndSettle();

        expectLine(
          locale,
          blockResponse.userMessageBn,
          blockResponse.userMessageEn,
        );
        expectLine(locale, blockFinding.titleBn, blockFinding.titleEn);
        expectLine(
          locale,
          blockFinding.explanationBn,
          blockFinding.explanationEn,
        );
        expectLine(
          locale,
          mediumFinding.explanationBn,
          mediumFinding.explanationEn,
        );
      });

      testWidgets('intervention overlay: script, reasons and the toggle', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        final audio = FakeApaAudio();
        final score = holdScore();
        // An asset the client does not bundle, so the fallback speaks it.
        final r = served(audioAssetId: 'apa_future_clip');
        await tester.pumpWidget(
          localizedApp(
            locale: locale,
            overrides: [
              apaAudioProvider.overrideWithValue(audio),
              metricsLogProvider.overrideWithValue(MetricsLog()),
            ],
            InterventionScreen(
              score: score,
              trigger: 'call_active',
              predictedAsset: 'apa_hold_call_active',
              intervene: Future.value(r),
              actions: (_) => score.actions,
              onAction: (_) {},
              onDismiss: () {},
              speak: true,
              scoreArrivedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        final script = tester.widget<Text>(
          find.byKey(const ValueKey('intervention_script')),
        );
        expect(script.data, english ? r.scriptEn : r.scriptBn);
        expectLine(locale, reasonScam.textBn, reasonScam.textEn);
        expectLine(locale, reasonCall.textBn, reasonCall.textEn);

        // The toggle reveals the other language, so both stay reachable.
        final toggle = find.byKey(
          const ValueKey('intervention_english_toggle'),
        );
        expect(
          find.descendant(
            of: toggle,
            matching: find.text(english ? 'Show Bangla' : 'English'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('intervention_script_other')),
          findsNothing,
        );
        await tester.tap(toggle);
        await tester.pump();
        final other = tester.widget<Text>(
          find.byKey(const ValueKey('intervention_script_other')),
        );
        expect(other.data, english ? r.scriptBn : r.scriptEn);

        // Audio is the Bangla line in both languages (no English audio).
        expect(audio.played, ['apa_hold_call_active']);
        // A warning line is never spoken by the phone's own engine.
        expect(audio.spoken, isEmpty);
      });

      testWidgets('result (held): server reasons', (tester) async {
        await pumpApp(
          tester,
          harness: ScreenHarness(),
          location: '${Routes.result}?state=held',
          extraOverrides: [
            initialLocaleProvider.overrideWithValue(locale),
            lastScoreProvider.overrideWith((_) => holdScore()),
          ],
        );
        expectLine(locale, reasonScam.textBn, reasonScam.textEn);
        expectLine(locale, reasonCall.textBn, reasonCall.textEn);
      });

      testWidgets('approve: script and reasons', (tester) async {
        final h = approve.ApproveHarness();
        await tester.runAsync(h.warm);
        addTearDown(h.dispose);
        const scriptEn =
            'This is your FinNest Assistant. Pause and check first.';
        await h.ledger.create('rina', approve.heldTxn());
        await h.interventions.upsert(
          approve.openRecord(
            status: InterventionStatus.pending,
            requestId: 'req_1',
            expiresAt: approve.t0.add(const Duration(minutes: 10)),
            scriptEn: scriptEn,
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              trustedContactFlowProvider.overrideWithValue(h.flow),
              approveClockProvider.overrideWithValue(h.clock),
              ledgerRepoProvider.overrideWithValue(h.ledger),
              interventionRepoProvider.overrideWithValue(h.interventions),
            ],
            child: MaterialApp(
              locale: locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: buildTheme(Brightness.light),
              home: const ApproveScreen(requestId: 'req_1'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expectLine(
          locale,
          approve.reasonCall.textBn,
          approve.reasonCall.textEn,
        );
        expectLine(
          locale,
          approve.reasonNewPayee.textBn,
          approve.reasonNewPayee.textEn,
        );
        expectLine(
          locale,
          'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন, আগে যাচাই করে নিন।',
          scriptEn,
        );
        // Cancel the countdown ticker before the pending-timer check.
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  }

  test('the default app language is Bangla', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(localeProvider), LocaleNotifier.bangla);
  });
}
