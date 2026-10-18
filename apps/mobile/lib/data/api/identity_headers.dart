/// Who the caller is, as the risk-api wants to hear it (app/auth.py).
///
/// Demo mode (`RISK_API_AUTH_REQUIRED=false`, the deployment today) trusts
/// `X-Demo-User: <uid>`; otherwise the service requires
/// `Authorization: Bearer <Firebase ID token>`.
library;

/// Supplies the identity headers for one request. Awaited per request so a
/// token refresh can happen underneath.
abstract class IdentityHeaders {
  Future<Map<String, String>> headers();
}

/// Demo-mode identity: `X-Demo-User: <uid>`.
class DemoIdentityHeaders implements IdentityHeaders {
  const DemoIdentityHeaders(this.uid);

  static const headerName = 'X-Demo-User';

  /// `RequestOptions.extra` key of a per-call `X-Demo-User` override: the
  /// approve screen speaks as the trusted contact and the Fraud desk as
  /// staff, while every other call keeps the signed-in persona. Applied by
  /// `AuthHeaderInterceptor` after the identity headers, so it wins over
  /// them for that one request and never changes the client's identity.
  /// The `Authorization` bearer (when there is one) is left as it is: a
  /// server with auth on ignores `X-Demo-User`.
  static const overrideKey = 'bhorosha.demo_user_override';

  final String uid;

  @override
  Future<Map<String, String>> headers() async => {headerName: uid};
}

/// Firebase identity: `Authorization: Bearer <token>`.
///
/// When [fallbackDemoUid] is set, `X-Demo-User: <uid>` is always sent
/// alongside the bearer: the deployed risk-api runs with
/// `RISK_API_AUTH_REQUIRED=false` and keys its stored app-safety verdicts on
/// that header, while a server that requires auth ignores it. Without a token
/// the demo header alone is sent; without token or fallback no identity
/// header is sent and the server answers 401.
class BearerIdentityHeaders implements IdentityHeaders {
  const BearerIdentityHeaders(this._tokenProvider, {this.fallbackDemoUid});

  static const headerName = 'Authorization';

  final Future<String?> Function() _tokenProvider;

  /// Demo uid sent as `X-Demo-User` on every request.
  final String? fallbackDemoUid;

  @override
  Future<Map<String, String>> headers() async {
    final token = await _tokenProvider();
    final uid = fallbackDemoUid;
    return {
      if (token != null && token.isNotEmpty) headerName: 'Bearer $token',
      DemoIdentityHeaders.headerName: ?uid,
    };
  }
}
