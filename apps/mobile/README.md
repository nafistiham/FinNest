# FinNest Android app

## Purpose

FinNest (ফিননেস্ট) is the Bangla-first customer app of a fictional Bangladeshi digital bank. It
stops scams at the moment of payment: a risky transfer is held, and the app explains the hold in
plain Bangla or English. FinNest Assistant (FNA, ফিননেস্ট সহকারী) answers safety questions by chat
and by voice.

This is a demo prototype. Personas, balances, billers and operators are fictional. "Bhorosha" is the
old internal code name; it stays in identifiers only (Dart package `bhorosha`, application id
`com.bhorosha.app`, the `bhorosha://` deep-link scheme, `Apa*` and `Bhorosha*` classes).

## How it fits in FinNest

```
 FinNest app (this folder)
   |-- HTTPS ------------------> services/risk-mw    risk scoring, interventions, App Safety Check
   |-- HTTPS ------------------> services/case-zero  watch-list and investigations (staff Fraud desk)
   |-- Firebase Auth/Firestore   anonymous sign-in, ledger and hold records
   |-- Firebase AI Logic ------> Vertex AI Gemini    FNA chat, Gemini Live voice, Gemini TTS
   '-- Firebase App Check        Play Integrity (release) or debug provider (debug)
```

Every backend part is optional at boot. Without Firebase the app runs on bundled local demo stores.
Without risk-mw a scored transfer fails closed: the money does not move.

## Features

| Area | What it does |
|---|---|
| Login | Demo sign-in as Rina or Rahima, with the phone's fingerprint or face, or a demo password. Passkey login is behind a flag and off. |
| Home | Balance, held-transfer cards, the FNA security card, a grid of money features, recent transactions. |
| Payments | Send money, cash out, cash in, mobile recharge (operator picked by number prefix, shown as "Operator A" to "Operator E"), pay bill, savings (DPS) and loans. Front-end only for billers, loans and savings. |
| PIN pad and risk check | The PIN is checked on the device. Device signals and a 55-float behaviour vector go to risk-mw, which scores the transfer. |
| Hold and explain | A held or blocked transfer opens an overlay or banner with the server's reason text, a bundled Bangla voice clip within 300 ms, the server's actions, an identity step-up and a trusted-contact request. |
| Trusted contact | The contact approves or declines on `bhorosha://approve/{id}` with a countdown. |
| App Safety Check | A native Kotlin collector lists risky apps (side-loaded apps with accessibility access, remote-access tools) and sends the facts to risk-mw. The Safety screen shows the verdict, findings, search, filters and actions. |
| FinNest Assistant | Chat first, voice one tap away. Gemini Live voice, an on-device BM25 safety knowledge base, five tools and a transcript guard. See [docs/fna-voice-assistant.md](docs/fna-voice-assistant.md). |
| Fraud desk | Staff view of Case Zero: the payee watch-list and investigations. Shown only with the demo panel. |
| Demo panel | Long-press the logo (debug builds, or `DEMO_PANEL=true`): persona, flags, forced verdicts, one-tap demo stories, scam-call replay. |

## Architecture

- **State and navigation.** Riverpod 3 providers and `go_router`. `lib/data/providers.dart` wires
  the data layer; each feature owns its providers.
- **Layout.** Feature-first. Each feature under `lib/features/<name>/` has `logic/` (controllers,
  pure Dart rules) and `ui/` (screens and widgets).
- **Contracts.** `lib/data/contracts/` mirrors `services/risk-mw/app/contracts.py`. A test compares
  them with `test/fixtures/openapi.json` and, when present, with the risk-mw source.
- **Native plugin.** `android/app/src/main/kotlin/com/bhorosha/app/native/` holds one method channel
  (`bhorosha_native`): device signals, Play Integrity, FLAG_SECURE, the App Safety collector
  (`com/bhorosha/appsafety/`), the voice audio session and a PCM player.
- **Firebase.** Initialised from Dart only (`lib/data/firebase/`); the `google-services` Gradle
  plugin is not applied, so no `google-services.json` is needed. Firestore stores the ledger and
  hold records; FCM handles trusted-contact pushes.
- **Gemini.** Firebase AI Logic on Vertex AI: Gemini Live (`us-central1`) for voice mode, Gemini
  text models (`global`) for chat, Gemini TTS for spoken lines. No API key in the app; calls carry
  App Check tokens.
- **App Check.** Debug provider in debug builds (or with `APP_CHECK_DEBUG=true`), Play Integrity
  otherwise.
- **Localisation.** ARB files in `lib/l10n/` (Bangla is the template); `make gen` regenerates the
  classes.

## Requirements

| Tool | Version |
|---|---|
| Flutter | 3.47.7, pinned in `.fvmrc`; use [FVM](https://fvm.app) |
| JDK | 17 or newer (Android Studio's bundled runtime works) |
| Android SDK | compile SDK 37.0, target SDK 36, min SDK 28 |
| Device | Android 9 or newer, or an emulator |

`source tool/env.sh` sets `JAVA_HOME`, `ANDROID_HOME` and the Flutter path. Values already in your
environment win; the script falls back to the default Android Studio locations on macOS and Linux.
Put machine-specific values in `tool/env.local.sh` (git-ignored).

## Configuration

All settings are compile-time defines. Copy the example file and fill in your values:

```bash
cp config/dart_defines.example.json config/dart_defines.json   # git-ignored
fvm flutter run --dart-define-from-file=config/dart_defines.json
```

The `Makefile` passes `config/dart_defines.json` automatically when it exists.

| Define | Default | Meaning |
|---|---|---|
| `RISK_API_BASE_URL` | `http://10.0.2.2:8080` | risk-mw base URL. The default is a local risk-mw seen from the emulator. |
| `CASE_ZERO_URL` | `http://10.0.2.2:8090` | Case Zero root (watch-list API). |
| `CONSOLE_URL` | `http://10.0.2.2:8090` | Case Zero web console, opened from the Fraud desk. |
| `FIREBASE_API_KEY` | empty | Firebase Android API key. |
| `FIREBASE_APP_ID` | empty | Firebase Android app id (`1:<number>:android:<hash>`). |
| `FIREBASE_MESSAGING_SENDER_ID` | empty | Firebase project number. |
| `FIREBASE_PROJECT_ID` | empty | Google Cloud / Firebase project id. |
| `FIREBASE_STORAGE_BUCKET` | empty | Optional storage bucket. |
| `CLOUD_PROJECT_NUMBER` | empty | Project number for Play Integrity. Empty disables Play Integrity tokens. |
| `APP_CHECK_DEBUG` | `false` | Use the App Check debug provider in a profile or release build. Debug builds always use it. |
| `APP_CHECK_DEBUG_TOKEN` | empty | A fixed App Check debug token for a sideloaded demo APK. Used only with the debug provider. Set it only through `tool/build_judges_apk.sh`. |
| `DEMO_PANEL` | on in debug, off otherwise | The hidden demo panel and the Fraud desk. |
| `DEMO_PASSWORD` | `finnest` | Demo password for the password login path. A demo value, not a credential. |
| `PASSKEYS_ENABLED` | `false` | Passkey login. Off: the passkey routes are not deployed. |
| `BEHAVIOUR_MODE` | `live` | `live` posts the behaviour vector; `off` posts none. |
| `RISK_MW_SESSION_FIELDS` | `false` | Send `session_id`, `intervention_id` and `txn.txn_id`. Turn on with the current risk-mw. |
| `RISK_MW_APP_SAFETY_IN_SCORE` | `true` | Send the last App Safety Check result with each score. |
| `STAFF_DEMO_USER` | `staff_fraud_desk` | `X-Demo-User` of the Fraud desk's case calls. |
| `TRUSTED_CONTACT_DEMO_USER` | `rafiq` | `X-Demo-User` for approve/decline when no local record names the contact. |
| `HELPLINE` | `09666-123456` | Fictional FinNest helpline shown and dialled by the app. |
| `RECORDING` | `false` | Debug builds only: skip FLAG_SECURE for screen recordings. |
| `GEMINI_TTS` | `true` | Speak dynamic lines with Gemini TTS before the phone's own voice. |
| `GEMINI_TTS_MODEL` / `GEMINI_TTS_FALLBACK_MODEL` | `gemini-3.8-flash-lite-tts` / `gemini-3.8-flash-tts` | TTS models. |
| `GEMINI_TTS_LOCATION` | `global` | TTS region. |
| `GEMINI_TTS_STYLE` | `true` | Send the delivery style as speech metadata. |
| `VOICE_OWN_DELIVERY` | `true` | Prefer the app's own Gemini delivery over the server's clip. |
| `FNA_VOICE_AGENT` | `true` | FNA chat and voice views. `false` keeps the original sheet. |
| `FNA_HALF_DUPLEX` | `true` | Close the microphone while FNA speaks. |
| `APA_LIVE_MODEL` / `APA_LIVE_LOCATION` | `gemini-3.8-live` / `us-central1` | Gemini Live model and region. |
| `FNA_TEXT_MODEL` / `FNA_TEXT_FALLBACK_MODEL` | `gemini-3.8-flash` / `gemini-3.5-flash-lite` | FNA chat models. |
| `FNA_TEXT_LOCATION` | `global` | FNA chat region. |

### Firebase

1. Create a Firebase project (or use your Google Cloud project) and add an Android app with the
   package name `com.bhorosha.app` and your debug SHA-1.
2. Enable Anonymous sign-in, Firestore, App Check and Firebase AI Logic (Vertex AI).
3. Copy the values of the Android app into the `FIREBASE_*` defines. You can read them in the
   Firebase console (Project settings, Your apps) or generate them with
   `flutterfire configure --platforms=android --android-package-name=com.bhorosha.app`. Do not commit
   the generated `firebase_options.dart` or `google-services.json`; `.gitignore` excludes both.
4. Deploy the demo rules and indexes:
   `cd firebase && firebase deploy --only firestore --project "$PROJECT_ID"`.

Without the `FIREBASE_*` defines the app boots in local demo mode: bundled personas and local
stores on the device, no FNA Gemini paths.

### App Check debug token

Debug builds use the App Check debug provider. To register the device:

1. Run a debug build with the Firebase defines.
2. Read the token: `adb logcat -s DebugAppCheckProvider`.
3. Register it in the Firebase console (App Check, Apps, your Android app, Manage debug tokens), or
   with `firebase appcheck:debugtokens:create <token> --project "$PROJECT_ID" --app "$FIREBASE_APP_ID"`.

A release build uses Play Integrity unless it is built with `APP_CHECK_DEBUG=true`.

### Demo APK for sideloaded installs

Play Integrity fails for an APK that is not installed from Google Play, and each install with the
debug provider makes its own random token. For a demo APK that many people install, use one fixed
token:

1. Make a UUID v4 (`uuidgen`) and register it as a debug token in the Firebase console.
2. Build: `FINNEST_APPCHECK_TOKEN=<token> tool/build_judges_apk.sh`. The APK has the demo panel on
   and behaviour scoring off.
3. Revoke the token in the Firebase console after the event. The APK's AI features then stop.

Anyone who has the APK can extract the token, so share the APK only with the intended people.

## Run locally

Against a local backend on the emulator (debug builds allow plain HTTP to `10.0.2.2` only):

```bash
cd apps/mobile
source tool/env.sh
fvm flutter pub get
make gen
# start services/risk-mw on port 8080 and services/case-zero on port 8090 first
fvm flutter run --dart-define-from-file=config/dart_defines.json
```

Against a deployed backend, set `RISK_API_BASE_URL`, `CASE_ZERO_URL` and `CONSOLE_URL` to the HTTPS
service URLs in `config/dart_defines.json`. risk-mw runs in demo mode: every call carries
`X-Demo-User: <persona uid>` next to the Firebase bearer token.

Demo walkthrough:

1. Sign in as Rina (PIN `1234`) or Rahima (PIN `2468`). These are bundled demo credentials.
2. Long-press the logo for the demo panel. A demo story or the scam-call replay sets up the next
   transfer to be held.
3. Trusted-contact deep link without FCM:
   `adb shell am start -a android.intent.action.VIEW -d "bhorosha://approve/<request_id>"`.
4. `adb logcat -s flutter` shows every route, status and server timing (never bodies or tokens).

## Test

```bash
source tool/env.sh
fvm flutter analyze --no-fatal-infos
fvm flutter test
```

`make analyze` and `make test` regenerate the localisation classes first. The suite has about 2,550
tests: unit, widget and contract tests. They need no network and no Firebase. Two contract tests read
`services/risk-mw` sources when they are present.

## Build and release

```bash
make build-debug          # debug APK
make build-release        # release APK: Play Integrity App Check, no demo panel
make build-release-demo   # release APK with the demo panel and the App Check debug provider
make build-recording      # debug APK without FLAG_SECURE, for screen recordings
```

The APKs are in `build/app/outputs/flutter-apk/`.

The release build type is signed with the **debug key** so the demo APK can be side-loaded. This is
for the demo only. Before any store release, add a release keystore (`android/key.properties` and
the keystore are git-ignored), sign with it, and enable code shrinking.

## Tools

| File | Use |
|---|---|
| `tool/env.sh` | Toolchain environment for the Makefile and the shell. |
| `tool/arb_add.py` | Add or update keys in both ARB files under a file lock. |
| `tool/make_brand_assets.py` | Rebuild the launcher icons and splash mark from `assets/brand/finnest_logo.png` (needs Pillow). |
| `tool/render_apa_audio_gemini.py` | Re-render the bundled voice clips in `assets/audio/` with Gemini TTS. Needs `GOOGLE_CLOUD_PROJECT`, gcloud, ffmpeg. |

## Layout

```
apps/mobile/
  android/            Android host app, native Kotlin plugin, App Safety collector
  assets/             fonts (with OFL licences), brand mark, voice clips, demo data, FNA knowledge base
  config/             dart_defines.example.json (copy to dart_defines.json, git-ignored)
  docs/               api-call-flow.md, api-reference.md, fna-voice-assistant.md
  firebase/           Firestore rules and indexes (demo scope)
  lib/
    app/              app shell, router, theme, shared widgets, env.dart (all defines)
    core/             logging, clock, ids, haptics, audio helpers
    data/             API clients, contracts, Firebase, local stores, native bridge, repositories
    domain/           behaviour features, risk routing, signal merging
    features/         one folder per feature: logic/ and ui/
    l10n/             ARB files and generated localisations
  test/               mirrors lib/; fixtures/ holds the OpenAPI and schema fixtures
  tool/               scripts (see Tools)
```

## Known limits

- Passkey login is a labelled stub until the passkey routes are deployed.
- FCM pushes are handled when Firebase is configured, but the server does not send them yet.
- Live voice sends audio before the text of the same words, so the transcript guard can stop a bad
  answer only after its first words have played.
