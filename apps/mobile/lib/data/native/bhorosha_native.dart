/// The `bhorosha_native` bridge.
///
/// Every call has a timeout and a documented fallback; nothing here throws to
/// the caller. The Kotlin side lives in
/// `android/app/src/main/kotlin/com/bhorosha/app/native/`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/native/native_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'package:bhorosha/data/native/native_models.dart';

abstract class BhoroshaNative {
  /// Device signals for `/v1/risk/signals`. 1.5 s budget, then
  /// [NativeSignals.defaults].
  Future<NativeSignals> getSignals();

  /// Installed-app bundle for `/v1/appsafety/check`. 4 s budget, then
  /// [AppSafetyBundle.unavailable] (never posted; the check reports "could
  /// not verify"). Kotlin caches the scan per process (60 s).
  /// The channel reply is the App Safety collector's JSON string
  /// (`AppSafetyRequest` body); it is decoded here.
  Future<AppSafetyBundle> getAppSafetyBundle();

  /// Bundle + canonical hash + Integrity token bound to it. 5 s budget, then
  /// the bundle from [getAppSafetyBundle] with an empty hash and no token.
  Future<AppSafetyAttestation> getAppSafetyAttestation();

  /// Warms the Play Integrity token provider. Fire-and-forget at app start;
  /// no-op when [cloudProjectNumber] is empty.
  Future<void> prepareIntegrity(String cloudProjectNumber);

  /// Play Integrity token for [requestHash], or `null` when not prepared,
  /// not ready within 1.5 s, or on any failure (emulator, no Play).
  Future<String?> getIntegrityToken(String requestHash);

  /// FLAG_SECURE + obscured-touch filtering + hide overlay windows (FR-5).
  Future<void> setSecure(bool on);

  /// Opens the system app-info page for [package] (uninstall path, US-4).
  Future<void> openAppDetails(String package);

  /// Opens the system accessibility settings (turn a service off).
  Future<void> openAccessibilitySettings();

  /// Starts the system uninstall dialog for [package] (`ACTION_DELETE`);
  /// Kotlin falls back to the app-info page when the dialog cannot open.
  Future<void> uninstallApp(String package);

  /// Opens one system settings [panel]; [package] narrows it where Android
  /// allows (the overlay page of one app). Falls back to the main settings.
  Future<void> openSettingsPanel(SettingsPanel panel, {String? package});

  /// Streams 16-bit mono PCM to the speaker (Apa Live audio).
  Future<void> playPcm(Uint8List pcm16, int sampleRate);
  Future<void> stopPcm();

  /// Enters the voice audio session: communication mode with the
  /// loudspeaker forced and the volume keys on the voice-call stream.
  /// Idempotent.
  Future<void> enterVoiceSession();

  /// Restores the audio mode, routing and volume stream that were active
  /// before [enterVoiceSession]. Idempotent; safe without a prior enter.
  Future<void> exitVoiceSession();

  /// Broadcast stream of native events; malformed events are dropped.
  Stream<NativeEvent> get events;

  /// Requests READ_PHONE_STATE; resolves `true` when granted.
  Future<bool> requestPhoneStatePermission();
}

/// Channel-backed implementation. Timeouts are injectable for tests.
class MethodChannelBhoroshaNative implements BhoroshaNative {
  MethodChannelBhoroshaNative({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    this.signalsTimeout = const Duration(milliseconds: 1500),
    this.bundleTimeout = const Duration(seconds: 4),
    this.attestationTimeout = const Duration(seconds: 5),
    this.integrityTimeout = const Duration(milliseconds: 1500),
    this.controlTimeout = const Duration(seconds: 2),
  }) : _method = methodChannel ?? const MethodChannel(methodChannelName),
       _event = eventChannel ?? const EventChannel(eventChannelName);

  static const String methodChannelName = 'bhorosha_native';
  static const String _tag = 'native';
  static const String eventChannelName = 'bhorosha_native/events';

  final MethodChannel _method;
  final EventChannel _event;
  final Duration signalsTimeout;
  final Duration bundleTimeout;
  final Duration attestationTimeout;
  final Duration integrityTimeout;

  /// Budget for the fire-and-forget controls (setSecure, PCM, app details).
  final Duration controlTimeout;

  Stream<NativeEvent>? _events;

  @override
  Future<NativeSignals> getSignals() async {
    final map = await _invokeMap('getSignals', timeout: signalsTimeout);
    if (map == null) return NativeSignals.defaults();
    try {
      return NativeSignals.fromMap(map);
    } on FormatException catch (e) {
      _log('getSignals decode failed: ${e.message}');
      return NativeSignals.defaults();
    }
  }

  @override
  Future<AppSafetyBundle> getAppSafetyBundle() async {
    final raw = await _invoke<Object?>(
      'getAppSafetyBundle',
      timeout: bundleTimeout,
    );
    if (raw == null) return AppSafetyBundle.unavailable;
    try {
      // Kotlin replies with the collector's JSON string; a map is accepted too.
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) {
        throw const FormatException('bundle is not a JSON object');
      }
      return AppSafetyBundle.fromMap(decoded.cast<Object?, Object?>());
    } on FormatException catch (e) {
      _log('getAppSafetyBundle decode failed: ${e.message}');
      return AppSafetyBundle.unavailable;
    }
  }

  @override
  Future<AppSafetyAttestation> getAppSafetyAttestation() async {
    final map = await _invokeMap(
      'getAppSafetyAttestation',
      timeout: attestationTimeout,
    );
    if (map != null) {
      try {
        return AppSafetyAttestation.fromMap(map);
      } on FormatException catch (e) {
        _log('getAppSafetyAttestation decode failed: ${e.message}');
      }
    }
    return AppSafetyAttestation(bundle: await getAppSafetyBundle());
  }

  @override
  Future<void> prepareIntegrity(String cloudProjectNumber) async {
    final number = cloudProjectNumber.trim();
    if (number.isEmpty) return;
    await _invoke<void>(
      'prepareIntegrity',
      arguments: <String, Object?>{'cloudProjectNumber': number},
      timeout: controlTimeout,
    );
  }

  @override
  Future<String?> getIntegrityToken(String requestHash) async {
    if (requestHash.isEmpty) return null;
    final token = await _invoke<Object?>(
      'getIntegrityToken',
      arguments: <String, Object?>{'requestHash': requestHash},
      timeout: integrityTimeout,
    );
    return token is String && token.isNotEmpty ? token : null;
  }

  /// A failure here (no activity, channel error) is logged at warning level
  /// in every build: losing FLAG_SECURE must never be silent. Kotlin
  /// remembers the request and re-applies it when an activity attaches.
  @override
  Future<void> setSecure(bool on) async {
    try {
      await _method
          .invokeMethod<void>('setSecure', <String, Object?>{'on': on})
          .timeout(controlTimeout);
    } on PlatformException catch (e) {
      Log.w(_tag, 'setSecure($on) failed: ${e.code}');
    } on MissingPluginException {
      _log('setSecure: plugin not registered');
    } on Object catch (e) {
      Log.w(_tag, 'setSecure($on) failed', e);
    }
  }

  @override
  Future<void> openAppDetails(String package) => _invoke<void>(
    'openAppDetails',
    arguments: <String, Object?>{'package': package},
    timeout: controlTimeout,
  );

  @override
  Future<void> openAccessibilitySettings() =>
      _invoke<void>('openAccessibilitySettings', timeout: controlTimeout);

  @override
  Future<void> uninstallApp(String package) => _invoke<void>(
    'uninstallApp',
    arguments: <String, Object?>{'package': package},
    timeout: controlTimeout,
  );

  @override
  Future<void> openSettingsPanel(SettingsPanel panel, {String? package}) =>
      _invoke<void>(
        'openSettingsPanel',
        arguments: <String, Object?>{
          'panel': panel.wire,
          if (package != null && package.isNotEmpty) 'package': package,
        },
        timeout: controlTimeout,
      );

  @override
  Future<void> playPcm(Uint8List pcm16, int sampleRate) => _invoke<void>(
    'playPcm',
    arguments: <String, Object?>{'bytes': pcm16, 'sampleRate': sampleRate},
    timeout: controlTimeout,
  );

  @override
  Future<void> stopPcm() => _invoke<void>('stopPcm', timeout: controlTimeout);

  @override
  Future<void> enterVoiceSession() =>
      _invoke<void>('enterVoiceSession', timeout: controlTimeout);

  @override
  Future<void> exitVoiceSession() =>
      _invoke<void>('exitVoiceSession', timeout: controlTimeout);

  @override
  Future<bool> requestPhoneStatePermission() async {
    // No timeout: the system dialog takes as long as the user takes.
    try {
      final granted = await _method.invokeMethod<bool>(
        'requestPhoneStatePermission',
      );
      return granted ?? false;
    } on PlatformException catch (e) {
      _log('requestPhoneStatePermission failed: ${e.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<NativeEvent> get events => _events ??= _event
      .receiveBroadcastStream()
      .handleError((Object error) => _log('event stream error: $error'))
      .map<NativeEvent?>(NativeEvent.fromMap)
      .where((NativeEvent? e) => e != null)
      .cast<NativeEvent>();

  // ---------------------------------------------------------------- helpers

  Future<Map<Object?, Object?>?> _invokeMap(
    String method, {
    required Duration timeout,
  }) async {
    final raw = await _invoke<Object?>(method, timeout: timeout);
    return raw is Map ? raw.cast<Object?, Object?>() : null;
  }

  /// Invokes [method] with a timeout; any failure resolves to `null` and is
  /// logged by route only (no bodies, Global Constraints).
  Future<T?> _invoke<T>(
    String method, {
    Object? arguments,
    required Duration timeout,
  }) async {
    try {
      return await _method.invokeMethod<T>(method, arguments).timeout(timeout);
    } on TimeoutException {
      _log('$method timed out after ${timeout.inMilliseconds} ms');
    } on PlatformException catch (e) {
      _log('$method failed: ${e.code}');
    } on MissingPluginException {
      _log('$method: plugin not registered');
    } on Object catch (e) {
      _log('$method: ${e.runtimeType}');
    }
    return null;
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[bhorosha_native] $message');
  }
}

/// System settings pages the findings screen can open (`openSettingsPanel`).
enum SettingsPanel {
  /// "Display over other apps" (`ACTION_MANAGE_OVERLAY_PERMISSION`).
  overlay('overlay'),

  /// Developer options (`ACTION_APPLICATION_DEVELOPMENT_SETTINGS`).
  developer('developer'),

  /// Security settings, where Play Protect lives (`ACTION_SECURITY_SETTINGS`).
  security('security'),

  /// Cast / screen sharing (`ACTION_CAST_SETTINGS`).
  cast('cast');

  const SettingsPanel(this.wire);

  /// The channel argument Kotlin switches on.
  final String wire;
}

final nativeProvider = Provider<BhoroshaNative>(
  (ref) => MethodChannelBhoroshaNative(),
);
