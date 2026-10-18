// The call summary card: time, the secret asked
// for, the caller's words verbatim, what to do now and next time; amber,
// square, no confidence value; Hear it and the helpline.

import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/safety/logic/external_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safety/safety_test_support.dart' show loadAppFonts;
import 'fna_ui_fakes.dart';

void main() {
  setUpAll(loadAppFonts);

  late List<Uri> launched;

  Widget app(
    WidgetTester tester,
    ScriptedApaController c, {
    bool flag = true,
    String? nextTime,
  }) {
    launched = [];
    fnaPhone(tester);
    return fnaApp(
      c,
      flag: flag,
      nextTime: nextTime,
      extra: [
        uriLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
          return true;
        }),
      ],
    );
  }

  testWidgets('first in the transcript with every row, amber, no score', (
    tester,
  ) async {
    final c = ScriptedApaController(
      ApaState(turns: const [fnaAnswer], callSummary: fnaSummary),
    );
    await tester.pumpWidget(app(tester, c, nextTime: fnaNextTime));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('fna_call_summary_card'));
    expect(card, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('apa_bubble_0'), skipOffstage: false),
            )
            .dy,
      ),
    );
    // 08:30 UTC is 14:30 in Dhaka: "দুপুর ২:৩০".
    expect(find.text('সন্দেহজনক কল · দুপুর ২:৩০'), findsOneWidget);
    for (final (row, label, value) in [
      ('asked', 'ফোনে চেয়েছিল', 'ওটিপি বা কোড'),
      ('said', 'ফোনে বলেছিল', '“${fnaSummary.evidenceQuote}”'),
      (
        'now',
        'এখন কী করবেন',
        'আবার ফোন করলে কেটে দিন। টাকা পাঠাবেন না, কোনো কোড বলবেন না।',
      ),
      ('next', 'পরের বার যা করবেন', fnaNextTime),
    ]) {
      final r = find.byKey(Key('fna_call_row_$row'));
      expect(r, findsOneWidget, reason: row);
      expect(
        find.descendant(of: r, matching: find.text(label)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: r, matching: find.text(value)),
        findsOneWidget,
      );
    }

    final box = tester.widget<Container>(card).decoration! as BoxDecoration;
    final p = tester.element(card).palette;
    expect(box.color, p.warningContainer);
    expect(box.color, isNot(p.dangerContainer));
    expect(box.borderRadius, isNull, reason: 'square corners');
    // No confidence value anywhere on the card.
    for (final t in tester.widgetList<Text>(
      find.descendant(of: card, matching: find.byType(Text)),
    )) {
      expect(t.data ?? '', isNot(contains('%')));
      expect(t.data ?? '', isNot(contains('0.85')));
    }
  });

  testWidgets('without a prevent text the Next time row is left out', (
    tester,
  ) async {
    final c = ScriptedApaController(ApaState(callSummary: fnaSummary));
    await tester.pumpWidget(app(tester, c));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fna_call_row_next')), findsNothing);
    expect(find.byKey(const Key('fna_call_row_now')), findsOneWidget);
  });

  testWidgets('Hear it reads the card; the helpline opens the dialer', (
    tester,
  ) async {
    final c = ScriptedApaController(ApaState(callSummary: fnaSummary));
    await tester.pumpWidget(app(tester, c, nextTime: fnaNextTime));
    await tester.pumpAndSettle();
    expect(find.text('শুনুন'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('fna_call_hear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fna_call_hear')));
    await tester.pump();
    expect(c.calls, ['hearCallSummary']);

    await tester.ensureVisible(find.byKey(const Key('fna_call_helpline')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fna_call_helpline')));
    await tester.pump();
    expect(launched, [ExternalLinks.bankCall]);
    expect(launched.single.scheme, 'tel');
  });

  testWidgets('digits in the caller\'s words are masked', (tester) async {
    final c = ScriptedApaController(
      ApaState(
        callSummary: FnaCallSummary(
          scamType: 'fake_customer_care',
          urgency: 'high',
          requestedSecret: 'otp',
          evidenceQuote: 'আপনার কোড ৪৮২৯১৭ বলুন, 123456 না',
          recommendedAction: 'hold_and_warn',
          at: DateTime.utc(2026, 10, 18, 8, 30),
        ),
      ),
    );
    await tester.pumpWidget(app(tester, c));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('fna_call_row_said'));
    expect(
      find.descendant(
        of: row,
        matching: find.text('“আপনার কোড •••• বলুন, •••• না”'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('৪৮২৯১৭'), findsNothing);
    expect(find.textContaining('123456'), findsNothing);
  });

  testWidgets('Hear it turns into Stop while FNA reads the card', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final c = ScriptedApaController(ApaState(callSummary: fnaSummary));
    await tester.pumpWidget(app(tester, c));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(const Key('fna_call_hear'))),
      isSemantics(isButton: true, label: 'শুনুন: সন্দেহজনক কল · দুপুর ২:৩০'),
    );
    c.emit(c.state.copyWith(hearingSummary: true));
    await tester.pumpAndSettle();
    final stop = find.byKey(const Key('fna_call_hear_stop'));
    expect(stop, findsOneWidget);
    expect(
      find.descendant(of: stop, matching: find.byIcon(Icons.stop)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: stop, matching: find.text('থামান')),
      findsOneWidget,
    );
    await tester.ensureVisible(stop);
    await tester.pumpAndSettle();
    await tester.tap(stop);
    await tester.pump();
    // The same call stops it: the controller toggles.
    expect(c.calls, ['hearCallSummary']);
    semantics.dispose();
  });

  testWidgets('flag off: no card', (tester) async {
    final c = ScriptedApaController(ApaState(callSummary: fnaSummary));
    await tester.pumpWidget(app(tester, c, flag: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fna_call_summary_card')), findsNothing);
  });
}
