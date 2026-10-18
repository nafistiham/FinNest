import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/repos/persona.dart';
import 'package:bhorosha/data/repos/user_profile.dart';

/// Who is signed in, and how the risk-api should hear about it.
abstract class AuthRepo {
  /// Emits the current user on subscribe (`null` when signed out), then
  /// every sign-in and sign-out.
  Stream<UserProfile?> watch();

  UserProfile? get current;

  /// The labelled demo login (US-1 S2): loads the bundled persona profile.
  Future<UserProfile> demoLogin(Persona p);

  /// Throws [PasskeyUnavailableException] while the passkey routes are not deployed.
  Future<UserProfile> passkeyLogin();

  Future<void> signOut();

  /// Live view of the identity: the headers are resolved per request, so the
  /// same object stays valid across sign-in, persona switch and sign-out.
  IdentityHeaders get identity;
}

/// An [AuthRepo] backed by Firebase Auth. [firebaseSignedIn] is `false` when
/// Firebase is configured but the (anonymous) sign-in failed, so the
/// Firestore rules would reject every write; the data providers then fall
/// back to the local stores.
abstract interface class FirebaseBackedAuth {
  bool get firebaseSignedIn;
}
