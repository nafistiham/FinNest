import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/audio/apa_audio.dart';
import 'package:bhorosha/core/haptics.dart';
import 'package:bhorosha/data/contracts/score.dart';
import 'package:bhorosha/features/intervention/logic/action_labels.dart';
import 'package:bhorosha/features/intervention/ui/intervention_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intervention_fakes.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  testWidgets('renders reasons before intervene and script_bn after', (
    tester,
  ) async {
    final actions = <ActionItem>[];
    var dismissed = 0;
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: InterventionBanner(
            score: delayScore,
            intervene: null,
            actions: delayScore.actions,
            onAction: actions.add,
            onDismiss: () => dismissed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final texts = visibleTexts(tester);
    expect(texts, contains(delayScore.reasons.single.textBn));
    expect(texts, contains(l10n.interventionDelayTitle));
    final allowed = {
      delayScore.reasons.single.textBn,
      l10n.interventionDelayTitle,
      l10n.interventionDismiss,
      l10n.apaInitial,
      for (final a in delayScore.actions) ActionLabels.labelFor(l10n, a),
    };
    expect(texts.difference(allowed), isEmpty);
    expect(find.text('৬০ মিনিট পরে পাঠান'), findsOneWidget);

    // Trusted contact is the lowest button.
    final delayY = tester
        .getTopLeft(find.byKey(const ValueKey('action_delay_new_payee')))
        .dy;
    final trustedY = tester
        .getTopLeft(find.byKey(const ValueKey('action_trusted_contact_check')))
        .dy;
    expect(delayY, lessThan(trustedY));

    await tester.tap(
      find.byKey(const ValueKey('action_trusted_contact_check')),
    );
    await tester.tap(find.byKey(const ValueKey('banner_dismiss')));
    await tester.pump();
    expect(actions, [trustedAction]);
    expect(dismissed, 1);

    final r = served(
      audioAssetId: 'apa_delay_new_payee',
      scriptBn: 'এক ঘণ্টা পরে পাঠানো যাবে।',
    );
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: InterventionBanner(
            score: delayScore,
            intervene: r,
            actions: delayScore.actions,
            onAction: actions.add,
            onDismiss: () => dismissed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('banner_script')), findsOneWidget);
    expect(find.text(r.scriptBn), findsOneWidget);
    expect(find.text(delayScore.reasons.single.textBn), findsNothing);
  });

  testWidgets('showInterventionBanner floats at the bottom and closes', (
    tester,
  ) async {
    var dismissed = 0;
    late VoidCallback close;
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () => close = showInterventionBanner(
                  context,
                  score: delayScore,
                  intervene: null,
                  actions: delayScore.actions,
                  onAction: (_) {},
                  onDismiss: () => dismissed++,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    final banner = find.byKey(const ValueKey('intervention_banner'));
    expect(banner, findsOneWidget);
    final screen = tester.getSize(find.byType(Scaffold));
    expect(tester.getBottomLeft(banner).dy, greaterThan(screen.height / 2));
    expect(
      find.byKey(const ValueKey('open')),
      findsOneWidget,
      reason: 'the screen underneath stays put',
    );

    await tester.tap(find.byKey(const ValueKey('banner_dismiss')));
    await tester.pumpAndSettle();
    expect(dismissed, 1);
    expect(banner, findsNothing);

    // Closing twice is harmless.
    close();
    await tester.pump();
    expect(banner, findsNothing);
  });

  testWidgets(
    'dark theme: light text on the dark warning container, 4 dp stripe; '
    'a sent request shows the line',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          brightness: Brightness.dark,
          Scaffold(
            body: InterventionBanner(
              score: delayScore,
              intervene: null,
              actions: delayScore.actions,
              trustedSent: true,
              onAction: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final p = tester.element(find.byType(InterventionBanner)).palette;
      expect(p.isDark, isTrue);
      final card = tester.widget<Container>(
        find.byKey(const ValueKey('intervention_banner')),
      );
      final deco = card.decoration! as BoxDecoration;
      expect(deco.color, p.warningContainer);
      expect(deco.color!.computeLuminance(), lessThan(0.2));
      expect((deco.border! as Border).left.width, BhSize.stripe);
      final dismiss = tester.widget<TextButton>(
        find.byKey(const ValueKey('banner_dismiss')),
      );
      expect(
        dismiss.style?.foregroundColor?.resolve(const <WidgetState>{}),
        p.onWarningContainer,
      );
      expect(
        tester
            .widget<Text>(find.text(l10n.interventionDelayTitle))
            .style
            ?.color,
        p.onWarningContainer,
      );
      expect(
        find.byKey(const ValueKey('action_trusted_contact_check')),
        findsNothing,
      );
      expect(find.text(l10n.trustedRequestSentLine), findsOneWidget);
    },
  );

  group('M3: the delay banner from the stored record', () {
    const recordReasons = [
      Reason(
        code: 'NEW_PAYEE_ABOVE_P95',
        weight: 0.5,
        textBn: 'রেকর্ডের কারণ।',
        textEn: 'The record\'s reason.',
      ),
    ];

    testWidgets('shows the stored script above everything, locale-aware', (
      tester,
    ) async {
      for (final (locale, script) in [
        (const Locale('bn'), 'এক ঘণ্টা পরে পাঠানো যাবে।'),
        (const Locale('en'), 'You can send it in an hour.'),
      ]) {
        await tester.pumpWidget(
          localizedApp(
            locale: locale,
            Scaffold(
              body: InterventionBanner(
                score: delayScore,
                intervene: null,
                // The caller picks the language (record.script(context)).
                script: script,
                reasons: recordReasons,
                actions: delayScore.actions,
                onAction: (_) {},
                onDismiss: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('banner_script')), findsOneWidget);
        expect(find.text(script), findsOneWidget);
        expect(find.text(recordReasons.single.textBn), findsNothing);
        expect(find.text(delayScore.reasons.single.textBn), findsNothing);
      }
    });

    testWidgets('without a script shows the record\'s reasons, not the '
        'score\'s', (tester) async {
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: InterventionBanner(
              score: delayScore,
              intervene: null,
              script: '',
              reasons: recordReasons,
              actions: delayScore.actions,
              onAction: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(recordReasons.single.textBn), findsOneWidget);
      expect(find.text(delayScore.reasons.single.textBn), findsNothing);
    });

    testWidgets('queues the served clip once when it differs from the '
        'predicted one, and fires the warning haptic', (tester) async {
      final audio = FakeApaAudio();
      final haptics = RecordingHaptics();
      Widget banner({required String? served}) => localizedApp(
        overrides: [apaAudioProvider.overrideWithValue(audio)],
        Scaffold(
          body: InterventionBanner(
            score: delayScore,
            intervene: null,
            script: 'এক ঘণ্টা পরে পাঠানো যাবে।',
            servedClip: (
              assetId: served,
              scriptBn: 'এক ঘণ্টা পরে পাঠানো যাবে।',
            ),
            predictedAsset: 'apa_generic_caution',
            actions: delayScore.actions,
            onAction: (_) {},
            onDismiss: () {},
            haptics: haptics,
          ),
        ),
      );
      await tester.pumpWidget(banner(served: 'apa_delay_new_payee'));
      await tester.pumpAndSettle();
      expect(audio.played, ['apa_delay_new_payee']);
      expect(haptics.warnings, 1);
      // A rebuild (trustedSent flips, a tick) never replays it.
      await tester.pumpWidget(banner(served: 'apa_delay_new_payee'));
      await tester.pumpAndSettle();
      expect(audio.played, ['apa_delay_new_payee']);
      expect(haptics.warnings, 1);
    });

    testWidgets('the same served clip, or none, plays nothing more', (
      tester,
    ) async {
      final audio = FakeApaAudio();
      for (final served in <String?>['apa_generic_caution', null]) {
        await tester.pumpWidget(
          localizedApp(
            overrides: [apaAudioProvider.overrideWithValue(audio)],
            Scaffold(
              body: InterventionBanner(
                key: ValueKey(served),
                score: delayScore,
                intervene: null,
                servedClip: (assetId: served, scriptBn: 'x'),
                predictedAsset: 'apa_generic_caution',
                actions: delayScore.actions,
                onAction: (_) {},
                onDismiss: () {},
                haptics: const NoHaptics(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(audio.played, isEmpty);
      expect(audio.spoken, isEmpty);
    });

    testWidgets('an unknown served clip with no Gemini stays unspoken', (
      tester,
    ) async {
      final audio = FakeApaAudio();
      await tester.pumpWidget(
        localizedApp(
          overrides: [apaAudioProvider.overrideWithValue(audio)],
          Scaffold(
            body: InterventionBanner(
              score: delayScore,
              intervene: null,
              servedClip: (assetId: 'apa_future_clip', scriptBn: 'নতুন লাইন।'),
              predictedAsset: 'apa_generic_caution',
              actions: delayScore.actions,
              onAction: (_) {},
              onDismiss: () {},
              haptics: const NoHaptics(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // No clip for the text and no Gemini in tests: nothing, never the
      // phone's own voice (the predicted clip played from the PIN pad).
      expect(audio.played, isEmpty);
      expect(audio.spoken, isEmpty);
    });

    testWidgets('trustedBusy disables the trusted-contact button', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: InterventionBanner(
              score: delayScore,
              intervene: null,
              actions: delayScore.actions,
              trustedBusy: true,
              onAction: (_) {},
              onDismiss: () {},
              haptics: const NoHaptics(),
            ),
          ),
        ),
      );
      await tester.pump();
      final trusted = find.byKey(
        const ValueKey('action_trusted_contact_check'),
      );
      expect(tester.widget<FilledButton>(trusted).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('action_trusted_contact_check_busy')),
        findsOneWidget,
      );
      final delay = find.byKey(const ValueKey('action_delay_new_payee'));
      expect(tester.widget<FilledButton>(delay).onPressed, isNotNull);
    });
  });
}
