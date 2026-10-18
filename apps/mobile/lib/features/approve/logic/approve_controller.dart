/// State of one approve screen, keyed by request id.
library;

import 'dart:async';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the approve screen renders. [record] and [txn] are the local copies
/// when the request was created on this device; both are `null` otherwise.
@immutable
class ApproveState {
  const ApproveState({
    required this.requestId,
    this.loaded = false,
    this.record,
    this.txn,
    this.decision,
    this.busy = false,
    this.error,
    this.remaining,
    this.notYours = false,
  });

  final String requestId;

  /// `false` until the local lookup has answered (either way).
  final bool loaded;
  final InterventionRecord? record;

  /// The held ledger row of [record], when found by its `txnId`.
  final LedgerTxn? txn;

  /// The server's answer to approve/decline, once given.
  final TrustedContactDecision? decision;

  /// A decision call is in flight.
  final bool busy;

  /// Last call failed; the screen shows a retry.
  final String? error;

  /// Time until `expiresAt` on the feature clock; `null` without a record.
  final Duration? remaining;

  /// The request is on this device but addressed to someone else: the
  /// signed-in user is not the record's `contactUid` (the requester opening
  /// their own link, as a scammer on the call would ask). Read-only, no
  /// decision buttons.
  final bool notYours;

  /// [outcome] when the server's decision was not made by the trusted
  /// contact (`contact_verified: false`).
  static const notConfirmedOutcome = 'not_confirmed';

  /// The server answered, but not as the trusted contact: the screen says
  /// "not confirmed by your trusted person" and the hold stays.
  bool get notConfirmed => decision?.notByContact ?? false;

  /// The outcome to render: [notConfirmedOutcome] for a decision the
  /// contact did not make, else the server's decision, then the status
  /// already stored on the record, then the local countdown.
  String? get outcome {
    if (notConfirmed) return notConfirmedOutcome;
    final d = decision?.status;
    if (d != null && d != TrustedContactDecision.statusPending) return d;
    final s = record?.status;
    if (s == InterventionStatus.approved ||
        s == InterventionStatus.declined ||
        s == InterventionStatus.expired) {
      return s;
    }
    final r = remaining;
    if (r != null && r <= Duration.zero) {
      return TrustedContactDecision.statusExpired;
    }
    return null;
  }

  bool get approved => outcome == TrustedContactDecision.statusApproved;
  bool get declined => outcome == TrustedContactDecision.statusDeclined;
  bool get expired => outcome == TrustedContactDecision.statusExpired;

  /// Approve and decline are tappable.
  bool get canDecide => loaded && !busy && !notYours && outcome == null;

  ApproveState copyWith({
    bool? loaded,
    Object? record = _unset,
    Object? txn = _unset,
    Object? decision = _unset,
    bool? busy,
    Object? error = _unset,
    Object? remaining = _unset,
    bool? notYours,
  }) => ApproveState(
    requestId: requestId,
    loaded: loaded ?? this.loaded,
    record: identical(record, _unset)
        ? this.record
        : record as InterventionRecord?,
    txn: identical(txn, _unset) ? this.txn : txn as LedgerTxn?,
    decision: identical(decision, _unset)
        ? this.decision
        : decision as TrustedContactDecision?,
    busy: busy ?? this.busy,
    error: identical(error, _unset) ? this.error : error as String?,
    remaining: identical(remaining, _unset)
        ? this.remaining
        : remaining as Duration?,
    notYours: notYours ?? this.notYours,
  );

  static const Object _unset = Object();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApproveState &&
          requestId == other.requestId &&
          loaded == other.loaded &&
          record == other.record &&
          txn == other.txn &&
          decision == other.decision &&
          busy == other.busy &&
          error == other.error &&
          remaining == other.remaining &&
          notYours == other.notYours;

  @override
  int get hashCode => Object.hash(
    requestId,
    loaded,
    record,
    txn,
    decision,
    busy,
    error,
    remaining,
    notYours,
  );
}

/// The uid looking at the approve screen; `null` while signed out. The
/// router keeps signed-out users on login, so this is the signed-in user.
final approveViewerUidProvider = Provider<String?>(
  (ref) =>
      ref.watch(currentUserProvider).value?.uid ??
      ref.read(authRepoProvider).current?.uid,
);

/// The contact's uid the approve screen falls back to when no local record
/// names one; tests override it.
final approveContactFallbackProvider = Provider<String>(
  (_) => AppEnv.trustedContactDemoUser,
);

/// One controller per request id; disposed with the screen.
final approveControllerProvider = NotifierProvider.autoDispose
    .family<ApproveController, ApproveState, String>(ApproveController.new);

class ApproveController extends Notifier<ApproveState> {
  ApproveController(this.requestId);

  static const _tag = 'approve';

  /// How many recent rows to scan for the record's transaction.
  static const ledgerScan = 100;

  final String requestId;
  Timer? _ticker;
  _Action? _lastAction;

  @override
  ApproveState build() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    ref.onDispose(() {
      _ticker?.cancel();
      _ticker = null;
    });
    unawaited(_load());
    return ApproveState(requestId: requestId);
  }

  TrustedContactFlow get _flow => ref.read(trustedContactFlowProvider);

  Future<void> _load() async {
    final flow = _flow;
    InterventionRecord? record;
    LedgerTxn? txn;
    try {
      record = await flow.findByRequestId(requestId);
      if (record != null) txn = await _findTxn(record);
    } on Object catch (e, st) {
      Log.e(_tag, 'local lookup failed', e, st);
    }
    if (!ref.mounted) return;
    // A record found here was created on this phone. Only its trusted
    // contact may decide; anyone else (the requester above all) reads it.
    final viewer = ref.read(approveViewerUidProvider);
    final notYours = record != null && viewer != record.contactUid;
    if (notYours) {
      Log.w(_tag, 'request opened by someone other than its contact');
    }
    state = state.copyWith(
      loaded: true,
      record: record,
      txn: txn,
      remaining: _remainingOf(record),
      notYours: notYours,
    );
  }

  /// The record's ledger row from the first `watchRecent` snapshot.
  ///
  /// Takes the first event by hand instead of `Stream.first`: the local
  /// repos' `Stream.multi` cancel future resolves on the root zone, which
  /// never runs inside a widget test's fake-async zone.
  Future<LedgerTxn?> _findTxn(InterventionRecord record) {
    if (record.txnId.isEmpty) return Future.value(null);
    final completer = Completer<LedgerTxn?>();
    StreamSubscription<List<LedgerTxn>>? sub;
    void settle(LedgerTxn? hit) {
      if (!completer.isCompleted) completer.complete(hit);
      unawaited(sub?.cancel());
    }

    sub = ref
        .read(ledgerRepoProvider)
        .watchRecent(record.uid, limit: ledgerScan)
        .listen(
          (rows) {
            LedgerTxn? hit;
            for (final t in rows) {
              if (t.txnId == record.txnId) {
                hit = t;
                break;
              }
            }
            settle(hit);
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
            unawaited(sub?.cancel());
          },
          onDone: () => settle(null),
        );
    if (completer.isCompleted) unawaited(sub.cancel());
    return completer.future;
  }

  Duration? _remainingOf(InterventionRecord? record) {
    final at = record?.expiresAt;
    if (at == null) return null;
    final left = at.difference(ref.read(approveClockProvider).now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Recomputes the countdown from the clock. Called every second by the
  /// ticker; tests call it directly after advancing a `FakeClock`.
  @visibleForTesting
  void tick() {
    if (!ref.mounted) return;
    final next = _remainingOf(state.record);
    if (next == state.remaining) return;
    state = state.copyWith(remaining: next);
    if (next == Duration.zero) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> approve() => _decide(_Action.approve);

  Future<void> decline() => _decide(_Action.decline);

  /// Repeats the last approve or decline after a failure.
  Future<void> retry() async {
    final last = _lastAction;
    if (last != null) await _decide(last);
  }

  Future<void> _decide(_Action action) async {
    if (!state.canDecide) return;
    _lastAction = action;
    state = state.copyWith(busy: true, error: null);
    final flow = _flow;
    // Decided as the trusted contact (X-Demo-User for this call only), never
    // as the signed-in persona: the server's contact_verified then says
    // whether it really was the contact.
    final asUser = TrustedContactFlow.contactUidFor(
      state.record,
      ref.read(approveContactFallbackProvider),
    );
    try {
      final decision = switch (action) {
        _Action.approve => await flow.approve(requestId, asUser: asUser),
        _Action.decline => await flow.decline(requestId, asUser: asUser),
      };
      if (!ref.mounted) return;
      final record = state.record == null
          ? null
          : await flow.findByRequestId(requestId);
      if (!ref.mounted) return;
      state = state.copyWith(
        busy: false,
        decision: decision,
        record: record ?? state.record,
        error: decision.status == TrustedContactDecision.statusPending
            ? decision.status
            : null,
      );
      if (state.outcome != null) {
        _ticker?.cancel();
        _ticker = null;
      }
    } on ApiFailure catch (e) {
      Log.w(_tag, '${action.name} failed', e);
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: e.toString());
    } on Object catch (e, st) {
      // A local store write after the server answered: never leave the
      // buttons disabled; the retry repeats the call.
      Log.e(_tag, '${action.name} failed locally', e, st);
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: 'local');
    }
  }
}

enum _Action { approve, decline }
