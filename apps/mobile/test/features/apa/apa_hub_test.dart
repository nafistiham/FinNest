import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/ui/apa_screen.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_insight_card.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

Widget _app(
  ApaHarness h,
  Widget home, {
  String locale = 'bn',
  Brightness brightness = Brightness.light,
  List<Override> extra = const [],
}) => ProviderScope(
  overrides: [
    ...h.overrides,
    initialLocaleProvider.overrideWithValue(Locale(locale)),
    apaTipSeedProvider.overrideWithValue(0),
    // The original sheet: these tests pin the flag-off UI.
    fnaVoiceAgentEnabledProvider.overrideWithValue(false),
    ...extra,
  ],
  child: MaterialApp(
    theme: buildTheme(brightness),
    locale: Locale(locale),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: home,
  ),
);

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Padding(
      padding: EdgeInsets.all(BhSpace.m),
      child: Column(children: [ApaInsightCard()]),
    ),
  );
}

/// Every string drawn on screen.
List<String> _texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

final _wire = RegExp(
  r'\b(BLOCK|SAFE|CAUTION|fake_customer_care|hold_and_warn|otp|pin|'
  r'UNINSTALL_AND_RECHECK|send_money|none|high|medium|benign|'
  r'openSafety|callHelpline|danger|caution)\b',
);

void main() {
  group('quick actions', () {
    for (final (locale, labels) in [
      (
        'bn',
        [
          'আমার ফোন কি নিরাপদ?',
          'টাকা কেন আটকাল?',
          'কেউ ফোনে কোড চাইছে',
          'নিরাপদ থাকার ৫ নিয়ম',
        ],
      ),
      (
        'en',
        [
          'Is my phone safe?',
          'Why was my money held?',
          'Someone on the phone wants a code',
          '5 rules to stay safe',
        ],
      ),
    ]) {
      testWidgets('all four present in $locale', (tester) async {
        final h = ApaHarness();
        await tester.pumpWidget(_app(h, const ApaScreen(), locale: locale));
        await tester.pumpAndSettle();
        for (final label in labels) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(
          find.byKey(const Key('apa_english_toggle')),
          locale == 'bn' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(locale == 'bn' ? 'অফলাইন গাইড' : 'Offline guide'),
          findsOneWidget,
        );
      });
    }

    testWidgets('English: guide answers and server lines show in English', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const ApaScreen(),
          locale: 'en',
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(lastScore: heldScore, locale: 'en'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apa_quick_held')));
      await tester.pumpAndSettle();
      expect(find.text(heldFirstLineEn), findsOneWidget);
      expect(find.text(heldFirstLineBn), findsNothing);
      expect(find.textContaining('The money was not sent.'), findsOneWidget);
      // The spoken line follows the app language: with
      // Gemini off in this harness the English line goes to the phone's
      // English voice.
      expect(h.audio.spoken, [
        heldFirstLineEn,
      ], reason: 'FNA speaks the app language');
    });

    testWidgets('scam check: posts, renders the quote verbatim, stores it', (
      tester,
    ) async {
      final h = ApaHarness();
      h.api.scamTurnResponse = scamResponse;
      await tester.pumpWidget(_app(h, const ApaScreen()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('apa_quick_code')));
      await tester.tap(find.byKey(const Key('apa_quick_code')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apa_scam_cancel')), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.hintText, 'কলার যা বলেছে…');

      await tester.enterText(
        find.byType(TextField),
        scamResponse.evidenceQuote,
      );
      await tester.tap(find.byKey(const Key('apa_send')));
      await tester.pumpAndSettle();

      final req = h.api.callsTo(RiskRoutes.scamTurn).single.body as Map;
      expect(req['pending_action'], 'send_money');
      expect(((req['turns'] as List).single as Map)['speaker'], 'caller');
      expect(
        find.textContaining('কলার বলেছে: “${scamResponse.evidenceQuote}”'),
        findsOneWidget,
      );
      expect(find.textContaining(ApaHelpline.bn), findsWidgets);
      expect(
        find.byKey(const Key('apa_bubble_action_callHelpline')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('apa_scam_cancel')), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ApaScreen)),
      );
      expect(
        container.read(lastEvidenceQuoteProvider),
        scamResponse.evidenceQuote,
      );
    });

    testWidgets('no raw enum, wire value or package name on screen', (
      tester,
    ) async {
      // Tall enough that the lazy list builds every bubble of the transcript.
      tester.view.physicalSize = const Size(1080, 9000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final h = ApaHarness();
      h.api.scamTurnResponse = scamResponse;
      await tester.pumpWidget(
        _app(
          h,
          const ApaScreen(),
          extra: [apaSnapshotProvider.overrideWithValue(blockSnapshot)],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apa_quick_phone')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('apa_quick_code')));
      await tester.tap(find.byKey(const Key('apa_quick_code')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'কোডটা বলুন');
      await tester.tap(find.byKey(const Key('apa_send')));
      await tester.pumpAndSettle();

      final all = _texts(tester).join('\n');
      expect(all, contains(blockMessageBn));
      expect(all, contains('TakaNow Loan'));
      expect(all, contains('ধরন: ভুয়া কাস্টমার কেয়ার কল'));
      expect(all, contains('চাওয়া হয়েছে: ওটিপি বা কোড'));
      expect(all, isNot(contains('com.takanow')));
      expect(_wire.firstMatch(all)?.group(0), isNull);
    });
  });

  group('provenance and layout', () {
    testWidgets('held line is captioned as the bank check, rules as Apa\'s', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const ApaScreen(),
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(lastScore: heldScore),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apa_quick_held')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apa_source_server')), findsOneWidget);
      expect(find.text('ফিননেস্টের যাচাই'), findsOneWidget);
      expect(find.byKey(const Key('apa_source_rules')), findsOneWidget);
      // No caption under the user's own bubble.
      expect(find.byKey(const Key('apa_source_ai')), findsNothing);
    });

    testWidgets('quick actions: 2 x 2 at first, one row after a question', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final h = ApaHarness();
      await tester.pumpWidget(_app(h, const ApaScreen()));
      await tester.pumpAndSettle();
      final phone = tester.getTopLeft(find.byKey(const Key('apa_quick_phone')));
      final code = tester.getTopLeft(find.byKey(const Key('apa_quick_code')));
      expect(code.dy, greaterThan(phone.dy), reason: 'second row');
      for (final k in ['phone', 'held', 'code', 'rules']) {
        expect(
          tester.getSize(find.byKey(Key('apa_quick_$k'))).height,
          greaterThanOrEqualTo(BhSize.touch),
        );
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('apa_quick_rules')));
      await tester.pumpAndSettle();
      final phone2 = tester.getTopLeft(
        find.byKey(const Key('apa_quick_phone')),
      );
      final code2 = tester.getTopLeft(find.byKey(const Key('apa_quick_code')));
      expect(code2.dy, phone2.dy, reason: 'one row');
      expect(tester.takeException(), isNull);
    });
  });

  group('ApaInsightCard', () {
    testWidgets('BLOCK: danger label, title, 56 dp action, opens the sheet', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [apaSnapshotProvider.overrideWithValue(blockSnapshot)],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apa_insight_card_app_block')),
        findsOneWidget,
      );
      expect(find.text('বিপদ'), findsOneWidget);
      expect(find.text('আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে'), findsOneWidget);
      expect(find.text('ফোনের নিরাপত্তা দেখুন'), findsOneWidget);
      final card = tester.getSize(
        find.byKey(const Key('apa_insight_card_tap')),
      );
      expect(card.height, greaterThanOrEqualTo(BhSize.touch));
      final action = tester.getSize(
        find.byKey(const Key('apa_insight_action')),
      );
      expect(action.height, greaterThanOrEqualTo(BhSize.touch));

      await tester.tap(find.byKey(const Key('apa_insight_card_tap')));
      await tester.pumpAndSettle();
      expect(find.byType(ApaSheetBody), findsOneWidget);
      // The insight is the first bubble: title and body together.
      expect(
        find.textContaining('আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে\n$blockMessageBn'),
        findsOneWidget,
      );
    });

    testWidgets('held: caution label and the server reasons', (tester) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(
                verdict: SafetyVerdict.safe,
                lastScore: heldScore,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('সাবধান'), findsOneWidget);
      expect(find.text(heldFirstLineBn), findsOneWidget);
    });

    testWidgets('all clear: ok label, the tip, action opens the rules', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(verdict: SafetyVerdict.safe),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('নিরাপদ'), findsOneWidget);
      expect(find.text('ফোন ও লেনদেন নিরাপদ দেখাচ্ছে'), findsOneWidget);
      expect(
        find.textContaining(ApaHelpline.bn),
        findsOneWidget,
        reason: 'the tip',
      );

      await tester.tap(find.byKey(const Key('apa_insight_action')));
      await tester.pumpAndSettle();
      expect(find.byType(ApaSheetBody), findsOneWidget);
      // The sheet opens at the top (the insight first); the rules follow.
      final rule5 = find.textContaining('৫. নতুন কাউকে টাকা পাঠানোর আগে থামুন');
      await tester.scrollUntilVisible(
        rule5,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ApaSheetBody),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(rule5, findsOneWidget);
    });

    testWidgets('footer counts the other issues and lists them in the sheet', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(
                verdict: SafetyVerdict.block,
                safetyMessageBn: blockMessageBn,
                simSwap: true,
                screenShare: true,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('আরও ২টি বিষয়'), findsOneWidget);
      await tester.tap(find.byKey(const Key('apa_insight_more')));
      await tester.pumpAndSettle();
      final turns = ProviderScope.containerOf(
        tester.element(find.byType(ApaSheetBody)),
      ).read(apaControllerProvider).turns;
      expect(turns.map((t) => t.textBn.split('\n').first), [
        'আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে',
        'আপনার সিম সম্প্রতি বদলেছে',
        'আপনার স্ক্রিন শেয়ার হচ্ছে',
      ]);
    });

    testWidgets('no footer when there is one issue', (tester) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [apaSnapshotProvider.overrideWithValue(blockSnapshot)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apa_insight_more')), findsNothing);
    });

    testWidgets('loading while the phone check runs', (tester) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(safetyChecking: true),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('apa_insight_loading')), findsOneWidget);
      expect(find.text('এফএনএ দেখছে…'), findsOneWidget);
    });

    testWidgets('a danger insight still shows while the check runs', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(
        _app(
          h,
          const _Home(),
          extra: [
            apaSnapshotProvider.overrideWithValue(
              const ApaContextSnapshot(
                safetyChecking: true,
                evidenceQuote: 'কোডটা বলুন',
              ),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('apa_insight_card_scam_call')),
        findsOneWidget,
      );
    });

    for (final locale in ['bn', 'en']) {
      for (final brightness in Brightness.values) {
        testWidgets('renders in $locale/${brightness.name} at 360 dp', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1080, 1920);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          final h = ApaHarness();
          await tester.pumpWidget(
            _app(
              h,
              const _Home(),
              locale: locale,
              brightness: brightness,
              extra: [apaSnapshotProvider.overrideWithValue(blockSnapshot)],
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(locale == 'bn' ? 'বিপদ' : 'Danger'), findsOneWidget);
          if (locale == 'en') {
            expect(find.text('A risky app is on your phone'), findsOneWidget);
            expect(find.textContaining(blockMessageEn), findsOneWidget);
          }
        });
      }
    }

    testWidgets('real providers: no state yet → unchecked, no crash', (
      tester,
    ) async {
      final h = ApaHarness();
      await tester.pumpWidget(_app(h, const _Home()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('apa_insight_card_unchecked')),
        findsOneWidget,
      );
    });
  });

  test('the insight ids the card keys on are stable', () {
    expect(ApaSeverity.values.map((s) => s.name), [
      'danger',
      'caution',
      'ok',
      'info',
    ]);
  });
}
