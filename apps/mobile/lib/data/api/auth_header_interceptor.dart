/// dio interceptors of the risk-api client: identity headers, server timing
/// and the redacting request log.
library;

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:dio/dio.dart';

/// Awaits [IdentityHeaders.headers] for every request and merges the result
/// into the request headers, then applies a per-call `X-Demo-User` override
/// ([DemoIdentityHeaders.overrideKey] in `extra`) when the call set one. A
/// failing provider rejects the request with a `DioExceptionType.unknown`
/// error (mapped to `NetworkFailure`).
class AuthHeaderInterceptor extends Interceptor {
  AuthHeaderInterceptor(this._identity);

  final IdentityHeaders _identity;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      options.headers.addAll(await _identity.headers());
      final override = options.extra[DemoIdentityHeaders.overrideKey];
      if (override is String && override.isNotEmpty) {
        options.headers[DemoIdentityHeaders.headerName] = override;
      }
    } on Object catch (e, st) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          stackTrace: st,
          message: 'identity headers unavailable',
        ),
      );
      return;
    }
    handler.next(options);
  }
}

/// Reads `X-Processing-Time-Ms` (a decimal such as `1.1` on the live
/// service) from every response, including error responses, and reports it
/// rounded to whole milliseconds.
class TimingInterceptor extends Interceptor {
  TimingInterceptor(this._onTiming);

  static const headerName = 'X-Processing-Time-Ms';

  final void Function(int ms) _onTiming;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _record(response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.response);
    handler.next(err);
  }

  void _record(Response<dynamic>? response) {
    final ms = parseTiming(response?.headers.value(headerName));
    if (ms != null) _onTiming(ms);
  }

  /// `"1.1"` → 1, `"12"` → 12, garbage → null.
  static int? parseTiming(String? raw) {
    if (raw == null) return null;
    final value = double.tryParse(raw.trim());
    if (value == null || value.isNaN || value.isInfinite || value < 0) {
      return null;
    }
    return value.round();
  }
}

/// Logs `METHOD path → status in <ms> ms` through [Log.d]. Never headers,
/// never bodies, never the query string.
class RedactingLogInterceptor extends Interceptor {
  RedactingLogInterceptor({this.tag = 'api'});

  static const _startedKey = 'bhorosha.api.started';

  final String tag;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedKey] = Stopwatch()..start();
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _log(response.requestOptions, '${response.statusCode}');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    _log(err.requestOptions, status == null ? err.type.name : '$status');
    handler.next(err);
  }

  void _log(RequestOptions options, String outcome) {
    final started = options.extra[_startedKey];
    final elapsed = started is Stopwatch ? started.elapsedMilliseconds : null;
    final path = options.uri.path;
    final timing = elapsed == null ? '' : ' in $elapsed ms';
    Log.d(tag, '${options.method} $path → $outcome$timing');
  }
}
