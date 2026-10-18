/// Riverpod wiring of the loan and savings modules.
///
/// [financeStateProvider] follows the signed-in uid so a persona switch swaps
/// the stream; [FinanceController] runs the two writes and
/// exposes busy/error for the buttons.
library;

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/features/finance/logic/finance_models.dart';
import 'package:bhorosha/features/finance/logic/finance_repo.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final financeRepoProvider = Provider<FinanceRepo>((ref) {
  final repo = LocalFinanceRepo(ledger: ref.watch(ledgerRepoProvider));
  ref.onDispose(repo.dispose);
  return repo;
});

/// Plans, applications and limits of the signed-in user;
/// [FinanceState.empty] while signed out.
final financeStateProvider = StreamProvider<FinanceState>((ref) {
  final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
  if (uid == null) return Stream.value(FinanceState.empty);
  return ref.watch(financeRepoProvider).watch(uid);
});

/// What the buttons need: whether a write is in flight and whether the last
/// one failed.
class FinanceActionState {
  const FinanceActionState({this.busy = false, this.error});

  static const idle = FinanceActionState();

  final bool busy;

  /// The last failure, cleared by the next action.
  final Object? error;

  bool get failed => error != null;
}

class FinanceController extends Notifier<FinanceActionState> {
  static const _tag = 'finance';

  @override
  FinanceActionState build() => FinanceActionState.idle;

  /// Opens a plan for the signed-in user; `null` when signed out or when the
  /// write failed (then [FinanceActionState.error] is set).
  Future<DpsPlan?> openDps({
    required int monthlyBdt,
    required int tenureMonths,
  }) => _run(
    (uid) => ref
        .read(financeRepoProvider)
        .openDps(uid, monthlyBdt: monthlyBdt, tenureMonths: tenureMonths),
  );

  /// Files an application for the signed-in user; `null` on failure.
  Future<LoanApplication?> applyLoan(LoanProduct product) =>
      _run((uid) => ref.read(financeRepoProvider).applyLoan(uid, product));

  Future<T?> _run<T>(Future<T> Function(String uid) action) async {
    if (state.busy) return null;
    final uid = ref.read(currentUserProvider).value?.uid;
    if (uid == null) {
      state = FinanceActionState(error: StateError('signed out'));
      return null;
    }
    state = const FinanceActionState(busy: true);
    try {
      final result = await action(uid);
      if (ref.mounted) state = FinanceActionState.idle;
      return result;
    } on Object catch (e, st) {
      Log.e(_tag, 'action failed', e, st);
      if (ref.mounted) state = FinanceActionState(error: e);
      return null;
    }
  }
}

final financeControllerProvider =
    NotifierProvider<FinanceController, FinanceActionState>(
      FinanceController.new,
    );
