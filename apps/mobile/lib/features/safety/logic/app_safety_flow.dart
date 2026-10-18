/// US-4 app-safety check (3.8a).
///
/// Collects the attested installed-app bundle from the native channel, merges
/// the bundled fake apps when the demo panel forces a CAUTION or BLOCK
/// verdict (never when a real integrity token is bound to that bundle), obtains an integrity token (real Play Integrity, else a demo
/// token minted by the server, else `null`) and posts the result to
/// `/v1/appsafety/check`. The response is rendered as sent (3.8a "Response
/// fields"); nothing here composes risk copy.
library;

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/repos/repos.dart';

/// The installed-app scan did not answer, so nothing was checked. The badge
/// and the findings screen show their "could not check" state with a retry.
class AppSafetyScanFailed implements Exception {
  const AppSafetyScanFailed();

  @override
  String toString() => 'AppSafetyScanFailed';
}

class AppSafetyFlow {
  AppSafetyFlow({
    required this.api,
    required this.native,
    required this.demoFakeApps,
  });

  static const _tag = 'appsafety';

  final RiskApi api;
  final BhoroshaNative native;

  /// `assets/demo/fake_apps.json`: appended to the bundle only when the demo
  /// panel forces CAUTION or BLOCK, so the server has something to find on an
  /// emulator with nothing sideloaded.
  final List<InstalledApp> demoFakeApps;

  /// The request most recently posted (fake apps included), so the findings
  /// screen can resolve a finding's package to the label the bundle carried.
  AppSafetyRequest? get lastRequest => _lastRequest;
  AppSafetyRequest? _lastRequest;

  /// Builds and posts the request. Throws `ApiFailure` through unchanged,
  /// and [AppSafetyScanFailed] without posting anything when the native scan
  /// did not answer: an empty list must never come back SAFE.
  ///
  /// Token order: [integrityToken] when given; else the real Play Integrity
  /// token from the native attestation; else a demo token minted by
  /// `/v1/appsafety/demo-token` over the exact lists about to be sent (the
  /// server recomputes the hash over them); else `null` when minting fails
  /// (for example 404 outside demo mode). The app never fabricates a token.
  Future<AppSafetyResponse> check({
    required DemoState demo,
    String? integrityToken,
  }) async {
    final attestation = await native.getAppSafetyAttestation();
    if (attestation.bundle.failed) {
      Log.w(_tag, 'app scan unavailable: nothing posted');
      throw const AppSafetyScanFailed();
    }
    // A real Play Integrity token is bound to the native bundle's hash:
    // appending the fake apps would break that binding (the server would
    // reject the token), so a forced verdict sends the real bundle as is.
    final List<InstalledApp> apps;
    if (attestation.integrityToken != null) {
      if (_wantsFakeApps(demo.forcedSafetyVerdict)) {
        Log.i(_tag, 'real integrity token bound to the bundle: no fake apps');
      }
      apps = attestation.bundle.installedApps;
    } else {
      apps = installedAppsFor(attestation.bundle, demo);
    }
    final device = attestation.bundle.device;
    final token =
        integrityToken ??
        attestation.integrityToken ??
        await _mintDemoToken(apps, device, demo.integrityScenario);
    final request = AppSafetyRequest(
      installedApps: apps,
      device: device,
      integrityToken: token,
    );
    _lastRequest = request;
    return api.postAppSafety(request);
  }

  /// The standing verdict for [uid] (`GET /v1/appsafety/latest/{uid}`), or
  /// `null` on any failure. Used as the badge fallback when a fresh check
  /// cannot be made.
  Future<AppSafetyLatest?> latest(String uid) async {
    try {
      return await api.getAppSafetyLatest(uid);
    } on ApiFailure catch (e) {
      Log.w(_tag, 'latest unavailable', e);
      return null;
    }
  }

  /// The real bundle, plus [demoFakeApps] (deduplicated by package, real
  /// entries win) when [DemoState.forcedSafetyVerdict] is CAUTION or BLOCK.
  /// A forced SAFE or no forced verdict sends the bundle unchanged.
  List<InstalledApp> installedAppsFor(AppSafetyBundle bundle, DemoState demo) {
    final real = bundle.installedApps;
    if (!_wantsFakeApps(demo.forcedSafetyVerdict) || demoFakeApps.isEmpty) {
      return real;
    }
    final seen = real.map((a) => a.package).toSet();
    final extra = demoFakeApps.where((a) => seen.add(a.package)).toList();
    if (extra.isEmpty) return real;
    // The server caps installed_apps; keep every fake entry and trim the
    // real tail rather than lose the app the demo is about.
    final room = AppSafetyRequest.maxInstalledApps - extra.length;
    final kept = real.length > room ? real.sublist(0, room) : real;
    return List.unmodifiable([...kept, ...extra]);
  }

  /// The demo-token request for [scenario] (`DemoState.integrityScenario`),
  /// bound to the exact [apps] and [device] the check will send.
  static DemoIntegrityRequest demoTokenRequest({
    required List<InstalledApp> apps,
    required DeviceState device,
    String? scenario,
  }) => DemoIntegrityRequest(
    installedApps: apps,
    device: device,
    appsDetected: scenario == scenarioUnknownControlling
        ? const [scenarioUnknownControlling]
        : const [],
    appRecognition: scenario == scenarioUnrecognizedVersion
        ? DemoIntegrityRequest.appRecognitionUnrecognizedVersion
        : DemoIntegrityRequest.appRecognitionPlayRecognized,
    deviceRecognition: scenario == scenarioVirtual
        ? const [scenarioVirtual]
        : const ['MEETS_DEVICE_INTEGRITY'],
    bound: scenario != scenarioUnbound,
  );

  /// `DemoState.integrityScenario` values the demo panel can set.
  static const scenarioUnknownControlling = 'UNKNOWN_CONTROLLING';
  static const scenarioUnrecognizedVersion = 'UNRECOGNIZED_VERSION';
  static const scenarioVirtual = 'MEETS_VIRTUAL_INTEGRITY';
  static const scenarioUnbound = 'unbound';

  Future<String?> _mintDemoToken(
    List<InstalledApp> apps,
    DeviceState device,
    String? scenario,
  ) async {
    try {
      final minted = await api.postAppSafetyDemoToken(
        demoTokenRequest(apps: apps, device: device, scenario: scenario),
      );
      return minted.integrityToken.isEmpty ? null : minted.integrityToken;
    } on ApiFailure catch (e) {
      Log.w(_tag, 'demo token unavailable, checking without a token', e);
      return null;
    }
  }

  static bool _wantsFakeApps(SafetyVerdict? forced) =>
      forced == SafetyVerdict.caution || forced == SafetyVerdict.block;
}
