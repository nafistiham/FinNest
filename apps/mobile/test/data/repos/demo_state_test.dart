import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DemoState', () {
    test('toDoc uses the Firestore snake_case keys', () {
      const s = DemoState(
        simSwap: true,
        callActive: true,
        screenShare: false,
        callerInContacts: true,
        persona: Persona.rahima,
        forcedSafetyVerdict: SafetyVerdict.block,
        scamScore: 0.85,
        integrityScenario: 'MEETS_VIRTUAL_INTEGRITY',
      );
      expect(s.toDoc(), {
        'sim_swap': true,
        'call_active': true,
        'screen_share': false,
        'caller_in_contacts': true,
        'persona': 'rahima',
        'forced_safety_verdict': 'BLOCK',
        'scam_score': 0.85,
        'integrity_scenario': 'MEETS_VIRTUAL_INTEGRITY',
        'inbound_mule_score': 0.0,
      });
    });

    test('fromDoc(toDoc()) round-trips, including nulls', () {
      const full = DemoState(
        simSwap: true,
        persona: Persona.rina,
        forcedSafetyVerdict: SafetyVerdict.caution,
        scamScore: 0.4,
        integrityScenario: 'unbound',
      );
      expect(DemoState.fromDoc(full.toDoc()), full);
      expect(DemoState.initial.integrityScenario, isNull);
      expect(DemoState.fromDoc(DemoState.initial.toDoc()), DemoState.initial);
      expect(DemoState.fromDoc(const {}), DemoState.initial);
    });

    test('copyWith clears nullable fields only when asked', () {
      const s = DemoState(
        persona: Persona.rina,
        forcedSafetyVerdict: SafetyVerdict.block,
      );
      expect(
        s.copyWith(simSwap: true).forcedSafetyVerdict,
        SafetyVerdict.block,
      );
      expect(s.copyWith(forcedSafetyVerdict: null).forcedSafetyVerdict, isNull);
      expect(s.copyWith(persona: null).persona, isNull);

      const withScenario = DemoState(integrityScenario: 'UNKNOWN_CONTROLLING');
      expect(
        withScenario.copyWith(simSwap: true).integrityScenario,
        'UNKNOWN_CONTROLLING',
      );
      expect(
        withScenario.copyWith(integrityScenario: null).integrityScenario,
        isNull,
      );
      expect(
        withScenario.copyWith(integrityScenario: 'unbound').integrityScenario,
        'unbound',
      );
      expect(withScenario, isNot(equals(DemoState.initial)));
    });

    test('toDemoFlags lets the forced verdict win and copies the flags', () {
      const s = DemoState(
        callActive: true,
        scamScore: 0.85,
        integrityScenario: 'UNRECOGNIZED_VERSION',
      );
      final flags = s.toDemoFlags(appSafetyVerdict: SafetyVerdict.caution);
      // integrity_scenario is client-only and never reaches the wire.
      expect(flags.toJson().keys, isNot(contains('integrity_scenario')));
      expect(flags.callActive, isTrue);
      expect(flags.scamScore, 0.85);
      expect(flags.appSafetyVerdict, SafetyVerdict.caution);
      expect(
        s
            .copyWith(forcedSafetyVerdict: SafetyVerdict.block)
            .toDemoFlags(appSafetyVerdict: SafetyVerdict.safe)
            .appSafetyVerdict,
        SafetyVerdict.block,
      );
    });
  });

  group('Persona', () {
    test('carries the seed facts and parses uids', () {
      expect(Persona.rina.uid, 'rina');
      expect(Persona.rina.p95SendBdt, 5000);
      expect(Persona.rahima.p95SendBdt, 2000);
      expect(Persona.rahima.trustedContactUid, 'rafiq');
      expect(Persona.rina.acctId, 'acct_rina');
      expect('rahima'.asPersona, Persona.rahima);
      expect('rafiq'.asPersona, isNull);
      expect(() => Persona.parse('rafiq'), throwsFormatException);
    });
  });
}
