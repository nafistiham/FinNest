// The compact (calm) Home security card never cuts its copy: the owner's
// phone showed "…দে…", "…অ…" and "এফএনএ-র নি…" on the safe card.
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_insight_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadAppFonts;
import 'apa_test_doubles.dart';

Widget _app(ApaHarness h, String locale, int seed, Brightness b) =>
    ProviderScope(
      overrides: [
        ...h.overrides,
        initialLocaleProvider.overrideWithValue(Locale(locale)),
        apaTipSeedProvider.overrideWithValue(seed),
        apaSnapshotProvider.overrideWithValue(
          const ApaContextSnapshot(verdict: SafetyVerdict.safe),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(b, locale: Locale(locale)),
        locale: Locale(locale),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(
          body: Padding(
            // Home's gutter.
            padding: EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: Column(children: [ApaInsightCard(key: Key('card'))]),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadAppFonts);

  for (final width in [360.0, 412.0]) {
    for (final locale in ['bn', 'en']) {
      testWidgets('safe compact card at ${width.toInt()} dp ($locale): no '
          'cut text, no source caption, at most 150 dp', (tester) async {
        tester.view.physicalSize = Size(width * 3, 915 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        // Every tip the card can rotate to, plus the all-clear body.
        for (var seed = 0; seed < ApaContent.embedded.tips.length; seed++) {
          await tester.pumpWidget(
            _app(ApaHarness(), locale, seed, Brightness.dark),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final card = find.byKey(const Key('card'));
          expect(find.byKey(const Key('apa_insight_card_all_clear')), findsOne);

          final paragraphs = tester
              .renderObjectList<RenderParagraph>(
                find.descendant(of: card, matching: find.byType(RichText)),
              )
              .toList();
          expect(paragraphs, isNotEmpty);
          for (final r in paragraphs) {
            expect(
              r.didExceedMaxLines,
              isFalse,
              reason: '"${r.text.toPlainText()}" is cut (seed $seed)',
            );
          }
          for (final t in tester.widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          )) {
            if (t.overflow == TextOverflow.ellipsis) {
              final r = tester.renderObject<RenderParagraph>(
                find.descendant(
                  of: find.byWidget(t),
                  matching: find.byType(RichText),
                ),
              );
              expect(r.didExceedMaxLines, isFalse, reason: t.data);
            }
          }
          // The title fits one line at 412 dp.
          final title = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(const Key('apa_insight_title')),
              matching: find.byType(RichText),
            ),
          );
          if (width == 412) {
            expect(
              title.size.height,
              lessThan(title.text.style!.fontSize! * 2),
              reason: 'title wraps at 412 dp',
            );
          }
          // The body is one line.
          final body = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(const Key('apa_insight_body')),
              matching: find.byType(RichText),
            ),
          );
          expect(body.maxLines, 1);
          // No source caption; the action sits at the trailing edge.
          expect(
            find.byKey(const Key('apa_insight_source_phone')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('apa_insight_source_rules')),
            findsNothing,
          );
          final action = tester.getRect(
            find.byKey(const Key('apa_insight_action')),
          );
          final cardRect = tester.getRect(card);
          expect(cardRect.right - action.right, lessThanOrEqualTo(BhSpace.m));
          expect(cardRect.height, lessThanOrEqualTo(150));
        }
      });
    }
  }
}
