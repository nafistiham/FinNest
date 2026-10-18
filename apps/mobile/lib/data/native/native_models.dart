/// Dart-side shapes of what the `bhorosha_native` channel returns.
/// The payload field names are the contract
/// snake_case keys, so the contract `fromJson` constructors decode them.
library;

import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';

/// Recursively converts a `StandardMessageCodec` map (`Map<Object?, Object?>`)
/// into the `Map<String, dynamic>` the contract decoders expect. Non-map input
/// yields an empty map so decoders fall back to their defaults.
Map<String, dynamic> stringKeyed(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  final out = <String, dynamic>{};
  value.forEach((Object? key, Object? v) {
    if (key is String) out[key] = _deep(v);
  });
  return out;
}

Object? _deep(Object? value) {
  if (value is Map) return stringKeyed(value);
  if (value is List) return value.map<Object?>(_deep).toList(growable: false);
  return value;
}

/// `getSignals()` result: the `signals` and `device` halves of
/// `SignalsRequest`.
class NativeSignals {
  const NativeSignals({required this.signals, required this.device});

  /// Decodes `{signals: {...}, device: {...}}`. Missing halves decode to the
  /// contract defaults; a malformed value throws [FormatException], which the
  /// bridge turns into [defaults].
  factory NativeSignals.fromMap(Map<Object?, Object?> map) => NativeSignals(
    signals: DeviceSignals.fromJson(stringKeyed(map['signals'])),
    device: DeviceInfo.fromJson(stringKeyed(map['device'])),
  );

  /// What the risk flow sends when the channel is missing, slow or failing:
  /// idle call, no accessibility services, nothing captured, unknown device.
  static NativeSignals defaults() =>
      const NativeSignals(signals: DeviceSignals(), device: DeviceInfo());

  final DeviceSignals signals;
  final DeviceInfo device;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeSignals &&
          signals == other.signals &&
          device == other.device;

  @override
  int get hashCode => Object.hash(signals, device);

  @override
  String toString() => 'NativeSignals(signals: $signals, device: $device)';
}

/// `getAppSafetyBundle()` result: the body of `AppSafetyRequest` minus the
/// integrity token.
class AppSafetyBundle {
  const AppSafetyBundle({
    required this.installedApps,
    required this.device,
    this.failed = false,
  });

  /// Decodes `{installed_apps: [...], device: {...}}`. Entries without a
  /// `package` throw [FormatException]; the bridge returns [empty] then.
  factory AppSafetyBundle.fromMap(Map<Object?, Object?> map) {
    final apps = map['installed_apps'];
    return AppSafetyBundle(
      installedApps: apps is List
          ? apps
                .map((Object? e) => InstalledApp.fromJson(stringKeyed(e)))
                .toList(growable: false)
          : const [],
      device: DeviceState.fromJson(stringKeyed(map['device'])),
    );
  }

  static const AppSafetyBundle empty = AppSafetyBundle(
    installedApps: [],
    device: DeviceState(),
  );

  /// The scan did not answer (timeout, channel error, undecodable reply).
  /// Never posted: the check reports "could not verify" instead of letting
  /// an empty list come back SAFE.
  static const AppSafetyBundle unavailable = AppSafetyBundle(
    installedApps: [],
    device: DeviceState(),
    failed: true,
  );

  final List<InstalledApp> installedApps;
  final DeviceState device;

  /// `true` only for [unavailable].
  final bool failed;

  bool get isEmpty => installedApps.isEmpty && device == const DeviceState();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyBundle &&
          listEq(installedApps, other.installedApps) &&
          device == other.device &&
          failed == other.failed;

  @override
  int get hashCode => Object.hash(hashList(installedApps), device, failed);

  @override
  String toString() => failed
      ? 'AppSafetyBundle(unavailable)'
      : 'AppSafetyBundle(${installedApps.length} apps, device: $device)';
}

/// `getAppSafetyAttestation()` result: the bundle, the collector's canonical
/// SHA-256 of it (the Play Integrity `requestHash`) and the token bound to
/// that hash, or `null` when Integrity is not prepared or failed.
class AppSafetyAttestation {
  const AppSafetyAttestation({
    required this.bundle,
    this.bundleHash = '',
    this.integrityToken,
  });

  /// Decodes `{bundle: <json string or map>, bundle_hash, integrity_token}`.
  /// Throws [FormatException] when the bundle is malformed.
  factory AppSafetyAttestation.fromMap(Map<Object?, Object?> map) {
    final raw = map['bundle'];
    final Object? decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) {
      throw const FormatException('attestation bundle is not a JSON object');
    }
    final hash = map['bundle_hash'];
    final token = map['integrity_token'];
    return AppSafetyAttestation(
      bundle: AppSafetyBundle.fromMap(decoded.cast<Object?, Object?>()),
      bundleHash: hash is String ? hash : '',
      integrityToken: token is String && token.isNotEmpty ? token : null,
    );
  }

  final AppSafetyBundle bundle;
  final String bundleHash;
  final String? integrityToken;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyAttestation &&
          bundle == other.bundle &&
          bundleHash == other.bundleHash &&
          integrityToken == other.integrityToken;

  @override
  int get hashCode => Object.hash(bundle, bundleHash, integrityToken);

  @override
  String toString() =>
      'AppSafetyAttestation($bundle, hash: $bundleHash, token: ${integrityToken == null ? 'none' : 'present'})';
}

/// Events on `bhorosha_native/events`.
sealed class NativeEvent {
  const NativeEvent();

  /// Decodes `{type: ..., value: ...}`; returns `null` for anything that is
  /// not a well-formed event so the bridge can drop it silently.
  static NativeEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final value = raw['value'];
    switch (type) {
      case 'call_state':
        if (value is! String) return null;
        try {
          return CallStateEvent(CallState.fromWire(value));
        } on FormatException {
          return null;
        }
      case 'screen_capture':
        return value is bool ? ScreenCaptureEvent(value) : null;
      case 'screen_recording':
        return value is bool ? ScreenRecordingEvent(value) : null;
      case 'obscured_touch':
        return const ObscuredTouchEvent();
      case 'pcm_drained':
        return const PcmDrainedEvent();
      default:
        return null;
    }
  }
}

class CallStateEvent extends NativeEvent {
  const CallStateEvent(this.state);
  final CallState state;

  @override
  bool operator ==(Object other) =>
      other is CallStateEvent && state == other.state;

  @override
  int get hashCode => Object.hash(CallStateEvent, state);

  @override
  String toString() => 'CallStateEvent(${state.wire})';
}

class ScreenCaptureEvent extends NativeEvent {
  const ScreenCaptureEvent(this.active);
  final bool active;

  @override
  bool operator ==(Object other) =>
      other is ScreenCaptureEvent && active == other.active;

  @override
  int get hashCode => Object.hash(ScreenCaptureEvent, active);

  @override
  String toString() => 'ScreenCaptureEvent($active)';
}

class ScreenRecordingEvent extends NativeEvent {
  const ScreenRecordingEvent(this.active);
  final bool active;

  @override
  bool operator ==(Object other) =>
      other is ScreenRecordingEvent && active == other.active;

  @override
  int get hashCode => Object.hash(ScreenRecordingEvent, active);

  @override
  String toString() => 'ScreenRecordingEvent($active)';
}

class ObscuredTouchEvent extends NativeEvent {
  const ObscuredTouchEvent();

  @override
  bool operator ==(Object other) => other is ObscuredTouchEvent;

  @override
  int get hashCode => (ObscuredTouchEvent).hashCode;

  @override
  String toString() => 'ObscuredTouchEvent()';
}

/// The PCM player has played every byte queued since the last write.
/// Never sent after `stopPcm` until the next `playPcm`.
class PcmDrainedEvent extends NativeEvent {
  const PcmDrainedEvent();

  @override
  bool operator ==(Object other) => other is PcmDrainedEvent;

  @override
  int get hashCode => (PcmDrainedEvent).hashCode;

  @override
  String toString() => 'PcmDrainedEvent()';
}
