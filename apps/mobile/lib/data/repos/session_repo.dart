import 'package:bhorosha/core/ids.dart';

/// Per-login session id sent as `session_id` to the risk-api. Rotated on
/// sign-in and persona switch so no cross-persona state leaks (Review
/// Focus 5).
abstract class SessionRepo {
  String get sessionId;

  /// Starts a fresh session and returns its id.
  String rotate();
}

class InMemorySessionRepo implements SessionRepo {
  InMemorySessionRepo({String Function()? idFactory})
    : _idFactory = idFactory ?? (() => newId('sess')),
      _sessionId = (idFactory ?? (() => newId('sess')))();

  final String Function() _idFactory;
  String _sessionId;

  @override
  String get sessionId => _sessionId;

  @override
  String rotate() => _sessionId = _idFactory();
}
