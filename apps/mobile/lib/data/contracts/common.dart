/// Shared enums and JSON helpers for the Dart mirrors of
/// `services/risk-mw/app/contracts.py`.
///
/// Every model in this package follows the same rules:
/// - JSON keys are the exact snake_case names of contracts.py;
/// - unknown extra keys are ignored, missing optional keys take the
///   contracts.py default, missing required keys throw a [FormatException];
/// - numbers are accepted as `int` or `double`;
/// - lists produced by `fromJson` are unmodifiable.
library;

// --- Enums -----------------------------------------------------------------

/// `Decision = Literal["allow", "step_up", "delay", "hold", "block"]`.
enum Decision {
  allow('allow'),
  stepUp('step_up'),
  delay('delay'),
  hold('hold'),
  block('block');

  const Decision(this.wire);

  /// The exact string used on the wire.
  final String wire;

  static Decision fromWire(String wire) =>
      enumFromWire(values, (d) => d.wire, wire, 'Decision');
}

/// `Band = Literal["low", "medium", "high", "critical"]`.
enum Band {
  low('low'),
  medium('medium'),
  high('high'),
  critical('critical');

  const Band(this.wire);
  final String wire;

  static Band fromWire(String wire) =>
      enumFromWire(values, (b) => b.wire, wire, 'Band');
}

/// `TxnType = Literal["pin_reset", "new_payee", "send_money"]`.
enum TxnType {
  pinReset('pin_reset'),
  newPayee('new_payee'),
  sendMoney('send_money');

  const TxnType(this.wire);
  final String wire;

  static TxnType fromWire(String wire) =>
      enumFromWire(values, (t) => t.wire, wire, 'TxnType');
}

/// `UiMode = Literal["banner", "fullscreen", "call_apa"]`.
enum UiMode {
  banner('banner'),
  fullscreen('fullscreen'),
  callApa('call_apa');

  const UiMode(this.wire);
  final String wire;

  static UiMode fromWire(String wire) =>
      enumFromWire(values, (u) => u.wire, wire, 'UiMode');
}

/// `SafetyVerdict = Literal["SAFE", "CAUTION", "BLOCK"]`.
enum SafetyVerdict {
  safe('SAFE'),
  caution('CAUTION'),
  block('BLOCK');

  const SafetyVerdict(this.wire);
  final String wire;

  static SafetyVerdict fromWire(String wire) =>
      enumFromWire(values, (v) => v.wire, wire, 'SafetyVerdict');
}

/// `DeviceSignals.call_state: Literal["IDLE", "RINGING", "OFFHOOK"]`.
enum CallState {
  idle('IDLE'),
  ringing('RINGING'),
  offhook('OFFHOOK');

  const CallState(this.wire);
  final String wire;

  static CallState fromWire(String wire) =>
      enumFromWire(values, (c) => c.wire, wire, 'CallState');
}

/// Resolves [wire] against [values]; throws [FormatException] when unknown.
T enumFromWire<T extends Enum>(
  List<T> values,
  String Function(T value) wireOf,
  String wire,
  String enumName,
) {
  for (final value in values) {
    if (wireOf(value) == wire) return value;
  }
  throw FormatException('Unknown $enumName wire value "$wire"');
}

// --- copyWith sentinel -----------------------------------------------------

/// Marker for `copyWith` parameters that can be set to `null`: passing
/// nothing keeps the current value, passing `null` clears it.
const Object unchanged = _Unchanged();

class _Unchanged {
  const _Unchanged();
}

// --- Readers ---------------------------------------------------------------

Object _require(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) {
    throw FormatException('Missing required key "$key"');
  }
  return value as Object;
}

Never _wrongType(String key, Object value, String expected) =>
    throw FormatException(
      'Key "$key" expected $expected, got ${value.runtimeType}',
    );

String _asString(String key, Object value) =>
    value is String ? value : _wrongType(key, value, 'a string');

bool _asBool(String key, Object value) =>
    value is bool ? value : _wrongType(key, value, 'a bool');

double _asDouble(String key, Object value) =>
    value is num ? value.toDouble() : _wrongType(key, value, 'a number');

int _asInt(String key, Object value) => switch (value) {
  final int i => i,
  final double d when d == d.truncateToDouble() => d.toInt(),
  _ => _wrongType(key, value, 'an integer'),
};

List<Object?> _asList(String key, Object value) =>
    value is List ? value : _wrongType(key, value, 'a list');

Map<String, dynamic> _asMap(String key, Object value) => switch (value) {
  final Map<String, dynamic> m => m,
  final Map<dynamic, dynamic> m => m.cast<String, dynamic>(),
  _ => _wrongType(key, value, 'an object'),
};

/// Required string.
String requireString(Map<String, dynamic> json, String key) =>
    _asString(key, _require(json, key));

/// Optional string with a default.
String readString(Map<String, dynamic> json, String key, String fallback) {
  final value = json[key];
  return value == null ? fallback : _asString(key, value as Object);
}

/// Nullable string (`str | None`).
String? readStringOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value == null ? null : _asString(key, value as Object);
}

/// Required bool.
bool requireBool(Map<String, dynamic> json, String key) =>
    _asBool(key, _require(json, key));

/// Optional bool with a default.
bool readBool(Map<String, dynamic> json, String key, bool fallback) {
  final value = json[key];
  return value == null ? fallback : _asBool(key, value as Object);
}

/// Nullable bool (`bool | None`).
bool? readBoolOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value == null ? null : _asBool(key, value as Object);
}

/// Required number, accepted as `int` or `double`.
double requireDouble(Map<String, dynamic> json, String key) =>
    _asDouble(key, _require(json, key));

/// Optional number with a default, accepted as `int` or `double`.
double readDouble(Map<String, dynamic> json, String key, double fallback) {
  final value = json[key];
  return value == null ? fallback : _asDouble(key, value as Object);
}

/// Nullable number (`float | None`).
double? readDoubleOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value == null ? null : _asDouble(key, value as Object);
}

/// Required integer; a whole-valued double such as `30.0` is accepted.
int requireInt(Map<String, dynamic> json, String key) =>
    _asInt(key, _require(json, key));

/// Optional integer with a default.
int readInt(Map<String, dynamic> json, String key, int fallback) {
  final value = json[key];
  return value == null ? fallback : _asInt(key, value as Object);
}

/// Nullable integer (`int | None`).
int? readIntOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value == null ? null : _asInt(key, value as Object);
}

/// Required enum, resolved through [fromWire].
T requireEnum<T>(
  Map<String, dynamic> json,
  String key,
  T Function(String wire) fromWire,
) => fromWire(requireString(json, key));

/// Optional enum with a default.
T readEnum<T>(
  Map<String, dynamic> json,
  String key,
  T Function(String wire) fromWire,
  T fallback,
) {
  final value = json[key];
  return value == null ? fallback : fromWire(_asString(key, value as Object));
}

/// Required list, each item converted by [convert]; the result is unmodifiable.
List<T> requireList<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Object item) convert,
) => _convertList(key, _asList(key, _require(json, key)), convert);

/// Optional list (default empty), unmodifiable.
List<T> readList<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Object item) convert,
) {
  final value = json[key];
  if (value == null) return List<T>.empty();
  return _convertList(key, _asList(key, value as Object), convert);
}

List<T> _convertList<T>(
  String key,
  List<Object?> raw,
  T Function(Object item) convert,
) {
  final out = <T>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item == null) {
      throw FormatException('Key "$key" has a null item at index $i');
    }
    out.add(convert(item));
  }
  return List<T>.unmodifiable(out);
}

/// Item converters for [requireList] / [readList].
String stringItem(Object item) =>
    item is String ? item : _wrongType('item', item, 'a string');

double doubleItem(Object item) =>
    item is num ? item.toDouble() : _wrongType('item', item, 'a number');

/// Wraps an object converter so nested models can be read from list items.
T Function(Object item) objectItem<T>(
  T Function(Map<String, dynamic> json) parse,
) =>
    (item) => parse(_asMap('item', item));

/// Required nested object.
T requireObject<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic> json) parse,
) => parse(_asMap(key, _require(json, key)));

/// Optional nested object with a default.
T readObject<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic> json) parse,
  T fallback,
) {
  final value = json[key];
  return value == null ? fallback : parse(_asMap(key, value as Object));
}

/// Optional map of JSON primitives (`dict[str, int | float | str | bool]`),
/// unmodifiable; `null` values are dropped.
Map<String, Object> readPrimitiveMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return const {};
  final raw = _asMap(key, value as Object);
  final out = <String, Object>{};
  for (final entry in raw.entries) {
    final v = entry.value;
    if (v == null) continue;
    if (v is num || v is String || v is bool) {
      out[entry.key] = v as Object;
    } else {
      _wrongType('$key.${entry.key}', v as Object, 'a JSON primitive');
    }
  }
  return Map<String, Object>.unmodifiable(out);
}

// --- Equality and hashing --------------------------------------------------

/// Element-wise list equality (`==` on each element).
bool listEq<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Key/value map equality (`==` on each value).
bool mapEq<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Order-sensitive list hash.
int hashList<T>(List<T> list) => Object.hashAll(list);

/// Order-insensitive map hash.
int hashMap<K, V>(Map<K, V> map) => Object.hashAllUnordered(
  map.entries.map((e) => Object.hash(e.key, e.value)),
);
