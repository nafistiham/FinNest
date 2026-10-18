// The demo panel's "আচরণ" and "গল্প" sections (1.3, 1.13).

import 'dart:io';

import 'package:bhorosha/app/router.dart' show Routes;
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/domain/behaviour/behaviour_replay.dart';
import 'package:bhorosha/domain/behaviour/enrolment_store.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:bhorosha/features/demo_panel/logic/demo_panel_controller.dart';
import 'package:bhorosha/features/demo_panel/ui/demo_panel_sheet.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_panel_test_support.dart';

const _user = UserProfile(
  uid: 'rina',
  nameBn: 'রিনা',
  nameEn: 'Rina',
  phoneMasked: '017*****412',
  persona: Persona.rina,
  trustedContactUid: 'rafiq',
  p95SendBdt: 5000,
  acctId: 'acct_rina',
  balanceBdt: 9841,
);

final _live = [for (var i = 0; i < FeatureNames.count; i++) i + 1.0];

EnrolmentRow _row(int n) => EnrolmentRow(
  sessionId: 's$n',
  ts: DateTime.utc(2026, 10, 17, 9, n),
  persona: 'rina',
  features: List<double>.filled(FeatureNames.count, 1),
);

Finder _segment(String label) => find.descendant(
  of: find.byKey(DemoPanelBody.behaviourModeKey),
  matching: find.text(label),
);

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('controller', () {
    test('"প্রাপক সন্দেহভাজন": behaviour off, every flag off, verdict and '
        'integrity automatic, no scam score', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).setFlag(DemoFlagNames.callActive, true);
      await ctl(c).setFlag(DemoFlagNames.simSwap, true);
      await ctl(c).setForcedVerdict(SafetyVerdict.block);
      await ctl(c).setIntegrityScenario(IntegrityScenarios.emulator);

      await ctl(c).storySuspectPayee();
      expect(c.read(behaviourModeProvider), BehaviourMode.off);
      final d = panel(c).demo;
      expect(d.callActive || d.simSwap || d.screenShare, isFalse);
      expect(d.callerInContacts, isFalse);
      expect(d.forcedSafetyVerdict, isNull);
      expect(d.integrityScenario, isNull);
      expect(d.scamScore, 0);
      expect((await stored(c, 'rina')).callActive, isFalse);
    });

    test(
      '"প্রাপক সন্দেহভাজন" then a transfer: no behaviour block is sent',
      () async {
        final h = DemoPanelHarness();
        final c = await h.container();
        await ctl(c).storySuspectPayee();
        await c
            .read(riskFlowProvider)
            .scoreTransfer(
              user: _user,
              sessionId: 'sess',
              txn: const Txn(
                type: TxnType.sendMoney,
                amountBdt: 500,
                toAccount: DemoPanelController.suspectPayeeAcct,
              ),
              features: List<double>.filled(FeatureNames.count, 1),
              demo: panel(c).demo,
              mode: c.read(behaviourModeProvider),
            );
        final body =
            h.api.callsTo(RiskRoutes.signals).single.body!
                as Map<String, dynamic>;
        expect(body.containsKey('behaviour'), isFalse);
      },
    );

    test('"অন্য কেউ ফোন চালাচ্ছে" sets the stranger replay; a persona switch '
        'puts it back to the start mode (live by default)', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).storyStranger();
      ctl(c).setEnrolling(true);
      expect(c.read(behaviourModeProvider), BehaviourMode.replayStranger);

      await ctl(c).setPersona(Persona.rahima);
      await pumpEventQueue();
      expect(c.read(behaviourModeProvider), BehaviourMode.live);
      expect(c.read(behaviourEnrollingProvider), isFalse);
    });

    test('each behaviour story sets its replay mode', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final stories = <BehaviourMode, Future<void> Function()>{
        BehaviourMode.replayStranger: ctl(c).storyStranger,
        BehaviourMode.replayTapPattern: ctl(c).storyTapPattern,
        BehaviourMode.replayShaking: ctl(c).storyShaking,
        BehaviourMode.replayCoached: ctl(c).storyCoached,
      };
      for (final MapEntry(key: mode, value: story) in stories.entries) {
        await story();
        expect(c.read(behaviourModeProvider), mode);
      }
    });

    test('tap pattern and shaking leave the call flag alone', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).storyTapPattern();
      await ctl(c).storyShaking();
      expect(panel(c).demo.callActive, isFalse);
      // A call the presenter switched on is not a story's to switch off.
      await ctl(c).setFlag(DemoFlagNames.callActive, true);
      await ctl(c).storyTapPattern();
      expect(panel(c).demo.callActive, isTrue);
    });

    test('"কেউ বলে দিচ্ছে" switches the call on (the server holds on coaching '
        'only in a call); another story switches it off again', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).storyCoached();
      expect(c.read(behaviourModeProvider), BehaviourMode.replayCoached);
      expect(panel(c).demo.callActive, isTrue);
      expect((await stored(c, 'rina')).callActive, isTrue);

      for (final next in [
        ctl(c).storyStranger,
        ctl(c).storyTapPattern,
        ctl(c).storyShaking,
        ctl(c).storySuspectPayee,
      ]) {
        await ctl(c).storyCoached();
        expect(panel(c).demo.callActive, isTrue);
        await next();
        expect(panel(c).demo.callActive, isFalse);
        expect((await stored(c, 'rina')).callActive, isFalse);
      }
    });

    test('"কেউ বলে দিচ্ছে" then a reset: the call is off', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).storyCoached();
      await ctl(c).resetAll();
      expect(panel(c).demo.callActive, isFalse);
      expect((await stored(c, 'rina')).callActive, isFalse);
      // The reset forgot the story: a later story does not touch a call the
      // presenter switched on.
      await ctl(c).setFlag(DemoFlagNames.callActive, true);
      await ctl(c).storyShaking();
      expect(panel(c).demo.callActive, isTrue);
    });

    test('"কেউ বলে দিচ্ছে" then a transfer: the coached vector and the call '
        'reach the server', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).storyCoached();
      DemoFlags? flags;
      await c
          .read(riskFlowProvider)
          .scoreTransfer(
            user: _user,
            sessionId: 'sess',
            txn: const Txn(
              type: TxnType.sendMoney,
              amountBdt: 500,
              toAccount: 'acct_x',
            ),
            features: _live,
            demo: panel(c).demo,
            mode: c.read(behaviourModeProvider),
            onFlags: (f) => flags = f,
          );
      final body =
          h.api.callsTo(RiskRoutes.signals).single.body!
              as Map<String, dynamic>;
      final sent = [
        for (final v in (body['behaviour'] as Map)['features'] as List)
          (v as num).toDouble(),
      ];
      final enrolled = await c.read(enrolmentStoreProvider).last('rina');
      expect(sent, BehaviourReplay.coached(enrolled?.features ?? _live));
      expect(flags?.callActive, isTrue);
    });

    test('the behaviour mode is not part of the synced demo state', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final before = await stored(c, 'rina');
      ctl(c).setBehaviourMode(BehaviourMode.off);
      expect(await stored(c, 'rina'), before);
    });

    test('export writes the persona file; clear empties it', () async {
      final dir = Directory.systemTemp.createTempSync('demo_enrol');
      addTearDown(() => dir.deleteSync(recursive: true));
      final h = DemoPanelHarness();
      SharedPreferences.setMockInitialValues({});
      final store = EnrolmentStore(exportDir: () async => dir);
      final c = ProviderContainer(
        overrides: [
          ...h.overrides,
          enrolmentStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      c.listen(currentUserProvider, (_, _) {});
      await c.read(authRepoProvider).demoLogin(Persona.rina);
      await pumpEventQueue();
      await store.append(_row(1));
      final file = await ctl(c).exportEnrolment();
      expect(file!.path, endsWith('rina_phone_sessions.jsonl'));
      expect(file.readAsLinesSync(), hasLength(1));
      await ctl(c).clearEnrolment();
      expect(await store.rows('rina'), isEmpty);
    });
  });

  group('sheet', () {
    testWidgets('both sections render with every control and note', (
      tester,
    ) async {
      final h = DemoPanelHarness();
      await pumpDemo(
        tester,
        harness: h,
        child: const Scaffold(body: DemoPanelBody()),
      );
      for (final t in [
        'গল্প',
        'প্রাপক সন্দেহভাজন',
        'অন্য কেউ ফোন চালাচ্ছে',
        'হাত কাঁপছে',
        'কেউ বলে দিচ্ছে',
        'তদন্ত দেখুন',
        'আচরণ',
        'নথিভুক্ত করা হচ্ছে',
        'ফাইলে লিখুন',
        'মুছুন',
      ]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      for (final t in [
        'লাইভ',
        'বন্ধ',
        'অন্য কেউ',
        'ট্যাপের ধরন বদলে গেছে',
        'হাত কাঁপছে, ফোন অন্যভাবে ধরা',
        'কেউ বলে দিচ্ছে: ধীরে, থেমে থেমে টাইপ',
      ]) {
        expect(_segment(t), findsOneWidget, reason: t);
      }
      // The story and the mode share this label.
      expect(
        find.descendant(
          of: find.byKey(DemoPanelBody.storyTapPatternKey),
          matching: find.text('ট্যাপের ধরন বদলে গেছে'),
        ),
        findsOneWidget,
      );
      for (final m in BehaviourMode.values) {
        expect(
          find.byKey(DemoPanelBody.behaviourModeOptionKey(m)),
          findsOneWidget,
          reason: m.name,
        );
      }
      expect(find.text('নথিভুক্ত সেশন: ০'), findsOneWidget);
      expect(
        find.textContaining('ডেমো: এই গল্পে সার্ভার যা দেখবে:'),
        findsNWidgets(6),
      );
      // The new notes: plain words, the reason, the simulated tag.
      expect(
        find.textContaining('ট্যাপ যেখানে পড়ছে আর কতটা জোরে'),
        findsOneWidget,
      );
      expect(find.textContaining('ফোন কতটা নড়ছে'), findsOneWidget);
      expect(find.textContaining('পিন টাইপের গতি আর বিরতি'), findsOneWidget);
      expect(find.textContaining('কলও চালু করা হলো'), findsOneWidget);
      expect(find.textContaining('আচরণ মালিকের সাথে মেলেনি'), findsNWidgets(3));
      expect(find.textContaining('কেউ বলে দিচ্ছে বলে সন্দেহ'), findsOneWidget);
      expect(
        find.textContaining('রেকর্ডে "সিমুলেটেড" লেখা থাকবে।'),
        findsNWidgets(3),
      );
    });

    testWidgets('stories set the state and navigate: the send flow with the '
        'payee, then the fraud desk', (tester) async {
      final h = DemoPanelHarness();
      final went = <String>[];
      final c = await pumpDemo(
        tester,
        harness: h,
        child: Scaffold(body: DemoPanelBody(navigate: went.add)),
      );
      await _tap(tester, find.byKey(DemoPanelBody.storySuspectKey));
      expect(c.read(behaviourModeProvider), BehaviourMode.off);
      expect(went, ['/pay/send?payee=acct_01070']);

      await _tap(tester, find.byKey(DemoPanelBody.storyStrangerKey));
      expect(c.read(behaviourModeProvider), BehaviourMode.replayStranger);
      expect(went, hasLength(1), reason: 'the stranger story stays here');

      await _tap(tester, find.byKey(DemoPanelBody.storyTapPatternKey));
      expect(c.read(behaviourModeProvider), BehaviourMode.replayTapPattern);

      await _tap(tester, find.byKey(DemoPanelBody.storyShakingKey));
      expect(c.read(behaviourModeProvider), BehaviourMode.replayShaking);

      await _tap(tester, find.byKey(DemoPanelBody.storyCoachedKey));
      expect(c.read(behaviourModeProvider), BehaviourMode.replayCoached);
      expect(c.read(demoPanelControllerProvider).demo.callActive, isTrue);
      expect(went, hasLength(1), reason: 'the behaviour stories stay here');

      await _tap(tester, find.byKey(DemoPanelBody.storyStrangerKey));
      expect(c.read(demoPanelControllerProvider).demo.callActive, isFalse);

      await _tap(tester, find.byKey(DemoPanelBody.storyInvestigationKey));
      expect(went.last, Routes.fraudDesk);
    });

    testWidgets('the mode segments and the enrolment switch drive the '
        'session providers', (tester) async {
      final h = DemoPanelHarness();
      final c = await pumpDemo(
        tester,
        harness: h,
        child: const Scaffold(body: DemoPanelBody()),
      );
      await _tap(tester, _segment('অন্য কেউ'));
      expect(c.read(behaviourModeProvider), BehaviourMode.replayStranger);
      await _tap(tester, _segment('বন্ধ'));
      expect(c.read(behaviourModeProvider), BehaviourMode.off);
      for (final m in BehaviourMode.values) {
        await _tap(tester, find.byKey(DemoPanelBody.behaviourModeOptionKey(m)));
        expect(c.read(behaviourModeProvider), m);
      }
      await _tap(tester, find.byKey(DemoPanelBody.enrolToggleKey));
      expect(c.read(behaviourEnrollingProvider), isTrue);
    });

    testWidgets('"ফাইলে লিখুন" shows the path in a snackbar', (tester) async {
      final dir = Directory.systemTemp.createTempSync('demo_enrol_ui');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = EnrolmentStore(exportDir: () async => dir);
      final h = DemoPanelHarness();
      await pumpDemo(
        tester,
        harness: h,
        extraOverrides: [enrolmentStoreProvider.overrideWithValue(store)],
        child: const Scaffold(body: DemoPanelBody()),
      );
      final export = find.byKey(DemoPanelBody.enrolExportKey);
      await tester.ensureVisible(export);
      await tester.pumpAndSettle();
      // The file write is real I/O: let it finish outside the fake zone.
      await tester.runAsync(() async {
        await tester.tap(export);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('ফাইলে লেখা হয়েছে: ${dir.path}/rina_phone_sessions.jsonl'),
        findsOneWidget,
      );
    });
  });
}
