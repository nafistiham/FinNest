// The FNA sheet on the owner's phone: the header title was cut
// ("ফিননেস্ট সহকারী · নি…"), and the sheet opened scrolled so the first
// insight hid behind the header.
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_insight_card.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadAppFonts;
import 'apa_test_doubles.dart';

Widget _app(ApaHarness h, String locale) => ProviderScope(
  overrides: [
    ...h.overrides,
    // The original sheet: these tests pin the flag-off UI.
    fnaVoiceAgentEnabledProvider.overrideWithValue(false),
    initialLocaleProvider.overrideWithValue(Locale(locale)),
    apaTipSeedProvider.overrideWithValue(0),
    apaSnapshotProvider.overrideWithValue(blockSnapshot),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, locale: Locale(locale)),
    locale: Locale(locale),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: const Scaffold(
      body: Padding(
        padding: EdgeInsets.all(BhSpace.m),
        child: Column(children: [ApaInsightCard()]),
      ),
    ),
  ),
);

void main() {
  setUpAll(loadAppFonts);

  for (final (w, hgt) in [(360.0, 640.0), (412.0, 915.0)]) {
    for (final locale in ['bn', 'en']) {
      testWidgets('sheet at ${w.toInt()} dp ($locale): header text whole, '
          'first bubble below the header, 36 dp pills, icon-only send', (
        tester,
      ) async {
        tester.view.physicalSize = Size(w * 3, hgt * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_app(ApaHarness(), locale));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apa_insight_card_tap')));
        await tester.pumpAndSettle();
        expect(find.byType(ApaSheetBody), findsOneWidget);
        expect(tester.takeException(), isNull);

        final header = find.byKey(const Key('apa_sheet_header'));
        // Title and role are whole: no paragraph in the header is cut.
        for (final r in tester.renderObjectList<RenderParagraph>(
          find.descendant(of: header, matching: find.byType(RichText)),
        )) {
          expect(r.didExceedMaxLines, isFalse, reason: r.text.toPlainText());
        }
        for (final t in tester.widgetList<Text>(
          find.descendant(of: header, matching: find.byType(Text)),
        )) {
          expect(t.overflow, isNot(TextOverflow.ellipsis), reason: t.data);
        }
        final title = find.byKey(const Key('apa_sheet_title'));
        expect(
          tester.widget<Text>(title).data,
          locale == 'bn' ? 'ফিননেস্ট সহকারী' : 'FinNest Assistant',
        );
        final titleBox = tester.renderObject<RenderParagraph>(
          find.descendant(of: title, matching: find.byType(RichText)),
        );
        expect(
          titleBox.size.height,
          lessThan(titleBox.text.style!.fontSize! * 2),
          reason: 'the title fits one line',
        );
        expect(find.byKey(const Key('apa_sheet_role')), findsOneWidget);

        // Opened at offset 0: the first bubble starts at or below the
        // header's bottom edge.
        final first = find.byKey(const Key('apa_bubble_0'));
        expect(first, findsOneWidget);
        expect(
          tester.getTopLeft(first).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(header).dy),
        );
        final list = find.descendant(
          of: find.byType(ApaSheetBody),
          matching: find.byType(ListView),
        );
        expect(tester.widget<ListView>(list).controller!.offset, 0);

        // Path pill and (Bangla) English toggle: 36 dp pills.
        final path = find.descendant(
          of: find.byKey(const Key('apa_path_chip')),
          matching: find.byType(Container),
        );
        expect(tester.getSize(path.first).height, 36);
        if (locale == 'bn') {
          final toggle = find.byKey(const Key('apa_english_toggle'));
          expect(
            tester
                .getSize(
                  find
                      .descendant(of: toggle, matching: find.byType(Container))
                      .first,
                )
                .height,
            36,
          );
          expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
        }

        // Send: icon only, 56 dp, the word as a tooltip.
        final send = find.byKey(const Key('apa_send'));
        expect(tester.getSize(send), const Size(56, 56));
        expect(
          find.descendant(of: send, matching: find.byType(Text)),
          findsNothing,
        );
        expect(find.byIcon(Icons.send), findsOneWidget);
      });
    }
  }

  testWidgets('with a 48 dp gesture-bar inset at 412 x 915 the hold-to-talk '
      'button ends above the inset (ux-review 4 P2)', (tester) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48 * 3);
    tester.view.padding = const FakeViewPadding(bottom: 48 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(ApaHarness(), 'bn'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apa_insight_card_tap')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final button = tester.getRect(find.byKey(const Key('apa_hold_to_talk')));
    expect(button.bottom, lessThanOrEqualTo(915 - 48));
    // And keeps the 16 dp gutter above the inset.
    expect(button.bottom, lessThanOrEqualTo(915 - 48 - BhSpace.m + 0.5));
  });
}
