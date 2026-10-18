import 'package:firebase_core/firebase_core.dart';

/// The single switch for Firebase.
///
/// The Firebase options come from compile-time defines, so no project
/// identifier is committed to the repository:
///
/// | Define | FirebaseOptions field |
/// | --- | --- |
/// | `FIREBASE_API_KEY` | `apiKey` |
/// | `FIREBASE_APP_ID` | `appId` (`1:<number>:android:<hash>`) |
/// | `FIREBASE_MESSAGING_SENDER_ID` | `messagingSenderId` (the project number) |
/// | `FIREBASE_PROJECT_ID` | `projectId` |
/// | `FIREBASE_STORAGE_BUCKET` | `storageBucket` (optional) |
///
/// Put them in the git-ignored `config/dart_defines.json` (copy
/// `config/dart_defines.example.json`) and build with
/// `--dart-define-from-file=config/dart_defines.json`. Read the values from
/// the Firebase console (Project settings, Your apps, Android app
/// `com.bhorosha.app`) or from the file that
/// `flutterfire configure --platforms=android --android-package-name=com.bhorosha.app`
/// writes (do not commit that file; `.gitignore` excludes it).
///
/// The values are client-side identifiers, not secrets. The Android build
/// never applies the `google-services` Gradle plugin;
/// `Firebase.initializeApp(options:)` from Dart is the only initialisation
/// path. Without the defines the app boots in local demo mode.
abstract final class BhoroshaFirebaseOptions {
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );

  /// `true` only when the required defines are set. `false` keeps the app on
  /// the local demo stores.
  static const bool isConfigured =
      _apiKey != '' && _appId != '' && _senderId != '' && _projectId != '';

  /// The options to initialise with; `null` while unconfigured.
  static FirebaseOptions? get current => isConfigured
      ? const FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          storageBucket: _storageBucket == '' ? null : _storageBucket,
        )
      : null;
}
