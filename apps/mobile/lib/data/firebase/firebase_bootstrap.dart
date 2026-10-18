import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/firebase/firebase_options.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Outcome of [FirebaseBootstrap.tryInit]; gates every `firebase_*`
/// consumer through `firebaseStatusProvider`.
enum FirebaseStatus {
  /// `Firebase.initializeApp` succeeded; Firestore, Auth, FCM are usable.
  configured,

  /// No options bundled; the app runs on the local demo stores.
  absent,

  /// Options were present but initialisation threw; treated like [absent]
  /// by every consumer, and announced on the Home banner.
  failed,
}

abstract final class FirebaseBootstrap {
  static const _tag = 'firebase';

  /// Initialises Firebase when [options] (default
  /// [BhoroshaFirebaseOptions.current]) are present. Never throws and never
  /// touches a Firebase API when the options are `null`.
  static Future<FirebaseStatus> tryInit({
    FirebaseOptions? options,
    bool useBundledOptions = true,
  }) async {
    final opts =
        options ?? (useBundledOptions ? BhoroshaFirebaseOptions.current : null);
    if (opts == null) {
      Log.i(_tag, 'no options bundled, running on local demo stores');
      return FirebaseStatus.absent;
    }
    try {
      await Firebase.initializeApp(options: opts);
    } on Object catch (e, st) {
      Log.e(_tag, 'initializeApp failed', e, st);
      return FirebaseStatus.failed;
    }
    await _activateAppCheck();
    return FirebaseStatus.configured;
  }

  /// Debug provider in debug builds (or with `APP_CHECK_DEBUG=true`), Play
  /// Integrity otherwise ([AppEnv.useAppCheckDebugProvider]). With
  /// `APP_CHECK_DEBUG_TOKEN` the debug provider uses that fixed, registered
  /// token instead of a random one per install. A failure here must not take
  /// the app down: risk-mw in demo mode does not verify App Check tokens.
  static Future<void> _activateAppCheck() async {
    final debug = AppEnv.useAppCheckDebugProvider;
    final token = AppEnv.fixedAppCheckDebugToken;
    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: androidProviderFor(debug: debug, debugToken: token),
      );
      // Never log the token itself.
      Log.i(
        _tag,
        'App Check active (${debug ? (token != null ? 'debug, fixed token' : 'debug') : 'play_integrity'})',
      );
    } on Object catch (e) {
      Log.w(_tag, 'App Check activation failed', e);
    }
  }

  /// The Android provider [_activateAppCheck] installs, as a pure function
  /// for tests: Play Integrity unless [debug]; the debug provider with
  /// [debugToken] (a `null` token lets the SDK make and persist its own).
  @visibleForTesting
  static AndroidAppCheckProvider androidProviderFor({
    required bool debug,
    String? debugToken,
  }) => debug
      ? AndroidDebugProvider(debugToken: debugToken)
      : const AndroidPlayIntegrityProvider();
}
