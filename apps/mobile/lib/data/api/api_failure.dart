/// Typed failures of the risk-api client.
///
/// Callers switch over the sealed hierarchy; nothing else crosses the API
/// boundary. Messages never contain tokens, headers or request bodies.
library;

/// Base of every failure the [RiskApi] surface can throw.
sealed class ApiFailure implements Exception {
  const ApiFailure(this.message);

  /// Short, log-safe description (no secrets, no bodies).
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The host could not be reached: DNS, refused connection, TLS error,
/// socket closed, request cancelled.
final class NetworkFailure extends ApiFailure {
  const NetworkFailure([super.message = 'network unreachable']);
}

/// Connect, send, receive or overall deadline exceeded.
final class TimeoutFailure extends ApiFailure {
  const TimeoutFailure([super.message = 'request timed out', this.timeout]);

  /// The deadline that was exceeded, when known.
  final Duration? timeout;

  @override
  String toString() => timeout == null
      ? super.toString()
      : 'TimeoutFailure: $message after ${timeout!.inMilliseconds} ms';
}

/// The server answered with a 4xx or 5xx status.
final class ServerFailure extends ApiFailure {
  const ServerFailure(this.status, {this.serverMessage})
    : super('server returned $status');

  /// Builds the failure from a decoded error [body].
  ///
  /// FastAPI shapes: `{"detail": "text"}` for hand-raised errors (404, 401)
  /// and `{"detail": [{"loc": [...], "msg": "...", ...}]}` for 422
  /// validation errors, where the first item's `msg` and `loc` are kept.
  factory ServerFailure.fromBody(int status, Object? body) =>
      ServerFailure(status, serverMessage: _detailOf(body));

  /// HTTP status code (400..599).
  final int status;

  /// What the server said, when the body carried a FastAPI `detail`.
  final String? serverMessage;

  bool get isClientError => status >= 400 && status < 500;
  bool get isServerError => status >= 500;

  @override
  String toString() => serverMessage == null
      ? 'ServerFailure($status)'
      : 'ServerFailure($status): $serverMessage';
}

/// `GET /v1/investigations/{case_id}` answered 404: the server does not know
/// the case (expired, or opened on another instance's store).
final class CaseNotFound extends ServerFailure {
  const CaseNotFound({super.serverMessage}) : super(404);
}

/// The Case Zero investigator behind risk-mw failed (risk-mw answers 502).
final class InvestigatorUnavailable extends ServerFailure {
  const InvestigatorUnavailable({super.serverMessage}) : super(502);
}

/// HTTP 429 on any route. [retryAfterSeconds] is the `Retry-After` header in
/// seconds, `null` when absent or not a number of seconds.
final class RateLimited extends ServerFailure {
  const RateLimited({this.retryAfterSeconds, super.serverMessage}) : super(429);

  final int? retryAfterSeconds;

  @override
  String toString() => retryAfterSeconds == null
      ? super.toString()
      : '${super.toString()} (retry after ${retryAfterSeconds}s)';
}

/// The body was not JSON, or JSON that does not match the frozen contract.
final class ContractFailure extends ApiFailure {
  const ContractFailure(super.message);
}

String? _detailOf(Object? body) {
  if (body is! Map) return null;
  final detail = body['detail'];
  return switch (detail) {
    final String s => s,
    final List<Object?> items when items.isNotEmpty => _validationItem(
      items.first,
    ),
    _ => null,
  };
}

String? _validationItem(Object? item) {
  if (item is! Map) return item?.toString();
  final msg = item['msg']?.toString();
  final loc = item['loc'];
  final where = loc is List ? loc.map((e) => '$e').join('.') : null;
  if (msg == null) return where;
  return where == null || where.isEmpty ? msg : '$msg ($where)';
}
