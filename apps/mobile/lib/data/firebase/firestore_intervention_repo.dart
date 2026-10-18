import 'package:bhorosha/data/firebase/firestore_writes.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// `interventions/{id}` listener filtered by `uid`, newest first.
class FirestoreInterventionRepo implements InterventionRepo {
  FirestoreInterventionRepo(this._db, {String? Function()? authUid})
    : _authUid = authUid ?? _noAuth;

  final FirebaseFirestore _db;

  /// This phone's Firebase (anonymous) auth uid, stamped on every write as
  /// [ownerAuthKey]; `firestore.rules` lets only that uid create the record
  /// or change its `status`.
  final String? Function() _authUid;

  static String? _noAuth() => null;

  /// The field `firestore.rules` checks a status change against.
  static const ownerAuthKey = 'owner_auth_uid';

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('interventions');

  static InterventionRecord _fromSnap(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) => fromData(snap.id, snap.data()!);

  /// An `interventions/{id}` document as a record (timestamps may be
  /// [Timestamp]s); documents without the step-up, case-link and warning
  /// fields read with them unset.
  @visibleForTesting
  static InterventionRecord fromData(String id, Map<String, dynamic> doc) {
    final data = Map<String, dynamic>.of(doc);
    for (final key in const ['created_at', 'expires_at']) {
      final v = data[key];
      if (v is Timestamp) data[key] = v.toDate().toIso8601String();
    }
    return InterventionRecord.fromDoc(id, data);
  }

  /// The full document of [r] (its null fields included).
  @visibleForTesting
  static Map<String, Object?> toData(InterventionRecord r) => <String, Object?>{
    ...r.toDoc(),
    'created_at': Timestamp.fromDate(r.createdAt),
    'expires_at': switch (r.expiresAt) {
      null => null,
      final t => Timestamp.fromDate(t),
    },
  };

  @override
  Stream<List<InterventionRecord>> watch(String uid) => _col
      .where('uid', isEqualTo: uid)
      .orderBy('created_at', descending: true)
      .snapshots()
      .map((q) => List.unmodifiable(q.docs.map(_fromSnap)));

  /// What [upsert] merges into `interventions/{id}`: [toData] without the
  /// null fields, so a stale copy never erases `request_id`, `contact_uid`
  /// or `step_up` written by another path.
  /// With [ownerAuthUid], the owner stamp the rules check: the same value on
  /// every write from this phone, so it never changes on an update.
  @visibleForTesting
  static Map<String, Object?> mergeData(
    InterventionRecord r, {
    String? ownerAuthUid,
  }) => <String, Object?>{
    ...toData(r)..removeWhere((_, v) => v == null),
    ownerAuthKey: ?ownerAuthUid,
  };

  Future<void> _set(InterventionRecord r) => _col
      .doc(r.id)
      .set(mergeData(r, ownerAuthUid: _authUid()), SetOptions(merge: true));

  @override
  Future<void> upsert(InterventionRecord r) async =>
      fireAndLog(_set(r), 'intervention upsert');

  /// Awaits the server's acknowledgement (the step-up release); the caller bounds the wait.
  @override
  Future<void> upsertAcked(InterventionRecord r) => _set(r);

  @override
  Future<InterventionRecord?> byId(String id) async {
    final DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _col.doc(id).get().timeout(const Duration(seconds: 1));
    } on Object {
      // Offline or slow: the local cache holds this phone's own writes.
      try {
        final cached = await _col
            .doc(id)
            .get(const GetOptions(source: Source.cache));
        return cached.exists ? _fromSnap(cached) : null;
      } on Object {
        return null;
      }
    }
    return snap.exists ? _fromSnap(snap) : null;
  }

  @override
  Future<InterventionRecord?> findByRequestId(String requestId) async {
    final q = await _col
        .where('request_id', isEqualTo: requestId)
        .limit(1)
        .get();
    return q.docs.isEmpty ? null : _fromSnap(q.docs.first);
  }

  @override
  Future<void> reset(String uid) async {
    // Shared collection; nothing to drop locally.
  }
}
