import 'package:bhorosha/data/firebase/firestore_writes.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// `demo_state/{uid}` snapshot stream; a missing doc reads as
/// [DemoState.initial].
class FirestoreDemoStateRepo implements DemoStateRepo {
  FirestoreDemoStateRepo(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('demo_state').doc(uid);

  @override
  Stream<DemoState> watch(String uid) => _doc(uid).snapshots().map((snap) {
    final data = snap.data();
    return data == null ? DemoState.initial : DemoState.fromDoc(data);
  });

  @override
  Future<void> write(String uid, DemoState s) async =>
      fireAndLog(_doc(uid).set(s.toDoc()), 'demo_state write');

  @override
  Future<void> reset(String uid) => write(uid, DemoState.initial);
}
