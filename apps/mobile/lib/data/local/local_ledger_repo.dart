import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/repos/repos.dart';

/// History and balance seeded from `assets/demo/personas.json`; rows created
/// in this session sit on top and are the only ones that move the balance
/// (`done` debits lower it, `done` credits such as a confirmed cash in raise
/// it).
///
/// The seed's timestamps are in November 2026, after the demo date, so
/// [_seed] rebases them: every seed row moves by `now - 2 h - newest seed
/// ts`, so the newest row reads "today" two hours ago and the gaps between
/// rows are kept. The seed file is not edited.
class LocalLedgerRepo extends LedgerRepo {
  LocalLedgerRepo(this._assets, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const _tag = 'ledger';

  /// How long before "now" the newest seed row lands.
  static const seedLead = Duration(hours: 2);

  final DemoAssets _assets;
  final DateTime Function() _now;
  final _rows = <String, List<LedgerTxn>>{};
  final _createdIds = <String, Set<String>>{};
  final _controllers = <String, StreamController<void>>{};
  final _seeded = <String, PersonaSeed>{};

  StreamController<void> _controller(String uid) =>
      _controllers.putIfAbsent(uid, StreamController<void>.broadcast);

  Future<PersonaSeed> _seed(String uid) async {
    final cached = _seeded[uid];
    if (cached != null) return cached;
    final seed = await _assets.persona(Persona.parse(uid));
    _seeded[uid] = seed;
    _rows.putIfAbsent(uid, () => rebase(seed.transactions, _now()));
    _createdIds.putIfAbsent(uid, () => <String>{});
    return seed;
  }

  /// [rows] shifted so the newest lands at [now] minus [seedLead], gaps kept.
  static List<LedgerTxn> rebase(List<LedgerTxn> rows, DateTime now) {
    if (rows.isEmpty) return <LedgerTxn>[];
    final newest = rows.map((t) => t.ts).reduce((a, b) => a.isAfter(b) ? a : b);
    final shift = now.subtract(seedLead).difference(newest);
    return [for (final t in rows) t.copyWith(ts: t.ts.add(shift))];
  }

  /// Current rows, newest first (after [_seed]).
  List<LedgerTxn> _snapshot(String uid, int? limit) {
    final rows = _rows[uid] ?? const <LedgerTxn>[];
    final cut = limit == null || limit >= rows.length
        ? rows
        : rows.sublist(0, limit);
    return List.unmodifiable(cut);
  }

  double _balance(String uid) {
    final seed = _seeded[uid];
    if (seed == null) return 0;
    final created = _createdIds[uid] ?? const <String>{};
    var balance = seed.profile.balanceBdt;
    final acct = seed.profile.acctId;
    for (final t in _rows[uid] ?? const <LedgerTxn>[]) {
      if (!created.contains(t.txnId) || !LedgerStatus.movesMoney(t.status)) {
        continue;
      }
      if (t.isDebitFor(acct)) {
        balance -= t.amountBdt;
      } else if (t.isCreditFor(acct)) {
        balance += t.amountBdt;
      }
    }
    return balance;
  }

  Stream<T> _watch<T>(String uid, T Function() read) =>
      Stream.multi((emitter) async {
        final sub = _controller(uid).stream.listen((_) {
          if (!emitter.isClosed) emitter.add(read());
        });
        emitter.onCancel = sub.cancel;
        try {
          await _seed(uid);
        } on Object catch (e, st) {
          Log.e(_tag, 'seed failed for $uid', e, st);
        }
        if (!emitter.isClosed) emitter.add(read());
      });

  @override
  Stream<List<LedgerTxn>> watchRecent(String uid, {int limit = 8}) =>
      _watch(uid, () => _snapshot(uid, limit));

  @override
  Stream<double> watchBalance(String uid) => _watch(uid, () => _balance(uid));

  @override
  Future<LedgerTxn> create(String uid, LedgerTxn t) async {
    await _seed(uid);
    _rows[uid]!.insert(0, t);
    _createdIds[uid]!.add(t.txnId);
    _controller(uid).add(null);
    return t;
  }

  @override
  Future<void> setStatus(String txnId, String status) async {
    for (final entry in _rows.entries) {
      final rows = entry.value;
      final i = rows.indexWhere((t) => t.txnId == txnId);
      if (i < 0) continue;
      rows[i] = rows[i].copyWith(status: status);
      _controller(entry.key).add(null);
      return;
    }
    Log.w(_tag, 'setStatus: unknown txn');
  }

  @override
  Future<void> patch(String txnId, LedgerPatch patch) async {
    for (final entry in _rows.entries) {
      final rows = entry.value;
      final i = rows.indexWhere((t) => t.txnId == txnId);
      if (i < 0) continue;
      rows[i] = patch.applyTo(rows[i]);
      _controller(entry.key).add(null);
      return;
    }
    Log.w(_tag, 'patch: unknown txn');
  }

  @override
  Future<void> confirmCashIn(String txnId) async {
    for (final rows in _rows.values) {
      final t = rows.where((r) => r.txnId == txnId).firstOrNull;
      if (t == null) continue;
      if (!t.isRequestedCashIn) {
        Log.w(_tag, 'confirmCashIn: not a waiting cash in');
        return;
      }
      await setStatus(txnId, LedgerStatus.done);
      return;
    }
    Log.w(_tag, 'confirmCashIn: unknown txn');
  }

  @override
  List<Payee> savedPayees(Persona p) {
    final seed = _seeded[p.uid] ?? _assets.personaIfLoaded(p);
    if (seed == null) {
      Log.w(_tag, 'savedPayees before seed loaded for ${p.uid}');
      return const [];
    }
    return seed.savedPayees;
  }

  @override
  Future<void> reset(String uid) async {
    final seed = await _seed(uid);
    _rows[uid] = rebase(seed.transactions, _now());
    _createdIds[uid] = <String>{};
    _controller(uid).add(null);
  }

  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }
}
