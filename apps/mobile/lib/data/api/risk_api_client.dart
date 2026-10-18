/// dio-backed [RiskApi] against the live risk-api.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/auth_header_interceptor.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Per-route receive timeouts, the connect timeout and
/// the overall deadlines.
///
/// Every request runs under one overall deadline ([deadlineFor]); when it
/// passes, the dio request is cancelled through its `CancelToken` (a late
/// answer is dropped, not merely ignored) and a [TimeoutFailure] is thrown.
/// `/v1/risk/score` gets a hard [scoreDeadline] of 4 s, connect included:
/// it sits on the eleven-seconds path, and a slow score is "cannot verify
/// now", never an allow. The budget is
/// 2 s warm plus headroom for a cold Cloud Run instance, which the demo
/// hits after every idle stretch. Every other route keeps
/// `connect + receive`.
class RouteTimeouts {
  const RouteTimeouts({
    this.connect = const Duration(seconds: 3),
    this.score = const Duration(seconds: 4),
    this.scoreDeadline = const Duration(seconds: 4),
    this.signals = const Duration(seconds: 2),
    // A real phone lists 80-200 apps; the server runs Gemini triage over every hit,
    // measured 5-10 s on 2026-10-17. The badge shows "checking" meanwhile.
    this.appSafety = const Duration(seconds: 15),
    this.appSafetyDemoToken = const Duration(seconds: 4),
    this.appSafetyLatest = const Duration(seconds: 2),
    this.intervene = const Duration(seconds: 4),
    // Gemini classifies each turn live; a cold instance has answered in 6-7 s.
    this.scamTurn = const Duration(seconds: 12),
    this.apaTurn = const Duration(seconds: 8),
    this.trustedContact = const Duration(seconds: 4),
    this.health = const Duration(seconds: 2),
    // Case Zero: the start call queues a Gemini run; a cold instance is slow.
    this.investigate = const Duration(seconds: 10),
    this.investigateDeadline = const Duration(seconds: 10),
    this.apaClip = const Duration(seconds: 4),
    // The server answers once the first audio is in hand and streams the rest;
    // the whole line is buffered before it plays.
    this.apaWhyAudio = const Duration(seconds: 10),
  });

  final Duration connect;
  final Duration score;

  /// Overall budget of `/v1/risk/score`, connect and receive together.
  final Duration scoreDeadline;
  final Duration signals;
  final Duration appSafety;
  final Duration appSafetyDemoToken;
  final Duration appSafetyLatest;
  final Duration intervene;
  final Duration scamTurn;
  final Duration apaTurn;
  final Duration trustedContact;
  final Duration health;

  /// Receive timeout of `/v1/investigate` and `/v1/investigations/{id}`.
  final Duration investigate;

  /// Overall budget of the two Case Zero routes, connect included.
  final Duration investigateDeadline;

  /// Receive timeout of `GET /v1/apa/clips/{id}`.
  final Duration apaClip;

  /// Receive timeout of `POST /v1/apa/why-audio` (the whole WAV).
  final Duration apaWhyAudio;

  /// The overall deadline of [route] whose receive timeout is [receive].
  Duration deadlineFor(String route, Duration receive) => switch (route) {
    RiskRoutes.score => scoreDeadline,
    RiskRoutes.investigate ||
    RiskRoutes.investigationTemplate => investigateDeadline,
    _ => receive + connect,
  };
}

/// Talks JSON to the risk-api and converts every outcome into a contract
/// model or an [ApiFailure]. Thread-safe for concurrent calls.
class RiskApiClient implements RiskApi {
  RiskApiClient({
    required String baseUrl,
    required IdentityHeaders identity,
    Dio? dio,
    RouteTimeouts timeouts = const RouteTimeouts(),
  }) : _dio = dio ?? Dio(),
       _timeouts = timeouts {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = timeouts.connect
      ..contentType = Headers.jsonContentType
      ..responseType = ResponseType.plain
      ..headers[HttpHeaders.acceptHeader] = Headers.jsonContentType;
    _dio.interceptors.addAll([
      RedactingLogInterceptor(),
      AuthHeaderInterceptor(identity),
      TimingInterceptor((ms) => serverTiming.value = ms),
    ]);
  }

  final Dio _dio;
  final RouteTimeouts _timeouts;

  /// `X-Processing-Time-Ms` of the latest response; listen for the demo panel.
  final ValueNotifier<int?> serverTiming = ValueNotifier<int?>(null);

  @override
  int? get lastServerTimingMs => serverTiming.value;

  @override
  Future<SignalsResponse> postSignals(SignalsRequest r) => _post(
    RiskRoutes.signals,
    r.toJson(),
    _timeouts.signals,
    SignalsResponse.fromJson,
  );

  @override
  Future<ScoreResponse> postScore(ScoreRequest r) => _post(
    RiskRoutes.score,
    r.toJson(),
    _timeouts.score,
    ScoreResponse.fromJson,
  );

  @override
  Future<AppSafetyResponse> postAppSafety(AppSafetyRequest r) => _post(
    RiskRoutes.appSafety,
    r.toJson(),
    _timeouts.appSafety,
    AppSafetyResponse.fromJson,
  );

  @override
  Future<DemoIntegrityResponse> postAppSafetyDemoToken(
    DemoIntegrityRequest r,
  ) => _post(
    RiskRoutes.appSafetyDemoToken,
    r.toJson(),
    _timeouts.appSafetyDemoToken,
    DemoIntegrityResponse.fromJson,
  );

  @override
  Future<AppSafetyLatest> getAppSafetyLatest(String uid) => _get(
    RiskRoutes.latest(uid),
    _timeouts.appSafetyLatest,
    AppSafetyLatest.fromJson,
  );

  @override
  Future<InterveneResponse> postIntervene(InterveneRequest r) => _post(
    RiskRoutes.intervene,
    r.toJson(),
    _timeouts.intervene,
    InterveneResponse.fromJson,
  );

  @override
  Future<ScamTurnResponse> postScamTurn(ScamTurnRequest r) => _post(
    RiskRoutes.scamTurn,
    r.toJson(),
    _timeouts.scamTurn,
    ScamTurnResponse.fromJson,
  );

  @override
  Future<ApaTurnResponse> postApaTurn(ApaTurnRequest r) => _post(
    RiskRoutes.apaTurn,
    r.toJson(),
    _timeouts.apaTurn,
    ApaTurnResponse.fromJson,
  );

  @override
  Future<TrustedContactResponse> createTrustedContact(
    TrustedContactRequest r,
  ) => _post(
    RiskRoutes.trustedContact,
    r.toJson(),
    _timeouts.trustedContact,
    TrustedContactResponse.fromJson,
  );

  @override
  Future<TrustedContactDecision> approveTrustedContact(
    String requestId, {
    String? asUser,
  }) => _post(
    RiskRoutes.approve(requestId),
    null,
    _timeouts.trustedContact,
    TrustedContactDecision.fromJson,
    asUser: asUser,
  );

  @override
  Future<TrustedContactDecision> declineTrustedContact(
    String requestId, {
    String? asUser,
  }) => _post(
    RiskRoutes.decline(requestId),
    null,
    _timeouts.trustedContact,
    TrustedContactDecision.fromJson,
    asUser: asUser,
  );

  /// `POST /v1/investigate {"acct_id"}`: queues a Case Zero run.
  /// 502 → [InvestigatorUnavailable], 429 → [RateLimited]; 10 s deadline.
  @override
  Future<InvestigateResponse> postInvestigate(
    String acctId, {
    String? asUser,
  }) async {
    final json = await _send(
      RiskRoutes.investigate,
      (cancel) => _dio.post<String>(
        RiskRoutes.investigate,
        data: <String, dynamic>{'acct_id': acctId},
        cancelToken: cancel,
        options: Options(
          receiveTimeout: _timeouts.investigate,
          sendTimeout: _timeouts.investigate,
          extra: _actingAs(asUser),
        ),
      ),
      _timeouts.investigate,
      refine: _caseFailure,
    );
    return _parse(json, InvestigateResponse.fromJson);
  }

  /// `GET /v1/investigations/{caseId}`: the case report, partial while the
  /// run is queued or running. 404 → [CaseNotFound], 502 →
  /// [InvestigatorUnavailable], 429 → [RateLimited]; 10 s deadline.
  @override
  Future<CaseReport> getCase(String caseId, {String? asUser}) async {
    final path = RiskRoutes.investigation(caseId);
    final json = await _send(
      RiskRoutes.investigationTemplate,
      (cancel) => _dio.get<String>(
        path,
        cancelToken: cancel,
        options: Options(
          receiveTimeout: _timeouts.investigate,
          extra: _actingAs(asUser),
        ),
      ),
      _timeouts.investigate,
      refine: _caseFailure,
    );
    return _parse(json, CaseReport.fromJson);
  }

  static ApiFailure _caseFailure(ApiFailure failure) => switch (failure) {
    ServerFailure(status: 404, :final serverMessage) => CaseNotFound(
      serverMessage: serverMessage,
    ),
    ServerFailure(status: 502, :final serverMessage) => InvestigatorUnavailable(
      serverMessage: serverMessage,
    ),
    _ => failure,
  };

  @override
  Future<ApaAudioBytes> getApaClip(String clipId) async {
    final audio = await _sendBytes(
      (cancel) => _dio.get<List<int>>(
        RiskRoutes.apaClip(clipId),
        cancelToken: cancel,
        options: _bytesOptions(_timeouts.apaClip),
      ),
      _timeouts.apaClip + _timeouts.connect,
    );
    if (audio == null) throw const ServerFailure(204);
    return audio;
  }

  @override
  Future<ApaAudioBytes?> postApaWhyAudio(ApaWhyAudioRequest r) => _sendBytes(
    (cancel) => _dio.post<List<int>>(
      RiskRoutes.apaWhyAudio,
      data: r.toJson(),
      cancelToken: cancel,
      options: _bytesOptions(_timeouts.apaWhyAudio),
    ),
    _timeouts.apaWhyAudio + _timeouts.connect,
  );

  static Options _bytesOptions(Duration timeout) => Options(
    responseType: ResponseType.bytes,
    receiveTimeout: timeout,
    sendTimeout: timeout,
    headers: {HttpHeaders.acceptHeader: 'audio/*'},
  );

  /// Audio bytes under [deadline]; `null` on 204 or an empty body. Failures
  /// are mapped as for JSON routes (429 → [RateLimited] with `Retry-After`).
  Future<ApaAudioBytes?> _sendBytes(
    Future<Response<List<int>>> Function(CancelToken cancel) request,
    Duration deadline,
  ) async {
    final cancel = CancelToken();
    final Response<List<int>> response;
    try {
      response = await request(cancel).timeout(deadline);
    } on DioException catch (e) {
      throw mapDioException(e);
    } on TimeoutException {
      cancel.cancel('deadline exceeded');
      throw TimeoutFailure('deadline exceeded', deadline);
    }
    final data = response.data;
    if (response.statusCode == 204 || data == null || data.isEmpty) {
      return null;
    }
    final type = response.headers.value(Headers.contentTypeHeader);
    return ApaAudioBytes(
      data is Uint8List ? data : Uint8List.fromList(data),
      mimeType: (type == null || type.isEmpty) ? 'audio/wav' : type,
    );
  }

  @override
  Future<bool> health() async {
    try {
      final body = await _send(
        RiskRoutes.health,
        (cancel) => _dio.get<String>(
          RiskRoutes.health,
          cancelToken: cancel,
          options: Options(receiveTimeout: _timeouts.health),
        ),
        _timeouts.health,
      );
      return body['status'] == 'ok';
    } on Object {
      return false;
    }
  }

  Future<T> _get<T>(
    String path,
    Duration timeout,
    T Function(Map<String, dynamic> json) parse,
  ) async {
    final json = await _send(
      path,
      (cancel) => _dio.get<String>(
        path,
        cancelToken: cancel,
        options: Options(receiveTimeout: timeout),
      ),
      timeout,
    );
    return _parse(json, parse);
  }

  /// The per-call `X-Demo-User` override for [asUser] (none when null or
  /// empty); see [DemoIdentityHeaders.overrideKey].
  static Map<String, dynamic>? _actingAs(String? asUser) =>
      asUser == null || asUser.isEmpty
      ? null
      : <String, dynamic>{DemoIdentityHeaders.overrideKey: asUser};

  Future<T> _post<T>(
    String path,
    Map<String, dynamic>? body,
    Duration timeout,
    T Function(Map<String, dynamic> json) parse, {
    String? asUser,
  }) async {
    final json = await _send(
      path,
      (cancel) => _dio.post<String>(
        path,
        data: body,
        cancelToken: cancel,
        options: Options(
          receiveTimeout: timeout,
          sendTimeout: timeout,
          extra: _actingAs(asUser),
        ),
      ),
      timeout,
    );
    return _parse(json, parse);
  }

  T _parse<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic> json) parse,
  ) => parseContract(json, parse);

  /// Runs [request] under [route]'s overall deadline and returns the
  /// decoded JSON object, or throws the matching [ApiFailure] ([refine]
  /// may narrow it per route). On the deadline the request is cancelled, so
  /// it ends on the wire too.
  Future<Map<String, dynamic>> _send(
    String route,
    Future<Response<String>> Function(CancelToken cancel) request,
    Duration receive, {
    ApiFailure Function(ApiFailure failure)? refine,
  }) => sendWithDeadline(
    request,
    _timeouts.deadlineFor(route, receive),
    refine: refine,
  );
}

/// Runs [request] under [deadline] and decodes the JSON object it returns.
/// Every failure is an [ApiFailure] ([refine] may narrow it); past the
/// deadline the request is cancelled and a [TimeoutFailure] is thrown.
/// Shared by [RiskApiClient] and `CaseZeroClient`.
Future<Map<String, dynamic>> sendWithDeadline(
  Future<Response<String>> Function(CancelToken cancel) request,
  Duration deadline, {
  ApiFailure Function(ApiFailure failure)? refine,
}) async {
  final cancel = CancelToken();
  final Response<String> response;
  try {
    response = await request(cancel).timeout(deadline);
  } on DioException catch (e) {
    final failure = mapDioException(e);
    throw refine == null ? failure : refine(failure);
  } on TimeoutException {
    cancel.cancel('deadline exceeded');
    throw TimeoutFailure('deadline exceeded', deadline);
  }
  return decodeJsonObject(response.data);
}

/// Runs a contract `fromJson`; a mismatch is a [ContractFailure].
T parseContract<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic> json) parse,
) {
  try {
    return parse(json);
  } on FormatException catch (e) {
    throw ContractFailure('response does not match contract: ${e.message}');
  } on TypeError catch (e) {
    throw ContractFailure('response does not match contract: $e');
  }
}

/// Parses a JSON object body; anything else is a [ContractFailure].
Map<String, dynamic> decodeJsonObject(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    throw const ContractFailure('empty response body');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw ContractFailure('response is not JSON: ${e.message}');
  }
  if (decoded is Map<String, dynamic>) return decoded;
  throw ContractFailure(
    'response is not a JSON object (${decoded.runtimeType})',
  );
}

/// Converts every [DioException] into the right [ApiFailure].
ApiFailure mapDioException(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return TimeoutFailure(
        e.type.name,
        e.requestOptions.receiveTimeout ?? e.requestOptions.connectTimeout,
      );
    case DioExceptionType.badResponse:
      final response = e.response;
      final status = response?.statusCode ?? 0;
      final failure = ServerFailure.fromBody(
        status,
        _tryDecode(response?.data),
      );
      if (status == 429) {
        return RateLimited(
          retryAfterSeconds: parseRetryAfter(
            response?.headers.value('retry-after'),
          ),
          serverMessage: failure.serverMessage,
        );
      }
      return failure;
    case DioExceptionType.badCertificate:
    case DioExceptionType.connectionError:
    case DioExceptionType.cancel:
      return NetworkFailure(e.type.name);
    case DioExceptionType.unknown:
      final cause = e.error;
      if (cause is FormatException) {
        return ContractFailure('response is not JSON: ${cause.message}');
      }
      if (cause is ApiFailure) return cause;
      return NetworkFailure(
        cause == null
            ? (e.message ?? 'unknown error')
            : cause.runtimeType.toString(),
      );
  }
}

/// `Retry-After` in whole seconds; `null` when absent, negative or an
/// HTTP-date (the servers here send seconds).
int? parseRetryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : seconds;
}

Object? _tryDecode(Object? data) {
  if (data is! String) return data;
  try {
    return jsonDecode(data);
  } on FormatException {
    return null;
  }
}
