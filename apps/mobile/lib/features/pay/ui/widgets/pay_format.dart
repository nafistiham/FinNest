/// How pay-flow data reads on screen: grouped phone numbers, account
/// numbers in fours, counterparty names in the active language and digits.
library;

import 'package:flutter/widgets.dart';

import '../../../../app/dates.dart';
import '../../../../app/l10n.dart';
import '../../logic/billers.dart';
import '../../logic/pay_intent.dart';
import '../../logic/pay_rules.dart';

extension PayFormatX on BuildContext {
  /// "০১৭১২-৩৪৫৬৭৮" / "০১৯XX-XXX৮৮১" in the active digits.
  String phoneShown(String ascii) => digits(PayRules.groupPhone(ascii));

  /// The counterparty's name in the app language and digits.
  String counterpartyName(Counterparty c) =>
      digits(localName(c.nameBn, c.nameEn));

  /// The second line: a grouped phone number, or a bill account in fours.
  String counterpartyNumber(Counterparty c) {
    if (c.subtitle.isEmpty) return '';
    // A district or a label ("গাজীপুর"), not a number: shown as is.
    if (!RegExp(r'^[0-9X]+$').hasMatch(c.subtitle)) return digits(c.subtitle);
    if (c.acctId.startsWith('biller_')) {
      return digits(Bill.groupAccount(c.subtitle));
    }
    return phoneShown(c.subtitle);
  }

  String operatorName(Operator op) => switch (op) {
    Operator.a => l10n.opA,
    Operator.b => l10n.opB,
    Operator.c => l10n.opC,
    Operator.d => l10n.opD,
    Operator.e => l10n.opE,
  };

  String billerName(Biller b) => localName(b.nameBn, b.nameEn);

  String billName(Biller b) => localName(b.billNameBn, b.billNameEn);

  /// "শেষ আজ" / "শেষ ১০ নভে." for the newest payment to a recipient.
  String lastPaidLabel(DateTime ts, {DateTime? now}) {
    final locale = Localizations.maybeLocaleOf(this) ?? const Locale('bn');
    final n = now ?? DateTime.now();
    final day = switch (BhDates.daysAgo(ts, n)) {
      0 => l10n.today,
      1 => l10n.yesterday,
      _ => BhDates.shortDate(ts, locale, now: n),
    };
    return l10n.recipientLast(day);
  }

  /// A DPS plan in one line: "মাসে ৳ ৫০০ · ৩ বছর" / "৳ 500 a month · 3
  /// years"; empty for any other intent.
  String dpsPlanLine(PayIntent intent) {
    final months = intent.dpsTenureMonths;
    if (intent.kind != PayKind.dps || months == null) return '';
    return l10n.dpsPlanLine(
      taka(intent.amountBdt),
      l10n.dpsTenureYears(months ~/ 12),
    );
  }

  /// The app-bar title of each kind.
  String payTitle(PayKind kind) => switch (kind) {
    PayKind.send => l10n.featureSend,
    PayKind.cashOut => l10n.featureCashOut,
    PayKind.cashIn => l10n.featureCashIn,
    PayKind.recharge => l10n.featureRecharge,
    PayKind.bill => l10n.featureBill,
    PayKind.dps => l10n.dpsOpenNew,
  };
}
