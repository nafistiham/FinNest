import 'package:flutter/foundation.dart';

/// Compile-time configuration. Override with `--dart-define=KEY=value` or
/// `--dart-define-from-file=config/dart_defines.json`. README.md lists every
/// define. The Firebase defines live in `data/firebase/firebase_options.dart`.
abstract final class AppEnv {
  /// Base URL of the risk-mw backend. The default reaches a risk-mw on the
  /// development machine's port 8080 from the Android emulator. Set it to
  /// the deployed service URL for a device build.
  static const riskApiBaseUrl = String.fromEnvironment(
    'RISK_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  /// Root of the Case Zero investigator service: the watch-list
  /// `GET /api/payee-risk` and the web console. The default reaches a local
  /// Case Zero on port 8090 from the Android emulator.
  static const caseZeroUrl = String.fromEnvironment(
    'CASE_ZERO_URL',
    defaultValue: 'http://10.0.2.2:8090',
  );

  /// Web console of the Case Zero investigator, opened from "Fraud desk".
  /// The Case Zero root serves it.
  static const consoleUrl = String.fromEnvironment(
    'CONSOLE_URL',
    defaultValue: 'http://10.0.2.2:8090',
  );

  /// The demo account's password on Login's password path (used when the
  /// phone has no strong fingerprint or face), compared on the device. It is
  /// printed in the demo note. This is a demo value, not a credential: the
  /// demo login protects no real account.
  static const demoPassword = String.fromEnvironment(
    'DEMO_PASSWORD',
    defaultValue: 'finnest',
  );

  /// Passkey login (`/v1/auth/passkey/*`). Off: the passkey routes are not
  /// deployed, so Login uses the labelled demo sign-in.
  static const passkeysEnabled = bool.fromEnvironment(
    'PASSKEYS_ENABLED',
    defaultValue: false,
  );

  /// Forces the App Check debug provider in a profile or release build
  /// (an emulator APK). Off by default, so a release APK built without the
  /// define uses Play Integrity.
  static const appCheckDebug = bool.fromEnvironment(
    'APP_CHECK_DEBUG',
    defaultValue: false,
  );

  /// The App Check debug provider is used in debug builds, or when
  /// `APP_CHECK_DEBUG=true` asks for it; Play Integrity otherwise.
  static bool get useAppCheckDebugProvider =>
      appCheckDebugFor(debugBuild: kDebugMode, flag: appCheckDebug);

  /// [useAppCheckDebugProvider] as a pure function, for tests.
  @visibleForTesting
  static bool appCheckDebugFor({
    required bool debugBuild,
    required bool flag,
  }) => debugBuild || flag;

  /// A fixed App Check debug token for a sideloaded demo APK, where Play
  /// Integrity fails. Empty by default: the debug provider then makes a
  /// random token per install, which is not on the Firebase allow list.
  /// Pass it only through `tool/build_judges_apk.sh`, which reads it from the
  /// `FINNEST_APPCHECK_TOKEN` environment variable. Never commit the value.
  /// Used only when the debug provider is on ([useAppCheckDebugProvider]).
  static const appCheckDebugToken = String.fromEnvironment(
    'APP_CHECK_DEBUG_TOKEN',
    defaultValue: '',
  );

  /// The token the debug provider is given, or `null` to let it make its
  /// own ([appCheckDebugToken] is ignored with Play Integrity).
  static String? get fixedAppCheckDebugToken => appCheckDebugTokenFor(
    debugProvider: useAppCheckDebugProvider,
    token: appCheckDebugToken,
  );

  /// [fixedAppCheckDebugToken] as a pure function, for tests.
  @visibleForTesting
  static String? appCheckDebugTokenFor({
    required bool debugProvider,
    required String token,
  }) {
    final t = token.trim();
    return debugProvider && t.isNotEmpty ? t : null;
  }

  /// The demo panel (long-press on the logo, `/demo`): it can force a
  /// safety verdict, mint demo integrity tokens, confirm cash-ins and switch
  /// persona, so a release APK hides it unless built with
  /// `--dart-define=DEMO_PANEL=true` (the video build).
  static const demoPanel = bool.fromEnvironment(
    'DEMO_PANEL',
    defaultValue: kDebugMode,
  );

  /// Sends the session fields: `session_id` and `intervention_id` on
  /// `/v1/intervene`, and `txn.txn_id`. Off by default because an older
  /// risk-mw forbids unknown keys and answers 422; the current risk-mw
  /// accepts them, so turn it on with
  /// `--dart-define=RISK_MW_SESSION_FIELDS=true`. Response fields need no
  /// flag (unknown keys are ignored when read).
  static const riskMwSessionFields = bool.fromEnvironment(
    'RISK_MW_SESSION_FIELDS',
    defaultValue: false,
  );

  /// The deployed risk-mw accepts `ScoreRequest.app_safety`: the
  /// App Safety Check result the phone holds, sent with every score so the
  /// decision does not depend on the server instance's memory. On by
  /// default; against an older service that forbids unknown keys, build with
  /// `--dart-define=RISK_MW_APP_SAFETY_IN_SCORE=false`.
  static const riskMwAppSafetyInScore = bool.fromEnvironment(
    'RISK_MW_APP_SAFETY_IN_SCORE',
    defaultValue: true,
  );

  /// The behaviour mode a cold start begins in (`BehaviourMode.startMode`):
  /// `live` (the default) posts the measured 55-float vector on
  /// `/v1/risk/signals`; `off` posts none, for a phone the per-user models do
  /// not fit yet. The demo panel's radio overrides it for the session.
  static const behaviourMode = String.fromEnvironment(
    'BEHAVIOUR_MODE',
    defaultValue: 'live',
  );

  /// The `X-Demo-User` of the staff Fraud desk's case calls
  /// (`POST /v1/investigate`, `GET /v1/investigations/{id}`), so a desk
  /// investigation is never audited to the customer persona signed in on
  /// the phone.
  static const staffDemoUser = String.fromEnvironment(
    'STAFF_DEMO_USER',
    defaultValue: 'staff_fraud_desk',
  );

  /// The trusted contact's `X-Demo-User` on approve/decline when the
  /// request was not created on this phone (no local record names the
  /// contact): the seed's contact for both personas, `rafiq`
  /// (`UserProfile.trustedContactUid`). The server then answers
  /// `contact_verified: true` only when it is the contact on file.
  static const trustedContactDemoUser = String.fromEnvironment(
    'TRUSTED_CONTACT_DEMO_USER',
    defaultValue: 'rafiq',
  );

  /// Google Cloud project number for Play Integrity. Empty disables Integrity.
  static const cloudProjectNumber = String.fromEnvironment(
    'CLOUD_PROJECT_NUMBER',
    defaultValue: '',
  );

  /// Gemini Live model and Vertex location for FNA voice mode. The Live
  /// model is served from `us-central1`.
  static const apaLiveModel = String.fromEnvironment(
    'APA_LIVE_MODEL',
    defaultValue: 'gemini-3.8-live',
  );
  static const apaLiveLocation = String.fromEnvironment(
    'APA_LIVE_LOCATION',
    defaultValue: 'us-central1',
  );

  /// FNA's dynamic lines (text the app has no bundled or server clip for) are
  /// spoken by Gemini TTS on Vertex AI through Firebase AI Logic (App Check,
  /// no API key) before the phone's own voice. Only with Firebase
  /// configured; `--dart-define=GEMINI_TTS=false` goes straight to on-device
  /// TTS.
  static const geminiTts = bool.fromEnvironment(
    'GEMINI_TTS',
    defaultValue: true,
  );

  /// The TTS model and its Vertex location. Dynamic lines are spoken by
  /// Gemini 3.8 TTS, expressive, in Bangladeshi Bengali. The Lite model is
  /// the server's `tts` role in `risk-mw/config/models.yaml`; the full Flash
  /// TTS model is the fallback when Lite answers "not found". Both are
  /// Preview and served from `global` only.
  static const geminiTtsModel = String.fromEnvironment(
    'GEMINI_TTS_MODEL',
    defaultValue: 'gemini-3.8-flash-lite-tts',
  );

  /// The app renders dynamic warning lines in its own delivery (Gemini TTS
  /// with [FnaVoiceStyle]) before asking the server for its clip or live
  /// audio: the server's engine speaks in risk-mw's "urgent" style, which
  /// sounds dramatic; the app's delivery is a calm customer-care agent.
  /// `--dart-define=VOICE_OWN_DELIVERY=false` restores the server-first
  /// order.
  static const voiceOwnDelivery = bool.fromEnvironment(
    'VOICE_OWN_DELIVERY',
    defaultValue: true,
  );

  static const geminiTtsFallbackModel = String.fromEnvironment(
    'GEMINI_TTS_FALLBACK_MODEL',
    defaultValue: 'gemini-3.8-flash-tts',
  );
  static const geminiTtsLocation = String.fromEnvironment(
    'GEMINI_TTS_LOCATION',
    defaultValue: 'global',
  );

  /// Sends the urgent delivery as the text part's `speechMetadata.style`
  /// (how risk-mw `app/tts.py` styles the 3.8 TTS engine, which reads its
  /// text verbatim). `false` sends the bare line, no style.
  static const geminiTtsStyle = bool.fromEnvironment(
    'GEMINI_TTS_STYLE',
    defaultValue: true,
  );

  /// The FinNest helpline in the safety rules, the ARB lines that mention
  /// it and the "call the helpline" actions. Fictional on purpose: a real
  /// short code would send viewers to a real company
  /// (`test/app/brand_test.dart` keeps real numbers out).
  /// Override with `--dart-define=HELPLINE=...`; screens show it through
  /// `context.digits`.
  static const helpline = String.fromEnvironment(
    'HELPLINE',
    defaultValue: '09666-123456',
  );

  /// Skips FLAG_SECURE in debug builds so the demo video can be captured.
  static const recording = bool.fromEnvironment(
    'RECORDING',
    defaultValue: false,
  );

  /// FR-5: sensitive screens are secure unless this is a debug build in
  /// recording mode. Release builds always set FLAG_SECURE.
  static bool get secureScreensEnabled => !(recording && kDebugMode);

  /// The FNA voice assistant: the chat-first view with a one-tap voice mode
  /// on Gemini Live. `false` keeps the original sheet (four topic buttons and
  /// hold-to-talk).
  static const fnaVoiceAgent = bool.fromEnvironment(
    'FNA_VOICE_AGENT',
    defaultValue: true,
  );

  /// Closes the microphone while FNA speaks, for a phone whose echo
  /// canceller still lets FNA hear itself on the loudspeaker.
  static const fnaHalfDuplex = bool.fromEnvironment(
    'FNA_HALF_DUPLEX',
    // On by default: in device tests, fan and room noise on the loudspeaker
    // kept interrupting FNA. The mic closes while FNA speaks;
    // the Stop button interrupts. Set false for full duplex (barge-in by voice).
    defaultValue: true,
  );

  /// FNA's chat (text agent) model, with the same tools as voice mode.
  static const fnaTextModel = String.fromEnvironment(
    'FNA_TEXT_MODEL',
    defaultValue: 'gemini-3.8-flash',
  );

  /// The text agent's model when [fnaTextModel] fails or is not found.
  static const fnaTextFallbackModel = String.fromEnvironment(
    'FNA_TEXT_FALLBACK_MODEL',
    defaultValue: 'gemini-3.5-flash-lite',
  );

  /// Vertex location of the text agent. The Gemini 3.x text models answer
  /// only on `global` (`us-central1` returns 404 for `gemini-3.8-flash` and
  /// `gemini-3.5-flash-lite`), while Live runs on [apaLiveLocation].
  static const fnaTextLocation = String.fromEnvironment(
    'FNA_TEXT_LOCATION',
    defaultValue: 'global',
  );
}
