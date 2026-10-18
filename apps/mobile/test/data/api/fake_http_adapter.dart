/// Test double for dio's transport: no sockets, scripted [ResponseBody]s.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

typedef FakeFetch = Future<ResponseBody> Function(
  RequestOptions options,
  String? body,
);

class FakeHttpClientAdapter implements HttpClientAdapter {
  FakeHttpClientAdapter(this.handler);

  /// Answers one request; may throw a [DioException] or any other error.
  final FakeFetch handler;

  /// Every request seen, after the interceptors ran (headers included).
  final List<RequestOptions> requests = [];

  /// Request bodies as sent on the wire (`null` for body-less requests).
  final List<String?> bodies = [];

  RequestOptions get last => requests.last;

  Map<String, dynamic>? lastJson() {
    final raw = bodies.last;
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = requestStream == null
        ? null
        : await utf8.decodeStream(requestStream);
    requests.add(options);
    bodies.add(body);
    return handler(options, body);
  }

  @override
  void close({bool force = false}) {}
}

/// A JSON response with the given status and extra headers.
ResponseBody jsonBody(
  Object json, {
  int status = 200,
  Map<String, String> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(json),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    for (final e in headers.entries) e.key: [e.value],
  },
);

/// A non-JSON response (HTML error page, proxy banner, ...).
ResponseBody textBody(String text, {int status = 200}) =>
    ResponseBody.fromString(
      text,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );

/// Adapter that answers every request with a fresh [body] (a [ResponseBody]
/// carries a single-subscription stream, so it cannot be reused).
FakeHttpClientAdapter always(ResponseBody Function() body) =>
    FakeHttpClientAdapter((_, _) async => body());
