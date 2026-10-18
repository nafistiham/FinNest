/// Test double for [BhoroshaNative]: settable answers, an optional delay on
/// every call, and recorders for the fire-and-forget methods.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/data/native/bhorosha_native.dart';

class FakeBhoroshaNative implements BhoroshaNative {
  FakeBhoroshaNative({
    NativeSignals? signals,
    this.bundle = AppSafetyBundle.empty,
    this.integrityToken,
    this.delay = Duration.zero,
    this.phoneStateGranted = true,
  }) : signals = signals ?? NativeSignals.defaults();

  /// Returned by [getSignals].
  NativeSignals signals;

  /// Returned by [getAppSafetyBundle].
  AppSafetyBundle bundle;

  /// Returned by [getIntegrityToken]; `null` mimics "not prepared".
  String? integrityToken;

  /// Returned by [getAppSafetyAttestation]; when `null`, built from [bundle]
  /// and [integrityToken] with an empty hash.
  AppSafetyAttestation? attestation;

  /// Applied to every call before it resolves (simulates a slow channel).
  Duration delay;

  /// Returned by [requestPhoneStatePermission].
  bool phoneStateGranted;

  /// Recorded `setSecure` arguments, in order.
  final List<bool> secureCalls = [];

  /// Recorded `openAppDetails` packages, in order.
  final List<String> openedPackages = [];

  /// Number of `openAccessibilitySettings` calls.
  int accessibilitySettingsCalls = 0;

  /// Recorded `uninstallApp` packages, in order.
  final List<String> uninstalledPackages = [];

  /// Recorded `openSettingsPanel` calls, in order.
  final List<(SettingsPanel, String?)> settingsPanels = [];

  /// Recorded `playPcm` chunks, in order (sample rates in [pcmSampleRates]).
  final List<Uint8List> pcmChunks = [];
  final List<int> pcmSampleRates = [];

  /// Recorded `prepareIntegrity` numbers (empty numbers are still recorded so
  /// tests can assert the caller's behaviour).
  final List<String> prepared = [];

  /// Recorded `getIntegrityToken` request hashes.
  final List<String> integrityRequests = [];

  int stopPcmCalls = 0;

  /// Number of `enterVoiceSession` / `exitVoiceSession` calls.
  int enterVoiceSessionCalls = 0;
  int exitVoiceSessionCalls = 0;
  int signalsCalls = 0;
  int bundleCalls = 0;

  final StreamController<NativeEvent> _events =
      StreamController<NativeEvent>.broadcast();

  /// Pushes an event to every [events] listener.
  void emit(NativeEvent event) => _events.add(event);

  Future<void> dispose() => _events.close();

  Future<T> _after<T>(T value) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return value;
  }

  @override
  Future<NativeSignals> getSignals() {
    signalsCalls++;
    return _after(signals);
  }

  @override
  Future<AppSafetyBundle> getAppSafetyBundle() {
    bundleCalls++;
    return _after(bundle);
  }

  @override
  Future<AppSafetyAttestation> getAppSafetyAttestation() {
    bundleCalls++;
    return _after(
      attestation ??
          AppSafetyAttestation(bundle: bundle, integrityToken: integrityToken),
    );
  }

  @override
  Future<void> prepareIntegrity(String cloudProjectNumber) {
    prepared.add(cloudProjectNumber);
    return _after(null);
  }

  @override
  Future<String?> getIntegrityToken(String requestHash) {
    integrityRequests.add(requestHash);
    return _after(integrityToken);
  }

  @override
  Future<void> setSecure(bool on) {
    secureCalls.add(on);
    return _after(null);
  }

  @override
  Future<void> openAppDetails(String package) {
    openedPackages.add(package);
    return _after(null);
  }

  @override
  Future<void> openAccessibilitySettings() {
    accessibilitySettingsCalls++;
    return _after(null);
  }

  @override
  Future<void> uninstallApp(String package) {
    uninstalledPackages.add(package);
    return _after(null);
  }

  @override
  Future<void> openSettingsPanel(SettingsPanel panel, {String? package}) {
    settingsPanels.add((panel, package));
    return _after(null);
  }

  @override
  Future<void> playPcm(Uint8List pcm16, int sampleRate) {
    pcmChunks.add(pcm16);
    pcmSampleRates.add(sampleRate);
    return _after(null);
  }

  @override
  Future<void> stopPcm() {
    stopPcmCalls++;
    return _after(null);
  }

  @override
  Future<void> enterVoiceSession() {
    enterVoiceSessionCalls++;
    return _after(null);
  }

  @override
  Future<void> exitVoiceSession() {
    exitVoiceSessionCalls++;
    return _after(null);
  }

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  Future<bool> requestPhoneStatePermission() => _after(phoneStateGranted);
}
