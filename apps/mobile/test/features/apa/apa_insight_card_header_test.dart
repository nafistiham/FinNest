// The danger card on the owner's phone opened with "ফোনের নিরাপত্তা ·
// নিরাপদ" and a green tick above "বিপদ" (ux-review 2b P1); with a pending
// intervention the held message was said three times (2c).
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_insight_card.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_status_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadAppFonts;
import 'apa_test_doubles.dart';

Widget _app(
  ApaHarness h,
  ApaContextSnapshot snapshot, {
  String locale = 'bn',
  bool withoutHeld = false,
}) => ProviderScope(
  overrides: [
    ...h.overrides,
    initialLocaleProvider.overrideWithValue(Locale(locale)),
    apaTipSeedProvider.overrideWithValue(0),
    apaSnapshotProvider.overrideWithValue(snapshot),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, locale: Locale(locale)),
    locale: Locale(locale),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
        child: Column(
          children: [
            ApaInsightCard(key: const Key('card'), withoutHeld: withoutHeld),
          ],
        ),
      ),
    ),
  ),
);

/// Phone verdict SAFE, but a scam call was found: a danger card.
const _dangerSafePhone = ApaContextSnapshot(
  verdict: SafetyVerdict.safe,
  evidenceQuote: 'এখনই কোডটা বলুন',
);

/// Phone verdict SAFE, SIM changed: a caution card.
const _cautionSafePhone = ApaContextSnapshot(
  verdict: SafetyVerdict.safe,
  simSwap: true,
);

void _useViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(412 * 3, 915 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

String _plain(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  return w is Text ? (w.data ?? w.textSpan!.toPlainText()) : '';
}

void main() {
  setUpAll(loadAppFonts);

  for (final (name, snapshot, word, icon, status) in [
    (
      'danger',
      _dangerSafePhone,
      'বিপদ',
      Icons.remove_moderator_outlined,
      BhStatus.danger,
    ),
    (
      'caution',
      _cautionSafePhone,
      'সাবধান',
      Icons.warning_amber_rounded,
      BhStatus.warning,
    ),
  ]) {
    testWidgets('$name card with a safe phone: the header leads with "এফএনএ: '
        '$word", no green নিরাপদ in it; the verdict moves to a caption', (
      tester,
    ) async {
      _useViewport(tester);
      await tester.pumpWidget(_app(ApaHarness(), snapshot));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final header = find.byKey(const Key('apa_insight_severity_header'));
      expect(header, findsOneWidget);
      expect(find.byKey(const Key('apa_insight_status_row')), findsNothing);
      final headerText = _plain(tester, const Key('apa_insight_header_text'));
      expect(headerText, 'এফএনএ: $word');
      expect(headerText, isNot(contains('নিরাপদ')));
      expect(
        find.descendant(of: header, matching: find.textContaining('নিরাপদ')),
        findsNothing,
      );
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.verified_user)),
        findsNothing,
      );
      final p = tester.element(header).palette;
      final headerIcon = tester.widget<Icon>(
        find.byKey(const Key('apa_insight_header_icon')),
      );
      expect(headerIcon.icon, icon);
      expect(headerIcon.color, p.statusText(status));
      // Nothing in the header is painted green.
      for (final t in tester.widgetList<Text>(
        find.descendant(of: header, matching: find.byType(Text)),
      )) {
        expect(t.style?.color, isNot(p.statusText(BhStatus.success)));
      }

      // The phone fact stays visible, one line, green on the word only.
      final caption = tester.widget<Text>(
        find.byKey(const Key('apa_insight_phone_caption')),
      );
      final span = caption.textSpan! as TextSpan;
      expect(span.toPlainText(), 'ফোনের নিরাপত্তা: নিরাপদ');
      expect(caption.maxLines, 1);
      final verdictSpan = span.children![1] as TextSpan;
      expect(verdictSpan.text, 'নিরাপদ');
      expect(verdictSpan.style?.color, p.statusText(BhStatus.success));
      expect(
        (span.children![0] as TextSpan).style?.color,
        isNot(p.statusText(BhStatus.success)),
      );
    });
  }

  testWidgets('English danger header reads "FNA: Danger"', (tester) async {
    _useViewport(tester);
    await tester.pumpWidget(_app(ApaHarness(), _dangerSafePhone, locale: 'en'));
    await tester.pumpAndSettle();
    expect(_plain(tester, const Key('apa_insight_header_text')), 'FNA: Danger');
    expect(
      (tester
              .widget<Text>(find.byKey(const Key('apa_insight_phone_caption')))
              .textSpan!)
          .toPlainText(),
      'Phone safety: Safe',
    );
  });

  testWidgets('calm card is unchanged: the phone-safety row heads it, no '
      'severity header, no caption', (tester) async {
    _useViewport(tester);
    await tester.pumpWidget(
      _app(ApaHarness(), const ApaContextSnapshot(verdict: SafetyVerdict.safe)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apa_insight_card_all_clear')), findsOneWidget);
    expect(find.byKey(const Key('apa_insight_status_row')), findsOneWidget);
    expect(find.byKey(SafetyStatusRow.prefixKey), findsOneWidget);
    expect(find.byKey(const Key('apa_insight_severity_header')), findsNothing);
    expect(find.byKey(const Key('apa_insight_phone_caption')), findsNothing);
  });

  group('pending intervention on screen', () {
    const held = ApaContextSnapshot(
      verdict: SafetyVerdict.safe,
      held: [ApaHeldItem(txnId: 't1')],
      simSwap: true,
    );
    const heldOnCall = ApaContextSnapshot(
      verdict: SafetyVerdict.safe,
      held: [ApaHeldItem(txnId: 't1')],
      callActive: true,
    );

    testWidgets('without the pending card the held insight leads', (
      tester,
    ) async {
      _useViewport(tester);
      await tester.pumpWidget(_app(ApaHarness(), held));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('apa_insight_card_held_transfer')),
        findsOneWidget,
      );
    });

    testWidgets('with it the card skips held_transfer and shows the next '
        'insight; the sheet list keeps it', (tester) async {
      _useViewport(tester);
      await tester.pumpWidget(_app(ApaHarness(), held, withoutHeld: true));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('apa_insight_card_held_transfer')),
        findsNothing,
      );
      expect(find.byKey(const Key('apa_insight_card_sim_swap')), findsOne);
      expect(find.text('আপনার একটি লেনদেন আটকে আছে'), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('card'))),
      );
      expect(
        container.read(apaInsightsProvider).map((i) => i.id),
        contains('held_transfer'),
      );
    });

    testWidgets('call_transfer is skipped too; with nothing else the card '
        'falls back to the all-clear', (tester) async {
      _useViewport(tester);
      await tester.pumpWidget(
        _app(ApaHarness(), heldOnCall, withoutHeld: true),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('apa_insight_card_call_transfer')),
        findsNothing,
      );
      expect(find.byKey(const Key('apa_insight_card_all_clear')), findsOne);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('card'))),
      );
      expect(container.read(apaInsightsProvider).first.id, 'call_transfer');
    });
  });
}
