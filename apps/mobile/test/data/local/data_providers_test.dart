import 'dart:async';

import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/in_memory_demo_state_repo.dart';
import 'package:bhorosha/data/local/local_auth_repo.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('absent status wires the local repos and follows the user', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        ...dataOverrides(FirebaseStatus.absent),
        demoAssetsProvider.overrideWithValue(
          DemoAssets(bundle: DiskAssetBundle()),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(firebaseStatusProvider), FirebaseStatus.absent);
    expect(container.read(authRepoProvider), isA<LocalAuthRepo>());
    expect(container.read(ledgerRepoProvider), isA<LocalLedgerRepo>());
    expect(container.read(demoStateRepoProvider), isA<InMemoryDemoStateRepo>());

    final userSub = container.listen(currentUserProvider, (_, _) {});
    final stateSub = container.listen(demoStateProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(currentUserProvider).value, isNull);
    expect(container.read(demoStateProvider).value, DemoState.initial);
    expect(await container.read(identityHeadersProvider).headers(), {
      'X-Demo-User': 'demo',
    });

    await container.read(authRepoProvider).demoLogin(Persona.rina);
    await pumpEventQueue();
    expect(container.read(currentUserProvider).value?.uid, 'rina');
    await container
        .read(demoStateRepoProvider)
        .write('rina', const DemoState(callActive: true));
    await pumpEventQueue();
    expect(container.read(demoStateProvider).value?.callActive, isTrue);
    expect(await container.read(identityHeadersProvider).headers(), {
      'X-Demo-User': 'rina',
    });

    // riskApiProvider resolves to a real client (no UnimplementedError).
    expect(container.read(riskApiProvider), isNotNull);
    userSub.close();
    stateSub.close();
  });

  group('Firebase configured but sign-in failed', () {
    ProviderContainer containerWith(_FirebaseAuthStub auth) {
      final container = ProviderContainer(
        overrides: [
          firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
          authRepoProvider.overrideWithValue(auth),
          demoAssetsProvider.overrideWithValue(
            DemoAssets(bundle: DiskAssetBundle()),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('no Firebase user: every data repo is the local one', () async {
      final auth = _FirebaseAuthStub(signedIn: false);
      final c = containerWith(auth);
      expect(c.read(firebaseSignedInProvider), isFalse);
      expect(c.read(ledgerRepoProvider), isA<LocalLedgerRepo>());
      expect(c.read(interventionRepoProvider), isA<LocalInterventionRepo>());
      expect(c.read(demoStateRepoProvider), isA<InMemoryDemoStateRepo>());

      // Still local after the (failed) demo login emitted the profile.
      final sub = c.listen(currentUserProvider, (_, _) {});
      await auth.demoLogin(Persona.rina);
      await pumpEventQueue();
      expect(c.read(firebaseSignedInProvider), isFalse);
      expect(c.read(ledgerRepoProvider), isA<LocalLedgerRepo>());
      sub.close();
    });

    test('flips when the sign-in state changes on the next login', () async {
      final auth = _FirebaseAuthStub(signedIn: false);
      final c = containerWith(auth);
      final sub = c.listen(currentUserProvider, (_, _) {});
      expect(c.read(firebaseSignedInProvider), isFalse);

      auth.signedIn = true;
      await auth.demoLogin(Persona.rina);
      await pumpEventQueue();
      expect(c.read(firebaseSignedInProvider), isTrue);
      sub.close();
    });

    test('absent Firebase is never "signed in"', () {
      final c = ProviderContainer(
        overrides: [authRepoProvider.overrideWithValue(_FirebaseAuthStub())],
      );
      addTearDown(c.dispose);
      expect(c.read(firebaseSignedInProvider), isFalse);
    });
  });
}

/// A Firebase-backed auth repo whose Firebase sign-in state is scripted.
class _FirebaseAuthStub implements AuthRepo, FirebaseBackedAuth {
  _FirebaseAuthStub({this.signedIn = true});

  bool signedIn;
  final _changes = StreamController<UserProfile?>.broadcast();
  UserProfile? _current;

  @override
  bool get firebaseSignedIn => signedIn;

  @override
  UserProfile? get current => _current;

  @override
  Stream<UserProfile?> watch() => Stream.multi((e) {
    final sub = _changes.stream.listen(e.add);
    e.onCancel = sub.cancel;
    e.add(_current);
  });

  @override
  Future<UserProfile> demoLogin(Persona p) async {
    final profile = UserProfile(
      uid: p.uid,
      persona: p,
      nameBn: 'রিনা',
      nameEn: 'Rina',
      phoneMasked: '',
      p95SendBdt: 5000,
      acctId: 'acct_${p.uid}',
      balanceBdt: 0,
      trustedContactUid: 'rafiq',
    );
    _current = profile;
    _changes.add(profile);
    return profile;
  }

  @override
  Future<UserProfile> passkeyLogin() => throw UnimplementedError();

  @override
  Future<void> signOut() async {
    _current = null;
    _changes.add(null);
  }

  @override
  IdentityHeaders get identity => const DemoIdentityHeaders('rina');
}
