/// The shared money flow's data model: one
/// feature-specific first step (who or what), then the shared amount, PIN
/// and result steps. [PayIntent] is what the steps have collected so far;
/// `PayController` owns it.
library;

import 'package:flutter/widgets.dart' show IconData, immutable;

import 'billers.dart';

/// The money-moving features. [slug] is the `/pay/:kind` path segment.
/// [dps] is the first instalment of a new savings plan: no amount step (the
/// Savings sheet sets the plan), the PIN step, then a local allow.
enum PayKind {
  send('send'),
  cashOut('cashout'),
  cashIn('cashin'),
  recharge('recharge'),
  bill('bill'),
  dps('dps');

  const PayKind(this.slug);

  final String slug;

  /// `null` for anything that is not one of the five slugs.
  static PayKind? parse(String? slug) {
    for (final k in values) {
      if (k.slug == slug) return k;
    }
    return null;
  }

  /// Send money and cash out go through `/v1/risk/score`; recharge, bill
  /// and DPS are a local allow after the PIN check; cash in has no PIN step.
  bool get scored => this == send || this == cashOut;

  bool get usesPin => this != cashIn;

  /// The bill's amount is fixed: the amount step is replaced by the bill card.
  bool get fixedAmount => this == bill || this == dps;

  /// `LedgerTxn.type` written for this kind (the seed vocabulary).
  String get ledgerType => switch (this) {
    send => 'send_money',
    cashOut => 'cash_out',
    cashIn => 'cash_in',
    recharge => 'recharge',
    bill => 'payment',
    dps => 'dps_deposit',
  };
}

/// Mobile operators by number prefix. The demo uses generic labels
/// ("Operator A" to "Operator E") instead of real company names. Names are
/// shown as plain text only; the Bangla name is also what the ledger row
/// stores.
enum Operator {
  a('অপারেটর ক', 'Operator A'),
  b('অপারেটর খ', 'Operator B'),
  c('অপারেটর গ', 'Operator C'),
  d('অপারেটর ঘ', 'Operator D'),
  e('অপারেটর ঙ', 'Operator E');

  const Operator(this.nameBn, this.nameEn);

  final String nameBn;
  final String nameEn;

  /// The operator a number's prefix suggests: 017/013 [a], 018 [b],
  /// 019/014 [c], 015 [d], 016 [e]. A guess (numbers are portable): the
  /// customer can change it. `null` below three digits.
  static Operator? forNumber(String digits) {
    if (digits.length < 3) return null;
    return switch (digits.substring(0, 3)) {
      '017' || '013' => a,
      '018' => b,
      '016' => e,
      '019' || '014' => c,
      '015' => d,
      _ => null,
    };
  }
}

/// How a [Counterparty] is drawn in rows and summaries: a person's initial,
/// an icon on a neutral tile (agent, biller), or an operator.
@immutable
sealed class CounterpartyAvatar {
  const CounterpartyAvatar();

  const factory CounterpartyAvatar.initial() = InitialAvatar;
  const factory CounterpartyAvatar.icon(IconData icon) = IconAvatar;
  const factory CounterpartyAvatar.operator(Operator operator) = OperatorAvatar;
}

final class InitialAvatar extends CounterpartyAvatar {
  const InitialAvatar();
}

final class IconAvatar extends CounterpartyAvatar {
  const IconAvatar(this.icon);
  final IconData icon;
}

final class OperatorAvatar extends CounterpartyAvatar {
  const OperatorAvatar(this.operator);
  final Operator operator;
}

/// Who or what receives the money, as shown on the amount, PIN and result
/// screens.
@immutable
class Counterparty {
  const Counterparty({
    required this.acctId,
    required this.nameBn,
    this.nameEn,
    this.subtitle = '',
    this.avatar = const CounterpartyAvatar.initial(),
    this.isSaved = true,
  });

  /// `acct_rahima`, `AG-0027` / `agent_01712345678`, `mob_01812345678`,
  /// `biller_desco_12345678`.
  final String acctId;

  /// "মা", "এজেন্ট", "ডেসকো (বিদ্যুৎ)", or a grouped number "01712-345678"
  /// (ASCII digits; screens convert with `context.digits`).
  final String nameBn;
  final String? nameEn;

  /// ASCII digits: "019XXXXX881", "01712345678", or the bill account
  /// "12345678". Screens group and convert it.
  final String subtitle;
  final CounterpartyAvatar avatar;

  /// `false` → `is_new_payee: true` on the wire.
  final bool isSaved;

  @override
  bool operator ==(Object other) =>
      other is Counterparty &&
      acctId == other.acctId &&
      nameBn == other.nameBn &&
      nameEn == other.nameEn &&
      subtitle == other.subtitle &&
      isSaved == other.isSaved;

  @override
  int get hashCode => Object.hash(acctId, nameBn, nameEn, subtitle, isSaved);

  @override
  String toString() => 'Counterparty($acctId, saved: $isSaved)';
}

/// What the pay flow has collected so far.
@immutable
class PayIntent {
  const PayIntent({
    required this.kind,
    required this.sessionId,
    this.counterparty,
    this.amountBdt = 0,
    this.feeBdt = 0,
    this.fixedAmountBdt,
    this.operator,
    this.postpaid = false,
    this.bill,
    this.dpsTenureMonths,
    this.warningShown,
    this.warningChoice,
  });

  final PayKind kind;
  final Counterparty? counterparty;

  /// What the customer typed (or the bill's fixed amount).
  final int amountBdt;

  /// Cash out only (demo 1.5 %), else 0.
  final int feeBdt;

  /// Bill: the amount step is skipped.
  final int? fixedAmountBdt;

  /// `session_id` of this attempt (from `SessionRepo`).
  final String sessionId;

  /// Recharge: the operator (auto-picked by prefix, customer can override).
  final Operator? operator;

  /// Recharge: postpaid instead of the default prepaid.
  final bool postpaid;

  /// Bill: the seeded bill being paid.
  final Bill? bill;

  /// DPS: the plan's tenure (the amount is the monthly instalment).
  final int? dpsTenureMonths;

  /// The pre-PIN warning the amount step showed (`unfamiliar_payee`), or
  /// null; copied onto the ledger row as `warning_shown`.
  final String? warningShown;

  /// What the customer did after [warningShown] (`continued`), or null;
  /// the ledger row's `warning_choice`.
  final String? warningChoice;

  int get debitBdt => amountBdt + feeBdt;

  bool get canProceed => counterparty != null && amountBdt > 0;

  /// `is_new_payee` on the wire.
  bool get isNewPayee => !(counterparty?.isSaved ?? true);

  PayIntent copyWith({
    Object? counterparty = _unchanged,
    int? amountBdt,
    int? feeBdt,
    Object? fixedAmountBdt = _unchanged,
    Object? operator = _unchanged,
    bool? postpaid,
    Object? bill = _unchanged,
    Object? dpsTenureMonths = _unchanged,
    Object? warningShown = _unchanged,
    Object? warningChoice = _unchanged,
  }) => PayIntent(
    kind: kind,
    sessionId: sessionId,
    counterparty: identical(counterparty, _unchanged)
        ? this.counterparty
        : counterparty as Counterparty?,
    amountBdt: amountBdt ?? this.amountBdt,
    feeBdt: feeBdt ?? this.feeBdt,
    fixedAmountBdt: identical(fixedAmountBdt, _unchanged)
        ? this.fixedAmountBdt
        : fixedAmountBdt as int?,
    operator: identical(operator, _unchanged)
        ? this.operator
        : operator as Operator?,
    postpaid: postpaid ?? this.postpaid,
    bill: identical(bill, _unchanged) ? this.bill : bill as Bill?,
    dpsTenureMonths: identical(dpsTenureMonths, _unchanged)
        ? this.dpsTenureMonths
        : dpsTenureMonths as int?,
    warningShown: identical(warningShown, _unchanged)
        ? this.warningShown
        : warningShown as String?,
    warningChoice: identical(warningChoice, _unchanged)
        ? this.warningChoice
        : warningChoice as String?,
  );

  static const _unchanged = Object();

  @override
  String toString() =>
      'PayIntent(${kind.slug}, $counterparty, $amountBdt + $feeBdt)';
}
