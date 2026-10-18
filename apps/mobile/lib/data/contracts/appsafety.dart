/// `/v1/appsafety/check`, `GET /v1/appsafety/latest/{uid}` and the demo
/// integrity endpoint (contracts.py).
library;

import 'package:bhorosha/data/contracts/common.dart';

/// `class InstalledApp(Strict)`.
class InstalledApp {
  const InstalledApp({
    required this.package,
    this.label = '',
    this.installer,
    this.version = '',
    this.permissions = const [],
    this.hasAccessibilityService = false,
    this.accessibilityEnabled = false,
    this.targetSdk,
    this.firstInstall,
    this.hasNotificationListener = false,
    this.hasHceService = false,
    this.isDefaultSmsApp = false,
    this.launcherIconHidden = false,
    this.installerDeclaresInstallPackages = false,
  });

  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
    package: requireString(json, 'package'),
    label: readString(json, 'label', ''),
    installer: readStringOrNull(json, 'installer'),
    version: readString(json, 'version', ''),
    permissions: readList(json, 'permissions', stringItem),
    hasAccessibilityService: readBool(json, 'has_accessibility_service', false),
    accessibilityEnabled: readBool(json, 'accessibility_enabled', false),
    targetSdk: readIntOrNull(json, 'target_sdk'),
    firstInstall: readStringOrNull(json, 'first_install'),
    hasNotificationListener: readBool(json, 'has_notification_listener', false),
    hasHceService: readBool(json, 'has_hce_service', false),
    isDefaultSmsApp: readBool(json, 'is_default_sms_app', false),
    launcherIconHidden: readBool(json, 'launcher_icon_hidden', false),
    installerDeclaresInstallPackages: readBool(
      json,
      'installer_declares_install_packages',
      false,
    ),
  );

  final String package;
  final String label;
  final String? installer;
  final String version;
  final List<String> permissions;
  final bool hasAccessibilityService;
  final bool accessibilityEnabled;
  final int? targetSdk;
  final String? firstInstall;
  final bool hasNotificationListener;
  final bool hasHceService;
  final bool isDefaultSmsApp;
  final bool launcherIconHidden;
  final bool installerDeclaresInstallPackages;

  /// `version` is omitted while it is the empty default. The deployed
  /// risk-api (revision 00011) now knows the field, so this is only a
  /// courtesy to older `extra="forbid"` deployments; the parity test's
  /// `pendingDeploy` allowlist tracks any field the fixture still lacks.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'package': package,
    'label': label,
    'installer': installer,
    if (version.isNotEmpty) 'version': version,
    'permissions': List<String>.of(permissions),
    'has_accessibility_service': hasAccessibilityService,
    'accessibility_enabled': accessibilityEnabled,
    'target_sdk': targetSdk,
    'first_install': firstInstall,
    'has_notification_listener': hasNotificationListener,
    'has_hce_service': hasHceService,
    'is_default_sms_app': isDefaultSmsApp,
    'launcher_icon_hidden': launcherIconHidden,
    'installer_declares_install_packages': installerDeclaresInstallPackages,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstalledApp &&
          package == other.package &&
          label == other.label &&
          installer == other.installer &&
          version == other.version &&
          listEq(permissions, other.permissions) &&
          hasAccessibilityService == other.hasAccessibilityService &&
          accessibilityEnabled == other.accessibilityEnabled &&
          targetSdk == other.targetSdk &&
          firstInstall == other.firstInstall &&
          hasNotificationListener == other.hasNotificationListener &&
          hasHceService == other.hasHceService &&
          isDefaultSmsApp == other.isDefaultSmsApp &&
          launcherIconHidden == other.launcherIconHidden &&
          installerDeclaresInstallPackages ==
              other.installerDeclaresInstallPackages;

  @override
  int get hashCode => Object.hash(
    package,
    label,
    installer,
    version,
    hashList(permissions),
    hasAccessibilityService,
    accessibilityEnabled,
    targetSdk,
    firstInstall,
    hasNotificationListener,
    hasHceService,
    isDefaultSmsApp,
    launcherIconHidden,
    installerDeclaresInstallPackages,
  );

  @override
  String toString() => 'InstalledApp(${toJson()})';
}

/// `class DeviceState(Strict)`.
class DeviceState {
  const DeviceState({
    this.overlayHolders = const [],
    this.deviceAdmins = const [],
    this.devOptions = false,
    this.adb = false,
    this.rooted = false,
    this.playProtect = true,
    this.sdkInt,
    this.defaultSmsPackage,
    this.nfcDefaultPaymentPackage,
  });

  factory DeviceState.fromJson(Map<String, dynamic> json) => DeviceState(
    overlayHolders: readList(json, 'overlay_holders', stringItem),
    deviceAdmins: readList(json, 'device_admins', stringItem),
    devOptions: readBool(json, 'dev_options', false),
    adb: readBool(json, 'adb', false),
    rooted: readBool(json, 'rooted', false),
    playProtect: readBool(json, 'play_protect', true),
    sdkInt: readIntOrNull(json, 'sdk_int'),
    defaultSmsPackage: readStringOrNull(json, 'default_sms_package'),
    nfcDefaultPaymentPackage: readStringOrNull(
      json,
      'nfc_default_payment_package',
    ),
  );

  final List<String> overlayHolders;
  final List<String> deviceAdmins;
  final bool devOptions;
  final bool adb;
  final bool rooted;
  final bool playProtect;
  final int? sdkInt;
  final String? defaultSmsPackage;
  final String? nfcDefaultPaymentPackage;

  /// Pass [unchanged] (the default) to keep a nullable value; `null` clears it.
  DeviceState copyWith({
    List<String>? overlayHolders,
    List<String>? deviceAdmins,
    bool? devOptions,
    bool? adb,
    bool? rooted,
    bool? playProtect,
    Object? sdkInt = unchanged,
    Object? defaultSmsPackage = unchanged,
    Object? nfcDefaultPaymentPackage = unchanged,
  }) => DeviceState(
    overlayHolders: overlayHolders ?? this.overlayHolders,
    deviceAdmins: deviceAdmins ?? this.deviceAdmins,
    devOptions: devOptions ?? this.devOptions,
    adb: adb ?? this.adb,
    rooted: rooted ?? this.rooted,
    playProtect: playProtect ?? this.playProtect,
    sdkInt: identical(sdkInt, unchanged) ? this.sdkInt : sdkInt as int?,
    defaultSmsPackage: identical(defaultSmsPackage, unchanged)
        ? this.defaultSmsPackage
        : defaultSmsPackage as String?,
    nfcDefaultPaymentPackage: identical(nfcDefaultPaymentPackage, unchanged)
        ? this.nfcDefaultPaymentPackage
        : nfcDefaultPaymentPackage as String?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'overlay_holders': List<String>.of(overlayHolders),
    'device_admins': List<String>.of(deviceAdmins),
    'dev_options': devOptions,
    'adb': adb,
    'rooted': rooted,
    'play_protect': playProtect,
    'sdk_int': sdkInt,
    'default_sms_package': defaultSmsPackage,
    'nfc_default_payment_package': nfcDefaultPaymentPackage,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceState &&
          listEq(overlayHolders, other.overlayHolders) &&
          listEq(deviceAdmins, other.deviceAdmins) &&
          devOptions == other.devOptions &&
          adb == other.adb &&
          rooted == other.rooted &&
          playProtect == other.playProtect &&
          sdkInt == other.sdkInt &&
          defaultSmsPackage == other.defaultSmsPackage &&
          nfcDefaultPaymentPackage == other.nfcDefaultPaymentPackage;

  @override
  int get hashCode => Object.hash(
    hashList(overlayHolders),
    hashList(deviceAdmins),
    devOptions,
    adb,
    rooted,
    playProtect,
    sdkInt,
    defaultSmsPackage,
    nfcDefaultPaymentPackage,
  );

  @override
  String toString() => 'DeviceState(${toJson()})';
}

/// `class AppSafetyRequest(Strict)`.
class AppSafetyRequest {
  const AppSafetyRequest({
    this.installedApps = const [],
    this.device = const DeviceState(),
    this.integrityToken,
  });

  factory AppSafetyRequest.fromJson(Map<String, dynamic> json) =>
      AppSafetyRequest(
        installedApps: readList(
          json,
          'installed_apps',
          objectItem(InstalledApp.fromJson),
        ),
        device: readObject(
          json,
          'device',
          DeviceState.fromJson,
          const DeviceState(),
        ),
        integrityToken: readStringOrNull(json, 'integrity_token'),
      );

  /// `Field(max_length=500)` in contracts.py.
  static const int maxInstalledApps = 500;

  final List<InstalledApp> installedApps;
  final DeviceState device;
  final String? integrityToken;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'installed_apps': installedApps.map((a) => a.toJson()).toList(),
    'device': device.toJson(),
    'integrity_token': integrityToken,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyRequest &&
          listEq(installedApps, other.installedApps) &&
          device == other.device &&
          integrityToken == other.integrityToken;

  @override
  int get hashCode =>
      Object.hash(hashList(installedApps), device, integrityToken);

  @override
  String toString() => 'AppSafetyRequest(${toJson()})';
}

/// `class Finding(Strict)`.
///
/// [severity] is `low|medium|high|critical` and [scope] is `app|device` on
/// the wire (see [scopeApp], [scopeDevice]); both are kept as strings because
/// the plan does not bind enums for them.
class Finding {
  const Finding({
    required this.package,
    required this.signal,
    required this.severity,
    required this.evidence,
    required this.explanationBn,
    required this.explanationEn,
    this.titleBn = '',
    this.titleEn = '',
    this.scope = scopeApp,
  });

  factory Finding.fromJson(Map<String, dynamic> json) => Finding(
    package: requireString(json, 'package'),
    signal: requireString(json, 'signal'),
    severity: requireString(json, 'severity'),
    evidence: requireString(json, 'evidence'),
    explanationBn: requireString(json, 'explanation_bn'),
    explanationEn: requireString(json, 'explanation_en'),
    titleBn: readString(json, 'title_bn', ''),
    titleEn: readString(json, 'title_en', ''),
    scope: readString(json, 'scope', scopeApp),
  );

  static const String scopeApp = 'app';
  static const String scopeDevice = 'device';

  final String package;
  final String signal;
  final String severity;
  final String evidence;
  final String explanationBn;
  final String explanationEn;
  final String titleBn;
  final String titleEn;
  final String scope;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'package': package,
    'signal': signal,
    'severity': severity,
    'evidence': evidence,
    'explanation_bn': explanationBn,
    'explanation_en': explanationEn,
    'title_bn': titleBn,
    'title_en': titleEn,
    'scope': scope,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Finding &&
          package == other.package &&
          signal == other.signal &&
          severity == other.severity &&
          evidence == other.evidence &&
          explanationBn == other.explanationBn &&
          explanationEn == other.explanationEn &&
          titleBn == other.titleBn &&
          titleEn == other.titleEn &&
          scope == other.scope;

  @override
  int get hashCode => Object.hash(
    package,
    signal,
    severity,
    evidence,
    explanationBn,
    explanationEn,
    titleBn,
    titleEn,
    scope,
  );

  @override
  String toString() => 'Finding(${toJson()})';
}

/// `class UninstallTarget(Strict)`: one Uninstall button on the findings
/// screen. [deepLink] is `package:<pkg>` for
/// `Settings.ACTION_APPLICATION_DETAILS_SETTINGS`.
class UninstallTarget {
  const UninstallTarget({
    required this.package,
    required this.label,
    required this.primarySignal,
    required this.deepLink,
  });

  factory UninstallTarget.fromJson(Map<String, dynamic> json) =>
      UninstallTarget(
        package: requireString(json, 'package'),
        label: requireString(json, 'label'),
        primarySignal: requireString(json, 'primary_signal'),
        deepLink: requireString(json, 'deep_link'),
      );

  final String package;
  final String label;
  final String primarySignal;
  final String deepLink;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'package': package,
    'label': label,
    'primary_signal': primarySignal,
    'deep_link': deepLink,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UninstallTarget &&
          package == other.package &&
          label == other.label &&
          primarySignal == other.primarySignal &&
          deepLink == other.deepLink;

  @override
  int get hashCode => Object.hash(package, label, primarySignal, deepLink);

  @override
  String toString() => 'UninstallTarget(${toJson()})';
}

/// `class AppSafetyResponse(Strict)`.
///
/// [attestation] is one of `none|failed|tampered|mismatch|unbound|virtual|
/// basic|device|strong`; [resolution] is one of `NONE|UNINSTALL_AND_RECHECK|
/// FIX_PHONE_AND_RECHECK|REINSTALL_FROM_PLAY|CALL_BANK|WAIT`. Both are plain
/// strings in contracts.py.
class AppSafetyResponse {
  const AppSafetyResponse({
    required this.verdict,
    required this.riskScore,
    required this.findings,
    required this.recommendedAction,
    required this.appsToUninstall,
    required this.userMessageBn,
    required this.userMessageEn,
    required this.simulatedVerdict,
    this.modelVersion = '',
    this.agreesWithClassifier,
    this.disagreementReason = '',
    this.attestation = 'none',
    this.resolution = 'NONE',
    this.recheckLiftsBlock = false,
    this.uninstallTargets = const [],
    this.checkId = '',
    this.validUntil = '',
  });

  factory AppSafetyResponse.fromJson(Map<String, dynamic> json) =>
      AppSafetyResponse(
        verdict: requireEnum(json, 'verdict', SafetyVerdict.fromWire),
        riskScore: requireDouble(json, 'risk_score'),
        findings: requireList(json, 'findings', objectItem(Finding.fromJson)),
        recommendedAction: requireString(json, 'recommended_action'),
        appsToUninstall: requireList(json, 'apps_to_uninstall', stringItem),
        userMessageBn: requireString(json, 'user_message_bn'),
        userMessageEn: requireString(json, 'user_message_en'),
        simulatedVerdict: requireBool(json, 'simulated_verdict'),
        modelVersion: readString(json, 'model_version', ''),
        agreesWithClassifier: readBoolOrNull(json, 'agrees_with_classifier'),
        disagreementReason: readString(json, 'disagreement_reason', ''),
        attestation: readString(json, 'attestation', 'none'),
        resolution: readString(json, 'resolution', 'NONE'),
        recheckLiftsBlock: readBool(json, 'recheck_lifts_block', false),
        uninstallTargets: readList(
          json,
          'uninstall_targets',
          objectItem(UninstallTarget.fromJson),
        ),
        checkId: readString(json, 'check_id', ''),
        validUntil: readString(json, 'valid_until', ''),
      );

  final SafetyVerdict verdict;
  final double riskScore;
  final List<Finding> findings;
  final String recommendedAction;
  final List<String> appsToUninstall;
  final String userMessageBn;
  final String userMessageEn;
  final bool simulatedVerdict;
  final String modelVersion;
  final bool? agreesWithClassifier;
  final String disagreementReason;
  final String attestation;
  final String resolution;
  final bool recheckLiftsBlock;
  final List<UninstallTarget> uninstallTargets;
  final String checkId;

  /// ISO-8601; until then `/v1/risk/score` reads this verdict for the uid.
  final String validUntil;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'verdict': verdict.wire,
    'risk_score': riskScore,
    'findings': findings.map((f) => f.toJson()).toList(),
    'recommended_action': recommendedAction,
    'apps_to_uninstall': List<String>.of(appsToUninstall),
    'user_message_bn': userMessageBn,
    'user_message_en': userMessageEn,
    'simulated_verdict': simulatedVerdict,
    'model_version': modelVersion,
    'agrees_with_classifier': agreesWithClassifier,
    'disagreement_reason': disagreementReason,
    'attestation': attestation,
    'resolution': resolution,
    'recheck_lifts_block': recheckLiftsBlock,
    'uninstall_targets': uninstallTargets.map((u) => u.toJson()).toList(),
    'check_id': checkId,
    'valid_until': validUntil,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyResponse &&
          verdict == other.verdict &&
          riskScore == other.riskScore &&
          listEq(findings, other.findings) &&
          recommendedAction == other.recommendedAction &&
          listEq(appsToUninstall, other.appsToUninstall) &&
          userMessageBn == other.userMessageBn &&
          userMessageEn == other.userMessageEn &&
          simulatedVerdict == other.simulatedVerdict &&
          modelVersion == other.modelVersion &&
          agreesWithClassifier == other.agreesWithClassifier &&
          disagreementReason == other.disagreementReason &&
          attestation == other.attestation &&
          resolution == other.resolution &&
          recheckLiftsBlock == other.recheckLiftsBlock &&
          listEq(uninstallTargets, other.uninstallTargets) &&
          checkId == other.checkId &&
          validUntil == other.validUntil;

  @override
  int get hashCode => Object.hash(
    verdict,
    riskScore,
    hashList(findings),
    recommendedAction,
    hashList(appsToUninstall),
    userMessageBn,
    userMessageEn,
    simulatedVerdict,
    modelVersion,
    agreesWithClassifier,
    disagreementReason,
    attestation,
    resolution,
    recheckLiftsBlock,
    hashList(uninstallTargets),
    checkId,
    validUntil,
  );

  @override
  String toString() => 'AppSafetyResponse(${toJson()})';
}

/// `class AppSafetyLatest(Strict)`: `GET /v1/appsafety/latest/{uid}`, the
/// standing verdict for a uid, or `known == false`.
class AppSafetyLatest {
  const AppSafetyLatest({
    required this.uid,
    required this.known,
    this.verdict = SafetyVerdict.safe,
    this.riskScore = 0.0,
    this.flaggedPackages = const [],
    this.attestation = 'none',
    this.checkedAt = '',
    this.validUntil = '',
    this.source = 'server',
    this.facts = const [],
  });

  factory AppSafetyLatest.fromJson(Map<String, dynamic> json) =>
      AppSafetyLatest(
        uid: requireString(json, 'uid'),
        known: requireBool(json, 'known'),
        verdict: readEnum(
          json,
          'verdict',
          SafetyVerdict.fromWire,
          SafetyVerdict.safe,
        ),
        riskScore: readDouble(json, 'risk_score', 0.0),
        flaggedPackages: readList(json, 'flagged_packages', stringItem),
        attestation: readString(json, 'attestation', 'none'),
        checkedAt: readString(json, 'checked_at', ''),
        validUntil: readString(json, 'valid_until', ''),
        source: readString(json, 'source', 'server'),
        facts: readList(json, 'facts', stringItem),
      );

  final String uid;
  final bool known;
  final SafetyVerdict verdict;
  final double riskScore;
  final List<String> flaggedPackages;
  final String attestation;
  final String checkedAt;
  final String validUntil;

  /// `server` when risk-mw ran the check itself; `phone` when the
  /// answer is the phone's own report (only for callers that ask for it with
  /// `?include_phone=true`, which the app never does).
  final String source;

  /// The closed-set phone facts behind the verdict
  /// (`REMOTE_CONTROL`, `READS_MESSAGES`, ...), never an app name.
  final List<String> facts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'uid': uid,
    'known': known,
    'verdict': verdict.wire,
    'risk_score': riskScore,
    'flagged_packages': List<String>.of(flaggedPackages),
    'attestation': attestation,
    'checked_at': checkedAt,
    'valid_until': validUntil,
    'source': source,
    'facts': List<String>.of(facts),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSafetyLatest &&
          uid == other.uid &&
          known == other.known &&
          verdict == other.verdict &&
          riskScore == other.riskScore &&
          listEq(flaggedPackages, other.flaggedPackages) &&
          attestation == other.attestation &&
          checkedAt == other.checkedAt &&
          validUntil == other.validUntil &&
          source == other.source &&
          listEq(facts, other.facts);

  @override
  int get hashCode => Object.hash(
    uid,
    known,
    verdict,
    riskScore,
    hashList(flaggedPackages),
    attestation,
    checkedAt,
    validUntil,
    source,
    hashList(facts),
  );

  @override
  String toString() => 'AppSafetyLatest(${toJson()})';
}

/// `class DemoIntegrityRequest(Strict)`: the demo panel asks the server to
/// mint a signed synthetic Play Integrity verdict bound to the bundle the
/// app is about to send (demo mode only).
///
/// [appRecognition] is `PLAY_RECOGNIZED|UNRECOGNIZED_VERSION|UNEVALUATED`
/// on the wire (see the `appRecognition*` constants); kept as a string.
class DemoIntegrityRequest {
  const DemoIntegrityRequest({
    this.installedApps = const [],
    this.device = const DeviceState(),
    this.appsDetected = const [],
    this.playProtectVerdict = 'NO_ISSUES',
    this.appRecognition = appRecognitionPlayRecognized,
    this.deviceRecognition = const ['MEETS_DEVICE_INTEGRITY'],
    this.bound = true,
  });

  factory DemoIntegrityRequest.fromJson(Map<String, dynamic> json) =>
      DemoIntegrityRequest(
        installedApps: readList(
          json,
          'installed_apps',
          objectItem(InstalledApp.fromJson),
        ),
        device: readObject(
          json,
          'device',
          DeviceState.fromJson,
          const DeviceState(),
        ),
        appsDetected: readList(json, 'apps_detected', stringItem),
        playProtectVerdict: readString(
          json,
          'play_protect_verdict',
          'NO_ISSUES',
        ),
        appRecognition: readString(
          json,
          'app_recognition',
          appRecognitionPlayRecognized,
        ),
        deviceRecognition: json.containsKey('device_recognition')
            ? readList(json, 'device_recognition', stringItem)
            : const ['MEETS_DEVICE_INTEGRITY'],
        bound: readBool(json, 'bound', true),
      );

  static const String appRecognitionPlayRecognized = 'PLAY_RECOGNIZED';
  static const String appRecognitionUnrecognizedVersion =
      'UNRECOGNIZED_VERSION';
  static const String appRecognitionUnevaluated = 'UNEVALUATED';

  final List<InstalledApp> installedApps;
  final DeviceState device;
  final List<String> appsDetected;
  final String playProtectVerdict;
  final String appRecognition;
  final List<String> deviceRecognition;

  /// `false` mints a token with no requestHash (an "unbound" attestation).
  final bool bound;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'installed_apps': installedApps.map((a) => a.toJson()).toList(),
    'device': device.toJson(),
    'apps_detected': List<String>.of(appsDetected),
    'play_protect_verdict': playProtectVerdict,
    'app_recognition': appRecognition,
    'device_recognition': List<String>.of(deviceRecognition),
    'bound': bound,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DemoIntegrityRequest &&
          listEq(installedApps, other.installedApps) &&
          device == other.device &&
          listEq(appsDetected, other.appsDetected) &&
          playProtectVerdict == other.playProtectVerdict &&
          appRecognition == other.appRecognition &&
          listEq(deviceRecognition, other.deviceRecognition) &&
          bound == other.bound;

  @override
  int get hashCode => Object.hash(
    hashList(installedApps),
    device,
    hashList(appsDetected),
    playProtectVerdict,
    appRecognition,
    hashList(deviceRecognition),
    bound,
  );

  @override
  String toString() => 'DemoIntegrityRequest(${toJson()})';
}

/// `class DemoIntegrityResponse(Strict)`.
class DemoIntegrityResponse {
  const DemoIntegrityResponse({
    required this.integrityToken,
    required this.bundleHash,
    required this.expiresInS,
  });

  factory DemoIntegrityResponse.fromJson(Map<String, dynamic> json) =>
      DemoIntegrityResponse(
        integrityToken: requireString(json, 'integrity_token'),
        bundleHash: requireString(json, 'bundle_hash'),
        expiresInS: requireInt(json, 'expires_in_s'),
      );

  final String integrityToken;
  final String bundleHash;
  final int expiresInS;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'integrity_token': integrityToken,
    'bundle_hash': bundleHash,
    'expires_in_s': expiresInS,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DemoIntegrityResponse &&
          integrityToken == other.integrityToken &&
          bundleHash == other.bundleHash &&
          expiresInS == other.expiresInS;

  @override
  int get hashCode => Object.hash(integrityToken, bundleHash, expiresInS);

  @override
  String toString() => 'DemoIntegrityResponse(${toJson()})';
}
