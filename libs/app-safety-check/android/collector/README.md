# App Safety collector: Android reference sources for the Flutter app

Two Kotlin files that make the Flutter app able to call `getAppSafetyBundle()` and get back the
exact JSON body of `POST /v1/appsafety/check` (`AppSafetyRequest` in
`services/risk-mw/app/contracts.py`).

| File | What it is |
|---|---|
| `AppSafetyCollector.kt` | `fun collect(context): JSONObject` — builds `{installed_apps[], device{}, integrity_token}`; `fun integrityToken(...)` stub for Play Integrity |
| `MainActivity.kt` | `FlutterActivity` subclass that registers the MethodChannel and runs `collect()` on a worker thread |

## 1. Channel contract

- Channel name: `bhorosha/appsafety`
- Method: `getAppSafetyBundle` (no arguments)
- Reply: a JSON **string** that is, byte for byte, an `AppSafetyRequest` body. `integrity_token`
  is `null` in the reply; Dart fills it in (section 5) before posting.

```dart
const _channel = MethodChannel('bhorosha/appsafety');

Future<Map<String, dynamic>> appSafetyBundle() async {
  final raw = await _channel.invokeMethod<String>('getAppSafetyBundle');
  return jsonDecode(raw!) as Map<String, dynamic>;
}

// body['integrity_token'] = token;  then  POST /v1/appsafety/check with body
```

Shape of the reply (one entry per visible app):

```json
{
  "installed_apps": [
    {
      "package": "com.demo.takanow",
      "label": "TakaNow Loan",
      "installer": "com.android.chrome",
      "version": "1.0",
      "permissions": ["android.permission.READ_SMS", "android.permission.SYSTEM_ALERT_WINDOW"],
      "has_accessibility_service": true,
      "accessibility_enabled": true,
      "target_sdk": 35,
      "first_install": "2026-10-16T09:12:03Z",
      "has_notification_listener": false,
      "has_hce_service": false,
      "is_default_sms_app": false,
      "launcher_icon_hidden": false,
      "installer_declares_install_packages": false
    }
  ],
  "device": {
    "overlay_holders": ["com.demo.takanow"],
    "device_admins": [],
    "dev_options": true,
    "adb": true,
    "rooted": false,
    "play_protect": true,
    "sdk_int": 35,
    "default_sms_package": "com.google.android.apps.messaging",
    "nfc_default_payment_package": "com.google.android.apps.walletnfcrel"
  },
  "integrity_token": null
}
```

Field notes (what the server expects):

- `installer`: `"system"` for `FLAG_SYSTEM` apps; otherwise the installing package name; `null`
  means manual/ADB and is classified as sideloaded. On API 30+ `getInstallSourceInfo` is used;
  when the installer of record is the system package installer the originating package (browser,
  messenger, file manager) is sent instead; on API 33+ `PACKAGE_SOURCE_DOWNLOADED_FILE` /
  `PACKAGE_SOURCE_LOCAL_FILE` (the OS's own sideload verdict, Android 15 CDD 9.8) forces the
  originating package or `com.google.android.packageinstaller`, so the server classifies it as
  sideloaded even when names are missing.
- `version`: `versionName`. **Additive field** — `contracts.py` uses `extra="forbid"`, so the
  the server's `InstalledApp.version` is `str` (default ""); the collector sends `""` when `versionName` is null.
  or the request is rejected with 422. Until then, Dart may drop the key.
- `accessibility_enabled`: from `AccessibilityManager.getEnabledAccessibilityServiceList`,
  matched by package. Sideloaded + enabled on Android 13+ implies the user passed
  "Allow restricted settings" → `SIDELOADED_ACCESSIBILITY` critical.
- `overlay_holders`: `AppOpsManager.unsafeCheckOpNoThrow(OPSTR_SYSTEM_ALERT_WINDOW)` ==
  `MODE_ALLOWED` for each visible app; if the op check throws, falls back to "declares
  SYSTEM_ALERT_WINDOW" (over-reports). Verify on the test device in hour 0.
- `play_protect`: not readable without Play Integrity; always `true`. The real Play Protect
  signal is `playProtectVerdict` inside the integrity token's `environmentDetails`, decoded on
  the server.
- Open question carried from the spec: whether `getEnabledAccessibilityServiceList` and
  `getActiveAdmins` are visibility-filtered on API 30+. The code handles both outcomes; it only
  affects whether apps outside `<queries>` can show up in those two lists.

2026 signals (additive, defaulted on the server; behaviours from
`research_notes/App safety 2026 and tamper resistance/threat_landscape_2026.md`, Key Question 4). The
collector reports facts; the server combines them with `installer` and scores them.

| Field | How it is derived | What it catches (KQ4 rule) |
|---|---|---|
| `has_notification_listener` | a `<service>` protected by `BIND_NOTIFICATION_LISTENER_SERVICE` | OTP reading without `READ_SMS`; one of Play Protect's four sideload-fraud permissions (rule 4) |
| `has_hce_service` | the package resolves for `android.nfc.cardemulation.action.HOST_APDU_SERVICE` | NFC relay: Tap-and-Steal wave, PhantomCard, NGate, SuperCard X, RatOn (rule 5) |
| `is_default_sms_app` | `Telephony.Sms.getDefaultSmsPackage(context) == package` | `ROLE_SMS` takeover: Crocodilus `SpinderSpike`, Google's 2026 "SMS forwarding" warning (rule 4) |
| `launcher_icon_hidden` | visible (via HCE / listener / SMS role / declared list) but resolves no MAIN/LAUNCHER activity, and not `FLAG_SYSTEM` | icon hiding after install, what Google's Pixel-only Live Threat Detection keys on (rule 9). TeamViewer add-ons legitimately have no icon, so never score it alone |
| `installer_declares_install_packages` | the raw `installingPackageName` is a visible, non-system, non-store package that declares `REQUEST_INSTALL_PACKAGES` | session-installer droppers: SecuriDropper, Zombinder, Herodotus `com.cd3.app` (rule 3). An installer outside `<queries>` cannot be inspected and yields `false` (under-reports) |
| `device.sdk_int` | `Build.VERSION.SDK_INT` | `<= 31` lacks Restricted Settings, OTP redaction and in-call blocks, so the server raises rule weights (rule 13) |
| `device.default_sms_package` | `Telephony.Sms.getDefaultSmsPackage` | the SMS-role holder even when it is outside `<queries>` |
| `device.nfc_default_payment_package` | `CardEmulation.isDefaultServiceForCategory(component, CATEGORY_PAYMENT)` over the visible `HostApduService`s, then the hidden `Settings.Secure` key `nfc_payment_default_component` | relay app installed as the default payment service (rule 5) |

Limitation on `nfc_default_payment_package`: the public API is per-component, so the collector can only
test services it can see. `null` means "unknown" (no NFC/HCE on the device, the default is outside
`<queries>`, the `NFC` permission is missing, or the OEM leaves the settings key empty), never "none".

## 2. Where the files go

```
android/app/src/main/kotlin/com/bhorosha/appsafety/AppSafetyCollector.kt   (copy as is)
android/app/src/main/kotlin/<applicationId path>/MainActivity.kt           (replace Flutter's default)
```

Change the `package` line of `MainActivity.kt` to the Flutter project's applicationId package and
keep `android:name=".MainActivity"` in the manifest. No Gradle dependencies are needed:
`org.json`, `java.time` (minSdk 26) and the Android framework are enough. For
`nfc_default_payment_package` add the normal (install-time, no prompt) permission and the optional feature:

```xml
<uses-permission android:name="android.permission.NFC" />
<uses-feature android:name="android.hardware.nfc" android:required="false" />
<uses-feature android:name="android.hardware.nfc.hce" android:required="false" />
```

Without them the field is simply `null`; nothing else in the bundle depends on NFC.

## 3. Manifest `<queries>` block (package visibility, API 30+)

Add inside `<manifest>` (sibling of `<application>`):

```xml
<queries>
    <!-- Every app with a launcher icon: the user-facing install base. -->
    <intent>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent>

    <!-- 2026 signals (threat_landscape_2026.md KQ4). These also expose icon-hidden apps that declare them,
         which is what makes `launcher_icon_hidden` observable at all. -->
    <intent>  <!-- NFC relay: HostApduService (rule 5) -->
        <action android:name="android.nfc.cardemulation.action.HOST_APDU_SERVICE" />
    </intent>
    <intent>  <!-- OTP theft via notification listener (rule 4) -->
        <action android:name="android.service.notification.NotificationListenerService" />
    </intent>
    <intent>  <!-- SMS apps, so the ROLE_SMS holder can be inspected (rule 4) -->
        <action android:name="android.intent.action.SENDTO" />
        <data android:scheme="smsto" />
    </intent>

    <!-- Remote-access tools scammers abuse ("customer care" walks the victim through installing
         one and reading out the code). Rule KNOWN_RAT, "remote control" tier.
         Source: project research policy_rules.md section 4. -->
    <package android:name="com.anydesk.anydeskandroid" />              <!-- AnyDesk -->
    <package android:name="com.teamviewer.quicksupport.market" />      <!-- TeamViewer QuickSupport -->
    <package android:name="com.teamviewer.host.market" />              <!-- TeamViewer Host -->
    <package android:name="com.teamviewer.quicksupport.addon.universal" /> <!-- TeamViewer Universal Add-On -->
    <package android:name="com.carriez.flutter_hbb" />                 <!-- RustDesk (sideload-only) -->
    <package android:name="com.sand.airdroid" />                       <!-- AirDroid -->
    <package android:name="com.sand.airsos" />                         <!-- AirDroid Remote Support -->
    <package android:name="com.sand.airmirror" />                      <!-- AirMirror -->
    <package android:name="com.zoho.assist.agent" />                   <!-- Zoho Assist -->
    <package android:name="com.splashtop.sos" />                       <!-- Splashtop SOS -->
    <package android:name="com.splashtop.streamer.csrs" />             <!-- Splashtop Streamer -->
    <package android:name="com.screenconnect.androidclient" />         <!-- ScreenConnect -->
    <package android:name="com.logmein.rescuemobile" />                <!-- LogMeIn Rescue -->
    <package android:name="com.islonline.isllight.mobile.android" />   <!-- ISL Light -->
    <package android:name="com.teknopars.AlpemixPro" />                <!-- Alpemix -->
    <package android:name="it.nanosystems.Supremo" />                  <!-- Supremo -->

    <!-- TakaNow Loan demo fixture -->
    <package android:name="com.demo.takanow" />
</queries>
```

Keep the list in sync with `AppSafetyCollector.DECLARED_PACKAGES`: a package that is installed but
not declared makes `getPackageInfo` throw `NameNotFoundException`, so it silently disappears from
the bundle. Viewer-only clients (Chrome Remote Desktop, Windows App, RemotePC Viewer, TeamViewer
Remote Control) and mirrors (Vysor, ApowerMirror) are deliberately not listed: they are the "low"
tier and cannot control this phone.

## 4. Why no `QUERY_ALL_PACKAGES`

Google Play's package-visibility policy only allows `QUERY_ALL_PACKAGES` for apps whose core
purpose needs it, and only after a declaration form in Play Console. Banking and financial-services
apps **are** an approved category (device-security / fraud-prevention use), which is the production
path: ship the declaration with the Play listing and the whole install base becomes visible. The
prototype is not on Play, so it uses scoped `<queries>` instead; an app that requests
`QUERY_ALL_PACKAGES` without an approved declaration is rejected or removed from Play.

**Hard constraint:** the client MUST NOT request `QUERY_ALL_PACKAGES`, `READ_SMS`,
`RECEIVE_SMS` or `READ_CALL_LOG`. These are the very permissions the rules layer flags on other
apps (Play Protect's four fraud permissions and the Personal Loans policy); a banking app that
declares them fails its own check and the Play review.

## 5. `integrity_token`

- **Real path (app on Play):** `AppSafetyCollector.integrityToken(context, requestHash, cb)`
  is a documented stub. Add `com.google.android.play:integrity`, paste the body from the KDoc
  (`StandardIntegrityManager` prepare → request with `requestHash` = `AppSafetyCollector.bundleHash(bundle)`, the SHA-256 the server recomputes over the bundle it receives), opt
  in to `environmentDetails` in Play Console, and forward the token unchanged. The server decodes
  `appAccessRiskVerdict` / `playProtectVerdict` and maps `UNKNOWN_CONTROLLING` to BLOCK.
- **Canonical form of `bundleHash`:** keys sorted, apps sorted by `package`, string arrays sorted,
  booleans `true`/`false`, `null` as `null`, integers as digits, compact separators, UTF-8 without
  `\u` escaping. `APP_KEYS` / `DEVICE_KEYS` in the collector are the exact key lists and must match
  `bhorosha_app_safety_check.integrity.bundle_hash`; whenever a field is added to `contracts.py` both sides
  change together. Every key is always sent: the server hashes the parsed model (defaults filled
  in), so a key the client leaves out hashes as `null` on the phone and as the default on the server.
- **Demo path (prototype):** the Flutter demo panel calls the server-side demo token builder and
  forwards the returned string as `integrity_token`. The format `demo.<base64url json>.<hmac>` is
  owned by the server; the app never builds or inspects it. The UI then shows
  "simulated verdict" from `simulated_verdict: true` in the response.

## 6. Thread and budget

The whole check has a 3 s budget. `collect()` typically takes 50–300 ms for 40–80 launcher
apps; it is run on a single-thread executor and the `MethodChannel.Result` is completed on the main
thread. Dart should put a 2 s timeout around the channel call and fall back to an empty bundle (the server answers CAUTION for an empty list and never lets it clear a standing BLOCK)
(the server then answers from the integrity token alone).

## Why the bundle is hashed into the token (modded clients)

Modified ("mod APK") builds are common in Bangladesh. A patched FinNest app could post a clean, invented bundle and ask
for a SAFE. The server therefore treats the bundle as a claim until a Play Integrity token vouches for it three ways:
`appIntegrity.appRecognitionVerdict == PLAY_RECOGNIZED` (genuine Play-signed build; a re-signed APK gets
`UNRECOGNIZED_VERSION` and is blocked with "reinstall from the Play Store"), `deviceIntegrity` at least
`MEETS_DEVICE_INTEGRITY`, and `requestDetails.requestHash == bundleHash(bundle)`. A token minted for one app list cannot
vouch for another; an empty or shrunken list cannot clear a BLOCK; a bad or expired token counts as "unattested".
In production (`RISK_MW_APPSAFETY_REQUIRE_ATTESTATION=true`) an unattested bundle can never earn SAFE (it gets
`PROCEED_WITH_OTP`). In demo mode the build is not on Play, so the demo panel asks the server for a signed stand-in:

```
POST /v1/appsafety/demo-token   {installed_apps, device, apps_detected?, play_protect_verdict?, app_recognition?, device_recognition?, bound?}
→ {integrity_token, bundle_hash, expires_in_s}
```

and sends that token with the very same `installed_apps` and `device` in `/v1/appsafety/check`. Scenarios for the
panel: clean (defaults), "screen controlled" (`apps_detected: ["UNKNOWN_CONTROLLING"]`), "modded app"
(`app_recognition: "UNRECOGNIZED_VERSION"`), "rooted phone" (`device_recognition: ["MEETS_VIRTUAL_INTEGRITY"]`).
