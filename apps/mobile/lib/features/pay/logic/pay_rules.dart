/// Limits, quick amounts, fees and number rules of the pay flow
/// (2.2, 9.2). Pure Dart; the screens read it for their
/// labels and the controller for what a key press may do.
library;

import 'dart:math' as math;

import 'pay_intent.dart';

/// Why the amount step's primary is disabled, or [ok].
enum AmountCheck { empty, belowMin, outOfRange, ok }

/// State of a typed mobile number.
enum PhoneCheck { incomplete, invalid, valid }

abstract final class PayRules {
  /// Demo build: an amount above the balance only shows a caution line; the
  /// server decides (the scam scenes need amounts the seeded balances cannot
  /// cover). True for any non-demo build (open question Q3).
  static const enforceBalance = false;

  /// Nine digits: well above any demo balance and still one line at 360 dp.
  static const maxAmount = 99999999;

  /// A Bangladeshi mobile number: 11 digits, `01`, third digit 3-9.
  static const phoneLength = 11;

  static const cashOutMin = 50;
  static const rechargeMin = 10;
  static const rechargeMax = 1000;

  /// How long a cash-in code stays valid.
  static const cashInTtl = Duration(minutes: 15);

  /// Recharge and bill: the local allow keeps the PIN pad's rhythm.
  static const localAllowDelay = Duration(milliseconds: 600);

  /// Four chips in one row (never a scroller). 7,900 on send stays: it is the
  /// new-payee delay demo (server p95 is 5,000 for every user).
  static List<int> quickAmounts(PayKind kind) => switch (kind) {
    PayKind.send => const [500, 1000, 5000, 7900],
    PayKind.cashOut || PayKind.cashIn => const [500, 1000, 2000, 5000],
    PayKind.recharge => const [50, 100, 200, 500],
    PayKind.bill || PayKind.dps => const [],
  };

  /// The persona's 95th-percentile send (risk-mw `config/personas.json`
  /// `p95_send_bdt`; `p95_test.dart` pins this table to a copy of it). The
  /// identity step-up is offered only at or below it.
  static const Map<String, double> p95ByPersona = {
    'rina': 5000,
    'rafiq': 3000,
    'rahima': 2000,
    'sumon': 4000,
  };

  /// For a uid the server does not list (`RISK_MW_DEFAULT_P95_AMOUNT_BDT`).
  static const double defaultP95 = 5000;

  static double p95For(String uid) => p95ByPersona[uid] ?? defaultP95;

  /// Cash out: demo 1.5 %, rounded up to whole taka. Everything else: 0.
  static int feeFor(PayKind kind, int amount) =>
      kind == PayKind.cashOut && amount > 0 ? (amount * 15 + 999) ~/ 1000 : 0;

  static AmountCheck checkAmount(PayKind kind, int amount) {
    if (amount <= 0) return AmountCheck.empty;
    return switch (kind) {
      PayKind.cashOut when amount < cashOutMin => AmountCheck.belowMin,
      PayKind.recharge when amount < rechargeMin || amount > rechargeMax =>
        AmountCheck.outOfRange,
      _ => AmountCheck.ok,
    };
  }

  /// Strips everything but digits and a leading `88` country code:
  /// `+880 1712-345678` → `01712345678`.
  static String normalisePhone(String raw) {
    var d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('880')) d = d.substring(2);
    return d;
  }

  static PhoneCheck checkPhone(String digits) {
    if (digits.length < phoneLength) return PhoneCheck.incomplete;
    final ok =
        digits.length == phoneLength &&
        RegExp(r'^01[3-9]\d{8}$').hasMatch(digits);
    return ok ? PhoneCheck.valid : PhoneCheck.invalid;
  }

  /// "01712-345678" (5 + 6) for a full or masked number, or as typed so far.
  /// ASCII in, ASCII out; screens convert with `context.digits`.
  static String groupPhone(String digits) => digits.length <= 5
      ? digits
      : '${digits.substring(0, 5)}-${digits.substring(5)}';

  /// The masked display form of a seed agent till `AG-0027`: the till number
  /// stands in for the last three digits ("017XXXXX027").
  static String agentMasked(String tillId) {
    final digits = tillId.replaceAll(RegExp(r'\D'), '');
    final last3 = digits.length >= 3
        ? digits.substring(digits.length - 3)
        : digits.padLeft(3, '0');
    return '017XXXXX$last3';
  }

  static const _codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  /// The brand initials a cash-in code starts with.
  static const cashInCodePrefix = 'FN';

  /// `FN-` (FinNest) + four characters from `[2-9A-HJ-NP-Z]` (no 0/O, 1/I).
  static String newCashInCode([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final b = StringBuffer('$cashInCodePrefix-');
    for (var i = 0; i < 4; i++) {
      b.write(_codeAlphabet[r.nextInt(_codeAlphabet.length)]);
    }
    return b.toString();
  }
}
