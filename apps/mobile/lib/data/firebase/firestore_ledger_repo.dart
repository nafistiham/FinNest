import 'package:bhorosha/data/firebase/firestore_writes.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// `transactions` collection listener for one account; writes `status`.
///
/// The seed carries no balance, so the balance is the bundled
/// `balance_bdt` minus `done` debits plus `done` credits created in this
/// session, exactly as the local ledger computes it. Saved payees come from
/// the bundle as well. The shared collection keeps the seed rows' stored
/// (November 2026) timestamps; they are rebased on read with the same rule
/// as [LocalLedgerRepo.rebase], so the newest seed row reads "today" on
/// every phone and the stored data is never rewritten.
class FirestoreLedgerRepo extends LedgerRepo {
  FirestoreLedgerRepo(
    this._db,
    this._assets, {
    DateTime Function()? now,
    String? Function()? authUid,
  }) : _now = now ?? DateTime.now,
       _authUid = authUid ?? _noAuth;

  final FirebaseFirestore _db;
  final DemoAssets _assets;
  final DateTime Function() _now;

  /// The Firebase (anonymous) auth uid of this phone, stamped on every row
  /// it creates as [ownerAuthKey]: `firestore.rules` lets only that uid
  /// change the row's `status`.
  final String? Function() _authUid;

  static String? _noAuth() => null;

  /// The field `firestore.rules` checks a status change against.
  static const ownerAuthKey = 'owner_auth_uid';
  final _createdIds = <String, Set<String>>{};
  final _rebasedTs = <String, Map<String, DateTime>>{};

  /// Seed `txn_id` -> rebased timestamp for [uid], computed once per session.
  Future<Map<String, DateTime>> _seedTimes(String uid) async {
    final cached = _rebasedTs[uid];
    if (cached != null) return cached;
    final seed = await _assets.persona(Persona.parse(uid));
    final rows = LocalLedgerRepo.rebase(seed.transactions, _now());
    return _rebasedTs[uid] = {for (final t in rows) t.txnId: t.ts};
  }

  /// How far past [now] a row may be dated before it is dropped (clock
  /// skew between phones writing the shared collection).
  static const futureSlack = Duration(hours: 24);

  /// [rows] with every seed row's timestamp replaced by its rebased one,
  /// newest first; rows created in this session keep their own time. A row
  /// dated more than [futureSlack] after [now] (a stray write in the shared
  /// collection, e.g. "২২ অক্টো." five days ahead) is dropped, with a
  /// one-line debug warning giving the count.
  static List<LedgerTxn> withSeedTimes(
    List<LedgerTxn> rows,
    Map<String, DateTime> seedTimes, {
    required DateTime now,
  }) {
    final limit = now.add(futureSlack);
    final timed = [
      for (final t in rows)
        seedTimes.containsKey(t.txnId)
            ? t.copyWith(ts: seedTimes[t.txnId]!)
            : t,
    ];
    final out = timed.where((t) => !t.ts.isAfter(limit)).toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
    final dropped = timed.length - out.length;
    if (dropped > 0 && kDebugMode) {
      debugPrint(
        '[ledger] dropped $dropped future-dated row(s) (> 24 h after now)',
      );
    }
    return List.unmodifiable(out);
  }

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('transactions');

  Query<Map<String, dynamic>> _forAccount(String acctId) => _col
      .where(
        Filter.or(
          Filter('from_acct', isEqualTo: acctId),
          Filter('to_acct', isEqualTo: acctId),
        ),
      )
      .orderBy('ts', descending: true);

  static LedgerTxn _fromSnap(DocumentSnapshot<Map<String, dynamic>> snap) =>
      fromData(snap.id, snap.data()!);

  /// A `transactions/{id}` document as a row: `ts` may be a [Timestamp];
  /// older documents (no `step_up`, `case_link`,
  /// `warning_*`, `simulated`) read with those unset.
  @visibleForTesting
  static LedgerTxn fromData(String id, Map<String, dynamic> doc) {
    final data = Map<String, dynamic>.of(doc);
    final ts = data['ts'];
    if (ts is Timestamp) data['ts'] = ts.toDate().toIso8601String();
    data.putIfAbsent('txn_id', () => id);
    return LedgerTxn.fromJson(data);
  }

  /// The document [create] writes for [t], stamped with the creating
  /// phone's [ownerAuthUid] when known.
  @visibleForTesting
  static Map<String, Object?> toData(
    String uid,
    LedgerTxn t, {
    String? ownerAuthUid,
  }) => <String, Object?>{
    ...t.toJson(),
    'uid': uid,
    'ts': Timestamp.fromDate(t.ts),
    ownerAuthKey: ?ownerAuthUid,
  };

  @override
  Stream<List<LedgerTxn>> watchRecent(String uid, {int limit = 8}) async* {
    final seedTimes = await _seedTimes(uid);
    yield* _forAccount(Persona.parse(uid).acctId)
        .limit(limit)
        .snapshots()
        .map(
          (q) => withSeedTimes(
            q.docs.map(_fromSnap).toList(),
            seedTimes,
            now: _now(),
          ),
        );
  }

  @override
  Stream<double> watchBalance(String uid) async* {
    final seed = await _assets.persona(Persona.parse(uid));
    final acctId = seed.profile.acctId;
    yield* _forAccount(acctId).snapshots().map((q) {
      final created = _createdIds[uid] ?? const <String>{};
      var balance = seed.profile.balanceBdt;
      for (final doc in q.docs) {
        final t = _fromSnap(doc);
        if (!created.contains(t.txnId) || !LedgerStatus.movesMoney(t.status)) {
          continue;
        }
        if (t.isDebitFor(acctId)) {
          balance -= t.amountBdt;
        } else if (t.isCreditFor(acctId)) {
          balance += t.amountBdt;
        }
      }
      return balance;
    });
  }

  @override
  Future<LedgerTxn> create(String uid, LedgerTxn t) async {
    _createdIds.putIfAbsent(uid, () => <String>{}).add(t.txnId);
    // Applied to the local cache now; the server ack is not awaited.
    fireAndLog(
      _col.doc(t.txnId).set(toData(uid, t, ownerAuthUid: _authUid())),
      'ledger create',
    );
    return t;
  }

  @override
  Future<void> setStatus(String txnId, String status) async => fireAndLog(
    _col.doc(txnId).update(<String, Object?>{'status': status}),
    'ledger setStatus',
  );

  /// Awaits the server's acknowledgement, unlike the other writes: only the
  /// step-up release patches a row, and it must know the write landed
  /// before it says the money moved.
  /// The caller bounds the wait (`pinWriteBudget`); a rejection (the rules'
  /// owner check) or no ack in time is a failed release.
  @override
  Future<void> patch(String txnId, LedgerPatch patch) async {
    final update = patch.toUpdate();
    if (update.isEmpty) return;
    await _col.doc(txnId).update(update);
  }

  @override
  Future<void> confirmCashIn(String txnId) => _db.runTransaction((tx) async {
    final ref = _col.doc(txnId);
    final snap = await tx.get(ref);
    final data = snap.data();
    if (data == null ||
        data['type'] != 'cash_in' ||
        data['status'] != LedgerStatus.requested) {
      return;
    }
    tx.update(ref, <String, Object?>{'status': LedgerStatus.done});
  });

  @override
  List<Payee> savedPayees(Persona p) =>
      _assets.personaIfLoaded(p)?.savedPayees ?? const [];

  @override
  Future<void> reset(String uid) async {
    // Firestore is the shared source of truth; only the session bookkeeping
    // resets so the next persona starts from the bundled balance.
    _createdIds.remove(uid);
  }
}
