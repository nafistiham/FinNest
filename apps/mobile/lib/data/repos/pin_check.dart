import 'package:bhorosha/core/ids.dart';

/// Verifies a PIN against the bundled SHA-256.
/// The digits are hashed immediately and never logged or stored.
abstract final class PinCheck {
  static bool matches(String pin, String sha256Hex) =>
      constantTimeEquals(sha256Hex.toLowerCase(), hashPin(pin));

  /// Lowercase hex SHA-256 of [pin]; what `personas.json` stores.
  static String hashPin(String pin) => sha256Hex(pin);
}
