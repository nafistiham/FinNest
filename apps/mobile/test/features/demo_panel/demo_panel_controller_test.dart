import 'package:bhorosha/app/appearance.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/demo_panel/logic/demo_panel_controller.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import 'demo_panel_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('flags', () {
    test('toggle writes the repo and the state follows', () async {
      final h = DemoPanelHarness();
      final c = await h.container();

      await ctl(c).toggle(DemoFlagNames.simSwap);
      await pumpEventQueue();

      expect(panel(c).demo.simSwap, isTrue);
      expect((await stored(c, 'rina')).simSwap, isTrue);
      expect(c.read(demoStateProvider).value?.simSwap, isTrue);

      await ctl(c).toggle(DemoFlagNames.simSwap);
      await pumpEventQueue();
      expect((await stored(c, 'rina')).simSwap, isFalse);
    });

    test('every flag name maps to its field; unknown names throw', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      for (final flag in DemoFlagNames.all) {
        await ctl(c).toggle(flag);
      }
      final d = panel(c).demo;
      expect(d.simSwap, isTrue);
      expect(d.callActive, isTrue);
      expect(d.screenShare, isTrue);
      expect(d.callerInContacts, isTrue);
      expect(() => ctl(c).toggle('bogus'), throwsArgumentError);
    });

    test(
      'an external write updates state.demo without losing the log',
      () async {
        final h = DemoPanelHarness();
        final c = await h.container();
        await ctl(c).replayScam();
        expect(panel(c).replayLog, isNotEmpty);

        await c
            .read(demoStateRepoProvider)
            .write('rina', const DemoState(screenShare: true));
        await pumpEventQueue();

        expect(panel(c).demo.screenShare, isTrue);
        expect(panel(c).replayLog, hasLength(3));
      },
    );

    test('forced verdict is stored and can be cleared', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).setForcedVerdict(SafetyVerdict.block);
      expect(
        (await stored(c, 'rina')).forcedSafetyVerdict,
        SafetyVerdict.block,
      );
      await ctl(c).setForcedVerdict(null);
      expect((await stored(c, 'rina')).forcedSafetyVerdict, isNull);
    });

    test(
      'integrity scenario is stored, can be cleared, rejects nothing',
      () async {
        final h = DemoPanelHarness();
        final c = await h.container();
        for (final scenario in IntegrityScenarios.all) {
          await ctl(c).setIntegrityScenario(scenario);
          expect(panel(c).demo.integrityScenario, scenario);
          expect((await stored(c, 'rina')).integrityScenario, scenario);
        }
        await ctl(c).setIntegrityScenario(IntegrityScenarios.moddedApp);
        await ctl(c).setIntegrityScenario(null);
        expect((await stored(c, 'rina')).integrityScenario, isNull);
        // The other fields survive the scenario writes.
        await ctl(c).toggle(DemoFlagNames.simSwap);
        await ctl(c).setIntegrityScenario(IntegrityScenarios.emulator);
        final d = await stored(c, 'rina');
        expect(d.simSwap, isTrue);
        expect(d.integrityScenario, IntegrityScenarios.emulator);
      },
    );

    test('rerunSafetyCheck posts /v1/appsafety/check again', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      await ctl(c).setIntegrityScenario(IntegrityScenarios.screenControlled);

      await ctl(c).rerunSafetyCheck();

      expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));
      expect(c.read(safetyControllerProvider).value, FakeRiskApi.safeDevice);
    });

    test('signed out, writes land on the default persona (Rina)', () async {
      final h = DemoPanelHarness();
      final c = await h.container(persona: null);
      await ctl(c).toggle(DemoFlagNames.callActive);
      expect(panel(c).demo.callActive, isTrue, reason: 'optimistic');
      expect((await stored(c, 'rina')).callActive, isTrue);
    });
  });

  group('replayScam', () {
    test('stores scam_score and the evidence quote, logs every turn', () async {
      final h = DemoPanelHarness();
      final c = await h.container();

      await ctl(c).replayScam();
      await pumpEventQueue();

      final s = panel(c);
      expect(s.replaying, isFalse);
      expect(s.error, isNull);
      expect(s.replayLog, hasLength(3), reason: 'three caller turns');
      expect(s.lastReplay?.rollingScore, 0.85);
      expect(s.lastServerMs, 42);
      expect(s.demo.scamScore, 0.85);
      expect((await stored(c, 'rina')).scamScore, 0.85);
      expect(c.read(lastEvidenceQuoteProvider), otpScam.evidenceQuote);

      final calls = h.api.callsTo(RiskRoutes.scamTurn).toList();
      expect(calls, hasLength(3));
      final first = calls.first.body as Map<String, dynamic>;
      expect(first['session_id'], c.read(sessionRepoProvider).sessionId);
      expect(first['pending_action'], 'send_money');
      expect(first['amount_bdt'], 5000.0);
    });

    test('a failure is reported and leaves scam_score alone', () async {
      final h = DemoPanelHarness();
      h.api.failures[RiskRoutes.scamTurn] = const NetworkFailure();
      final c = await h.container();

      await ctl(c).replayScam();

      final s = panel(c);
      expect(s.replaying, isFalse);
      expect(s.error, contains('NetworkFailure'));
      expect(s.replayLog, isEmpty);
      expect(s.demo.scamScore, 0.0);
      expect(c.read(lastEvidenceQuoteProvider), isNull);
    });

    test('is a no-op while a replay is in flight', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final release = h.api.hold(RiskRoutes.scamTurn);

      final first = ctl(c).replayScam();
      await pumpEventQueue();
      expect(panel(c).replaying, isTrue);
      await ctl(c).replayScam(); // ignored
      release();
      await first;

      expect(h.api.callsTo(RiskRoutes.scamTurn), hasLength(3));
    });
  });

  group('replayScam and a persona switch (F4)', () {
    test('the score is dropped when the persona changed mid-replay', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final release = h.api.hold(RiskRoutes.scamTurn);

      final replay = ctl(c).replayScam();
      await pumpEventQueue();
      expect(panel(c).replaying, isTrue);
      await c.read(authRepoProvider).signOut();
      await c.read(authRepoProvider).demoLogin(Persona.rahima);
      release();
      await replay;
      await pumpEventQueue();

      expect((await stored(c, 'rina')).scamScore, 0.0);
      expect((await stored(c, 'rahima')).scamScore, 0.0);
      expect(c.read(lastEvidenceQuoteProvider), isNull);
    });
  });

  group('videoPreset', () {
    test('turns call_active on before the replay starts', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final release = h.api.hold(RiskRoutes.scamTurn);

      final preset = ctl(c).videoPreset();
      await pumpEventQueue();

      // The flag is already written while the first scam call is held.
      expect(h.api.callsTo(RiskRoutes.scamTurn), hasLength(1));
      expect(panel(c).replaying, isTrue);
      expect(panel(c).demo.callActive, isTrue);
      expect((await stored(c, 'rina')).callActive, isTrue);

      release();
      await preset;
      final d = await stored(c, 'rina');
      expect(d.callActive, isTrue);
      expect(d.scamScore, 0.85);
      expect(c.read(lastEvidenceQuoteProvider), otpScam.evidenceQuote);
    });
  });

  group('setPersona', () {
    test(
      'signs in the other persona and resets every per-user handle',
      () async {
        final h = DemoPanelHarness();
        final c = await h.container();
        final ledger = c.read(ledgerRepoProvider);
        final session = c.read(sessionRepoProvider);
        final cooldown = c.read(cooldownProvider);

        // Rina's world: a flag, a replay, an armed cooldown, an in-session row.
        await ctl(c).toggle(DemoFlagNames.simSwap);
        await ctl(c).replayScam();
        cooldown.arm('call_active', 60);
        final seeded = (await ledger.watchRecent('rina').first).length;
        await ledger.create(
          'rina',
          LedgerTxn(
            txnId: 'txn-held-1',
            ts: h.clock.now(),
            type: 'send_money',
            amountBdt: 5000,
            fromAcct: 'acct_rina',
            toAcct: 'acct_x',
            status: LedgerStatus.held,
          ),
        );
        expect((await ledger.watchRecent('rina').first).length, seeded + 1);
        final before = session.sessionId;
        // Demo builds speak on every hold (alwaysSpeak), so the armed window
        // is checked directly.
        expect(cooldown.until('call_active'), isNotNull);
        expect(c.read(lastEvidenceQuoteProvider), isNotNull);
        final gen = c.read(riskSessionProvider);

        await ctl(c).setPersona(Persona.rahima);
        await pumpEventQueue();

        expect(c.read(authRepoProvider).current?.uid, 'rahima');
        expect(c.read(currentUserProvider).value?.persona, Persona.rahima);
        expect(session.sessionId, isNot(before), reason: 'session id rotated');
        expect(cooldown.until('call_active'), isNull, reason: 'cooldown');
        expect(c.read(lastEvidenceQuoteProvider), isNull, reason: 'evidence');
        expect(
          c.read(riskSessionProvider),
          gen + 1,
          reason: 'risk session reset',
        );
        expect(panel(c).replayLog, isEmpty);
        expect(panel(c).error, isNull);
        // Rahima's world is her own document, not Rina's.
        expect(panel(c).demo.simSwap, isFalse);
        expect(panel(c).demo.scamScore, 0.0);
        expect(c.read(demoStateProvider).value, DemoState.initial);
        // Rina's in-session ledger row is gone.
        expect((await ledger.watchRecent('rina').first).length, seeded);
        // Rina's flag was persisted, not wiped: switching back finds it.
        expect((await stored(c, 'rina')).simSwap, isTrue);
      },
    );
  });

  group('resets', () {
    test('resetCooldown clears armed windows only', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final cooldown = c.read(cooldownProvider);
      await ctl(c).toggle(DemoFlagNames.callActive);
      cooldown.arm('call_active', 60);

      ctl(c).resetCooldown();

      expect(cooldown.shouldSpeak('call_active'), isTrue);
      expect(panel(c).demo.callActive, isTrue, reason: 'flags untouched');
    });

    test(
      'resetAll restores DemoState.initial and clears the session',
      () async {
        final h = DemoPanelHarness();
        final c = await h.container();
        await ctl(c).toggle(DemoFlagNames.simSwap);
        await ctl(c).setForcedVerdict(SafetyVerdict.caution);
        await ctl(c).setIntegrityScenario(IntegrityScenarios.unbound);
        await ctl(c).replayScam();
        c.read(cooldownProvider).arm('sim_swap', 60);
        expect(
          (await stored(c, 'rina')).integrityScenario,
          IntegrityScenarios.unbound,
        );
        expect(c.read(lastEvidenceQuoteProvider), isNotNull);

        await ctl(c).resetAll();
        await pumpEventQueue();

        expect(panel(c).demo, DemoState.initial);
        expect(await stored(c, 'rina'), DemoState.initial);
        expect((await stored(c, 'rina')).integrityScenario, isNull);
        expect(c.read(demoStateProvider).value, DemoState.initial);
        expect(panel(c).replayLog, isEmpty);
        expect(c.read(lastEvidenceQuoteProvider), isNull);
        expect(c.read(cooldownProvider).shouldSpeak('sim_swap'), isTrue);
      },
    );
  });

  group('checkHealth', () {
    test('records the dot and the server timing', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      expect(panel(c).healthy, isNull);

      await ctl(c).checkHealth();
      expect(panel(c).healthy, isTrue);
      expect(panel(c).lastServerMs, 42);

      h.api.healthy = false;
      await ctl(c).checkHealth();
      expect(panel(c).healthy, isFalse);
    });
  });

  group('confirmCashIn', () {
    LedgerTxn cashIn(String id, double amount, DateTime ts) => LedgerTxn(
      txnId: id,
      ts: ts,
      type: 'cash_in',
      amountBdt: amount,
      fromAcct: 'cashin_BH-4K7Q',
      toAcct: 'acct_rina',
      channel: 'agent',
      status: LedgerStatus.requested,
      counterpartyNameBn: 'এজেন্ট ক্যাশ ইন',
    );

    test(
      'flips the newest waiting cash in to done and raises the balance',
      () async {
        final h = DemoPanelHarness();
        final c = await h.container();
        final ledger = c.read(ledgerRepoProvider);
        final before = await ledger.watchBalance('rina').first;
        final now = DateTime.now();
        await ledger.create(
          'rina',
          cashIn('txn_old', 500, now.subtract(const Duration(minutes: 2))),
        );
        await ledger.create('rina', cashIn('txn_new', 1000, now));

        final row = await ctl(c).confirmCashIn();
        await pumpEventQueue();

        expect(row?.txnId, 'txn_new');
        final rows = await ledger.watchRecent('rina').first;
        expect(rows.firstWhere((t) => t.txnId == 'txn_new').status, 'done');
        expect(
          rows.firstWhere((t) => t.txnId == 'txn_old').status,
          LedgerStatus.requested,
        );
        expect(await ledger.watchBalance('rina').first, before + 1000);
      },
    );

    test('nothing waiting: null, nothing changes', () async {
      final h = DemoPanelHarness();
      final c = await h.container();
      final ledger = c.read(ledgerRepoProvider);
      final before = await ledger.watchBalance('rina').first;
      expect(await ctl(c).confirmCashIn(), isNull);
      expect(await ledger.watchBalance('rina').first, before);
      expect(panel(c).error, isNull);
    });

    test('signed out: null', () async {
      final h = DemoPanelHarness();
      final c = await h.container(persona: null);
      expect(await ctl(c).confirmCashIn(), isNull);
    });
  });

  test('resetAll also puts the appearance back to the defaults', () async {
    final h = DemoPanelHarness();
    final c = await h.container();
    await c.read(themePresetProvider.notifier).set(BhPreset.values.last);
    await c.read(themeModeProvider.notifier).set(ThemeMode.dark);
    await ctl(c).resetAll();
    await pumpEventQueue();
    expect(c.read(themePresetProvider), Appearance.defaults.preset);
    expect(c.read(themeModeProvider), Appearance.defaults.mode);
  });
}
