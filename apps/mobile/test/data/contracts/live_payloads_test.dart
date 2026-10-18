import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _decode(String src) =>
    jsonDecode(src) as Map<String, dynamic>;

void main() {
  group('ScoreResponse from the live API', () {
    const live = '''
{
  "decision": "hold",
  "risk_score": 0.91,
  "band": "critical",
  "reasons": [
    {"code": "SCAM_CONVERSATION", "weight": 0.6,
     "text_bn": "কলে কেউ আপনার ওটিপি চেয়েছে।",
     "text_en": "Someone on the call asked for your OTP."},
    {"code": "SIM_CHANGED_24H", "weight": 1,
     "text_bn": "গত ২৪ ঘণ্টায় সিম বদলেছে।",
     "text_en": "SIM changed in the last 24 hours."}
  ],
  "actions": [
    {"type": "hold_transaction", "params": {}},
    {"type": "delay_new_payee", "params": {"minutes": 30}},
    {"type": "trusted_contact_check",
     "params": {"expires_in_minutes": 15, "contact": "rafiq", "urgent": true}}
  ],
  "model_version": "rules-2026-10-15",
  "server_timing_ms": 12,
  "experimental": {"nested": [1, 2, 3]}
}
''';

    test('parses with unknown extra keys ignored', () {
      final r = ScoreResponse.fromJson(_decode(live));
      expect(r.decision, Decision.hold);
      expect(r.riskScore, 0.91);
      expect(r.band, Band.critical);
      expect(r.reasons, hasLength(2));
      expect(r.reasons[0].code, 'SCAM_CONVERSATION');
      expect(r.reasons[0].textBn, 'কলে কেউ আপনার ওটিপি চেয়েছে।');
      expect(r.reasons[1].weight, 1.0);
      expect(r.actions.map((a) => a.type), [
        'hold_transaction',
        'delay_new_payee',
        'trusted_contact_check',
      ]);
      expect(r.actions[0].params, isEmpty);
      expect(r.actions[1].params, {'minutes': 30});
      expect(r.actions[2].params['contact'], 'rafiq');
      expect(r.actions[2].params['urgent'], isTrue);
      expect(r.modelVersion, 'rules-2026-10-15');
      expect(r.toJson().containsKey('server_timing_ms'), isFalse);
    });

    test('integers are accepted where the contract says float', () {
      final r = ScoreResponse.fromJson(_decode(live)..['risk_score'] = 1);
      expect(r.riskScore, 1.0);
      expect(r.riskScore, isA<double>());
    });

    test('lists and params are unmodifiable', () {
      final r = ScoreResponse.fromJson(_decode(live));
      expect(() => r.reasons.clear(), throwsUnsupportedError);
      expect(
        () => r.actions.add(const ActionItem(type: 'x')),
        throwsUnsupportedError,
      );
      expect(() => r.actions[1].params['minutes'] = 5, throwsUnsupportedError);
    });

    test('a missing required key is a FormatException naming the key', () {
      expect(
        () => ScoreResponse.fromJson(_decode(live)..remove('decision')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('decision'),
          ),
        ),
      );
    });

    test('an unknown decision is rejected, never mapped to allow', () {
      expect(
        () => ScoreResponse.fromJson(_decode(live)..['decision'] = 'approve'),
        throwsFormatException,
      );
    });

    test('an action without params parses to an empty map', () {
      final a = ActionItem.fromJson(const {'type': 'block_transaction'});
      expect(a.params, isEmpty);
      expect(a.toJson(), {
        'type': 'block_transaction',
        'params': <String, Object>{},
      });
    });
  });

  group('InterveneResponse from the live API', () {
    const live = '''
{
  "intervene": true,
  "script_bn": "আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন। টাকা পাঠানো আপাতত থামিয়ে রাখছি।",
  "script_en": "This is your FinNest Assistant. You are on a call right now. I am holding this payment for now.",
  "audio_asset_id": null,
  "ui": "fullscreen",
  "actions": [{"type": "trusted_contact_check", "params": {"expires_in_minutes": 15}}],
  "cooldown_s": 120
}
''';

    test('audio_asset_id: null parses to null and serialises back as null', () {
      final r = InterveneResponse.fromJson(_decode(live));
      expect(r.intervene, isTrue);
      expect(r.audioAssetId, isNull);
      expect(r.ui, UiMode.fullscreen);
      expect(r.cooldownS, 120);
      expect(r.actions.single.params, {'expires_in_minutes': 15});
      expect(r.scriptBn, startsWith('আমি ফিননেস্ট সহকারী বলছি।'));
      expect(r.toJson()['audio_asset_id'], isNull);
      expect(r.toJson().containsKey('audio_asset_id'), isTrue);
    });

    test('a missing audio_asset_id key is the same as null', () {
      final r = InterveneResponse.fromJson(
        _decode(live)..remove('audio_asset_id'),
      );
      expect(r.audioAssetId, isNull);
      expect(r, InterveneResponse.fromJson(_decode(live)));
    });

    test('cooldown_s arriving as 120.0 is accepted', () {
      final r = InterveneResponse.fromJson(
        _decode(live)..['cooldown_s'] = 120.0,
      );
      expect(r.cooldownS, 120);
    });
  });

  group('AppSafetyResponse across server revisions', () {
    const rev11 = '''
{
  "verdict": "BLOCK",
  "risk_score": 0.97,
  "findings": [{
    "package": "com.takanow.app", "signal": "accessibility_sideloaded",
    "severity": "high", "evidence": "BIND_ACCESSIBILITY_SERVICE",
    "explanation_bn": "এই অ্যাপ আপনার স্ক্রিন পড়তে পারে।",
    "explanation_en": "This app can read your screen.",
    "title_bn": "স্ক্রিন পড়ার অনুমতি", "title_en": "Screen reading", "scope": "app"
  }, {
    "package": "", "signal": "adb_enabled", "severity": "low",
    "evidence": "adb=true", "explanation_bn": "ইউএসবি ডিবাগিং চালু।",
    "explanation_en": "USB debugging is on.", "scope": "device"
  }],
  "recommended_action": "uninstall",
  "apps_to_uninstall": ["com.takanow.app"],
  "user_message_bn": "একটি বিপজ্জনক অ্যাপ পাওয়া গেছে।",
  "user_message_en": "A dangerous app was found.",
  "simulated_verdict": false,
  "model_version": "appsafety-00011",
  "agrees_with_classifier": true,
  "disagreement_reason": "",
  "attestation": "strong",
  "resolution": "UNINSTALL_AND_RECHECK",
  "recheck_lifts_block": true,
  "uninstall_targets": [{
    "package": "com.takanow.app", "label": "TakaNow",
    "primary_signal": "accessibility_sideloaded", "deep_link": "package:com.takanow.app"
  }],
  "check_id": "chk_42",
  "valid_until": "2026-10-17T08:00:00Z"
}
''';

    test('revision 00011 payload parses fully', () {
      final r = AppSafetyResponse.fromJson(_decode(rev11));
      expect(r.verdict, SafetyVerdict.block);
      expect(r.findings[0].titleBn, 'স্ক্রিন পড়ার অনুমতি');
      expect(r.findings[0].scope, Finding.scopeApp);
      expect(r.findings[1].scope, Finding.scopeDevice);
      expect(r.findings[1].titleBn, '');
      expect(r.uninstallTargets.single.deepLink, 'package:com.takanow.app');
      expect(r.resolution, 'UNINSTALL_AND_RECHECK');
      expect(r.attestation, 'strong');
      expect(r.checkId, 'chk_42');
      expect(r.validUntil, '2026-10-17T08:00:00Z');
      expect(() => r.uninstallTargets.clear(), throwsUnsupportedError);
    });

    test('a pre-00011 payload without the additive fields takes defaults', () {
      final json = _decode(rev11)
        ..removeWhere(
          (k, _) => const {
            'model_version',
            'agrees_with_classifier',
            'disagreement_reason',
            'attestation',
            'resolution',
            'recheck_lifts_block',
            'uninstall_targets',
            'check_id',
            'valid_until',
          }.contains(k),
        );
      final r = AppSafetyResponse.fromJson(json);
      expect(r.modelVersion, '');
      expect(r.agreesWithClassifier, isNull);
      expect(r.attestation, 'none');
      expect(r.resolution, 'NONE');
      // The contract default: a missing flag never promises that a
      // recheck lifts a block.
      expect(r.recheckLiftsBlock, isFalse);
      expect(r.uninstallTargets, isEmpty);
      expect(r.checkId, '');
      expect(r.validUntil, '');
    });

    test('AppSafetyLatest known=false carries the defaults', () {
      final r = AppSafetyLatest.fromJson(const {'uid': 'rina', 'known': false});
      expect(r.verdict, SafetyVerdict.safe);
      expect(r.riskScore, 0.0);
      expect(r.flaggedPackages, isEmpty);
      expect(r.attestation, 'none');
      expect(r.source, 'server');
      expect(r.facts, isEmpty);
    });

    // risk-mw-00019 (2026-10-18): who checked, and the closed-set
    // phone facts behind the verdict. The answer below is what the live
    // service gave Case Zero for acct_rina with ?include_phone=true.
    test('AppSafetyLatest reads source and facts', () {
      final r = AppSafetyLatest.fromJson(const {
        'uid': 'acct_rina',
        'known': true,
        'verdict': 'CAUTION',
        'risk_score': 0.5,
        'flagged_packages': <String>[],
        'attestation': 'none',
        'checked_at': '',
        'valid_until': '2026-10-17T20:16:34.300471+00:00',
        'source': 'phone',
        'facts': ['REMOTE_CONTROL'],
      });
      expect(r.verdict, SafetyVerdict.caution);
      expect(r.source, 'phone');
      expect(r.facts, ['REMOTE_CONTROL']);
      expect(AppSafetyLatest.fromJson(r.toJson()), r);
    });
  });

  group('requests serialise exactly what the server forbids extras on', () {
    test('InstalledApp omits version until the deployed server knows it', () {
      const bare = InstalledApp(package: 'x');
      expect(bare.toJson().containsKey('version'), isFalse);
      expect(InstalledApp.fromJson(bare.toJson()), bare);

      const versioned = InstalledApp(package: 'x', version: '1.2');
      expect(versioned.toJson()['version'], '1.2');
      expect(InstalledApp.fromJson(versioned.toJson()), versioned);
    });

    test('ScoreRequest sends only the DemoFlags subset', () {
      const req = ScoreRequest(
        userId: 'rina',
        sessionId: 'sess',
        txn: Txn(type: TxnType.sendMoney, amountBdt: 7900, isNewPayee: true),
        demoFlags: DemoFlags(callActive: true, scamScore: 0.85),
      );
      final json = req.toJson();
      expect(json['txn'], {
        'type': 'send_money',
        'amount_bdt': 7900.0,
        'to_account': null,
        'is_new_payee': true,
      });
      expect((json['demo_flags'] as Map<String, dynamic>).keys, [
        'sim_swap',
        'call_active',
        'screen_share',
        'caller_in_contacts',
        'app_safety_verdict',
        'inbound_mule_score',
        'scam_score',
      ]);
      expect(jsonDecode(jsonEncode(json)), json);
    });
  });
}
