import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/features/pay/logic/pay_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// `test/fixtures/risk_mw_personas.json` is a copy of risk-mw
/// `config/personas.json` (2026-10-17); refresh it when the server's table
/// changes and this test will say what to update.
void main() {
  test('PayRules.p95For matches the server persona table', () {
    final root = jsonDecode(
      File('test/fixtures/risk_mw_personas.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = (root['personas'] as List).cast<Map<String, dynamic>>();
    expect(rows, isNotEmpty);
    for (final row in rows) {
      final uid = row['uid'] as String;
      expect(
        PayRules.p95For(uid),
        (row['p95_send_bdt'] as num).toDouble(),
        reason: uid,
      );
    }
    expect(PayRules.p95ByPersona.keys.toSet(), {
      for (final r in rows) r['uid'] as String,
    });
  });

  test('the design values and the default', () {
    expect(PayRules.p95For('rina'), 5000);
    expect(PayRules.p95For('rahima'), 2000);
    expect(PayRules.p95For('rafiq'), 3000);
    expect(PayRules.p95For('someone_new'), 5000);
  });
}
