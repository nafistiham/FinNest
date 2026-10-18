# TakaNow Loan: harmless demo APK for the App Safety Check

`com.demo.takanow` is a test fixture that reproduces every signal the detector looks for
(browser install, "Allow restricted settings", forbidden loan-app permissions, an enabled
accessibility service) **without a single line of malicious code**. Real malware samples never
touch a phone in the demo. "TakaNow Loan" is an invented name; the package is `com.demo.takanow`.

```
takanow/
  build.gradle.kts              app module (applicationId com.demo.takanow, minSdk 26, targetSdk 35)
  settings.gradle.kts           single-module project root
  src/main/AndroidManifest.xml  the declared permissions + the accessibility service
  src/main/java/com/demo/takanow/MainActivity.kt            loan-form screen with the DEMO banner
  src/main/java/com/demo/takanow/EmptyAccessibilityService.kt  empty handlers
  src/main/res/xml/accessibility_service_config.xml          click events only, no window content
  src/main/res/values/strings.xml, values-bn/strings.xml     English and Bangla
```

## 1. Build the debug APK

Android Studio: open the `takanow/` folder as a project, **Build > Build Bundle(s) / APK(s) > Build APK(s)**.

Command line (needs ANDROID_HOME and a Gradle wrapper; copy `gradlew`, `gradlew.bat` and
`gradle/wrapper/` from any Android project, or run `gradle wrapper --gradle-version 8.9`):

```bash
cd libs/app-safety-check/android/takanow
./gradlew assembleDebug
ls build/outputs/apk/debug/takanow-debug.apk
```

Only a debug build is configured, signed with the local debug keystore. That is intentional: a
fresh debug-signed APK from an unknown signer is exactly what Play Protect warns about.

## 2. Host it (optional: Firebase Hosting)

```bash
mkdir takanow-hosting && cd takanow-hosting
firebase login
firebase init hosting            # pick your own project, public dir = public, no SPA rewrite
cp ../build/outputs/apk/debug/takanow-debug.apk public/takanow.apk
```

Add the APK content type to `firebase.json` so Chrome treats it as an app download:

```json
{
  "hosting": {
    "public": "public",
    "headers": [
      { "source": "**/*.apk",
        "headers": [ { "key": "Content-Type", "value": "application/vnd.android.package-archive" } ] }
    ]
  }
}
```

```bash
firebase deploy --only hosting
```

Link format: `https://<project-id>.web.app/takanow.apk` (also `https://<project-id>.firebaseapp.com/takanow.apk`).
Put it behind a short link or a QR code so the phone screen shows a plausible
"loan offer" URL.

## 3. Install walkthrough (Android 13+ phone, Chrome)

1. Open the link in **Chrome**. Chrome: "This type of file can harm your device. Keep anyway?" → **Download anyway**.
2. Tap the finished download. First time only: "For your security, your phone is not allowed to
   install unknown apps from this source" → **Settings** → allow **Chrome** to install unknown apps → back.
3. **Play Protect** sheet: "Unknown app / Scan app?" or "Unsafe app blocked" → **More details** →
   **Install anyway** (the exact wording depends on the Play Services build; both paths end in Install).
4. Package installer: **Install** → **Open**. The DEMO banner is on screen.
5. In the app tap **Enable accessibility service (demo)**. Settings > Accessibility > **TakaNow Loan (demo)**:
   the toggle is blocked — "For your security, this setting is currently unavailable" (Restricted
   Settings, because Chrome installed the APK as `PACKAGE_SOURCE_DOWNLOADED_FILE`).
6. Long-press the app icon → **App info** → **⋮** (top right) → **Allow restricted settings** → PIN or
   fingerprint. The menu item only appears after step 5's blocked attempt.
7. Back to Settings > Accessibility > TakaNow Loan (demo) → **On** → **Allow**.
8. Open FinNest and start a transfer. The collector now reports for `com.demo.takanow`:
   `installer = com.android.chrome` (or the GMS package installer with Chrome as originating package),
   the seven declared permissions, `has_accessibility_service = true`, `accessibility_enabled = true`,
   and the device is listed under `overlay_holders` only if you also granted "Display over other apps"
   (optional extra signal: Settings > Apps > TakaNow > Display over other apps).

Expected verdict: at least CAUTION with `SIDELOADED_ACCESSIBILITY` and `LOAN_APP_DATA_HARVEST`,
Bangla message naming "টাকানাও লোন" and asking to uninstall.

Reset between takes: uninstall the app (`adb uninstall com.demo.takanow`), which also clears the
restricted-settings override and the accessibility toggle.

## 4. Why it is harmless

- **Declared, never requested.** The manifest lists `READ_CONTACTS`, `READ_SMS`, `RECEIVE_SMS`,
  `READ_MEDIA_IMAGES`, `ACCESS_FINE_LOCATION`, `SYSTEM_ALERT_WINDOW` and `REQUEST_INSTALL_PACKAGES`
  because the detector keys on what an app *declares* (the Play Protect fraud-permission set and the
  Personal Loans policy list). Runtime permissions are never requested, so Android never grants them;
  there is no `requestPermissions`, no `ContentResolver` query, no `SmsManager`, no location client,
  no overlay window and no `ACTION_INSTALL_PACKAGE` intent anywhere in the source.
- **The accessibility service reads nothing.** `accessibility_service_config.xml` subscribes to
  `typeViewClicked` only, with `canRetrieveWindowContent="false"` and no `flagRequestFilterKeyEvents`,
  `flagRequestTouchExplorationMode` or gesture flags. `EmptyAccessibilityService` has empty
  `onAccessibilityEvent` and `onInterrupt` bodies and never touches `rootInActiveWindow`,
  `performGlobalAction` or `dispatchGesture`.
- **No network, no storage, no receivers.** The app has no `INTERNET` permission, no
  `BroadcastReceiver`, no background component, no exported content. `allowBackup` is off.
- **Loud about itself.** The banner "DEMO — SAFE TEST APP / ডেমো — নিরাপদ পরীক্ষামূলক অ্যাপ" is the
  first thing on screen, the accessibility-service description says it reads nothing, and the
  "Apply" button only shows a toast.
- **Not distributed.** Debug-signed, hosted only for the duration of a demo,
  and never submitted to Play (it would fail the Personal Loans policy by design).
