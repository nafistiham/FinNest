/// Scripted [RiskApi] for tests, widget previews and the emulator without a
/// network: canned responses per route, a call log, failure injection and
/// completer-based gating so tests can assert ordering.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';

/// One recorded call: the route template from [RiskRoutes] and the request
/// body (`toJson()` of the request, the request id for approve/decline,
/// `null` for health).
typedef FakeCall = ({String route, Object? body});

class FakeRiskApi implements RiskApi {
  FakeRiskApi({
    this.delay = Duration.zero,
    ScoreResponse? scoreResponse,
    InterveneResponse? interveneResponse,
    AppSafetyResponse? appSafetyResponse,
    DemoIntegrityResponse? demoTokenResponse,
    AppSafetyLatest? latestResponse,
    ScamTurnResponse? scamTurnResponse,
    ApaTurnResponse? apaTurnResponse,
    TrustedContactResponse? trustedResponse,
    this.decision,
    this.healthy = true,
    this.lastServerTimingMs,
  }) : scoreResponse = scoreResponse ?? allowScore,
       interveneResponse = interveneResponse ?? genericCaution,
       appSafetyResponse = appSafetyResponse ?? safeDevice,
       demoTokenResponse = demoTokenResponse ?? fakeDemoToken,
       latestResponse = latestResponse ?? unknownLatest,
       scamTurnResponse = scamTurnResponse ?? noScam,
       apaTurnResponse = apaTurnResponse ?? apaEcho,
       trustedResponse = trustedResponse ?? pendingTrusted;

  // --- Defaults ------------------------------------------------------------

  static const allowScore = ScoreResponse(
    decision: Decision.allow,
    riskScore: 0.05,
    band: Band.low,
    reasons: [],
    actions: [],
    modelVersion: 'fake',
  );

  static const genericCaution = InterveneResponse(
    intervene: true,
    scriptBn: 'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন, আগে যাচাই করে নিন।',
    scriptEn: 'This is FinNest Assistant. Pause a moment and verify first.',
    audioAssetId: 'apa_generic_caution',
    ui: UiMode.banner,
    actions: [ActionItem(type: 'hold_transaction')],
    cooldownS: 60,
  );

  static const safeDevice = AppSafetyResponse(
    verdict: SafetyVerdict.safe,
    riskScore: 0.0,
    findings: [],
    recommendedAction: 'none',
    appsToUninstall: [],
    userMessageBn: 'আপনার ফোন নিরাপদ।',
    userMessageEn: 'Your phone is safe.',
    simulatedVerdict: false,
    modelVersion: 'fake',
  );

  static const fakeDemoToken = DemoIntegrityResponse(
    integrityToken: 'demo.fake',
    bundleHash: 'fakehash',
    expiresInS: 600,
  );

  /// `known == false`: no verdict stored for the uid yet.
  static const unknownLatest = AppSafetyLatest(uid: 'fake', known: false);

  static const noScam = ScamTurnResponse(
    scamType: 'none',
    urgency: 'low',
    requestedSecret: 'none',
    confidence: 0.0,
    evidenceQuote: '',
    recommendedAction: 'none',
    rollingScore: 0.0,
  );

  /// Mirrors the real `/v1/apa/turn` stub: the introduction and the standing
  /// rule, never a claim about the customer's transactions (FR-3: the fake
  /// knows no facts).
  static const apaEcho = ApaTurnResponse(
    replyBn: 'আমি ফিননেস্ট সহকারী বলছি। কেউ যদি ফোনে কোড বা পিন চায়, কখনো দেবেন না। বলুন, কী সাহায্য করতে পারি?',
    replyEn: 'This is FinNest Assistant. If anyone asks for a code or PIN on the phone, never give it. How can I help?',
    toolCalls: [],
  );

  static const pendingTrusted = TrustedContactResponse(
    requestId: 'fake-req-1',
    expiresAt: '2026-10-16T12:00:00+00:00',
  );

  // --- Script ----------------------------------------------------------------

  /// Applied to every call before it resolves (also before a failure).
  Duration delay;

  SignalsResponse signalsResponse = const SignalsResponse(stored: true);
  ScoreResponse scoreResponse;
  InterveneResponse interveneResponse;
  AppSafetyResponse appSafetyResponse;
  DemoIntegrityResponse demoTokenResponse;
  AppSafetyLatest latestResponse;
  ScamTurnResponse scamTurnResponse;
  ApaTurnResponse apaTurnResponse;
  TrustedContactResponse trustedResponse;

  /// Returned by approve and decline when set; otherwise the decision echoes
  /// the request id with status `approved` or `declined` respectively.
  TrustedContactDecision? decision;

  /// What [health] answers.
  bool healthy;

  /// Route template ([RiskRoutes]) → failure thrown instead of answering.
  final Map<String, ApiFailure> failures = {};

  /// Route template → failures thrown by the next calls, one per call, before
  /// [failures] and the canned answer (e.g. a 429 then a success).
  final Map<String, List<ApiFailure>> failNext = {};

  /// What `POST /v1/investigate` answers.
  InvestigateResponse investigateResponse = const InvestigateResponse(
    caseId: 'CZ-FAKE',
    streamUrl: '/v1/investigations/CZ-FAKE/events',
  );

  /// Case id → the report `GET /v1/investigations/{id}` answers; an unknown
  /// id is a `CaseNotFound`.
  final Map<String, CaseReport> cases = {};

  /// Clip id → what `GET /v1/apa/clips/{id}` answers; unknown ids are a
  /// `ServerFailure(404)`, as on a server without the route.
  final Map<String, ApaAudioBytes> clips = {};

  /// What `POST /v1/apa/why-audio` answers; `null` is the 204.
  ApaAudioBytes? whyAudio;

  /// A tiny valid WAV (44-byte header, 4 samples of silence) for tests.
  static final ApaAudioBytes silentWav = ApaAudioBytes(
    Uint8List.fromList([
      ...'RIFF'.codeUnits, 44, 0, 0, 0, ...'WAVE'.codeUnits, //
      ...'fmt '.codeUnits, 16, 0, 0, 0, 1, 0, 1, 0, 0xC0, 0x5D, 0, 0, //
      0x80, 0xBB, 0, 0, 2, 0, 16, 0, ...'data'.codeUnits, 8, 0, 0, 0, //
      0, 0, 0, 0, 0, 0, 0, 0,
    ]),
  );

  /// Every call in order, including failed and held ones.
  final List<FakeCall> calls = [];

  /// Every call's route with its per-call `X-Demo-User` override, in order
  /// (`asUser` null: the call spoke as the signed-in persona).
  final List<({String route, String? asUser})> actingAs = [];

  /// The override of the latest call to [route]; `null` when it had none
  /// (or there was no such call).
  String? actingAsFor(String route) => actingAs
      .lastWhere(
        (c) => c.route == route,
        orElse: () => (route: route, asUser: null),
      )
      .asUser;

  final Map<String, Completer<void>> _gates = {};

  @override
  int? lastServerTimingMs;

  /// Calls recorded for [route].
  Iterable<FakeCall> callsTo(String route) =>
      calls.where((c) => c.route == route);

  /// Clears the call log, failures and open gates; keeps the canned responses.
  void reset() {
    calls.clear();
    actingAs.clear();
    failures.clear();
    failNext.clear();
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }

  /// Holds the next call(s) to [route] until the returned function is
  /// invoked. Calling it twice is harmless.
  void Function() hold(String route) {
    final gate = _gates.putIfAbsent(route, Completer<void>.new);
    return () {
      if (!gate.isCompleted) gate.complete();
      _gates.remove(route);
    };
  }

  /// Holds pending `/v1/intervene` calls; the returned function releases them.
  void Function() holdIntervene() => hold(RiskRoutes.intervene);

  // --- RiskApi -------------------------------------------------------------

  @override
  Future<SignalsResponse> postSignals(SignalsRequest r) =>
      _answer(RiskRoutes.signals, r.toJson(), () => signalsResponse);

  @override
  Future<ScoreResponse> postScore(ScoreRequest r) =>
      _answer(RiskRoutes.score, r.toJson(), () => scoreResponse);

  @override
  Future<AppSafetyResponse> postAppSafety(AppSafetyRequest r) =>
      _answer(RiskRoutes.appSafety, r.toJson(), () => appSafetyResponse);

  @override
  Future<DemoIntegrityResponse> postAppSafetyDemoToken(
    DemoIntegrityRequest r,
  ) => _answer(
    RiskRoutes.appSafetyDemoToken,
    r.toJson(),
    () => demoTokenResponse,
  );

  @override
  Future<AppSafetyLatest> getAppSafetyLatest(String uid) =>
      _answer(RiskRoutes.appSafetyLatest, uid, () => latestResponse);

  @override
  Future<InterveneResponse> postIntervene(InterveneRequest r) =>
      _answer(RiskRoutes.intervene, r.toJson(), () => interveneResponse);

  @override
  Future<ScamTurnResponse> postScamTurn(ScamTurnRequest r) =>
      _answer(RiskRoutes.scamTurn, r.toJson(), () => scamTurnResponse);

  @override
  Future<ApaTurnResponse> postApaTurn(ApaTurnRequest r) =>
      _answer(RiskRoutes.apaTurn, r.toJson(), () => apaTurnResponse);

  @override
  Future<TrustedContactResponse> createTrustedContact(
    TrustedContactRequest r,
  ) => _answer(RiskRoutes.trustedContact, r.toJson(), () => trustedResponse);

  @override
  Future<TrustedContactDecision> approveTrustedContact(
    String requestId, {
    String? asUser,
  }) => _answer(
    RiskRoutes.trustedApprove,
    requestId,
    () =>
        decision ??
        TrustedContactDecision(
          requestId: requestId,
          status: TrustedContactDecision.statusApproved,
        ),
    asUser: asUser,
  );

  @override
  Future<TrustedContactDecision> declineTrustedContact(
    String requestId, {
    String? asUser,
  }) => _answer(
    RiskRoutes.trustedDecline,
    requestId,
    () =>
        decision ??
        TrustedContactDecision(
          requestId: requestId,
          status: TrustedContactDecision.statusDeclined,
        ),
    asUser: asUser,
  );

  @override
  Future<InvestigateResponse> postInvestigate(
    String acctId, {
    String? asUser,
  }) => _answer(
    RiskRoutes.investigate,
    {'acct_id': acctId},
    () => investigateResponse,
    asUser: asUser,
  );

  @override
  Future<CaseReport> getCase(String caseId, {String? asUser}) =>
      _answer(RiskRoutes.investigationTemplate, caseId, () {
        final report = cases[caseId];
        if (report == null) throw const CaseNotFound();
        return report;
      }, asUser: asUser);

  @override
  Future<ApaAudioBytes> getApaClip(String clipId) =>
      _answer(RiskRoutes.apaClipTemplate, clipId, () {
        final clip = clips[clipId];
        if (clip == null) throw const ServerFailure(404);
        return clip;
      });

  @override
  Future<ApaAudioBytes?> postApaWhyAudio(ApaWhyAudioRequest r) =>
      _answer(RiskRoutes.apaWhyAudio, r.toJson(), () => whyAudio);

  @override
  Future<bool> health() async {
    try {
      return await _answer(RiskRoutes.health, null, () => healthy);
    } on ApiFailure {
      return false;
    }
  }

  Future<T> _answer<T>(
    String route,
    Object? body,
    T Function() value, {
    String? asUser,
  }) async {
    calls.add((route: route, body: body));
    actingAs.add((route: route, asUser: asUser));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final gate = _gates[route];
    if (gate != null) await gate.future;
    final queued = failNext[route];
    if (queued != null && queued.isNotEmpty) throw queued.removeAt(0);
    final failure = failures[route];
    if (failure != null) throw failure;
    return value();
  }
}
