/// On-device enrolment of this phone's owner:
/// the measured 55-float vector of each scored PIN entry, kept per persona
/// in SharedPreferences (`enrolment_<persona>`, at most [EnrolmentStore.maxRows]
/// rows) and exported as JSON Lines, so the backend can fit the per-user
/// model with `train_ato` (see `libs/ato`). One JSON object per line with
/// `ts`, `persona` and `features` (55 floats in `FeatureNames` order).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One enrolled session: a wire row plus who and when.
class EnrolmentRow {
  EnrolmentRow({
    required this.sessionId,
    required this.ts,
    required this.persona,
    required List<double> features,
  }) : features = List<double>.unmodifiable(features) {
    if (features.length != FeatureNames.count) {
      throw ArgumentError.value(
        features.length,
        'features.length',
        'an enrolment row carries exactly ${FeatureNames.count} features',
      );
    }
  }

  factory EnrolmentRow.fromJson(Map<String, dynamic> json) => EnrolmentRow(
    sessionId: json['session_id'] as String,
    ts: DateTime.parse(json['ts'] as String),
    persona: json['persona'] as String,
    features: [for (final v in json['features'] as List) (v as num).toDouble()],
  );

  final String sessionId;
  final DateTime ts;
  final String persona;
  final List<double> features;

  /// The JSONL object: `{"session_id","ts","persona","features":[55]}`.
  Map<String, Object> toJson() => {
    'session_id': sessionId,
    'ts': ts.toUtc().toIso8601String(),
    'persona': persona,
    'features': features,
  };
}

class EnrolmentStore {
  EnrolmentStore({
    Future<SharedPreferences>? prefs,
    Future<Directory?> Function()? exportDir,
  }) : _prefsOverride = prefs,
       _exportDir = exportDir ?? _defaultExportDir;

  static const _tag = 'enrolment';

  /// Oldest rows drop off beyond this (20 × 55 floats is small).
  static const maxRows = 20;

  static String keyFor(String persona) => 'enrolment_$persona';

  static String fileNameFor(String persona) =>
      '${persona}_phone_sessions.jsonl';

  final Future<SharedPreferences>? _prefsOverride;

  /// Resolved on first use (the provider is built with the risk flow, long
  /// before anything is enrolled).
  Future<SharedPreferences> get _prefs =>
      _prefsOverride ?? SharedPreferences.getInstance();
  final Future<Directory?> Function() _exportDir;
  final _counts = <String, StreamController<int>>{};

  /// The app-scoped external directory (readable with `adb pull` from a
  /// release build); the documents directory where there is none.
  static Future<Directory?> _defaultExportDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    } on Object catch (e) {
      Log.w(_tag, 'no external storage directory', e);
    }
    return getApplicationDocumentsDirectory();
  }

  StreamController<int> _controller(String persona) =>
      _counts.putIfAbsent(persona, StreamController<int>.broadcast);

  /// The rows of [persona], oldest first.
  Future<List<EnrolmentRow>> rows(String persona) async {
    try {
      final raw = (await _prefs).getString(keyFor(persona));
      if (raw == null) return const [];
      return [
        for (final item in jsonDecode(raw) as List)
          EnrolmentRow.fromJson((item as Map).cast<String, dynamic>()),
      ];
    } on Object catch (e) {
      Log.w(_tag, 'ignoring unreadable enrolment for $persona', e);
      return const [];
    }
  }

  /// The newest row of [persona], or `null`.
  Future<EnrolmentRow?> last(String persona) async {
    final all = await rows(persona);
    return all.isEmpty ? null : all.last;
  }

  /// Appends [row] to its persona's rows, keeping the newest [maxRows].
  Future<void> append(EnrolmentRow row) async {
    final all = [...await rows(row.persona), row];
    final kept = all.length > maxRows ? all.sublist(all.length - maxRows) : all;
    await _write(row.persona, kept);
  }

  Future<void> clear(String persona) => _write(persona, const []);

  /// How many rows [persona] has: the current count, then every change.
  Stream<int> watchCount(String persona) => Stream.multi((emitter) async {
    final sub = _controller(persona).stream.listen(emitter.add);
    emitter.onCancel = sub.cancel;
    final n = (await rows(persona)).length;
    if (!emitter.isClosed) emitter.add(n);
  });

  /// One JSON object per line, oldest first, a trailing newline.
  static String toJsonl(List<EnrolmentRow> rows) =>
      rows.map((r) => '${jsonEncode(r.toJson())}\n').join();

  /// Writes [persona]'s rows to `<persona>_phone_sessions.jsonl` in the
  /// export directory and returns the file. Throws a [StateError] when the
  /// platform gives no directory.
  Future<File> exportJsonl(String persona) async {
    final dir = await _exportDir();
    if (dir == null) throw StateError('no export directory');
    final file = File('${dir.path}/${fileNameFor(persona)}');
    await file.writeAsString(toJsonl(await rows(persona)), flush: true);
    Log.i(_tag, 'exported enrolment for $persona');
    return file;
  }

  Future<void> _write(String persona, List<EnrolmentRow> rows) async {
    try {
      await (await _prefs).setString(
        keyFor(persona),
        jsonEncode([for (final r in rows) r.toJson()]),
      );
    } on Object catch (e) {
      Log.w(_tag, 'could not persist enrolment for $persona', e);
    }
    _controller(persona).add(rows.length);
  }

  Future<void> dispose() async {
    for (final c in _counts.values) {
      await c.close();
    }
  }
}
