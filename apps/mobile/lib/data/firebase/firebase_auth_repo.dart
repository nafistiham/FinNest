import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Firebase identity: anonymous sign-in, profile from
/// `users/{persona uid}` layered over the bundled seed, ID token as bearer.
///
/// The Firebase uid and the persona uid differ; the persona uid is what the
/// risk-api knows, so it is kept as the demo fallback header too.
class FirebaseAuthRepo implements AuthRepo, FirebaseBackedAuth {
  FirebaseAuthRepo(
    this._auth,
    this._db,
    this._assets, {
    this._passkey = const NotDeployedPasskeyAuth(),
  });

  static const _tag = 'auth';

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  final DemoAssets _assets;
  final PasskeyAuth _passkey;
  final _changes = StreamController<UserProfile?>.broadcast();
  UserProfile? _current;

  @override
  UserProfile? get current => _current;

  @override
  bool get firebaseSignedIn {
    try {
      return _auth.currentUser != null;
    } on Object catch (e) {
      Log.w(_tag, 'currentUser unreadable', e);
      return false;
    }
  }

  @override
  Stream<UserProfile?> watch() => Stream.multi((emitter) {
    final sub = _changes.stream.listen(emitter.add);
    emitter.onCancel = sub.cancel;
    emitter.add(_current);
  });

  Future<void> _ensureSignedIn() async {
    if (_auth.currentUser != null) return;
    await _auth.signInAnonymously();
  }

  @override
  Future<UserProfile> demoLogin(Persona p) async {
    final seed = await _assets.persona(p);
    var profile = seed.profile;
    try {
      await _ensureSignedIn();
      final doc = await _db.collection('users').doc(p.uid).get();
      final data = doc.data();
      if (data != null) {
        profile = UserProfile.fromJson(<String, dynamic>{
          ...profile.toJson(),
          ...data,
        });
      }
    } on Object catch (e) {
      // Firebase reachable at boot but failing now: the bundled profile
      // still lets the demo continue (never crash on a missing service).
      Log.w(_tag, 'Firebase sign-in/profile read failed, using bundle', e);
    }
    _current = profile;
    _changes.add(profile);
    return profile;
  }

  @override
  Future<UserProfile> passkeyLogin() async {
    final result = await _passkey.login();
    switch (result) {
      case PasskeyUnavailable(:final reason):
        throw PasskeyUnavailableException(reason);
      case PasskeySuccess(:final customToken):
        final cred = await _auth.signInWithCustomToken(customToken);
        final persona = Persona.tryParse(cred.user?.uid);
        if (persona == null) {
          throw const PasskeyUnavailableException(
            'custom token uid is not a bundled persona',
          );
        }
        return demoLogin(persona);
    }
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _changes.add(null);
    try {
      await _auth.signOut();
    } on Object catch (e) {
      Log.w(_tag, 'signOut failed', e);
    }
  }

  @override
  IdentityHeaders get identity => _identity;
  late final IdentityHeaders _identity = _LiveBearerIdentity(this);

  Future<void> dispose() => _changes.close();
}

/// Resolves the token (and the demo fallback uid) per request.
class _LiveBearerIdentity implements IdentityHeaders {
  const _LiveBearerIdentity(this._repo);
  final FirebaseAuthRepo _repo;

  @override
  Future<Map<String, String>> headers() => BearerIdentityHeaders(
    () async => _repo._auth.currentUser?.getIdToken(),
    fallbackDemoUid: _repo._current?.uid,
  ).headers();
}
