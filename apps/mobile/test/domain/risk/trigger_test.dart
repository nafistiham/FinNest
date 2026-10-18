import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/domain/risk/trigger.dart';
import 'package:flutter_test/flutter_test.dart';

Reason reason(String code, double weight) =>
    Reason(code: code, weight: weight, textBn: 'বাংলা', textEn: 'en');

void main() {
  group('Triggers.choose', () {
    final rows =
        <
          ({
            String name,
            Decision decision,
            DemoFlags flags,
            List<Reason> reasons,
            String want,
          })
        >[
          (
            name: 'hold + callActive → call_active (video preset)',
            decision: Decision.hold,
            flags: const DemoFlags(callActive: true, scamScore: 0.85),
            reasons: [reason('SCAM_CONVERSATION', 0.85)],
            want: 'call_active',
          ),
          (
            name: 'hold + callActive wins even over a heavier reason',
            decision: Decision.hold,
            flags: const DemoFlags(callActive: true),
            reasons: [reason('SIM_CHANGED_24H', 0.85)],
            want: 'call_active',
          ),
          (
            name: 'hold, SIM_CHANGED_24H, no call → sim_swap',
            decision: Decision.hold,
            flags: const DemoFlags(simSwap: true),
            reasons: [reason('SIM_CHANGED_24H', 0.85)],
            want: 'sim_swap',
          ),
          (
            name: 'hold, SCAM_CONVERSATION, no call → scam_conversation',
            decision: Decision.hold,
            flags: const DemoFlags(scamScore: 0.85),
            reasons: [reason('SCAM_CONVERSATION', 0.85)],
            want: 'scam_conversation',
          ),
          (
            name: 'hold, ATO_BEHAVIOUR_MISMATCH → behaviour_mismatch',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [reason('ATO_BEHAVIOUR_MISMATCH', 1.0)],
            want: 'behaviour_mismatch',
          ),
          (
            name: 'hold, cold-start mismatch → behaviour_mismatch',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [reason('ATO_BEHAVIOUR_MISMATCH_COLD_START', 0.9)],
            want: 'behaviour_mismatch',
          ),
          (
            name: 'hold, COACHING_SUSPECTED → coaching',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [reason('COACHING_SUSPECTED', 0.8)],
            want: 'coaching',
          ),
          (
            name: 'hold, DEST_MULE_RISK → dest_mule_risk',
            decision: Decision.hold,
            flags: const DemoFlags(inboundMuleScore: 0.9),
            reasons: [reason('DEST_MULE_RISK', 0.9)],
            want: 'dest_mule_risk',
          ),
          (
            name: 'hold, CALL_ACTIVE_NON_CONTACT code without the flag',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [reason('CALL_ACTIVE_NON_CONTACT', 0.9)],
            want: 'call_active',
          ),
          (
            name: 'highest weight wins among several reasons',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [
              reason('NEW_PAYEE_ABOVE_P95', 0.6),
              reason('SIM_CHANGED_24H', 0.85),
              reason('SCREEN_SHARE_ACTIVE', 0.5),
            ],
            want: 'sim_swap',
          ),
          (
            name: 'equal weights: the earlier reason wins',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [
              reason('SCAM_CONVERSATION', 0.85),
              reason('SIM_CHANGED_24H', 0.85),
            ],
            want: 'scam_conversation',
          ),
          (
            name: 'delay with NEW_PAYEE_ABOVE_P95 → new_payee_high_amount',
            decision: Decision.delay,
            flags: const DemoFlags(),
            reasons: [reason('NEW_PAYEE_ABOVE_P95', 0.6)],
            want: 'new_payee_high_amount',
          ),
          (
            name: 'delay with NEW_PAYEE_ABOVE_P95 not the heaviest still wins',
            decision: Decision.delay,
            flags: const DemoFlags(),
            reasons: [
              reason('SCREEN_SHARE_ACTIVE', 0.7),
              reason('NEW_PAYEE_ABOVE_P95', 0.6),
            ],
            want: 'new_payee_high_amount',
          ),
          (
            name: 'delay + callActive does not become call_active',
            decision: Decision.delay,
            flags: const DemoFlags(callActive: true),
            reasons: [reason('NEW_PAYEE_ABOVE_P95', 0.6)],
            want: 'new_payee_high_amount',
          ),
          (
            name: 'stepUp + screenShare → screen_share',
            decision: Decision.stepUp,
            flags: const DemoFlags(screenShare: true),
            reasons: [reason('SCREEN_SHARE_ACTIVE', 0.5)],
            want: 'screen_share',
          ),
          (
            name: 'stepUp without the flag falls back to the reason code',
            decision: Decision.stepUp,
            flags: const DemoFlags(),
            reasons: [reason('SCREEN_SHARE_ACTIVE', 0.5)],
            want: 'screen_share',
          ),
          (
            name: 'block with APP_SAFETY_BLOCK → app_safety',
            decision: Decision.block,
            flags: const DemoFlags(appSafetyVerdict: SafetyVerdict.block),
            reasons: [reason('APP_SAFETY_BLOCK', 0.95)],
            want: 'app_safety',
          ),
          (
            name: 'delay led by an APP_SAFETY_CAUTION → app_safety',
            decision: Decision.delay,
            flags: const DemoFlags(appSafetyVerdict: SafetyVerdict.caution),
            reasons: [reason('APP_SAFETY_CAUTION', 0.59)],
            want: 'app_safety',
          ),
          (
            name: 'unknown code is lower-cased',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: [reason('MODEL_ANOMALY', 0.7)],
            want: 'model_anomaly',
          ),
          (
            name: 'no reasons → generic',
            decision: Decision.hold,
            flags: const DemoFlags(),
            reasons: const [],
            want: 'generic',
          ),
          (
            name: 'allow with no reasons → generic (unused but defined)',
            decision: Decision.allow,
            flags: const DemoFlags(),
            reasons: const [],
            want: 'generic',
          ),
        ];

    for (final row in rows) {
      test(row.name, () {
        expect(
          Triggers.choose(
            decision: row.decision,
            flags: row.flags,
            reasons: row.reasons,
          ),
          row.want,
        );
      });
    }
  });

  group('Triggers.predictedAsset', () {
    const rows = <String, String>{
      'call_active': 'apa_hold_call_active',
      'screen_share': 'apa_hold_screen_share',
      'new_payee_high_amount': 'apa_delay_new_payee',
      'sim_swap': 'apa_generic_caution',
      'scam_conversation': 'apa_generic_caution',
      'dest_mule_risk': 'apa_generic_caution',
      'app_safety': 'apa_generic_caution',
      'generic': 'apa_generic_caution',
      'something_new': 'apa_generic_caution',
      '': 'apa_generic_caution',
    };

    for (final entry in rows.entries) {
      test('${entry.key.isEmpty ? '<empty>' : entry.key} → ${entry.value}', () {
        expect(Triggers.predictedAsset(entry.key), entry.value);
      });
    }
  });
}
