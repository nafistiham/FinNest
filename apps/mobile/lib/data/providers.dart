/// Riverpod wiring of the data layer.
///
/// Every repo provider returns the Firestore implementation only when
/// [firebaseSignedInProvider] holds (Firebase [FirebaseStatus.configured] and
/// a Firebase user); otherwise the local demo stores. `main.dart` runs
/// `FirebaseBootstrap.tryInit()` and passes `dataOverrides(status)` to
/// `ProviderScope(overrides:)`; without overrides the app runs as `absent`.
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/case_zero_client.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/api/providers.dart';
import 'package:bhorosha/data/api/risk_api_client.dart';
import 'package:bhorosha/data/firebase/firebase_auth_repo.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/firebase/firestore_demo_state_repo.dart';
import 'package:bhorosha/data/firebase/firestore_intervention_repo.dart';
import 'package:bhorosha/data/firebase/firestore_ledger_repo.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/in_memory_demo_state_repo.dart';
import 'package:bhorosha/data/local/local_auth_repo.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/enrolment_store.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

export 'package:bhorosha/data/api/providers.dart' show riskApiProvider;

/// Result of `FirebaseBootstrap.tryInit()`; overridden in `main.dart`.
final firebaseStatusProvider = Provider<FirebaseStatus>(
  (_) => FirebaseStatus.absent,
);

/// Overrides for the root `ProviderScope` after bootstrap. Includes the
/// [riskApiProvider] override that Task 2 left to this layer.
List<Override> dataOverrides(FirebaseStatus status) => [
  firebaseStatusProvider.overrideWithValue(status),
  riskApiOverride,
];

/// `RiskApiClient` against the live service with the current identity.
/// Also usable alone, e.g. in widget tests that keep `absent`.
final riskApiOverride = riskApiProvider.overrideWith(
  (ref) => RiskApiClient(
    baseUrl: AppEnv.riskApiBaseUrl,
    identity: ref.watch(identityHeadersProvider),
  ),
);

/// The Case Zero watch-list client (no identity: the list is demo data).
/// Tests override it with a `CaseZeroClient` on a fake dio adapter.
final caseZeroClientProvider = Provider<CaseZeroClient>(
  (_) => CaseZeroClient(Dio(), AppEnv.caseZeroUrl),
);

bool _configured(Ref ref) =>
    ref.watch(firebaseStatusProvider) == FirebaseStatus.configured;

/// Bundled demo data, loaded once and shared by the local repos.
final demoAssetsProvider = Provider<DemoAssets>((_) => DemoAssets());

final passkeyAuthProvider = Provider<PasskeyAuth>(
  (_) => const NotDeployedPasskeyAuth(),
);

final authRepoProvider = Provider<AuthRepo>((ref) {
  final assets = ref.watch(demoAssetsProvider);
  final passkey = ref.watch(passkeyAuthProvider);
  if (_configured(ref)) {
    final repo = FirebaseAuthRepo(
      FirebaseAuth.instance,
      FirebaseFirestore.instance,
      assets,
      passkey: passkey,
    );
    ref.onDispose(repo.dispose);
    return repo;
  }
  final repo = LocalAuthRepo(assets, passkey: passkey);
  ref.onDispose(repo.dispose);
  return repo;
});

/// `true` only when Firebase is configured **and** Firebase Auth has a user.
/// A configured project whose anonymous sign-in failed (terms not accepted,
/// no network at login) keeps the Firebase auth repo, but every data repo
/// below falls back to its local implementation, since Firestore would reject
/// the writes and leave the PIN pad stuck. Re-evaluated on every sign-in and
/// sign-out (the auth repo emits after its sign-in attempt).
final firebaseSignedInProvider = Provider<bool>((ref) {
  if (!_configured(ref)) return false;
  ref.watch(currentUserProvider);
  final repo = ref.watch(authRepoProvider);
  final signedIn = switch (repo) {
    FirebaseBackedAuth(:final firebaseSignedIn) => firebaseSignedIn,
    _ => false,
  };
  if (!signedIn && repo.current != null) {
    Log.w('data', 'Firebase sign-in failed: using the local repos');
  }
  return signedIn;
});

/// Live identity of the signed-in user (demo header or bearer token).
final identityHeadersProvider = Provider<IdentityHeaders>(
  (ref) => ref.watch(authRepoProvider).identity,
);

final demoStateRepoProvider = Provider<DemoStateRepo>((ref) {
  if (ref.watch(firebaseSignedInProvider)) {
    return FirestoreDemoStateRepo(FirebaseFirestore.instance);
  }
  final repo = InMemoryDemoStateRepo();
  ref.onDispose(repo.dispose);
  return repo;
});

final ledgerRepoProvider = Provider<LedgerRepo>((ref) {
  final assets = ref.watch(demoAssetsProvider);
  if (ref.watch(firebaseSignedInProvider)) {
    return FirestoreLedgerRepo(
      FirebaseFirestore.instance,
      assets,
      authUid: _firebaseAuthUid,
    );
  }
  final repo = LocalLedgerRepo(assets);
  ref.onDispose(repo.dispose);
  return repo;
});

final interventionRepoProvider = Provider<InterventionRepo>((ref) {
  if (ref.watch(firebaseSignedInProvider)) {
    return FirestoreInterventionRepo(
      FirebaseFirestore.instance,
      authUid: _firebaseAuthUid,
    );
  }
  final repo = LocalInterventionRepo();
  ref.onDispose(repo.dispose);
  return repo;
});

/// This phone's Firebase (anonymous) auth uid, the owner stamp the
/// Firestore rules check on a status change; `null` when unreadable.
String? _firebaseAuthUid() {
  try {
    return FirebaseAuth.instance.currentUser?.uid;
  } on Object {
    return null;
  }
}

/// Per-login `session_id`; rotate on sign-in and persona switch.
final sessionRepoProvider = Provider<SessionRepo>((_) => InMemorySessionRepo());

/// `null` while signed out.
final currentUserProvider = StreamProvider<UserProfile?>(
  (ref) => ref.watch(authRepoProvider).watch(),
);

/// The simulated world of the signed-in user; [DemoState.initial] while
/// signed out or still resolving the user.
final demoStateProvider = StreamProvider<DemoState>((ref) {
  final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
  if (uid == null) return Stream.value(DemoState.initial);
  return ref.watch(demoStateRepoProvider).watch(uid);
});

// --- Case Zero links and the staff desk seam -------------------

/// The investigations this phone opened, per persona (SharedPreferences).
final caseLinkRepoProvider = Provider<CaseLinkRepo>((ref) {
  final repo = CaseLinkRepo();
  ref.onDispose(repo.dispose);
  return repo;
});

/// The links of persona [uid], newest first.
final caseLinksProvider = StreamProvider.autoDispose
    .family<List<CaseLink>, String>(
      (ref, uid) => ref.watch(caseLinkRepoProvider).watch(uid),
    );

/// The newest link this phone opened on payee [key].acctId for persona
/// [key].uid, or `null` (drives the customer's review lines). Links adopted
/// from the watch-list are left out: only a case started
/// from this phone says anything about a customer's transfer.
final caseLinkForPayeeProvider = Provider.autoDispose
    .family<CaseLink?, ({String uid, String acctId})>((ref, key) {
      final links = ref.watch(caseLinksProvider(key.uid)).value;
      return links
          ?.where((l) => l.acctId == key.acctId && !l.adopted)
          .firstOrNull;
    });

/// The staff Fraud desk's calls: the watch-list from Case Zero, start and
/// read a case through [riskApiProvider]. Tests override either side.
final caseDeskApiProvider = Provider<CaseDeskApi>(
  (ref) => LiveCaseDeskApi(
    watchList: ref.watch(caseZeroClientProvider),
    risk: ref.watch(riskApiProvider),
  ),
);

// --- behaviour enrolment ------------------------------------------

/// This phone's enrolment rows per persona (SharedPreferences), exported as
/// JSON Lines from the demo panel.
final enrolmentStoreProvider = Provider<EnrolmentStore>((ref) {
  final store = EnrolmentStore();
  ref.onDispose(store.dispose);
  return store;
});
