/// Passkey ceremony. The `credential_manager`
/// implementation against `/v1/auth/passkey/{register,login}` is written
/// once the passkey routes are deployed; until then [NotDeployedPasskeyAuth] is
/// the only implementation and the Login screen shows the demo login.
abstract class PasskeyAuth {
  Future<PasskeyResult> login();
}

sealed class PasskeyResult {
  const PasskeyResult();
}

/// The server accepted the assertion and minted a Firebase custom token.
class PasskeySuccess extends PasskeyResult {
  const PasskeySuccess(this.customToken);
  final String customToken;
}

/// No ceremony could run; [reason] is for logs, not for the screen.
class PasskeyUnavailable extends PasskeyResult {
  const PasskeyUnavailable(this.reason);
  final String reason;
}

/// Always [PasskeyUnavailable]: the routes are not deployed.
class NotDeployedPasskeyAuth implements PasskeyAuth {
  const NotDeployedPasskeyAuth();

  static const reason = 'passkey routes not deployed';

  @override
  Future<PasskeyResult> login() async => const PasskeyUnavailable(reason);
}

/// Thrown by `AuthRepo.passkeyLogin` when the ceremony returns
/// [PasskeyUnavailable]; the UI falls back to the labelled demo login.
class PasskeyUnavailableException implements Exception {
  const PasskeyUnavailableException(this.reason);
  final String reason;

  @override
  String toString() => 'PasskeyUnavailableException($reason)';
}
