import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/domain/behaviour/enrolment_store.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

EnrolmentRow row(int n, {String persona = 'rina'}) => EnrolmentRow(
  sessionId: 'sess_$n',
  ts: DateTime.utc(2026, 10, 17, 9, n),
  persona: persona,
  features: List<double>.filled(FeatureNames.count, n.toDouble()),
);

void main() {
  late Directory dir;
  late EnrolmentStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('enrolment_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    store = EnrolmentStore(exportDir: () async => dir);
  });

  test('a row carries exactly 55 features', () {
    expect(FeatureNames.count, 55);
    expect(row(1).features, hasLength(55));
    expect(
      () => EnrolmentRow(
        sessionId: 's',
        ts: DateTime.utc(2026),
        persona: 'rina',
        features: List.filled(39, 0),
      ),
      throwsArgumentError,
    );
  });

  test(
    'append keeps rows per persona, oldest first, under enrolment_<persona>',
    () async {
      await store.append(row(1));
      await store.append(row(2));
      await store.append(row(3, persona: 'rahima'));
      expect((await store.rows('rina')).map((r) => r.sessionId), [
        'sess_1',
        'sess_2',
      ]);
      expect((await store.rows('rahima')).single.persona, 'rahima');
      expect((await store.last('rina'))!.sessionId, 'sess_2');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('enrolment_rina'), isNotNull);
      expect(EnrolmentStore.keyFor('rina'), 'enrolment_rina');
    },
  );

  test('at most 20 rows: the oldest drop off', () async {
    for (var i = 1; i <= 23; i++) {
      await store.append(row(i));
    }
    final rows = await store.rows('rina');
    expect(rows, hasLength(EnrolmentStore.maxRows));
    expect(EnrolmentStore.maxRows, 20);
    expect(rows.first.sessionId, 'sess_4');
    expect(rows.last.sessionId, 'sess_23');
  });

  test('clear empties one persona; the counter follows', () async {
    final counts = <int>[];
    final sub = store.watchCount('rina').listen(counts.add);
    await pumpEventQueue();
    await store.append(row(1));
    await store.append(row(2, persona: 'rahima'));
    await store.clear('rina');
    await pumpEventQueue();
    await sub.cancel();
    expect(counts, [0, 1, 0]);
    expect(await store.rows('rina'), isEmpty);
    expect(await store.rows('rahima'), hasLength(1));
  });

  test('exportJsonl writes <persona>_phone_sessions.jsonl: one object per '
      'line with session_id, ts, persona and 55 features', () async {
    await store.append(row(1));
    await store.append(row(2));
    final file = await store.exportJsonl('rina');
    expect(file.path, '${dir.path}/rina_phone_sessions.jsonl');
    final lines = file.readAsStringSync().split('\n');
    expect(lines.last, isEmpty, reason: 'trailing newline');
    final objects = [
      for (final l in lines.where((l) => l.isNotEmpty))
        jsonDecode(l) as Map<String, dynamic>,
    ];
    expect(objects, hasLength(2));
    for (final o in objects) {
      expect(o.keys.toSet(), {'session_id', 'ts', 'persona', 'features'});
      expect(o['persona'], 'rina');
      expect(o['features'] as List, hasLength(55));
      expect(DateTime.parse(o['ts'] as String).isUtc, isTrue);
    }
    expect(objects.first['session_id'], 'sess_1');
    expect(objects.first['ts'], '2026-10-17T09:01:00.000Z');
  });

  test(
    'export without a directory throws (the panel shows the failure)',
    () async {
      final none = EnrolmentStore(exportDir: () async => null);
      expect(() => none.exportJsonl('rina'), throwsStateError);
    },
  );

  test('a corrupt stored value reads as empty', () async {
    SharedPreferences.setMockInitialValues({'enrolment_rina': 'not json'});
    expect(await EnrolmentStore().rows('rina'), isEmpty);
  });
}
