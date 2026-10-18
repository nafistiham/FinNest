/// Loan and savings store. Local only: there is no backend
/// route for either module; the state lives in SharedPreferences under
/// `finance/<uid>` and is seeded per persona the first time a uid is read.
library;

import 'dart:async';
import 'dart:convert';

import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/core/ids.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/finance/logic/finance_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class FinanceRepo {
  /// Emits the current state on subscribe, then every change.
  Stream<FinanceState> watch(String uid);

  /// Appends a plan with one instalment paid and debits that instalment from
  /// the ledger as a `dps_deposit` transaction.
  Future<DpsPlan> openDps(
    String uid, {
    required int monthlyBdt,
    required int tenureMonths,
  });

  /// Appends an application: `pending`, or `rejected` when the product's
  /// amount is above the user's limit.
  Future<LoanApplication> applyLoan(String uid, LoanProduct product);

  /// Drops everything stored for [uid] and restores the persona seed
  /// (persona switch).
  Future<void> reset(String uid);
}

/// The counterparty account every DPS instalment is paid into.
const dpsAccountId = 'acct_bhorosha_dps';

/// Ledger `type` of a DPS instalment.
const dpsDepositType = 'dps_deposit';

/// Seeds per persona.
abstract final class FinanceSeeds {
  static FinanceState forUid(String uid) => switch (Persona.tryParse(uid)) {
    Persona.rina => FinanceState(
      plans: [
        DpsPlan(
          id: 'dps_rina_01',
          monthlyBdt: 500,
          tenureMonths: 36,
          instalmentsPaid: 14,
          startedAt: DateTime.utc(2025, 8, 10),
        ),
      ],
      loanLimitBdt: 20000,
      monthlyIncomeBdt: 13500,
    ),
    Persona.rahima => FinanceState(
      plans: [
        DpsPlan(
          id: 'dps_rahima_01',
          monthlyBdt: 200,
          tenureMonths: 60,
          instalmentsPaid: 9,
          startedAt: DateTime.utc(2026, 1, 10),
        ),
      ],
      loanLimitBdt: 5000,
      monthlyIncomeBdt: 0,
    ),
    null => FinanceState.empty,
  };
}

/// Current value replayed to new listeners, writes broadcast, everything
/// mirrored to SharedPreferences so a restart keeps the plans and
/// applications. Same shape as `InMemoryDemoStateRepo`.
class LocalFinanceRepo implements FinanceRepo {
  LocalFinanceRepo({
    required this._ledger,
    Future<SharedPreferences>? prefs,
    this._clock = const SystemClock(),
  }) : _prefs = prefs ?? SharedPreferences.getInstance();

  static const _tag = 'finance';
  static String keyFor(String uid) => 'finance/$uid';

  final LedgerRepo _ledger;
  final Future<SharedPreferences> _prefs;
  final Clock _clock;
  final _current = <String, FinanceState>{};
  final _controllers = <String, StreamController<FinanceState>>{};

  StreamController<FinanceState> _controller(String uid) =>
      _controllers.putIfAbsent(uid, StreamController<FinanceState>.broadcast);

  @override
  Stream<FinanceState> watch(String uid) => Stream.multi((emitter) async {
    final sub = _controller(uid).stream.listen(emitter.add);
    emitter.onCancel = sub.cancel;
    final state = await _load(uid);
    if (!emitter.isClosed) emitter.add(state);
  });

  /// Stored state, else the persona seed; loads once per uid.
  Future<FinanceState> _load(String uid) async {
    final cached = _current[uid];
    if (cached != null) return cached;
    var loaded = FinanceSeeds.forUid(uid);
    try {
      final raw = (await _prefs).getString(keyFor(uid));
      if (raw != null) {
        loaded = FinanceState.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      }
    } on Object catch (e) {
      Log.w(_tag, 'ignoring unreadable stored state for $uid', e);
    }
    // A write may have landed while we were reading; it wins.
    return _current.putIfAbsent(uid, () => loaded);
  }

  Future<void> _write(String uid, FinanceState s) async {
    _current[uid] = s;
    _controller(uid).add(s);
    try {
      await (await _prefs).setString(keyFor(uid), jsonEncode(s.toJson()));
    } on Object catch (e) {
      Log.w(_tag, 'could not persist state for $uid', e);
    }
  }

  @override
  Future<DpsPlan> openDps(
    String uid, {
    required int monthlyBdt,
    required int tenureMonths,
  }) async {
    if (monthlyBdt <= 0 || tenureMonths <= 0) {
      throw ArgumentError('DPS needs a positive amount and tenure');
    }
    final before = await _load(uid);
    final now = _clock.now();
    final plan = DpsPlan(
      id: newId('dps'),
      monthlyBdt: monthlyBdt,
      tenureMonths: tenureMonths,
      instalmentsPaid: 1,
      startedAt: now,
    );
    // The first instalment leaves the account today; the ledger is the one
    // place the balance moves.
    await _ledger.create(
      uid,
      LedgerTxn(
        txnId: newId('txn'),
        ts: now,
        type: dpsDepositType,
        amountBdt: monthlyBdt.toDouble(),
        fromAcct: Persona.tryParse(uid)?.acctId ?? 'acct_$uid',
        toAcct: dpsAccountId,
        channel: 'app',
        status: LedgerStatus.done,
        counterpartyNameBn: 'ডিপিএস জমা',
      ),
    );
    await _write(uid, before.copyWith(plans: [plan, ...before.plans]));
    return plan;
  }

  @override
  Future<LoanApplication> applyLoan(String uid, LoanProduct product) async {
    final before = await _load(uid);
    final application = LoanApplication(
      id: newId('loan'),
      productId: product.id,
      amountBdt: product.amountBdt,
      status: before.canBorrow(product)
          ? LoanStatus.pending
          : LoanStatus.rejected,
      appliedAt: _clock.now(),
    );
    await _write(
      uid,
      before.copyWith(applications: [application, ...before.applications]),
    );
    return application;
  }

  @override
  Future<void> reset(String uid) async {
    try {
      await (await _prefs).remove(keyFor(uid));
    } on Object catch (e) {
      Log.w(_tag, 'could not clear stored state for $uid', e);
    }
    _current.remove(uid);
    _controller(uid).add(FinanceSeeds.forUid(uid));
  }

  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }
}
