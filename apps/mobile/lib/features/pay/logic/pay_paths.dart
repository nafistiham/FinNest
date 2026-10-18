/// Paths of the shared money flow (see `pay_routes.dart`).
library;

import 'pay_intent.dart';

export 'pay_intent.dart' show PayKind;

abstract final class PayPaths {
  static const home = '/home';

  /// Where a DPS starts and where back from its PIN pad returns.
  static const savings = '/savings';

  static String start(PayKind k) => '/pay/${k.slug}';
  static String amount(PayKind k) => '/pay/${k.slug}/amount';
  static String confirm(PayKind k) => '/pay/${k.slug}/confirm';
  static String pin(PayKind k) => '/pay/${k.slug}/pin';
  static String code(PayKind k) => '/pay/${k.slug}/code';

  /// Where back from the PIN pad goes: the amount step, the bill card, or
  /// (DPS) Savings.
  static String beforePin(PayKind k) => switch (k) {
    PayKind.bill => confirm(k),
    PayKind.dps => savings,
    _ => amount(k),
  };

  static String result(
    PayKind k, {
    required String state,
    int? amount,
    String? txn,
    bool banner = false,
    String? intervention,
  }) => Uri(
    path: '/pay/${k.slug}/result',
    queryParameters: {
      'state': state,
      if (amount != null) 'amount': '$amount',
      'txn': ?txn,
      if (banner) 'banner': '1',
      'intervention': ?intervention,
    },
  ).toString();

  /// Compatibility paths of the send flow (`Routes.send` etc.).
  static final send = start(PayKind.send);
  static final sendAmount = amount(PayKind.send);
  static final sendPin = pin(PayKind.send);
  static const sendResult = '/pay/send/result';
}
