/// The Case Zero investigations this phone opened: one
/// `CaseLink` per case, kept in SharedPreferences under
/// `case_links_<persona>` as a JSON list. The staff Fraud desk writes them;
/// the customer's review lines read them (never the watch-list).
library;

import 'dart:async';
import 'dart:convert';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One investigation opened from this app, with the last state seen.
class CaseLink {
  const CaseLink({
    required this.caseId,
    required this.acctId,
    required this.openedAt,
    this.lastStatus = CaseStatus.queued,
    this.lastAction = '',
    this.modelVersion = '',
    this.adopted = false,
  });

  factory CaseLink.fromJson(Map<String, dynamic> json) => CaseLink(
    caseId: requireString(json, 'case_id'),
    acctId: requireString(json, 'acct_id'),
    openedAt: DateTime.parse(requireString(json, 'opened_at')),
    lastStatus: CaseStatus.fromWire(readString(json, 'last_status', 'queued')),
    lastAction: readString(json, 'last_action', ''),
    modelVersion: readString(json, 'model_version', ''),
    adopted: readBool(json, 'adopted', false),
  );

  final String caseId;

  /// The investigated payee account.
  final String acctId;
  final DateTime openedAt;
  final CaseStatus lastStatus;

  /// `recommended_action` as the server last sent it (`''` before any read).
  final String lastAction;
  final String modelVersion;

  /// The case was not started from this phone: it was picked up from the
  /// watch-list (or opened on a case screen without a link). It shows on
  /// the staff desk but never counts as a review of a customer's held
  /// transfer, whatever its `openedAt`.
  final bool adopted;

  bool get isOpen => !lastStatus.isTerminal;

  /// The scripted stand-in answered (`model_version == stub-fallback`).
  bool get isStubFallback => modelVersion == CaseReport.stubFallbackVersion;

  /// This link updated from a freshly read [report].
  CaseLink withReport(CaseReport report) => CaseLink(
    caseId: caseId,
    acctId: acctId,
    openedAt: openedAt,
    lastStatus: report.status,
    lastAction: report.recommendedAction,
    modelVersion: report.modelVersion,
    adopted: adopted,
  );

  /// This link with [status] (a stale 404 is recorded as `failed`, so the
  /// customer is never told a review is running when the case is gone).
  CaseLink withStatus(CaseStatus status) => CaseLink(
    caseId: caseId,
    acctId: acctId,
    openedAt: openedAt,
    lastStatus: status,
    lastAction: lastAction,
    modelVersion: modelVersion,
    adopted: adopted,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'case_id': caseId,
    'acct_id': acctId,
    'opened_at': openedAt.toUtc().toIso8601String(),
    'last_status': lastStatus.wire,
    'last_action': lastAction,
    'model_version': modelVersion,
    if (adopted) 'adopted': true,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaseLink &&
          caseId == other.caseId &&
          acctId == other.acctId &&
          openedAt.isAtSameMomentAs(other.openedAt) &&
          lastStatus == other.lastStatus &&
          lastAction == other.lastAction &&
          modelVersion == other.modelVersion &&
          adopted == other.adopted;

  @override
  int get hashCode => Object.hash(
    caseId,
    acctId,
    openedAt.microsecondsSinceEpoch,
    lastStatus,
    lastAction,
    modelVersion,
    adopted,
  );

  @override
  String toString() =>
      'CaseLink($caseId $acctId ${lastStatus.wire}${adopted ? ' adopted' : ''})';
}

/// Newest link first; replays the current list to every new listener.
///
/// Writes ([upsert], [clear]) run one after another per persona through a
/// future chain, so two read-modify-writes never lose each other's link.
class CaseLinkRepo {
  CaseLinkRepo({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance();

  static const _tag = 'case_links';
  static String keyFor(String persona) => 'case_links_$persona';

  final Future<SharedPreferences> _prefs;
  final _current = <String, List<CaseLink>>{};
  final _controllers = <String, StreamController<List<CaseLink>>>{};
  final _writes = <String, Future<void>>{};

  /// Runs [write] after every earlier write of [persona]; a failed write
  /// does not stall the chain.
  Future<void> _serial(String persona, Future<void> Function() write) {
    final next = (_writes[persona] ?? Future<void>.value()).then(
      (_) => write(),
    );
    _writes[persona] = next.catchError((Object _) {});
    return next;
  }

  StreamController<List<CaseLink>> _controller(String persona) => _controllers
      .putIfAbsent(persona, StreamController<List<CaseLink>>.broadcast);

  /// Every link of [persona], newest `openedAt` first.
  Stream<List<CaseLink>> watch(String persona) => Stream.multi((emitter) async {
    final sub = _controller(persona).stream.listen(emitter.add);
    emitter.onCancel = sub.cancel;
    final current = await all(persona);
    if (!emitter.isClosed) emitter.add(current);
  });

  /// The stored links of [persona], newest first.
  Future<List<CaseLink>> all(String persona) => _load(persona);

  /// The newest link for [acctId], or `null`.
  Future<CaseLink?> latestFor(String persona, String acctId) async {
    for (final l in await _load(persona)) {
      if (l.acctId == acctId) return l;
    }
    return null;
  }

  /// Adds [link] or replaces the stored link with the same `caseId`.
  Future<void> upsert(String persona, CaseLink link) =>
      _serial(persona, () async {
        final rest = [
          for (final l in await _load(persona))
            if (l.caseId != link.caseId) l,
        ];
        await _write(persona, [link, ...rest]);
      });

  /// Drops every link of [persona] (persona switch, demo reset).
  Future<void> clear(String persona) =>
      _serial(persona, () => _write(persona, const []));

  Future<List<CaseLink>> _load(String persona) async {
    final cached = _current[persona];
    if (cached != null) return cached;
    var loaded = const <CaseLink>[];
    try {
      final raw = (await _prefs).getString(keyFor(persona));
      if (raw != null) {
        loaded = [
          for (final item in jsonDecode(raw) as List)
            CaseLink.fromJson((item as Map).cast<String, dynamic>()),
        ];
      }
    } on Object catch (e) {
      Log.w(_tag, 'ignoring unreadable links for $persona', e);
    }
    return _current.putIfAbsent(persona, () => _sorted(loaded));
  }

  Future<void> _write(String persona, List<CaseLink> links) async {
    final sorted = _sorted(links);
    _current[persona] = sorted;
    _controller(persona).add(sorted);
    try {
      await (await _prefs).setString(
        keyFor(persona),
        jsonEncode([for (final l in sorted) l.toJson()]),
      );
    } on Object catch (e) {
      Log.w(_tag, 'could not persist links for $persona', e);
    }
  }

  static List<CaseLink> _sorted(List<CaseLink> links) =>
      List<CaseLink>.unmodifiable(
        <CaseLink>[...links]..sort((a, b) => b.openedAt.compareTo(a.openedAt)),
      );

  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
  }
}
