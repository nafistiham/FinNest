/// The risk-api surface the app talks to (binding).
library;

import 'package:bhorosha/data/contracts/contracts.dart';

/// Routes of `services/risk-mw` (README "Routes"). Templates with
/// `{id}` are filled by [RiskRoutes.approve] / [RiskRoutes.decline].
abstract final class RiskRoutes {
  static const health = '/health';
  static const signals = '/v1/risk/signals';
  static const score = '/v1/risk/score';
  static const appSafety = '/v1/appsafety/check';
  static const appSafetyDemoToken = '/v1/appsafety/demo-token';
  static const appSafetyLatest = '/v1/appsafety/latest/{uid}';
  static const intervene = '/v1/intervene';
  static const scamTurn = '/v1/scam/turn';
  static const apaTurn = '/v1/apa/turn';
  static const trustedContact = '/v1/actions/trusted-contact';
  static const trustedApprove = '$trustedContact/{id}/approve';
  static const trustedDecline = '$trustedContact/{id}/decline';

  /// Case Zero through risk-mw: start a case, read its report.
  static const investigate = '/v1/investigate';
  static const investigationTemplate = '/v1/investigations/{case_id}';

  /// FNA's server audio (not on main yet: either may answer 404).
  static const apaClipTemplate = '/v1/apa/clips/{clip_id}';
  static const apaWhyAudio = '/v1/apa/why-audio';

  static String latest(String uid) =>
      '/v1/appsafety/latest/${Uri.encodeComponent(uid)}';
  static String approve(String requestId) =>
      '$trustedContact/${Uri.encodeComponent(requestId)}/approve';
  static String decline(String requestId) =>
      '$trustedContact/${Uri.encodeComponent(requestId)}/decline';
  static String investigation(String caseId) =>
      '/v1/investigations/${Uri.encodeComponent(caseId)}';
  static String apaClip(String clipId) =>
      '/v1/apa/clips/${Uri.encodeComponent(clipId)}';
}

/// Every call either returns the parsed response or throws an `ApiFailure`
/// (never a raw `DioException`), except [health], which never throws.
abstract class RiskApi {
  Future<SignalsResponse> postSignals(SignalsRequest r);

  /// Timeout 2 s: a slow answer here is "cannot verify now", not an allow.
  Future<ScoreResponse> postScore(ScoreRequest r);

  /// Timeout 4 s.
  Future<AppSafetyResponse> postAppSafety(AppSafetyRequest r);

  /// Timeout 4 s. Demo mode only: outside demo mode the server answers 404
  /// (`ServerFailure(404)`).
  Future<DemoIntegrityResponse> postAppSafetyDemoToken(DemoIntegrityRequest r);

  /// Timeout 2 s. The route may not be deployed yet: 404 surfaces as
  /// `ServerFailure(404)`.
  Future<AppSafetyLatest> getAppSafetyLatest(String uid);

  /// Timeout 4 s.
  Future<InterveneResponse> postIntervene(InterveneRequest r);

  /// Timeout 6 s.
  Future<ScamTurnResponse> postScamTurn(ScamTurnRequest r);

  /// Timeout 8 s.
  Future<ApaTurnResponse> postApaTurn(ApaTurnRequest r);

  Future<TrustedContactResponse> createTrustedContact(TrustedContactRequest r);

  /// 404 (`ServerFailure(404)`) for an unknown request id. [asUser], when
  /// set, is sent as `X-Demo-User` for this call only (the trusted
  /// contact's uid).
  Future<TrustedContactDecision> approveTrustedContact(
    String requestId, {
    String? asUser,
  });

  /// 404 (`ServerFailure(404)`) for an unknown request id; [asUser] as for
  /// [approveTrustedContact].
  Future<TrustedContactDecision> declineTrustedContact(
    String requestId, {
    String? asUser,
  });

  /// `POST /v1/investigate {"acct_id"}`: queues a Case Zero run.
  /// 502 → `InvestigatorUnavailable`, 429 → `RateLimited`; 10 s deadline.
  /// [asUser]: the `X-Demo-User` of this call (the Fraud desk's staff uid).
  Future<InvestigateResponse> postInvestigate(String acctId, {String? asUser});

  /// `GET /v1/investigations/{caseId}`: the report, partial while queued or
  /// running. 404 → `CaseNotFound`, 502 → `InvestigatorUnavailable`, 429 →
  /// `RateLimited`; 10 s deadline. [asUser] as for [postInvestigate].
  Future<CaseReport> getCase(String caseId, {String? asUser});

  /// `GET /v1/apa/clips/{clipId}`: a pre-rendered line's audio (OGG Opus or
  /// WAV). 404 (`ServerFailure(404)`) for an unknown or expired clip, or while
  /// the route is not deployed; 4 s receive timeout.
  Future<ApaAudioBytes> getApaClip(String clipId);

  /// `POST /v1/apa/why-audio`: one signed line as WAV (24 kHz mono 16-bit),
  /// buffered whole. `null` on 204 (the server has no live audio); 429 is
  /// `RateLimited` with its `Retry-After`; 10 s receive timeout.
  Future<ApaAudioBytes?> postApaWhyAudio(ApaWhyAudioRequest r);

  /// `true` only on HTTP 200 with `status == "ok"`; `false` on any failure.
  Future<bool> health();

  /// `X-Processing-Time-Ms` of the most recent response (demo panel).
  int? get lastServerTimingMs;
}
