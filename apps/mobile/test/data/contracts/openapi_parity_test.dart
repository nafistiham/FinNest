import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'samples.dart' as s;

/// Fields that main's `contracts.py` declares and the Dart model emits, but
/// the deployed service in `test/fixtures/openapi.json` (re-fetched from the
/// live service on 2026-10-17: unchanged) does not have yet. These await its
/// deploy. Each entry is checked against the class of the same name in
/// `services/risk-mw/app/contracts.py` (the group "pending fields exist on
/// main" below), so a name that main does not have fails here instead of
/// passing silently. Remove an entry once the fixture has it.
const pendingDeploy = <String, Set<String>>{
  // The warning lines and floor flags.
  'InterveneResponse': {
    'lines',
    'earcon',
    'vibrate',
    'speak_on_device',
    'warning_id',
  },
  // Which call and which hold the warning is for.
  'InterveneRequest': {'session_id', 'intervention_id'},
  // Keys transactions/{txnId}.
  'Txn': {'txn_id'},
  // The App Safety Check result the phone holds, sent with the score.
  'ScoreRequest': {'app_safety'},
  // Who checked (server, or the phone's own report) and the closed-
  // set phone facts. Deployed in risk-mw-00019 (2026-10-18); the fixture
  // predates it and is re-fetched separately (it trails several deploys).
  'AppSafetyLatest': {'source', 'facts'},
  // The payee's mule score before and with this transfer.
  'ScoreResponse': {
    'payee_score_before',
    'payee_score_with_this_transfer',
    'payee_moved_feature',
    'payee_score_as_of',
  },
};

/// Enum values main's `contracts.py` has and the fixture does not yet,
/// keyed `Schema.property`; checked against contracts.py like
/// [pendingDeploy]. A delivered case that failed the citation check.
const pendingEnumValues = <String, Set<String>>{
  'CaseReport.status': {'degraded'},
};

/// main's risk-mw contracts, next to the app in this repo; `null` in an
/// app-only checkout (the main-source checks are then skipped).
String? _serverContracts() {
  final file = File('../../services/risk-mw/app/contracts.py');
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// The body of `class [name](...):` in [src], up to the next top-level line.
String? _pyClass(String src, String name) {
  final m = RegExp(
    '^class $name\\b[^\\n]*:\\n((?:[ \\t]+[^\\n]*\\n|\\n)*)',
    multiLine: true,
  ).firstMatch(src);
  return m?.group(1);
}

/// Whole schemas that contracts.py declares but the deployed service does
/// not expose in its OpenAPI yet (no route uses them). Empty since risk-mw
/// revision 00002 (2026-10-17) exposes GET /v1/appsafety/latest; add an entry
/// only for a new class awaiting deploy, and move it to [pairs] once live.
final pendingSchemas = <String, (Set<String>, Map<String, dynamic>)>{};

/// Schemas in the fixture that the app does not model: the mule routes
/// (web console only), the Case Zero start body (built inline by
/// `RiskApiClient.postInvestigate`), `SignalSources` (parsed inside
/// `ScoreResponse`, checked by `score_signal_sources_test.dart`) and FastAPI's validation error bodies (read through
/// `ServerFailure.fromBody`). A schema in the fixture must be either here or
/// in [pairs].
const notUsedByApp = <String>{
  'InvestigateRequest',
  'MuleReason',
  'MuleScoreResponse',
  'SignalSources',
  'HTTPValidationError',
  'ValidationError',
};

/// Optional response fields the deployed service has and the Dart model does
/// not read yet. Dart readers ignore unknown keys, so these are additive;
/// model one by adding it to the class and removing it here. Empty now:
/// `identity_source`, `intervention_id`, `decided_by` and `contact_verified`
/// are modelled.
const serverOnly = <String, Set<String>>{};

/// Dart class <-> OpenAPI schema, with a fully populated instance and the
/// class's `fromJson`.
class _Pair {
  const _Pair(this.schema, this.dartName, this.json, this.parse);
  final String schema;
  final String dartName;
  final Map<String, dynamic> json;

  /// `fromJson`, returning the model (its `toJson()` is called dynamically).
  final Object Function(Map<String, dynamic> json) parse;

  Map<String, dynamic> roundTrip(Map<String, dynamic> json) =>
      (parse(json) as dynamic).toJson() as Map<String, dynamic>;
}

final pairs = <_Pair>[
  _Pair('DeviceInfo', 'DeviceInfo', s.deviceInfo.toJson(), DeviceInfo.fromJson),
  _Pair(
    'DeviceSignals',
    'DeviceSignals',
    s.deviceSignals.toJson(),
    DeviceSignals.fromJson,
  ),
  _Pair('Behaviour', 'Behaviour', s.behaviour.toJson(), Behaviour.fromJson),
  _Pair(
    'SignalsRequest',
    'SignalsRequest',
    s.signalsRequest.toJson(),
    SignalsRequest.fromJson,
  ),
  _Pair(
    'SignalsResponse',
    'SignalsResponse',
    s.signalsResponse.toJson(),
    SignalsResponse.fromJson,
  ),
  _Pair('Txn', 'Txn', s.txn.toJson(), Txn.fromJson),
  _Pair('DemoFlags', 'DemoFlags', s.demoFlags.toJson(), DemoFlags.fromJson),
  _Pair(
    'ScoreRequest',
    'ScoreRequest',
    s.scoreRequest.toJson(),
    ScoreRequest.fromJson,
  ),
  _Pair('Reason', 'Reason', s.reason.toJson(), Reason.fromJson),
  _Pair('Action', 'ActionItem', s.actionItem.toJson(), ActionItem.fromJson),
  _Pair(
    'ScoreResponse',
    'ScoreResponse',
    s.scoreResponse.toJson(),
    ScoreResponse.fromJson,
  ),
  _Pair(
    'InstalledApp',
    'InstalledApp',
    s.installedApp.toJson(),
    InstalledApp.fromJson,
  ),
  _Pair(
    'DeviceState',
    'DeviceState',
    s.deviceState.toJson(),
    DeviceState.fromJson,
  ),
  _Pair(
    'AppSafetyRequest',
    'AppSafetyRequest',
    s.appSafetyRequest.toJson(),
    AppSafetyRequest.fromJson,
  ),
  _Pair('Finding', 'Finding', s.finding.toJson(), Finding.fromJson),
  _Pair(
    'UninstallTarget',
    'UninstallTarget',
    s.uninstallTarget.toJson(),
    UninstallTarget.fromJson,
  ),
  _Pair(
    'AppSafetyResponse',
    'AppSafetyResponse',
    s.appSafetyResponse.toJson(),
    AppSafetyResponse.fromJson,
  ),
  _Pair(
    'AppSafetyLatest',
    'AppSafetyLatest',
    s.appSafetyLatest.toJson(),
    AppSafetyLatest.fromJson,
  ),
  _Pair(
    'DemoIntegrityRequest',
    'DemoIntegrityRequest',
    s.demoIntegrityRequest.toJson(),
    DemoIntegrityRequest.fromJson,
  ),
  _Pair(
    'DemoIntegrityResponse',
    'DemoIntegrityResponse',
    s.demoIntegrityResponse.toJson(),
    DemoIntegrityResponse.fromJson,
  ),
  _Pair(
    'InterveneRequest',
    'InterveneRequest',
    s.interveneRequest.toJson(),
    InterveneRequest.fromJson,
  ),
  _Pair(
    'InterveneResponse',
    'InterveneResponse',
    s.interveneResponse.toJson(),
    InterveneResponse.fromJson,
  ),
  _Pair('Turn', 'Turn', s.turn.toJson(), Turn.fromJson),
  _Pair(
    'ScamTurnRequest',
    'ScamTurnRequest',
    s.scamTurnRequest.toJson(),
    ScamTurnRequest.fromJson,
  ),
  _Pair(
    'ScamTurnResponse',
    'ScamTurnResponse',
    s.scamTurnResponse.toJson(),
    ScamTurnResponse.fromJson,
  ),
  _Pair('ApaContext', 'ApaContext', s.apaContext.toJson(), ApaContext.fromJson),
  _Pair(
    'ApaTurnRequest',
    'ApaTurnRequest',
    s.apaTurnRequest.toJson(),
    ApaTurnRequest.fromJson,
  ),
  _Pair(
    'ApaTurnResponse',
    'ApaTurnResponse',
    s.apaTurnResponse.toJson(),
    ApaTurnResponse.fromJson,
  ),
  _Pair(
    'TrustedContactRequest',
    'TrustedContactRequest',
    s.trustedContactRequest.toJson(),
    TrustedContactRequest.fromJson,
  ),
  _Pair(
    'TrustedContactResponse',
    'TrustedContactResponse',
    s.trustedContactResponse.toJson(),
    TrustedContactResponse.fromJson,
  ),
  _Pair(
    'TrustedContactDecision',
    'TrustedContactDecision',
    s.trustedContactDecision.toJson(),
    TrustedContactDecision.fromJson,
  ),
  _Pair(
    'InvestigateResponse',
    'InvestigateResponse',
    s.investigateResponse.toJson(),
    InvestigateResponse.fromJson,
  ),
  _Pair(
    'Evidence',
    'CaseEvidence',
    s.caseEvidence.toJson(),
    CaseEvidence.fromJson,
  ),
  _Pair('CaseReport', 'CaseReport', s.caseReport.toJson(), CaseReport.fromJson),
];

/// Dart enum <-> the schema property whose `enum` list it must equal.
class _EnumPair {
  const _EnumPair(this.name, this.wires, this.schema, this.property);
  final String name;
  final List<String> wires;
  final String schema;
  final String property;
}

final enumPairs = <_EnumPair>[
  _EnumPair(
    'Decision',
    Decision.values.map((e) => e.wire).toList(),
    'ScoreResponse',
    'decision',
  ),
  _EnumPair(
    'Band',
    Band.values.map((e) => e.wire).toList(),
    'ScoreResponse',
    'band',
  ),
  _EnumPair(
    'TxnType',
    TxnType.values.map((e) => e.wire).toList(),
    'Txn',
    'type',
  ),
  _EnumPair(
    'UiMode',
    UiMode.values.map((e) => e.wire).toList(),
    'InterveneResponse',
    'ui',
  ),
  _EnumPair(
    'SafetyVerdict',
    SafetyVerdict.values.map((e) => e.wire).toList(),
    'DemoFlags',
    'app_safety_verdict',
  ),
  _EnumPair(
    'SafetyVerdict',
    SafetyVerdict.values.map((e) => e.wire).toList(),
    'AppSafetyResponse',
    'verdict',
  ),
  _EnumPair(
    'SafetyVerdict',
    SafetyVerdict.values.map((e) => e.wire).toList(),
    'AppSafetyLatest',
    'verdict',
  ),
  _EnumPair(
    'CallState',
    CallState.values.map((e) => e.wire).toList(),
    'DeviceSignals',
    'call_state',
  ),
  // `unknown` is the app's own fallback, never on the wire.
  _EnumPair(
    'CaseStatus',
    CaseStatus.values
        .where((e) => e != CaseStatus.unknown)
        .map((e) => e.wire)
        .toList(),
    'CaseReport',
    'status',
  ),
];

/// Enum-typed schema properties deliberately kept as `String` in Dart.
const stringTypedEnums = <String>{
  'Finding.severity',
  'Finding.scope',
  'DemoIntegrityRequest.app_recognition',
  'Turn.speaker',
  'ScamTurnResponse.urgency',
  'ScamTurnResponse.requested_secret',
  'TrustedContactDecision.status',
  // `IdentitySource` (verified | demo), read as a plain string.
  'ScoreResponse.identity_source',
  'InterveneResponse.identity_source',
};

/// Models whose constructor needs no arguments: their defaults are compared
/// with the schema `default` values.
final defaultInstances = <String, Map<String, dynamic>>{
  'DeviceInfo': const DeviceInfo().toJson(),
  'DeviceSignals': const DeviceSignals().toJson(),
  'Behaviour': const Behaviour().toJson(),
  'DemoFlags': const DemoFlags().toJson(),
  'DeviceState': const DeviceState().toJson(),
  'ApaContext': const ApaContext().toJson(),
  'AppSafetyRequest': const AppSafetyRequest().toJson(),
  'DemoIntegrityRequest': const DemoIntegrityRequest().toJson(),
};

late Map<String, dynamic> schemas;

Map<String, dynamic> _schema(String name) {
  final schema = schemas[name];
  if (schema == null) fail('schema $name missing from openapi.json');
  return schema as Map<String, dynamic>;
}

Map<String, dynamic> _properties(String name) =>
    _schema(name)['properties'] as Map<String, dynamic>;

/// Resolves the `enum` list of a property node, through `anyOf`/`oneOf`/
/// `allOf`, `items` and `$ref` to a named enum schema.
List<String>? _resolveEnum(Map<String, dynamic> node) {
  if (node['enum'] is List) {
    return (node['enum'] as List<dynamic>).cast<String>();
  }
  if (node[r'$ref'] is String) {
    final name = (node[r'$ref'] as String).split('/').last;
    return _resolveEnum(_schema(name));
  }
  for (final key in const ['anyOf', 'oneOf', 'allOf']) {
    if (node[key] is List) {
      for (final alt in node[key] as List<dynamic>) {
        final found = _resolveEnum(alt as Map<String, dynamic>);
        if (found != null) return found;
      }
    }
  }
  if (node['items'] is Map) {
    return _resolveEnum(node['items'] as Map<String, dynamic>);
  }
  return null;
}

/// Pydantic serialises a nested model's default without its `None` fields
/// (e.g. the `device` default lacks `sdk_int`), while `toJson()` emits them
/// as `null`; drop those keys so the comparison is about values, not nulls.
Object? _withoutNulls(Object? value) {
  if (value is Map<String, dynamic>) {
    return <String, dynamic>{
      for (final e in value.entries)
        if (e.value != null) e.key: _withoutNulls(e.value),
    };
  }
  return value;
}

void main() {
  setUpAll(() {
    final src = File('test/fixtures/openapi.json').readAsStringSync();
    final root = jsonDecode(src) as Map<String, dynamic>;
    final components = root['components'] as Map<String, dynamic>;
    schemas = components['schemas'] as Map<String, dynamic>;
  });

  group('field parity with components.schemas', () {
    for (final pair in pairs) {
      test('${pair.dartName} <-> ${pair.schema}', () {
        final schemaKeys = _properties(pair.schema).keys.toSet();
        final pending = pendingDeploy[pair.schema] ?? const <String>{};
        expect(
          schemaKeys.intersection(pending),
          isEmpty,
          reason:
              'openapi.json now has ${pair.schema} $pending: '
              'remove them from pendingDeploy',
        );
        final notRead = serverOnly[pair.schema] ?? const <String>{};
        expect(
          schemaKeys.containsAll(notRead),
          isTrue,
          reason: 'stale serverOnly entries for ${pair.schema}',
        );
        expect(
          pair.json.keys.toSet(),
          equals(schemaKeys.union(pending).difference(notRead)),
          reason:
              '${pair.dartName}.toJson() keys must equal the schema '
              'properties of ${pair.schema}',
        );
      });
    }

    for (final entry in pendingSchemas.entries) {
      test('${entry.key} (not in the fixture yet) matches contracts.py', () {
        expect(
          schemas.containsKey(entry.key),
          isFalse,
          reason: 'openapi.json now has ${entry.key}: move it to pairs',
        );
        expect(entry.value.$2.keys.toSet(), equals(entry.value.$1));
      });
    }

    test('every required schema property is emitted', () {
      for (final pair in pairs) {
        final required =
            (_schema(pair.schema)['required'] as List<dynamic>?)
                ?.cast<String>() ??
            const <String>[];
        for (final key in required) {
          expect(
            pair.json.containsKey(key),
            isTrue,
            reason: '${pair.dartName} lacks required ${pair.schema}.$key',
          );
        }
      }
    });
  });

  group('pending fields exist on main (contracts.py)', () {
    final src = _serverContracts();
    for (final entry in pendingDeploy.entries) {
      test('${entry.key} declares ${entry.value.join(', ')}', () {
        if (src == null) {
          markTestSkipped('risk-mw source not next to the app');
          return;
        }
        final body = _pyClass(src, entry.key);
        expect(body, isNotNull, reason: 'class ${entry.key} not in main');
        for (final field in entry.value) {
          expect(
            RegExp('^\\s+$field\\s*:', multiLine: true).hasMatch(body!),
            isTrue,
            reason: '${entry.key}.$field is not on main',
          );
        }
      });
    }

    for (final entry in pendingEnumValues.entries) {
      test('${entry.key} allows ${entry.value.join(', ')} on main', () {
        if (src == null) {
          markTestSkipped('risk-mw source not next to the app');
          return;
        }
        final [schema, property] = entry.key.split('.');
        final body = _pyClass(src, schema);
        expect(body, isNotNull, reason: 'class $schema not in main');
        final line = RegExp(
          '^\\s+$property\\s*:[^\\n]*',
          multiLine: true,
        ).firstMatch(body!)?.group(0);
        expect(line, isNotNull, reason: '$schema.$property not on main');
        for (final value in entry.value) {
          expect(line, contains('"$value"'), reason: '$schema.$property');
        }
      });
    }

    test('the Dart models emit every pending field', () {
      for (final pair in pairs) {
        final pending = pendingDeploy[pair.schema] ?? const <String>{};
        expect(
          pair.json.keys.toSet().containsAll(pending),
          isTrue,
          reason: '${pair.dartName} lacks a pending field',
        );
      }
    });
  });

  group('enum parity', () {
    for (final e in enumPairs) {
      test('${e.name} == ${e.schema}.${e.property}', () {
        final node = _properties(e.schema)[e.property] as Map<String, dynamic>;
        final pending =
            pendingEnumValues['${e.schema}.${e.property}'] ?? const <String>{};
        final fixture = _resolveEnum(node)!;
        expect(
          fixture.toSet().intersection(pending),
          isEmpty,
          reason:
              'openapi.json now has ${e.schema}.${e.property} $pending: '
              'remove them from pendingEnumValues',
        );
        expect(
          e.wires.where((w) => !pending.contains(w)).toList(),
          equals(fixture),
        );
        expect(e.wires.toSet().containsAll(pending), isTrue);
      });
    }

    test('every enum-typed property is either a Dart enum or listed', () {
      final covered = enumPairs.map((e) => '${e.schema}.${e.property}').toSet();
      final found = <String>{};
      for (final pair in pairs) {
        for (final entry in _properties(pair.schema).entries) {
          final node = entry.value as Map<String, dynamic>;
          if (serverOnly[pair.schema]?.contains(entry.key) ?? false) continue;
          if (_resolveEnum(node) != null) {
            found.add('${pair.schema}.${entry.key}');
          }
        }
      }
      expect(found.difference(covered), equals(stringTypedEnums));
      expect(covered.difference(found), isEmpty);
    });
  });

  group('schema completeness', () {
    test('every fixture schema is paired or listed in notUsedByApp', () {
      final paired = pairs.map((p) => p.schema).toSet();
      final fixture = schemas.keys.toSet();
      expect(
        fixture.difference(paired.union(notUsedByApp)),
        isEmpty,
        reason:
            'schemas the app neither models nor excludes: add a _Pair '
            '(with samples.dart) or list them in notUsedByApp',
      );
      expect(
        paired.intersection(notUsedByApp),
        isEmpty,
        reason: 'a schema cannot be both paired and unused',
      );
      expect(
        notUsedByApp.difference(fixture),
        isEmpty,
        reason: 'stale notUsedByApp entries',
      );
      expect(
        paired.difference(fixture),
        isEmpty,
        reason: 'paired schemas missing from the fixture',
      );
    });
  });

  group('defaults and required keys, every model', () {
    for (final pair in pairs) {
      List<String> required() =>
          (_schema(pair.schema)['required'] as List<dynamic>?)
              ?.cast<String>() ??
          const <String>[];

      test('${pair.dartName}: only the required keys parse, and every '
          'other field takes the schema default (null when it has none)', () {
        final minimal = <String, dynamic>{
          for (final key in required()) key: pair.json[key],
        };
        final out = pair.roundTrip(minimal);
        for (final prop in _properties(pair.schema).entries) {
          if (required().contains(prop.key)) continue;
          // Omitted on the wire (InstalledApp.version when empty, for the
          // collector's canonical hash): the server applies its own default.
          if (!out.containsKey(prop.key)) continue;
          final node = prop.value as Map<String, dynamic>;
          expect(
            _withoutNulls(out[prop.key]),
            equals(node.containsKey('default') ? node['default'] : null),
            reason: '${pair.dartName}.${prop.key}',
          );
        }
      });

      test('${pair.dartName}: fromJson rejects a missing required key', () {
        for (final key in required()) {
          final without = Map<String, dynamic>.of(pair.json)..remove(key);
          expect(
            () => pair.parse(without),
            throwsFormatException,
            reason: '${pair.dartName} without $key',
          );
        }
      });
    }

    test('models with a no-arg constructor have no required schema keys', () {
      for (final name in defaultInstances.keys) {
        expect(_schema(name)['required'], anyOf(isNull, isEmpty), reason: name);
      }
    });
  });

  group('constructor defaults match schema defaults', () {
    for (final entry in defaultInstances.entries) {
      test(entry.key, () {
        for (final prop in _properties(entry.key).entries) {
          final node = prop.value as Map<String, dynamic>;
          if (!node.containsKey('default')) continue;
          expect(
            _withoutNulls(entry.value[prop.key]),
            equals(node['default']),
            reason: '${entry.key}.${prop.key}',
          );
        }
      });
    }
  });

  group('Case Zero routes the app calls', () {
    late Map<String, dynamic> paths;
    setUpAll(() {
      final src = File('test/fixtures/openapi.json').readAsStringSync();
      paths =
          (jsonDecode(src) as Map<String, dynamic>)['paths']
              as Map<String, dynamic>;
    });

    String? ref(Object? node) =>
        (node as Map<String, dynamic>?)?[r'$ref']?.toString().split('/').last;

    Map<String, dynamic> op(String path, String method) {
      final item = paths[path] as Map<String, dynamic>?;
      expect(item, isNotNull, reason: '$path missing from openapi.json');
      final operation = item![method] as Map<String, dynamic>?;
      expect(operation, isNotNull, reason: '$method $path missing');
      return operation!;
    }

    /// `node[k1][k2]...` through JSON maps.
    Object? at(Object? node, List<String> keys) {
      for (final k in keys) {
        node = (node! as Map<String, dynamic>)[k];
      }
      return node;
    }

    Object? okSchema(Map<String, dynamic> operation) => at(operation, const [
      'responses',
      '200',
      'content',
      'application/json',
      'schema',
    ]);

    test('POST ${RiskRoutes.investigate} takes {acct_id} and answers '
        'InvestigateResponse', () {
      final operation = op(RiskRoutes.investigate, 'post');
      final body = at(operation, const [
        'requestBody',
        'content',
        'application/json',
        'schema',
      ]);
      expect(ref(body), 'InvestigateRequest');
      expect(_properties('InvestigateRequest').keys, ['acct_id']);
      expect(_schema('InvestigateRequest')['required'], ['acct_id']);
      expect(ref(okSchema(operation)), 'InvestigateResponse');
    });

    test('GET ${RiskRoutes.investigationTemplate} answers CaseReport', () {
      final operation = op(RiskRoutes.investigationTemplate, 'get');
      expect(ref(okSchema(operation)), 'CaseReport');
      expect(RiskRoutes.investigation('CZ-0002'), '/v1/investigations/CZ-0002');
    });
  });
}
