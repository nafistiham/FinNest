import 'dart:async';

import 'package:bhorosha/data/repos/repos.dart';

/// Interventions kept in memory for the session; newest first.
class LocalInterventionRepo implements InterventionRepo {
  final _records = <String, InterventionRecord>{};
  final _changes = StreamController<void>.broadcast();

  List<InterventionRecord> _snapshot(String uid) {
    final rows = _records.values.where((r) => r.uid == uid).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(rows);
  }

  @override
  Stream<List<InterventionRecord>> watch(String uid) => Stream.multi((emitter) {
    final sub = _changes.stream.listen((_) {
      if (!emitter.isClosed) emitter.add(_snapshot(uid));
    });
    emitter.onCancel = sub.cancel;
    emitter.add(_snapshot(uid));
  });

  @override
  Future<void> upsert(InterventionRecord r) async {
    // Merge, not replace: a stale copy keeps the fields another writer set.
    _records[r.id] = r.mergedOnto(_records[r.id]);
    _changes.add(null);
  }

  /// In memory every write lands at once: the same as [upsert].
  @override
  Future<void> upsertAcked(InterventionRecord r) => upsert(r);

  @override
  Future<InterventionRecord?> byId(String id) async => _records[id];

  @override
  Future<InterventionRecord?> findByRequestId(String requestId) async {
    for (final r in _records.values) {
      if (r.requestId == requestId) return r;
    }
    return null;
  }

  @override
  Future<void> reset(String uid) async {
    _records.removeWhere((_, r) => r.uid == uid);
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
