/// Demo billers for Pay bill, from `assets/demo/billers.json`.
/// Front-end only: nothing calls a real biller.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class Biller {
  const Biller({
    required this.id,
    required this.nameBn,
    required this.nameEn,
    required this.billNameBn,
    required this.billNameEn,
    required this.icon,
    required this.accountDigits,
    required this.amountBdt,
    required this.month,
    required this.due,
  });

  factory Biller.fromJson(Map<String, dynamic> j) => Biller(
    id: j['id'] as String,
    nameBn: j['name_bn'] as String,
    nameEn: j['name_en'] as String,
    billNameBn: j['bill_name_bn'] as String,
    billNameEn: j['bill_name_en'] as String,
    icon: j['icon'] as String? ?? 'bill',
    accountDigits: (j['account_digits'] as num).toInt(),
    amountBdt: (j['amount_bdt'] as num).toInt(),
    month: DateTime.parse('${j['month']}-01T12:00:00+06:00'),
    due: DateTime.parse('${j['due']}T12:00:00+06:00'),
  );

  final String id;

  /// "ডেসকো (বিদ্যুৎ)" / "DESCO (electricity)": the row title.
  final String nameBn;
  final String nameEn;

  /// "ডেসকো বিদ্যুৎ বিল": the PIN line and the ledger row's counterparty.
  final String billNameBn;
  final String billNameEn;

  /// `electricity` | `water` | `gas` (the row's icon).
  final String icon;

  /// Length of the customer number (8 DESCO, 10 WASA, 9 Titas).
  final int accountDigits;
  final int amountBdt;

  /// The billed month and the due date (Asia/Dhaka noon).
  final DateTime month;
  final DateTime due;
}

/// One seeded bill for one customer number.
@immutable
class Bill {
  const Bill({required this.biller, required this.account});

  final Biller biller;

  /// ASCII digits, [Biller.accountDigits] long.
  final String account;

  int get amountBdt => biller.amountBdt;

  /// `biller_<id>_<account>`, the ledger row's `to_acct`.
  String get acctId => 'biller_${biller.id}_$account';

  /// "1234 5678": groups of four.
  String get accountGrouped => groupAccount(account);

  static String groupAccount(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 4 == 0) out.write(' ');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

abstract final class BillerCatalog {
  static const path = 'assets/demo/billers.json';

  static List<Biller> parse(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    return [
      for (final b in root['billers'] as List<dynamic>)
        Biller.fromJson(b as Map<String, dynamic>),
    ];
  }

  static Future<List<Biller>> load([AssetBundle? bundle]) async =>
      parse(await (bundle ?? rootBundle).loadString(path, cache: true));
}

/// The bundled billers. Tests override it with a parsed list.
final billersProvider = FutureProvider<List<Biller>>(
  (_) => BillerCatalog.load(),
);
