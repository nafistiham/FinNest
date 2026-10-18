/// Front-end-only models of the loan and savings (DPS) modules.
///
/// Everything here is demo data: the rate and the fees are fixed and labelled
/// "ডেমো" on screen. No backend route is involved. JSON keys are snake_case
/// like the rest of the app's stored documents.
library;

import 'package:bhorosha/data/contracts/contracts.dart';

/// A Deposit Pension Scheme: a fixed monthly deposit for a fixed tenure.
class DpsPlan {
  const DpsPlan({
    required this.id,
    required this.monthlyBdt,
    required this.tenureMonths,
    required this.instalmentsPaid,
    required this.startedAt,
    this.demoRatePct = defaultDemoRatePct,
  });

  factory DpsPlan.fromJson(Map<String, dynamic> json) => DpsPlan(
    id: requireString(json, 'id'),
    monthlyBdt: requireInt(json, 'monthly_bdt'),
    tenureMonths: requireInt(json, 'tenure_months'),
    instalmentsPaid: readInt(json, 'instalments_paid', 0),
    startedAt: DateTime.parse(requireString(json, 'started_at')),
    demoRatePct: readDouble(json, 'demo_rate_pct', defaultDemoRatePct),
  );

  /// The one rate every demo plan uses (per annum, simple interest).
  static const defaultDemoRatePct = 6.5;

  final String id;
  final int monthlyBdt;
  final int tenureMonths;
  final int instalmentsPaid;
  final DateTime startedAt;
  final double demoRatePct;

  /// Deposited so far.
  int get paidBdt => monthlyBdt * instalmentsPaid;

  /// Everything deposited over the whole tenure.
  int get principalBdt => monthlyBdt * tenureMonths;

  /// Principal plus simple interest at [demoRatePct] p.a. over the tenure.
  int get maturityBdt =>
      (principalBdt * (1 + demoRatePct / 100 * tenureMonths / 12)).round();

  /// Instalments paid over the tenure, 0..1.
  double get progress =>
      tenureMonths <= 0 ? 0 : (instalmentsPaid / tenureMonths).clamp(0.0, 1.0);

  bool get matured => instalmentsPaid >= tenureMonths;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'monthly_bdt': monthlyBdt,
    'tenure_months': tenureMonths,
    'instalments_paid': instalmentsPaid,
    'started_at': startedAt.toIso8601String(),
    'demo_rate_pct': demoRatePct,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpsPlan &&
          id == other.id &&
          monthlyBdt == other.monthlyBdt &&
          tenureMonths == other.tenureMonths &&
          instalmentsPaid == other.instalmentsPaid &&
          startedAt == other.startedAt &&
          demoRatePct == other.demoRatePct;

  @override
  int get hashCode => Object.hash(
    id,
    monthlyBdt,
    tenureMonths,
    instalmentsPaid,
    startedAt,
    demoRatePct,
  );

  @override
  String toString() =>
      'DpsPlan($id ৳$monthlyBdt x $tenureMonths, $instalmentsPaid paid)';
}

/// A fixed loan offer with a flat demo fee.
class LoanProduct {
  const LoanProduct({
    required this.id,
    required this.nameBn,
    required this.nameEn,
    required this.amountBdt,
    required this.tenureMonths,
    required this.flatFeePct,
  });

  final String id;
  final String nameBn;
  final String nameEn;
  final int amountBdt;
  final int tenureMonths;
  final double flatFeePct;

  /// The flat fee in taka, rounded.
  int get feeBdt => (amountBdt * flatFeePct / 100).round();

  int get totalRepayableBdt => amountBdt + feeBdt;

  /// Equal instalments; rounded up so the last one never exceeds the others.
  int get monthlyBdt => tenureMonths <= 0
      ? totalRepayableBdt
      : (totalRepayableBdt / tenureMonths).ceil();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LoanProduct && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LoanProduct($id ৳$amountBdt / $tenureMonths)';
}

/// The two bundled offers.
abstract final class LoanProducts {
  static const emergency = LoanProduct(
    id: 'loan_emergency',
    nameBn: 'জরুরি ঋণ',
    nameEn: 'Emergency loan',
    amountBdt: 5000,
    tenureMonths: 3,
    flatFeePct: 3,
  );

  static const business = LoanProduct(
    id: 'loan_business',
    nameBn: 'ব্যবসা ঋণ',
    nameEn: 'Business loan',
    amountBdt: 20000,
    tenureMonths: 12,
    flatFeePct: 8,
  );

  static const all = <LoanProduct>[emergency, business];

  static LoanProduct? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Status values of a [LoanApplication].
abstract final class LoanStatus {
  static const pending = 'pending';
  static const approved = 'approved';
  static const rejected = 'rejected';

  static const all = <String>{pending, approved, rejected};
}

class LoanApplication {
  const LoanApplication({
    required this.id,
    required this.productId,
    required this.amountBdt,
    required this.status,
    required this.appliedAt,
  });

  factory LoanApplication.fromJson(Map<String, dynamic> json) =>
      LoanApplication(
        id: requireString(json, 'id'),
        productId: requireString(json, 'product_id'),
        amountBdt: requireInt(json, 'amount_bdt'),
        status: readString(json, 'status', LoanStatus.pending),
        appliedAt: DateTime.parse(requireString(json, 'applied_at')),
      );

  final String id;
  final String productId;
  final int amountBdt;

  /// One of [LoanStatus].
  final String status;
  final DateTime appliedAt;

  LoanProduct? get product => LoanProducts.byId(productId);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'product_id': productId,
    'amount_bdt': amountBdt,
    'status': status,
    'applied_at': appliedAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoanApplication &&
          id == other.id &&
          productId == other.productId &&
          amountBdt == other.amountBdt &&
          status == other.status &&
          appliedAt == other.appliedAt;

  @override
  int get hashCode => Object.hash(id, productId, amountBdt, status, appliedAt);

  @override
  String toString() => 'LoanApplication($id $productId $status)';
}

/// Everything the two screens show for one user.
class FinanceState {
  const FinanceState({
    this.plans = const [],
    this.applications = const [],
    this.loanLimitBdt = 0,
    this.monthlyIncomeBdt = 0,
  });

  factory FinanceState.fromJson(Map<String, dynamic> json) => FinanceState(
    plans: readList(json, 'plans', objectItem(DpsPlan.fromJson)),
    applications: readList(
      json,
      'applications',
      objectItem(LoanApplication.fromJson),
    ),
    loanLimitBdt: readInt(json, 'loan_limit_bdt', 0),
    monthlyIncomeBdt: readInt(json, 'monthly_income_bdt', 0),
  );

  /// Signed out, or a uid with nothing seeded.
  static const empty = FinanceState();

  /// Newest first.
  final List<DpsPlan> plans;

  /// Newest first.
  final List<LoanApplication> applications;
  final int loanLimitBdt;
  final int monthlyIncomeBdt;

  bool canBorrow(LoanProduct p) => p.amountBdt <= loanLimitBdt;

  FinanceState copyWith({
    List<DpsPlan>? plans,
    List<LoanApplication>? applications,
    int? loanLimitBdt,
    int? monthlyIncomeBdt,
  }) => FinanceState(
    plans: plans ?? this.plans,
    applications: applications ?? this.applications,
    loanLimitBdt: loanLimitBdt ?? this.loanLimitBdt,
    monthlyIncomeBdt: monthlyIncomeBdt ?? this.monthlyIncomeBdt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'plans': [for (final p in plans) p.toJson()],
    'applications': [for (final a in applications) a.toJson()],
    'loan_limit_bdt': loanLimitBdt,
    'monthly_income_bdt': monthlyIncomeBdt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FinanceState &&
          _listEq(plans, other.plans) &&
          _listEq(applications, other.applications) &&
          loanLimitBdt == other.loanLimitBdt &&
          monthlyIncomeBdt == other.monthlyIncomeBdt;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(plans),
    Object.hashAll(applications),
    loanLimitBdt,
    monthlyIncomeBdt,
  );

  @override
  String toString() =>
      'FinanceState(${plans.length} plans, ${applications.length} applications, limit $loanLimitBdt)';
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
