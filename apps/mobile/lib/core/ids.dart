import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final _rng = Random.secure();

/// 16 random bytes as lowercase hex; used for session ids, nonces and txn ids.
String newId([String prefix = '']) {
  final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return prefix.isEmpty ? hex : '${prefix}_$hex';
}

/// Lowercase hex SHA-256 of a UTF-8 string.
String sha256Hex(String input) => sha256.convert(utf8.encode(input)).toString();

/// Constant-time comparison of two equal-length strings.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
