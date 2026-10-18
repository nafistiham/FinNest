/// Trusted-contact request and decision flow.
///
/// The server keeps the request state and answers `approved|declined|expired`;
/// this class mirrors the outcome onto the local [InterventionRecord] and the
/// held ledger row. It never composes Bangla copy (FR-3): the screen renders
/// the record's server strings.
library;

import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Time source of the approve feature; override with a `FakeClock` in tests.
final approveClockProvider = Provider<Clock>((_) => const SystemClock());

final trustedContactFlowProvider = Provider<TrustedContactFlow>(
  (ref) => TrustedContactFlow(
    api: ref.watch(riskApiProvider),
    interventions: ref.watch(interventionRepoProvider),
    ledger: ref.watch(ledgerRepoProvider),
    clock: ref.watch(approveClockProvider),
  ),
);

class TrustedContactFlow {
  TrustedContactFlow({
    required RiskApi api,
    required InterventionRepo interventions,
    required LedgerRepo ledger,
    required Clock clock,
  }) : this._(api, interventions, ledger, clock);

  TrustedContactFlow._(
    this._api,
    this._interventions,
    this._ledger,
    this._clock,
  );

  static const _tag = 'trusted';

  /// Used when the server's `expires_at` cannot be parsed (never expected;
  /// the contract says ISO-8601). Matches the server default.
  static const fallbackExpiry = Duration(minutes: 10);

  final RiskApi _api;
  final InterventionRepo _interventions;
  final LedgerRepo _ledger;
  final Clock _clock;

  /// `POST /v1/actions/trusted-contact` naming the server's intervention id
  /// ([InterventionRecord.idForServer]: the id `/v1/intervene` or the hold
  /// returned, this phone's record id only when the server named none);
  /// stores `request_id`, `expires_at` and the contact on [record], sets it
  /// to [InterventionStatus.pending] and returns the stored record.
  Future<InterventionRecord> request({
    required InterventionRecord record,
    required String contactUid,
  }) async {
    final response = await _api.createTrustedContact(
      TrustedContactRequest(
        interventionId: record.idForServer,
        contactUid: contactUid,
      ),
    );
    var expiresAt = DateTime.tryParse(response.expiresAt);
    if (expiresAt == null) {
      Log.w(_tag, 'expires_at not ISO-8601, using the default expiry');
      expiresAt = _clock.now().add(fallbackExpiry);
    }
    final updated = record.copyWith(
      status: InterventionStatus.pending,
      requestId: response.requestId,
      expiresAt: expiresAt,
      contactUid: contactUid,
    );
    await _interventions.upsert(updated);
    Log.i(_tag, 'request created for intervention ${record.id}');
    return updated;
  }

  /// `POST .../{id}/approve` as [asUser] (`X-Demo-User`, this call only:
  /// the trusted contact's uid). On `approved` from the contact the record
  /// becomes approved and the held ledger row becomes [LedgerStatus.done];
  /// an answer with `contact_verified: false` (someone else decided, which
  /// demo mode allows) changes nothing here and the hold stays. Throws the
  /// `ApiFailure` of the call (404 → `ServerFailure(404)`).
  Future<TrustedContactDecision> approve(
    String requestId, {
    String? asUser,
  }) async {
    final decision = await _api.approveTrustedContact(
      requestId,
      asUser: asUser,
    );
    await _apply(decision);
    return decision;
  }

  /// `POST .../{id}/decline` as [asUser]; the ledger row stays `held`
  /// whatever the answer, the record mirrors the server status (not when
  /// `contact_verified` is false).
  Future<TrustedContactDecision> decline(
    String requestId, {
    String? asUser,
  }) async {
    final decision = await _api.declineTrustedContact(
      requestId,
      asUser: asUser,
    );
    await _apply(decision);
    return decision;
  }

  /// The uid the approve screen decides as: the contact named on the local
  /// [record] when there is one, else [fallback] (the seed's contact,
  /// `AppEnv.trustedContactDemoUser`).
  static String contactUidFor(InterventionRecord? record, String fallback) {
    final named = record?.contactUid;
    return named == null || named.isEmpty ? fallback : named;
  }

  /// The local record of a request, `null` when it was created elsewhere.
  Future<InterventionRecord?> findByRequestId(String requestId) =>
      _interventions.findByRequestId(requestId);

  /// Whether [record] has run past its expiry on this clock.
  bool isExpired(InterventionRecord record) {
    final at = record.expiresAt;
    return at != null && !_clock.now().isBefore(at);
  }

  Future<void> _apply(TrustedContactDecision decision) async {
    if (decision.notByContact) {
      // Demo mode lets anyone decide and says so (contact_verified false):
      // that is not the contact's approval, so the hold and the record stay
      // as they are.
      Log.w(
        _tag,
        'decision ${decision.status} not made by the trusted contact; '
        'the hold stays',
      );
      return;
    }
    final record = await _interventions.findByRequestId(decision.requestId);
    if (record == null) {
      Log.i(
        _tag,
        'decision ${decision.status} for a request not on this device',
      );
      return;
    }
    switch (decision.status) {
      case TrustedContactDecision.statusApproved:
        await _interventions.upsert(
          record.copyWith(status: InterventionStatus.approved),
        );
        await _ledger.setStatus(record.txnId, LedgerStatus.done);
      case TrustedContactDecision.statusDeclined:
        await _interventions.upsert(
          record.copyWith(status: InterventionStatus.declined),
        );
      case TrustedContactDecision.statusExpired:
        await _interventions.upsert(
          record.copyWith(status: InterventionStatus.expired),
        );
      default:
        // `pending` cannot follow a decision call; leave the record alone and
        // let the screen offer a retry.
        Log.w(_tag, 'unexpected status after decision: ${decision.status}');
    }
  }
}
