import 'dart:async';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/approve_controller.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';
import 'package:bhorosha/features/approve/ui/approve_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approve_test_support.dart';

void main() {
  late ApproveHarness h;

  setUp(() async {
    h = ApproveHarness();
    await h.warm();
  });
  tearDown(() => h.dispose());

  Future<void> pumpScreen(
    WidgetTester tester,
    String requestId, {
    Brightness brightness = Brightness.light,
    Locale locale = const Locale('bn'),
    // The trusted contact of every seeded record (approve_test_support).
    String? viewer = 'rafiq',
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          approveViewerUidProvider.overrideWithValue(viewer),
          trustedContactFlowProvider.overrideWithValue(h.flow),
          approveClockProvider.overrideWithValue(h.clock),
          ledgerRepoProvider.overrideWithValue(h.ledger),
          interventionRepoProvider.overrideWithValue(h.interventions),
        ],
        child: MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: buildTheme(brightness, locale: locale),
          home: ApproveScreen(requestId: requestId),
        ),
      ),
    );
    // Local lookup resolves on the next frames; the ticker keeps running so
    // pumpAndSettle would never finish.
    await tester.pump();
    await tester.pump();
  }

  /// Disposes the ProviderScope so the controller's ticker is cancelled
  /// before flutter_test checks for pending timers.
  Future<void> tearDownScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }

  /// The ledger row after one pump. `Stream.first` is avoided on purpose:
  /// its cancel future resolves on the root zone and never completes inside
  /// the fake-async zone of a widget test.
  Future<LedgerTxn?> txnAfterPump(WidgetTester tester, String txnId) async {
    LedgerTxn? hit;
    final sub = h.ledger.watchRecent('rina', limit: 100).listen((rows) {
      for (final t in rows) {
        if (t.txnId == txnId) hit = t;
      }
    });
    await tester.pump();
    unawaited(sub.cancel());
    return hit;
  }

  bool enabled(WidgetTester tester, Key key) {
    final w = tester.widget<ButtonStyleButton>(find.byKey(key));
    return w.onPressed != null;
  }

  testWidgets('renders payee, amount, server reasons and the countdown', (
    tester,
  ) async {
    await h.seedPending();
    await pumpScreen(tester, 'req_1');

    expect(find.text('অনুমোদনের অনুরোধ'), findsOneWidget);
    // Who asks, then the payee in the summary's kind line.
    expect(find.text('রিনা আপনার মত চাইছেন'), findsOneWidget);
    expect(find.text('নতুন নম্বর-কে পাঠানো হচ্ছিল'), findsOneWidget);
    expect(find.text('কেন আটকানো হয়েছে'), findsOneWidget);
    expect(find.byKey(const Key('approve_amount')), findsOneWidget);
    expect(find.text('৳ ৫,০০০'), findsOneWidget);
    // Reasons and Apa's line are the server strings, verbatim.
    expect(find.text(reasonCall.textBn), findsOneWidget);
    expect(find.text(reasonNewPayee.textBn), findsOneWidget);
    expect(
      find.text('আমি ফিননেস্ট সহকারী বলছি। একটু থামুন, আগে যাচাই করে নিন।'),
      findsOneWidget,
    );
    // Nothing composed from the reason codes.
    expect(find.textContaining('call_active'), findsNothing);
    expect(find.textContaining('new_payee'), findsNothing);
    // Countdown in Bangla digits, a warning tag pinned to the summary
    // card's trailing 16 dp padding line.
    expect(find.bySemanticsLabel('১০:০০ বাকি'), findsOneWidget);
    final card = tester.getRect(find.byKey(const Key('approve_summary')));
    final tag = tester.getRect(find.byKey(const Key('approve_countdown')));
    expect(tag.right, moreOrLessEquals(card.right - 16, epsilon: 1));
    expect(tag.top, lessThan(tester.getRect(find.text('৳ ৫,০০০')).top));

    expect(find.text('অনুমোদন করুন'), findsOneWidget);
    expect(find.text('প্রত্যাখ্যান করুন'), findsOneWidget);
    expect(enabled(tester, const Key('approve_approve')), isTrue);
    expect(enabled(tester, const Key('approve_decline')), isTrue);

    // Both decision buttons are 64 dp tall. The money-moving approve is the
    // outlined one on top; the protective decline is filled and lowest, in
    // the thumb zone.
    final approveBox = tester.getRect(find.byKey(const Key('approve_approve')));
    final declineBox = tester.getRect(find.byKey(const Key('approve_decline')));
    expect(approveBox.height, ApproveScreen.buttonHeight);
    expect(declineBox.height, ApproveScreen.buttonHeight);
    expect(declineBox.top, greaterThan(approveBox.bottom));
    expect(
      tester.widget(find.byKey(const Key('approve_approve'))),
      isA<OutlinedButton>(),
    );
    expect(
      tester.widget(find.byKey(const Key('approve_decline'))),
      isA<FilledButton>(),
    );
    expect(find.byKey(const Key('approve_go_home')), findsNothing);

    await tearDownScreen(tester);
  });

  group('someone other than the contact opens it', () {
    for (final (viewer, locale, title) in [
      ('rina', const Locale('bn'), 'এই অনুরোধ আপনার আপনজনের জন্য'),
      ('rina', const Locale('en'), 'This request is for your trusted person'),
      (null, const Locale('bn'), 'এই অনুরোধ আপনার আপনজনের জন্য'),
    ]) {
      testWidgets('viewer ${viewer ?? 'signed out'} (${locale.languageCode}): '
          'read-only, explained, no decision buttons', (tester) async {
        await h.seedPending();
        await pumpScreen(tester, 'req_1', viewer: viewer, locale: locale);

        expect(find.byKey(const Key('approve_not_yours')), findsOneWidget);
        expect(find.text(title), findsOneWidget);
        // The details stay readable.
        expect(find.byKey(const Key('approve_amount')), findsOneWidget);
        expect(find.byKey(const Key('approve_approve')), findsNothing);
        expect(find.byKey(const Key('approve_decline')), findsNothing);
        expect(find.byKey(const Key('approve_go_home')), findsOneWidget);
        expect(h.api.calls, isEmpty);
        await tearDownScreen(tester);
      });
    }

    testWidgets('the contact sees no notice and can decide', (tester) async {
      await h.seedPending();
      await pumpScreen(tester, 'req_1');
      expect(find.byKey(const Key('approve_not_yours')), findsNothing);
      expect(enabled(tester, const Key('approve_approve')), isTrue);
      await tearDownScreen(tester);
    });
  });

  testWidgets('countdown ticks every second and shows 9:59', (tester) async {
    await h.seedPending();
    await pumpScreen(tester, 'req_1');
    h.clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.bySemanticsLabel('৯:৫৯ বাকি'), findsOneWidget);
    await tearDownScreen(tester);
  });

  testWidgets('approve calls the flow and shows the approved line', (
    tester,
  ) async {
    await h.seedPending();
    await pumpScreen(tester, 'req_1');

    await tester.tap(find.byKey(const Key('approve_approve')));
    await tester.pump();
    await tester.pump();

    expect(h.api.callsTo(RiskRoutes.trustedApprove), hasLength(1));
    expect(find.text('অনুমোদিত। টাকা পাঠানো হয়েছে।'), findsOneWidget);
    expect(find.byKey(const Key('approve_countdown')), findsNothing);
    // Decided: the buttons give way to "হোমে ফিরুন".
    expect(find.byKey(const Key('approve_approve')), findsNothing);
    expect(find.byKey(const Key('approve_decline')), findsNothing);
    expect(find.byKey(const Key('approve_go_home')), findsOneWidget);
    expect(find.text('হোমে ফিরুন'), findsOneWidget);
    expect((await txnAfterPump(tester, 'txn_held_1'))!.status, 'done');

    await tearDownScreen(tester);
  });

  testWidgets('an approval the '
      'contact did not make shows "আপনজন নিশ্চিত করেননি" and keeps the '
      'hold', (tester) async {
    await h.seedPending();
    h.api.decision = const TrustedContactDecision(
      requestId: 'req_1',
      status: TrustedContactDecision.statusApproved,
      decidedBy: 'rina',
      contactVerified: false,
    );
    await pumpScreen(tester, 'req_1');

    await tester.tap(find.byKey(const Key('approve_approve')));
    await tester.pump();
    await tester.pump();

    expect(h.api.actingAsFor(RiskRoutes.trustedApprove), 'rafiq');
    expect(find.text('আপনজন নিশ্চিত করেননি'), findsOneWidget);
    expect(find.text('অনুমোদিত। টাকা পাঠানো হয়েছে।'), findsNothing);
    expect(find.byKey(const Key('approve_approve')), findsNothing);
    expect(find.byKey(const Key('approve_go_home')), findsOneWidget);
    expect((await txnAfterPump(tester, 'txn_held_1'))!.status, 'held');
    await tearDownScreen(tester);
  });

  testWidgets('decline shows the declined line and keeps the row held', (
    tester,
  ) async {
    await h.seedPending();
    await pumpScreen(tester, 'req_1');

    await tester.tap(find.byKey(const Key('approve_decline')));
    await tester.pump();
    await tester.pump();

    expect(find.text('প্রত্যাখ্যাত। লেনদেন আটকে থাকবে।'), findsOneWidget);
    expect((await txnAfterPump(tester, 'txn_held_1'))!.status, 'held');
    await tearDownScreen(tester);
  });

  testWidgets('expired shows সময় শেষ and only the way home', (tester) async {
    await h.seedPending(ttl: const Duration(seconds: 2));
    await pumpScreen(tester, 'req_1');
    expect(enabled(tester, const Key('approve_approve')), isTrue);

    h.clock.advance(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('সময় শেষ'), findsOneWidget);
    expect(find.byKey(const Key('approve_countdown')), findsNothing);
    expect(find.byKey(const Key('approve_approve')), findsNothing);
    expect(find.byKey(const Key('approve_decline')), findsNothing);
    expect(find.byKey(const Key('approve_go_home')), findsOneWidget);
    await tearDownScreen(tester);
  });

  testWidgets('busy state shows progress and disables the buttons', (
    tester,
  ) async {
    await h.seedPending();
    await pumpScreen(tester, 'req_1');
    final release = h.api.hold(RiskRoutes.trustedApprove);

    await tester.tap(find.byKey(const Key('approve_approve')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(enabled(tester, const Key('approve_approve')), isFalse);
    expect(enabled(tester, const Key('approve_decline')), isFalse);

    release();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tearDownScreen(tester);
  });

  testWidgets('API failure shows the error line and retry works', (
    tester,
  ) async {
    await h.seedPending();
    h.api.failures[RiskRoutes.trustedApprove] = const NetworkFailure();
    await pumpScreen(tester, 'req_1');

    await tester.tap(find.byKey(const Key('approve_approve')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('approve_error')), findsOneWidget);
    expect(find.byKey(const Key('approve_retry')), findsOneWidget);
    expect(enabled(tester, const Key('approve_approve')), isTrue);

    h.api.failures.clear();
    await tester.tap(find.byKey(const Key('approve_retry')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('approve_error')), findsNothing);
    expect(find.text('অনুমোদিত। টাকা পাঠানো হয়েছে।'), findsOneWidget);
    await tearDownScreen(tester);
  });

  testWidgets('unknown id renders the minimal screen with both buttons', (
    tester,
  ) async {
    await pumpScreen(tester, 'from-other-phone');

    // A readable header and a short muted reference, never the raw id.
    expect(find.text('আপনজনের অনুরোধ'), findsOneWidget);
    expect(find.byKey(const Key('approve_reference')), findsOneWidget);
    expect(find.text('রেফারেন্স RPHONE'), findsOneWidget);
    expect(find.textContaining('from-other-phone'), findsNothing);
    expect(
      find.text(
        'এই অনুরোধের বিস্তারিত অন্য ফোনে আছে। আপনি তবুও অনুমোদন বা '
        'প্রত্যাখ্যান করতে পারেন।',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.phonelink_lock), findsOneWidget);
    expect(find.byKey(const Key('approve_amount')), findsNothing);
    expect(find.byKey(const Key('approve_countdown')), findsNothing);
    expect(enabled(tester, const Key('approve_approve')), isTrue);
    expect(enabled(tester, const Key('approve_decline')), isTrue);

    // A decision still reaches the server.
    await tester.tap(find.byKey(const Key('approve_decline')));
    await tester.pump();
    await tester.pump();
    expect(h.api.callsTo(RiskRoutes.trustedDecline), hasLength(1));
    expect(find.text('প্রত্যাখ্যাত। লেনদেন আটকে থাকবে।'), findsOneWidget);
    await tearDownScreen(tester);
  });

  testWidgets('record without a ledger row omits the amount card', (
    tester,
  ) async {
    await h.interventions.upsert(
      openRecord(
        txnId: 'txn_missing',
        status: 'pending',
        requestId: 'req_noamt',
        expiresAt: t0.add(const Duration(minutes: 5)),
      ),
    );
    await pumpScreen(tester, 'req_noamt');
    expect(find.byKey(const Key('approve_amount')), findsNothing);
    expect(find.text(reasonCall.textBn), findsOneWidget);
    expect(find.bySemanticsLabel('৫:০০ বাকি'), findsOneWidget);
    await tearDownScreen(tester);
  });

  testWidgets('decision buttons carry semantics labels', (tester) async {
    await h.seedPending();
    await pumpScreen(tester, 'req_1');
    expect(find.bySemanticsLabel('অনুমোদন করুন'), findsWidgets);
    expect(find.bySemanticsLabel('প্রত্যাখ্যান করুন'), findsWidgets);
    await tearDownScreen(tester);
  });

  test('state outcome prefers the server decision over the record', () {
    const s = ApproveState(requestId: 'r', loaded: true);
    expect(s.outcome, isNull);
    expect(s.canDecide, isTrue);
    final expired = s.copyWith(remaining: Duration.zero);
    expect(expired.expired, isTrue);
  });

  for (final size in const [Size(360, 640), Size(412, 915)]) {
    testWidgets('no overflow at $size, both themes and languages', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = size * 3;
      addTearDown(tester.view.reset);
      await h.seedPending();
      for (final b in Brightness.values) {
        for (final l in const [Locale('bn'), Locale('en')]) {
          for (final id in ['req_1', 'from-other-phone']) {
            await pumpScreen(tester, id, brightness: b, locale: l);
            expect(tester.takeException(), isNull, reason: '$b $l $id');
            await tearDownScreen(tester);
          }
        }
      }
    });
  }

  testWidgets('360 x 640, read-only: scrolled to the end, the script ends '
      'above "হোমে ফিরুন" (never under the fixed button)', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await h.seedPending();
    // Not the contact: read-only, "হোমে ফিরুন" pinned at the bottom.
    await pumpScreen(tester, 'req_1', viewer: 'someone_else');
    expect(tester.takeException(), isNull);
    final home = find.byKey(const Key('approve_go_home'));
    expect(home, findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();
    final script = find.byKey(const Key('approve_script'));
    expect(script, findsOneWidget);
    expect(
      tester.getBottomLeft(script).dy,
      lessThanOrEqualTo(tester.getTopLeft(home).dy),
    );
    // The list's viewport itself ends above the pinned buttons.
    expect(
      tester.getRect(find.byType(ListView)).bottom,
      lessThanOrEqualTo(tester.getTopLeft(home).dy),
    );
    await tearDownScreen(tester);
  });
}
