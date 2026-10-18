import 'dart:io';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/animated/rolling_amount.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/risk/trigger.dart';
import 'package:bhorosha/features/intervention/ui/intervention_banner.dart';
import 'package:bhorosha/features/pay/logic/billers.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:bhorosha/features/pin_pad/ui/pin_pad_screen.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../intervention/intervention_fakes.dart';
import '../pay/pay_test_support.dart';

/// Opens the result of [kind] with that kind's counterparty in the
/// controller, as the PIN pad leaves it.
Future<ProviderContainer> openResult(
  WidgetTester tester, {
  PayKind kind = PayKind.send,
  String state = 'done',
  int? amount = 5000,
  String? txn = 'txn_0123456789abcdef',
  ScreenHarness? harness,
  List<Override> extraOverrides = const [],
}) async {
  final h = harness ?? ScreenHarness();
  final c = await pumpPay(
    tester,
    harness: h,
    location: PayPaths.start(kind),
    extraOverrides: extraOverrides,
  );
  final ctl = c.read(payControllerProvider.notifier);
  switch (kind) {
    case PayKind.send:
      ctl.selectPayee(
        const Payee(
          acctId: 'acct_rahima',
          nameBn: 'মা',
          phoneMasked: '019XXXXX881',
        ),
      );
    case PayKind.cashOut:
      ctl.selectCounterparty(
        const Counterparty(
          acctId: 'AG-0027',
          nameBn: 'এজেন্ট',
          subtitle: '017XXXXX027',
        ),
      );
    case PayKind.recharge:
      ctl
        ..setOperator(Operator.a)
        ..selectCounterparty(
          const Counterparty(
            acctId: 'mob_017XXXXX412',
            nameBn: 'রিনা',
            subtitle: '017XXXXX412',
          ),
        );
    case PayKind.bill:
      ctl.setBill(
        Bill(
          biller: BillerCatalog.parse(
            File(BillerCatalog.path).readAsStringSync(),
          ).first,
          account: '12345678',
        ),
      );
    case PayKind.dps:
      ctl.beginDps(monthlyBdt: 500, tenureMonths: 36);
    case PayKind.cashIn:
      break;
  }
  routerOf(c).go(PayPaths.result(kind, state: state, amount: amount, txn: txn));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  BhPalette palette(WidgetTester tester) =>
      tester.element(find.byKey(const Key('result_icon'))).palette;

  Color squareColor(WidgetTester tester) =>
      (tester.widget<Container>(find.byKey(const Key('result_icon'))).color)!;

  testWidgets('done (send): tick square, title, amount, counterparty, time, '
      'new balance and reference; Home in the thumb zone', (tester) async {
    final c = await openResult(tester);
    expect(find.text('টাকা পাঠানো হয়েছে'), findsOneWidget);
    expect(
      tester
          .widget<RollingAmount>(find.byKey(const Key('result_amount')))
          .amount,
      5000,
    );
    expect(find.text('মা · ০১৯XX-XXX৮৮১'), findsOneWidget);
    expect(find.textContaining('আজ, '), findsOneWidget);
    expect(find.byKey(const Key('result_tick')), findsOneWidget);
    expect(squareColor(tester), palette(tester).successContainer);
    expect(find.text('নতুন ব্যালেন্স'), findsOneWidget);
    expect(find.text('৳ ৯,৮৪১'), findsOneWidget);
    expect(find.text('রেফারেন্স'), findsOneWidget);
    expect(find.text('ABCDEF'), findsOneWidget);

    final home = find.byKey(const Key('result_home'));
    expect(tester.getSize(home).height, greaterThanOrEqualTo(BhSize.touch));
    await tester.tap(home);
    await tester.pumpAndSettle();
    expect(find.byType(FakeHome), findsOneWidget);
    expect(locationOf(c), PayPaths.home);
  });

  testWidgets('system back from the result goes Home', (tester) async {
    final c = await openResult(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(locationOf(c), PayPaths.home);
  });

  for (final (kind, title, line) in [
    (PayKind.cashOut, 'ক্যাশ আউট হয়েছে', 'এজেন্ট · ০১৭XX-XXX০২৭'),
    (PayKind.recharge, 'রিচার্জ হয়েছে', '০১৭XX-XXX৪১২ · অপারেটর ক'),
    (PayKind.bill, 'বিল দেওয়া হয়েছে', 'ডেসকো বিদ্যুৎ বিল · ১২৩৪ ৫৬৭৮'),
  ]) {
    testWidgets('done (${kind.slug}): "$title" with its counterparty line', (
      tester,
    ) async {
      await openResult(tester, kind: kind);
      expect(find.text(title), findsOneWidget);
      expect(find.text(line), findsOneWidget);
      if (kind == PayKind.cashOut) {
        expect(find.text('এজেন্টের কাছ থেকে টাকা নিন'), findsOneWidget);
      }
    });
  }

  testWidgets('English: kind title and digits follow the language', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.start(PayKind.recharge),
      locale: const Locale('en'),
    );
    c.read(payControllerProvider.notifier)
      ..setOperator(Operator.b)
      ..selectCounterparty(
        const Counterparty(
          acctId: 'mob_01812345678',
          nameBn: '01812-345678',
          subtitle: '01812345678',
        ),
      );
    routerOf(c)
        .go(PayPaths.result(PayKind.recharge, state: 'done', amount: 100));
    await tester.pumpAndSettle();
    expect(find.text('Recharge done'), findsOneWidget);
    expect(find.text('01812-345678 · Operator B'), findsOneWidget);
  });

  testWidgets('held: amber hourglass, body line, server reasons as plain '
      'lines, ask Apa beside Home', (tester) async {
    await openResult(
      tester,
      state: 'held',
      amount: 7900,
      extraOverrides: [lastScoreProvider.overrideWith((_) => holdScore())],
    );
    expect(find.text('আপনার টাকা নিরাপদে আটকে আছে'), findsOneWidget);
    expect(find.text(reasonScam.textBn), findsOneWidget);
    expect(find.text(reasonCall.textBn), findsOneWidget);
    expect(squareColor(tester), palette(tester).warningContainer);
    expect(
      find.text(
        'টাকা আপনার অ্যাকাউন্টেই আছে, কোথাও যায়নি। '
        'কী করবেন জানতে ফিননেস্ট সহকারীকে জিজ্ঞাসা করুন।',
      ),
      findsOneWidget,
    );
    expect(find.text('নতুন ব্যালেন্স'), findsNothing);
    expect(find.byKey(const Key('apa_button_result')), findsOneWidget);
  });

  testWidgets('blocked: red, with a way to the phone-safety findings', (
    tester,
  ) async {
    final c = await openResult(tester, state: 'blocked');
    expect(find.text('লেনদেন বাতিল করা হয়েছে'), findsOneWidget);
    expect(squareColor(tester), palette(tester).dangerContainer);
    await tester.tap(find.byKey(const Key('result_safety')));
    await tester.pumpAndSettle();
    expect(locationOf(c), '/safety?block=1');
  });

  testWidgets('unavailable: neutral, body line, retry returns to that '
      "kind's PIN pad", (tester) async {
    final c = await openResult(
      tester,
      kind: PayKind.cashOut,
      state: 'unavailable',
    );
    expect(find.text('এখন যাচাই করা যাচ্ছে না'), findsOneWidget);
    expect(find.textContaining('আপনার টাকা কোথাও যায়নি'), findsOneWidget);
    expect(squareColor(tester), palette(tester).surfaceVariant);
    await tester.tap(find.byKey(const Key('result_retry')));
    await tester.pumpAndSettle();
    expect(find.byType(PinPadScreen), findsOneWidget);
    expect(locationOf(c), PayPaths.pin(PayKind.cashOut));
  });

  testWidgets('held with banner=1 shows the intervention banner', (
    tester,
  ) async {
    final h = ScreenHarness();
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.send,
      extraOverrides: [lastScoreProvider.overrideWith((_) => delayScore)],
    );
    routerOf(c).go(PayPaths.result(PayKind.send, state: 'held', banner: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intervention_banner')), findsOneWidget);
    expect(find.text('লেনদেন দেরি হবে'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('banner_dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intervention_banner')), findsNothing);
  });

  testWidgets('delay banner sits in the list above the bottom bar; its '
      'trusted-contact action runs the request flow', (tester) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    await tester.runAsync(() async {
      await c
          .read(interventionRepoProvider)
          .upsert(
            InterventionRecord(
              id: 'int_delay',
              uid: 'rina',
              txnId: 'txn_delay',
              trigger: 'new_payee_high_amount',
              scriptBn: '',
              reasons: delayScore.reasons,
              actions: delayScore.actions,
              status: InterventionStatus.open,
              // Fixed: nothing on the result reads the record's clock.
              createdAt: DateTime.utc(2026, 10, 17, 6),
            ),
          );
    });
    c.read(lastScoreProvider.notifier).state = delayScore;
    routerOf(c).go(
      PayPaths.result(
        PayKind.send,
        state: 'held',
        amount: 7900,
        banner: true,
        intervention: 'int_delay',
      ),
    );
    await tester.pumpAndSettle();
    // The record lookup reads the local store (real async).
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final banner = find.byKey(const ValueKey('intervention_banner'));
    expect(banner, findsOneWidget);
    expect(
      find.descendant(of: find.byType(ListView), matching: banner),
      findsOneWidget,
    );
    final home = tester.getRect(find.byKey(const Key('result_home')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('action_trusted_contact_check')),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(banner).overlaps(home), isFalse);

    await tester.tap(
      find.byKey(const ValueKey('action_trusted_contact_check')),
    );
    await tester.pumpAndSettle();
    final call =
        h.api.callsTo(RiskRoutes.trustedContact).single.body!
            as Map<String, dynamic>;
    expect(call['intervention_id'], 'int_delay');
    expect(call['contact_uid'], 'rafiq');
    expect(find.byKey(const ValueKey('trusted_request_sent')), findsOneWidget);
    final records = await tester.runAsync(
      () => c.read(interventionRepoProvider).watch('rina').first,
    );
    final record = records!.singleWhere((r) => r.id == 'int_delay');
    expect(record.status, InterventionStatus.pending);
  });

  testWidgets('delay banner takes the stored record: its script, reasons, '
      'served clip and the trigger\'s predicted clip', (tester) async {
    final h = ScreenHarness();
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    await tester.runAsync(() async {
      await c
          .read(interventionRepoProvider)
          .upsert(
            InterventionRecord(
              id: 'int_script',
              uid: 'rina',
              txnId: 'txn_script',
              trigger: 'new_payee_high_amount',
              scriptBn: 'সংরক্ষিত স্ক্রিপ্ট',
              scriptEn: 'Stored script',
              reasons: delayScore.reasons,
              actions: delayScore.actions,
              status: InterventionStatus.open,
              createdAt: DateTime.utc(2026, 10, 17, 6),
              audioAssetId: 'apa_served_clip',
            ),
          );
    });
    c.read(lastScoreProvider.notifier).state = delayScore;
    routerOf(c).go(
      PayPaths.result(
        PayKind.send,
        state: 'held',
        amount: 7900,
        banner: true,
        intervention: 'int_script',
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final banner = tester.widget<InterventionBanner>(
      find.byType(InterventionBanner),
    );
    expect(banner.script, 'সংরক্ষিত স্ক্রিপ্ট');
    expect(banner.reasons, delayScore.reasons);
    expect(banner.servedClip?.assetId, 'apa_served_clip');
    expect(banner.servedClip?.scriptBn, 'সংরক্ষিত স্ক্রিপ্ট');
    expect(
      banner.predictedAsset,
      Triggers.predictedAsset('new_payee_high_amount'),
    );
    expect(banner.trustedBusy, isFalse);
    expect(find.text('সংরক্ষিত স্ক্রিপ্ট'), findsOneWidget);
  });

  testWidgets('dark mode: dark containers, not light pastel', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await openResult(tester);
    final p = palette(tester);
    expect(p.isDark, isTrue);
    expect(squareColor(tester), p.successContainer);
    expect(p.successContainer.computeLuminance(), lessThan(0.2));
  });

  for (final locale in ['bn', 'en']) {
    testWidgets('reference is the last six characters as an ASCII code, never '
        'localised digits ($locale)', (tester) async {
      await openResult(
        tester,
        txn: 'txn_9f3a2c464c1',
        extraOverrides: [
          initialLocaleProvider.overrideWithValue(Locale(locale)),
        ],
      );
      final row = find.byKey(const Key('result_reference'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('C464C1')),
        findsOneWidget,
      );
      expect(find.textContaining('৪৬৪'), findsNothing);
      expect(find.textContaining('…'), findsNothing);
    });
  }

  test('referenceCode: last six letters and digits, uppercased ASCII', () {
    expect(referenceCode('txn_9f3a2c464c1'), 'C464C1');
    expect(referenceCode('txn_9f3a2c৪৬৪c১'), 'C464C1');
    expect(referenceCode('demo-request-1'), 'QUEST1');
    expect(referenceCode('t1'), 'T1');
    expect(referenceCode('--'), '');
  });

  // The App Safety Check said CAUTION, which allows the
  // payment. The money went, so there is no overlay; the server's own reason
  // text (FR-3) sits in an amber note, and the bottom bar offers the phone
  // safety page.
  group('done with an App Safety CAUTION', () {
    const caution = Reason(
      code: 'APP_SAFETY_CAUTION',
      weight: 0.5,
      textBn: 'আপনার ফোনে একটি সন্দেহজনক অ্যাপ পাওয়া গেছে। ফোনের নিরাপত্তা দেখে নিন।',
      textEn: 'A suspicious app was found on your phone. Check the phone safety page.',
    );
    const allowed = ScoreResponse(
      decision: Decision.allow,
      riskScore: 0.5,
      band: Band.medium,
      reasons: [caution],
      actions: [],
      modelVersion: 'rules-v1',
    );

    testWidgets('an amber note with the server text and a way to safety', (
      tester,
    ) async {
      final c = await openResult(
        tester,
        extraOverrides: [lastScoreProvider.overrideWith((_) => allowed)],
      );
      final note = find.byKey(const Key('result_caution'));
      expect(note, findsOneWidget);
      expect(
        find.descendant(of: note, matching: find.text(caution.textBn)),
        findsOneWidget,
      );
      final frame = tester.widget<Container>(note);
      expect(
        (frame.decoration! as BoxDecoration).color,
        tester.element(note).palette.warningContainer,
      );
      // The money went: still the green done square, never a hold.
      expect(squareColor(tester), palette(tester).successContainer);
      await tester.tap(find.byKey(const Key('result_caution_safety')));
      await tester.pumpAndSettle();
      expect(locationOf(c), '/safety');
    });

    testWidgets('English shows the server text in English', (tester) async {
      final c = await pumpPay(
        tester,
        harness: ScreenHarness(),
        location: PayPaths.start(PayKind.send),
        locale: const Locale('en'),
        extraOverrides: [lastScoreProvider.overrideWith((_) => allowed)],
      );
      routerOf(c).go(PayPaths.result(PayKind.send, state: 'done', amount: 500));
      await tester.pumpAndSettle();
      expect(find.text(caution.textEn), findsOneWidget);
      expect(find.text(caution.textBn), findsNothing);
    });

    testWidgets('no CAUTION, no note and no safety button', (tester) async {
      await openResult(tester);
      expect(find.byKey(const Key('result_caution')), findsNothing);
      expect(find.byKey(const Key('result_caution_safety')), findsNothing);
    });
  });
}
