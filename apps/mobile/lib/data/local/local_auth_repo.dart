import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/repos/repos.dart';

/// Demo-mode identity: the persona uid travels as
/// `X-Demo-User`; `demo` while nobody is signed in.
class LocalAuthRepo implements AuthRepo {
  LocalAuthRepo(this._assets, {this._passkey = const NotDeployedPasskeyAuth()});

  static const _tag = 'auth';
  static const signedOutUid = 'demo';

  final DemoAssets _assets;
  final PasskeyAuth _passkey;
  final _changes = StreamController<UserProfile?>.broadcast();
  UserProfile? _current;

  @override
  UserProfile? get current => _current;

  @override
  Stream<UserProfile?> watch() => Stream.multi((emitter) {
    final sub = _changes.stream.listen(emitter.add);
    emitter.onCancel = sub.cancel;
    emitter.add(_current);
  });

  @override
  Future<UserProfile> demoLogin(Persona p) async {
    final seed = await _assets.persona(p);
    _current = seed.profile;
    _changes.add(_current);
    Log.i(_tag, 'demo login as ${p.uid}');
    return seed.profile;
  }

  @override
  Future<UserProfile> passkeyLogin() async {
    final result = await _passkey.login();
    switch (result) {
      case PasskeyUnavailable(:final reason):
        Log.w(_tag, 'passkey unavailable: $reason');
        throw PasskeyUnavailableException(reason);
      case PasskeySuccess():
        // A custom token needs Firebase Auth; the local repo cannot redeem it.
        throw const PasskeyUnavailableException(
          'passkey custom token needs Firebase Auth (status absent)',
        );
    }
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _changes.add(null);
  }

  @override
  IdentityHeaders get identity => _identity;
  late final IdentityHeaders _identity = _LiveDemoIdentity(() => _current?.uid);

  Future<void> dispose() => _changes.close();
}

/// Resolves the uid at request time so one instance follows sign-in,
/// persona switch and sign-out.
class _LiveDemoIdentity implements IdentityHeaders {
  const _LiveDemoIdentity(this._uid);
  final String? Function() _uid;

  @override
  Future<Map<String, String>> headers() =>
      DemoIdentityHeaders(_uid() ?? LocalAuthRepo.signedOutUid).headers();
}
