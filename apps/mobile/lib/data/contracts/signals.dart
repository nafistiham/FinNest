/// `/v1/risk/signals` request and response (contracts.py).
library;

import 'package:bhorosha/data/contracts/common.dart';

/// `class DeviceInfo(Strict)`.
class DeviceInfo {
  const DeviceInfo({
    this.model = '',
    this.os = '',
    this.rooted = false,
    this.simSerialHash = '',
    this.simChangedAt,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    model: readString(json, 'model', ''),
    os: readString(json, 'os', ''),
    rooted: readBool(json, 'rooted', false),
    simSerialHash: readString(json, 'sim_serial_hash', ''),
    simChangedAt: readStringOrNull(json, 'sim_changed_at'),
  );

  final String model;
  final String os;
  final bool rooted;
  final String simSerialHash;
  final String? simChangedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'model': model,
    'os': os,
    'rooted': rooted,
    'sim_serial_hash': simSerialHash,
    'sim_changed_at': simChangedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceInfo &&
          model == other.model &&
          os == other.os &&
          rooted == other.rooted &&
          simSerialHash == other.simSerialHash &&
          simChangedAt == other.simChangedAt;

  @override
  int get hashCode =>
      Object.hash(model, os, rooted, simSerialHash, simChangedAt);

  @override
  String toString() => 'DeviceInfo(${toJson()})';
}

/// `class DeviceSignals(Strict)`.
class DeviceSignals {
  const DeviceSignals({
    this.callState = CallState.idle,
    this.audioMode = '',
    this.subscriptionChangedHours,
    this.accessibilityServices = const [],
    this.screenCapture = false,
    this.screenRecording = false,
    this.obscuredTouch = false,
  });

  factory DeviceSignals.fromJson(Map<String, dynamic> json) => DeviceSignals(
    callState: readEnum(json, 'call_state', CallState.fromWire, CallState.idle),
    audioMode: readString(json, 'audio_mode', ''),
    subscriptionChangedHours: readDoubleOrNull(
      json,
      'subscription_changed_hours',
    ),
    accessibilityServices: readList(json, 'accessibility_services', stringItem),
    screenCapture: readBool(json, 'screen_capture', false),
    screenRecording: readBool(json, 'screen_recording', false),
    obscuredTouch: readBool(json, 'obscured_touch', false),
  );

  final CallState callState;
  final String audioMode;
  final double? subscriptionChangedHours;
  final List<String> accessibilityServices;
  final bool screenCapture;
  final bool screenRecording;
  final bool obscuredTouch;

  /// Pass [unchanged] (the default) to keep a value; `null` clears
  /// [subscriptionChangedHours].
  DeviceSignals copyWith({
    CallState? callState,
    String? audioMode,
    Object? subscriptionChangedHours = unchanged,
    List<String>? accessibilityServices,
    bool? screenCapture,
    bool? screenRecording,
    bool? obscuredTouch,
  }) => DeviceSignals(
    callState: callState ?? this.callState,
    audioMode: audioMode ?? this.audioMode,
    subscriptionChangedHours: identical(subscriptionChangedHours, unchanged)
        ? this.subscriptionChangedHours
        : subscriptionChangedHours as double?,
    accessibilityServices: accessibilityServices ?? this.accessibilityServices,
    screenCapture: screenCapture ?? this.screenCapture,
    screenRecording: screenRecording ?? this.screenRecording,
    obscuredTouch: obscuredTouch ?? this.obscuredTouch,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'call_state': callState.wire,
    'audio_mode': audioMode,
    'subscription_changed_hours': subscriptionChangedHours,
    'accessibility_services': List<String>.of(accessibilityServices),
    'screen_capture': screenCapture,
    'screen_recording': screenRecording,
    'obscured_touch': obscuredTouch,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceSignals &&
          callState == other.callState &&
          audioMode == other.audioMode &&
          subscriptionChangedHours == other.subscriptionChangedHours &&
          listEq(accessibilityServices, other.accessibilityServices) &&
          screenCapture == other.screenCapture &&
          screenRecording == other.screenRecording &&
          obscuredTouch == other.obscuredTouch;

  @override
  int get hashCode => Object.hash(
    callState,
    audioMode,
    subscriptionChangedHours,
    hashList(accessibilityServices),
    screenCapture,
    screenRecording,
    obscuredTouch,
  );

  @override
  String toString() => 'DeviceSignals(${toJson()})';
}

/// `class Behaviour(Strict)`: the behaviour feature vector.
///
/// The server accepts at most 64 features; the app always sends exactly 55
/// (`FeatureNames.count`, the `schema.py` order). The length is asserted in the constructor;
/// `const Behaviour()` is fine, a non-empty vector is built with a non-const
/// call (`Behaviour(features: vector)`), which asserts at runtime.
class Behaviour {
  const Behaviour({this.features = const []})
    : assert(
        // The identical() guard lets `const Behaviour()` compile: Dart's
        // constant evaluator cannot read List.length, so a non-empty vector
        // must be built with a non-const call, which still asserts.
        identical(features, const <double>[]) || features.length <= maxFeatures,
        'Behaviour.features must have at most 64 entries',
      );

  factory Behaviour.fromJson(Map<String, dynamic> json) =>
      Behaviour(features: readList(json, 'features', doubleItem));

  /// `Field(max_length=64)` in contracts.py.
  static const int maxFeatures = 64;

  final List<double> features;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'features': List<double>.of(features),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Behaviour && listEq(features, other.features);

  @override
  int get hashCode => hashList(features);

  @override
  String toString() => 'Behaviour(${toJson()})';
}

/// `class SignalsRequest(Strict)`.
class SignalsRequest {
  const SignalsRequest({
    required this.sessionId,
    this.device = const DeviceInfo(),
    this.signals = const DeviceSignals(),
    this.integrityToken,
    this.behaviour,
    this.simulated = const [],
  });

  factory SignalsRequest.fromJson(Map<String, dynamic> json) => SignalsRequest(
    sessionId: requireString(json, 'session_id'),
    device: readObject(json, 'device', DeviceInfo.fromJson, const DeviceInfo()),
    signals: readObject(
      json,
      'signals',
      DeviceSignals.fromJson,
      const DeviceSignals(),
    ),
    integrityToken: readStringOrNull(json, 'integrity_token'),
    behaviour: readObject<Behaviour?>(
      json,
      'behaviour',
      Behaviour.fromJson,
      null,
    ),
    simulated: readList(json, 'simulated', stringItem),
  );

  /// `Field(max_length=32)` of `str` up to 64 chars in contracts.py.
  static const int maxSimulated = 32;

  final String sessionId;
  final DeviceInfo device;
  final DeviceSignals signals;
  final String? integrityToken;

  /// `null` (the default) omits the block, which the server reads as its
  /// empty default; behaviour mode `off` relies on it (no behaviour
  /// to score, rather than a short vector it ignores).
  final Behaviour? behaviour;

  /// Server field names whose values the demo panel forced,
  /// so the server can tag the stored signals as simulated. Sent only when
  /// non-empty; at most [maxSimulated] names.
  final List<String> simulated;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'session_id': sessionId,
    'device': device.toJson(),
    'signals': signals.toJson(),
    'integrity_token': integrityToken,
    if (behaviour != null) 'behaviour': behaviour!.toJson(),
    if (simulated.isNotEmpty) 'simulated': List<String>.of(simulated),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignalsRequest &&
          sessionId == other.sessionId &&
          device == other.device &&
          signals == other.signals &&
          integrityToken == other.integrityToken &&
          behaviour == other.behaviour &&
          listEq(simulated, other.simulated);

  @override
  int get hashCode => Object.hash(
    sessionId,
    device,
    signals,
    integrityToken,
    behaviour,
    hashList(simulated),
  );

  @override
  String toString() => 'SignalsRequest(${toJson()})';
}

/// `class SignalsResponse(Strict)`.
class SignalsResponse {
  const SignalsResponse({required this.stored});

  factory SignalsResponse.fromJson(Map<String, dynamic> json) =>
      SignalsResponse(stored: requireBool(json, 'stored'));

  final bool stored;

  Map<String, dynamic> toJson() => <String, dynamic>{'stored': stored};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignalsResponse && stored == other.stored;

  @override
  int get hashCode => stored.hashCode;

  @override
  String toString() => 'SignalsResponse(${toJson()})';
}
