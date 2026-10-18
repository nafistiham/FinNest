import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'samples.dart' as s;

/// Encodes to a JSON string and back so the parsed map has the real wire
/// types (every number may arrive as int or double).
Map<String, dynamic> _wire(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void _roundTrip<T>(
  String name,
  T value,
  Map<String, dynamic> Function(T v) toJson,
  T Function(Map<String, dynamic> json) fromJson,
) {
  test(name, () {
    final parsed = fromJson(_wire(toJson(value)));
    expect(parsed, equals(value));
    expect(parsed.hashCode, equals(value.hashCode));
    expect(toJson(parsed), equals(toJson(value)));
    expect(parsed.toString(), startsWith('$name('));
  });
}

void main() {
  group('fromJson(toJson(x)) == x', () {
    _roundTrip(
      'DeviceInfo',
      s.deviceInfo,
      (v) => v.toJson(),
      DeviceInfo.fromJson,
    );
    _roundTrip(
      'DeviceSignals',
      s.deviceSignals,
      (v) => v.toJson(),
      DeviceSignals.fromJson,
    );
    _roundTrip('Behaviour', s.behaviour, (v) => v.toJson(), Behaviour.fromJson);
    _roundTrip(
      'SignalsRequest',
      s.signalsRequest,
      (v) => v.toJson(),
      SignalsRequest.fromJson,
    );
    _roundTrip(
      'SignalsResponse',
      s.signalsResponse,
      (v) => v.toJson(),
      SignalsResponse.fromJson,
    );
    _roundTrip('Txn', s.txn, (v) => v.toJson(), Txn.fromJson);
    _roundTrip('DemoFlags', s.demoFlags, (v) => v.toJson(), DemoFlags.fromJson);
    _roundTrip(
      'ScoreRequest',
      s.scoreRequest,
      (v) => v.toJson(),
      ScoreRequest.fromJson,
    );
    _roundTrip('Reason', s.reason, (v) => v.toJson(), Reason.fromJson);
    _roundTrip(
      'ActionItem',
      s.actionItem,
      (v) => v.toJson(),
      ActionItem.fromJson,
    );
    _roundTrip(
      'ScoreResponse',
      s.scoreResponse,
      (v) => v.toJson(),
      ScoreResponse.fromJson,
    );
    _roundTrip(
      'InstalledApp',
      s.installedApp,
      (v) => v.toJson(),
      InstalledApp.fromJson,
    );
    _roundTrip(
      'DeviceState',
      s.deviceState,
      (v) => v.toJson(),
      DeviceState.fromJson,
    );
    _roundTrip(
      'AppSafetyRequest',
      s.appSafetyRequest,
      (v) => v.toJson(),
      AppSafetyRequest.fromJson,
    );
    _roundTrip('Finding', s.finding, (v) => v.toJson(), Finding.fromJson);
    _roundTrip(
      'UninstallTarget',
      s.uninstallTarget,
      (v) => v.toJson(),
      UninstallTarget.fromJson,
    );
    _roundTrip(
      'AppSafetyLatest',
      s.appSafetyLatest,
      (v) => v.toJson(),
      AppSafetyLatest.fromJson,
    );
    _roundTrip(
      'AppSafetyContext',
      s.appSafetyContext,
      (v) => v.toJson(),
      AppSafetyContext.fromJson,
    );
    _roundTrip(
      'ScoreRequest',
      s.scoreRequestBare,
      (v) => v.toJson(),
      ScoreRequest.fromJson,
    );
    _roundTrip(
      'DemoIntegrityRequest',
      s.demoIntegrityRequest,
      (v) => v.toJson(),
      DemoIntegrityRequest.fromJson,
    );
    _roundTrip(
      'DemoIntegrityResponse',
      s.demoIntegrityResponse,
      (v) => v.toJson(),
      DemoIntegrityResponse.fromJson,
    );
    _roundTrip(
      'AppSafetyResponse',
      s.appSafetyResponse,
      (v) => v.toJson(),
      AppSafetyResponse.fromJson,
    );
    _roundTrip(
      'InterveneRequest',
      s.interveneRequest,
      (v) => v.toJson(),
      InterveneRequest.fromJson,
    );
    _roundTrip(
      'InterveneResponse',
      s.interveneResponse,
      (v) => v.toJson(),
      InterveneResponse.fromJson,
    );
    _roundTrip('Turn', s.turn, (v) => v.toJson(), Turn.fromJson);
    _roundTrip(
      'ScamTurnRequest',
      s.scamTurnRequest,
      (v) => v.toJson(),
      ScamTurnRequest.fromJson,
    );
    _roundTrip(
      'ScamTurnResponse',
      s.scamTurnResponse,
      (v) => v.toJson(),
      ScamTurnResponse.fromJson,
    );
    _roundTrip(
      'ApaContext',
      s.apaContext,
      (v) => v.toJson(),
      ApaContext.fromJson,
    );
    _roundTrip(
      'ApaTurnRequest',
      s.apaTurnRequest,
      (v) => v.toJson(),
      ApaTurnRequest.fromJson,
    );
    _roundTrip(
      'ApaTurnResponse',
      s.apaTurnResponse,
      (v) => v.toJson(),
      ApaTurnResponse.fromJson,
    );
    _roundTrip(
      'TrustedContactRequest',
      s.trustedContactRequest,
      (v) => v.toJson(),
      TrustedContactRequest.fromJson,
    );
    _roundTrip(
      'TrustedContactResponse',
      s.trustedContactResponse,
      (v) => v.toJson(),
      TrustedContactResponse.fromJson,
    );
    _roundTrip(
      'TrustedContactDecision',
      s.trustedContactDecision,
      (v) => v.toJson(),
      TrustedContactDecision.fromJson,
    );
  });

  group('defaults round-trip too', () {
    test('default instances survive the wire', () {
      expect(
        DeviceInfo.fromJson(_wire(const DeviceInfo().toJson())),
        const DeviceInfo(),
      );
      expect(
        DeviceSignals.fromJson(_wire(const DeviceSignals().toJson())),
        const DeviceSignals(),
      );
      expect(
        DemoFlags.fromJson(_wire(const DemoFlags().toJson())),
        const DemoFlags(),
      );
      expect(
        DeviceState.fromJson(_wire(const DeviceState().toJson())),
        const DeviceState(),
      );
      expect(
        ApaContext.fromJson(_wire(const ApaContext().toJson())),
        const ApaContext(),
      );
      expect(
        AppSafetyRequest.fromJson(_wire(const AppSafetyRequest().toJson())),
        const AppSafetyRequest(),
      );
      expect(
        DemoIntegrityRequest.fromJson(
          _wire(const DemoIntegrityRequest().toJson()),
        ),
        const DemoIntegrityRequest(),
      );
      expect(DemoIntegrityRequest.fromJson(const {}).deviceRecognition, [
        'MEETS_DEVICE_INTEGRITY',
      ]);
      expect(
        DemoIntegrityRequest.fromJson(const {'device_recognition': <String>[]})
            .deviceRecognition,
        isEmpty,
      );
      expect(
        SignalsRequest.fromJson(const {'session_id': 's'}),
        const SignalsRequest(sessionId: 's'),
      );
    });
  });

  group('enums', () {
    test('wire strings are exact and fromWire inverts them', () {
      expect(Decision.values.map((e) => e.wire), [
        'allow',
        'step_up',
        'delay',
        'hold',
        'block',
      ]);
      expect(TxnType.values.map((e) => e.wire), [
        'pin_reset',
        'new_payee',
        'send_money',
      ]);
      expect(UiMode.values.map((e) => e.wire), [
        'banner',
        'fullscreen',
        'call_apa',
      ]);
      expect(SafetyVerdict.values.map((e) => e.wire), [
        'SAFE',
        'CAUTION',
        'BLOCK',
      ]);
      expect(Band.values.map((e) => e.wire), [
        'low',
        'medium',
        'high',
        'critical',
      ]);
      expect(CallState.values.map((e) => e.wire), [
        'IDLE',
        'RINGING',
        'OFFHOOK',
      ]);
      for (final d in Decision.values) {
        expect(Decision.fromWire(d.wire), d);
      }
      for (final v in SafetyVerdict.values) {
        expect(SafetyVerdict.fromWire(v.wire), v);
      }
    });

    test('unknown wire values throw FormatException', () {
      expect(() => Decision.fromWire('maybe'), throwsFormatException);
      expect(() => SafetyVerdict.fromWire('safe'), throwsFormatException);
      expect(() => CallState.fromWire('idle'), throwsFormatException);
    });
  });

  group('copyWith', () {
    test('DemoFlags changes only what is passed', () {
      final flags = const DemoFlags().copyWith(
        callActive: true,
        scamScore: 0.85,
        appSafetyVerdict: SafetyVerdict.block,
      );
      expect(flags.callActive, isTrue);
      expect(flags.scamScore, 0.85);
      expect(flags.appSafetyVerdict, SafetyVerdict.block);
      expect(flags.simSwap, isFalse);
      expect(flags.inboundMuleScore, 0.0);
      expect(flags.copyWith(), flags);
    });

    test('nullable fields can be kept or cleared', () {
      expect(s.txn.copyWith().toAccount, s.txn.toAccount);
      expect(s.txn.copyWith(toAccount: null).toAccount, isNull);
      expect(s.txn.copyWith(toAccount: 'x').toAccount, 'x');
      expect(
        s.deviceSignals.copyWith().subscriptionChangedHours,
        s.deviceSignals.subscriptionChangedHours,
      );
      expect(
        s.deviceSignals
            .copyWith(subscriptionChangedHours: null)
            .subscriptionChangedHours,
        isNull,
      );
      expect(
        s.deviceSignals.copyWith(callState: CallState.idle).callState,
        CallState.idle,
      );
      expect(s.deviceState.copyWith().sdkInt, 34);
      expect(s.deviceState.copyWith(sdkInt: null).sdkInt, isNull);
      expect(
        s.deviceState.copyWith(defaultSmsPackage: null).defaultSmsPackage,
        isNull,
      );
    });
  });

  group('Behaviour', () {
    test('asserts at most 64 features', () {
      expect(
        () => Behaviour(features: List<double>.filled(64, 0)),
        returnsNormally,
      );
      expect(
        () => Behaviour(features: List<double>.filled(65, 0)),
        throwsAssertionError,
      );
    });
  });
}
