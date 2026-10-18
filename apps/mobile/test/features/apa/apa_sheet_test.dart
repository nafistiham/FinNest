import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bh_bottom_bar.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_held_score.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_text_service.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/ui/apa_screen.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

Widget _app(ApaHarness h, Widget home, {List<Override> extra = const []}) =>
    ProviderScope(
      overrides: [
        ...h.overrides,
        // The original sheet: these tests pin the flag-off UI.
        fnaVoiceAgentEnabledProvider.overrideWithValue(false),
        ...extra,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        locale: const Locale('bn'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: home,
      ),
    );

/// A host screen with the FNA square, as the bottom bars carry it.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: SizedBox.expand(),
    floatingActionButton: ApaSquareButton(screen: 'home'),
  );
}

Future<void> _longPress(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets(
    'ApaScreen hosts the sheet full-screen with path chip and empty hint',
    (tester) async {
      final h = ApaHarness();
      await tester.pumpWidget(_app(h, const ApaScreen()));
      await tester.pumpAndSettle();

      expect(find.text('ফিননেস্ট সহকারী'), findsWidgets);
      expect(find.text('অফলাইন গাইড'), findsOneWidget);
      expect(find.text('লাইভ'), findsNothing);
      expect(
        find.text('ফিননেস্ট সহকারীকে যা খুশি জিজ্ঞাসা করুন'),
        findsOneWidget,
      );
      expect(find.text('চেপে ধরে বলুন'), findsOneWidget);
      for (final k in ['phone', 'held', 'code', 'rules']) {
        expect(find.byKey(Key('apa_quick_$k')), findsOneWidget);
      }

      final hold = tester.getSize(find.byKey(const Key('apa_hold_to_talk')));
      expect(hold.height, ApaSheet.holdButtonHeight);
      final send = tester.getSize(find.byKey(const Key('apa_send')));
      expect(send.width, BhSize.touch);
      expect(send.height, BhSize.touch);
    },
  );

  testWidgets(
    'FAB opens the sheet seeded with the held score; the first bubble is the reasons',
    (tester) async {
      final h = ApaHarness();
      await tester.pumpWidget(_app(h, const _Host()));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_Host)),
      );
      container.read(apaHeldScoreProvider.notifier).state = heldScore;

      await tester.tap(find.byType(ApaSquareButton));
      await tester.pumpAndSettle();

      expect(find.byType(ApaSheetBody), findsOneWidget);
      expect(find.text(heldFirstLineBn), findsOneWidget);
      expect(find.text(heldFirstLineEn), findsNothing);
      expect(h.audio.spoken, [heldFirstLineBn]);

      // English toggle reveals the small English line under the bubble.
      await tester.tap(find.byKey(const Key('apa_english_toggle')));
      await tester.pumpAndSettle();
      expect(find.text(heldFirstLineEn), findsOneWidget);
    },
  );

  testWidgets('quick action "টাকা কেন আটকাল?" with nothing held', (
    tester,
  ) async {
    final h = ApaHarness();
    await tester.pumpWidget(_app(h, const ApaScreen(screen: 'home')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apa_quick_held')));
    await tester.pumpAndSettle();

    final turns = ProviderScope.containerOf(
      tester.element(find.byType(ApaScreen)),
    ).read(apaControllerProvider).turns;
    expect(turns.first.textBn, 'টাকা কেন আটকাল?');
    expect(turns[1].textBn, 'এখন আপনার কোনো টাকা আটকে নেই।');
    // The list scrolled to the newest bubble: what would hold a transfer.
    expect(find.textContaining('এসব কারণে টাকা আটকাতে পারে:'), findsOneWidget);
    expect(h.api.calls, isEmpty);
    expect(h.audio.spoken, ['এখন আপনার কোনো টাকা আটকে নেই।']);
  });

  testWidgets('typed text is answered by the guide and the field clears', (
    tester,
  ) async {
    final h = ApaHarness();
    await tester.pumpWidget(_app(h, const ApaScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'আমি কি নিরাপদ?');
    await tester.tap(find.byKey(const Key('apa_send')));
    await tester.pumpAndSettle();

    expect(h.api.calls, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      find.text('ফোন এখনো যাচাই হয়নি। নিচের বোতাম চেপে যাচাই করুন।'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('apa_bubble_action_openSafety')),
      findsOneWidget,
    );
  });

  testWidgets(
    'hold button shows the unavailable hint with DisabledApaLiveService',
    (tester) async {
      final h = ApaHarness();
      await tester.pumpWidget(_app(h, const ApaScreen()));
      await tester.pumpAndSettle();

      await _longPress(tester, find.byKey(const Key('apa_hold_to_talk')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apa_hint')), findsOneWidget);
      expect(find.byKey(const Key('apa_hint')), findsOneWidget);
      expect(
        find.text(
          AppLocalizations.of(tester.element(find.byType(ApaScreen)))
              .apaLiveUnavailable,
        ),
        findsOneWidget,
      );
      expect(find.text('অফলাইন গাইড'), findsOneWidget);
      expect(h.mic.starts, 0);

      final state = ProviderScope.containerOf(
        tester.element(find.byType(ApaScreen)),
      ).read(apaControllerProvider);
      expect(state.error, ApaHint.liveUnavailable);
      expect(state.listening, isFalse);
    },
  );

  testWidgets(
    'with Live available the chip says লাইভ and holding shows শুনছি…',
    (tester) async {
      final live = FakeApaLiveService();
      final h = ApaHarness(live: live);
      await tester.pumpWidget(_app(h, const ApaScreen()));
      await tester.pumpAndSettle();

      expect(find.text('লাইভ'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('apa_hold_to_talk'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.text('শুনছি…'), findsOneWidget);
      expect(live.starts, 1);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('চেপে ধরে বলুন'), findsOneWidget);
      expect(live.endTurns, 1);
    },
  );

  testWidgets('a failed text turn shows the retry hint, no crash', (
    tester,
  ) async {
    final h = ApaHarness();
    await tester.pumpWidget(
      _app(
        h,
        const ApaScreen(),
        extra: [apaTextServiceProvider.overrideWithValue(_FailingService())],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'কী হলো?');
    await tester.tap(find.byKey(const Key('apa_send')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        AppLocalizations.of(tester.element(find.byType(ApaScreen)))
            .apaTextFailed,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet header at 360 dp: no overflow, 56 dp close, English '
      'toggle on its own row', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final h = ApaHarness();
    await tester.pumpWidget(_app(h, const _Host()));
    await tester.tap(find.byType(ApaSquareButton));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final close = find.byKey(const Key('apa_close'));
    expect(close, findsOneWidget);
    expect(tester.getSize(close).height, greaterThanOrEqualTo(56));
    expect(tester.getSize(close).width, greaterThanOrEqualTo(56));
    final toggle = find.byKey(const Key('apa_english_toggle'));
    expect(
      tester.getTopLeft(toggle).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(close).dy - 1),
    );

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(ApaSheetBody), findsNothing);
  });

  testWidgets('the /apa route has no close button (the app bar has back)', (
    tester,
  ) async {
    final h = ApaHarness();
    await tester.pumpWidget(_app(h, const ApaScreen()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apa_close')), findsNothing);
  });
}

class _FailingService implements ApaService {
  @override
  Future<List<ApaTurn>> ask(String t, ApaContext c, ApaContextSnapshot s) =>
      Future.error(StateError('down'));
}
