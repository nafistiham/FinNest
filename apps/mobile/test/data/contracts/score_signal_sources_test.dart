import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> base() => <String, dynamic>{
  'decision': 'hold',
  'risk_score': 1.0,
  'band': 'critical',
  'reasons': <Object>[],
  'actions': <Object>[],
  'model_version': 'rules-v1',
};

void main() {
  test('signal_sources parses each input; unknown values read as unknown, '
      'never none', () {
    final r = ScoreResponse.fromJson({
      ...base(),
      'signal_sources': {
        'call_active': 'device',
        'sim_swap': 'demo',
        'screen_share': 'none',
        'caller_in_contacts': 'something_new',
      },
    });
    expect(
      r.signalSources,
      const SignalSources(
        callActive: SignalSource.device,
        simSwap: SignalSource.demo,
        callerInContacts: SignalSource.unknown,
      ),
    );
    expect(r.signalSources!.callerInContacts, SignalSource.unknown);
  });

  test('a missing or null signal_sources is null (unknown)', () {
    expect(ScoreResponse.fromJson(base()).signalSources, isNull);
    expect(
      ScoreResponse.fromJson({...base(), 'signal_sources': null}).signalSources,
      isNull,
    );
  });

  test('missing keys inside read as unknown', () {
    final r = ScoreResponse.fromJson({
      ...base(),
      'signal_sources': {'call_active': 'demo'},
    });
    expect(
      r.signalSources,
      const SignalSources(
        callActive: SignalSource.demo,
        simSwap: SignalSource.unknown,
        screenShare: SignalSource.unknown,
        callerInContacts: SignalSource.unknown,
      ),
    );
  });

  test('an unknown call_active keeps the hold (it is not none)', () {
    final r = ScoreResponse.fromJson({
      ...base(),
      'signal_sources': {
        'call_active': 'carrier',
        'sim_swap': 'none',
        'screen_share': 'none',
        'caller_in_contacts': 'none',
      },
    });
    expect(r.signalSources!.callActive, SignalSource.unknown);
    expect(r.signalSources!.callActive == SignalSource.none, isFalse);
  });

  test('round-trips through the wire and takes part in equality', () {
    const r = ScoreResponse(
      decision: Decision.hold,
      riskScore: 1,
      band: Band.critical,
      reasons: [],
      actions: [],
      modelVersion: 'm',
      signalSources: SignalSources(screenShare: SignalSource.device),
    );
    final back = ScoreResponse.fromJson(
      jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
    );
    expect(back, r);
    expect(back == ScoreResponse.fromJson(base()), isFalse);
    expect(SignalSource.values.map((s) => s.wire), [
      'device',
      'demo',
      'none',
      'unknown',
    ]);
  });
}
