/// Biometric login: Login asks for the phone's
/// fingerprint or face instead of anything shareable like an OTP, and falls
/// back to a password when the phone has no strong biometric. A thin seam
/// over `local_auth` so widget tests drive every branch with a fake.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';

import '../../../core/log.dart';

const _tag = 'biometric';

/// What the phone can offer for a login.
enum BiometricStrength {
  /// A face or fingerprint is enrolled and the device has class-3
  /// (strong) biometrics.
  strong,

  /// Only class-2 (weak) biometrics, e.g. a camera-only face unlock.
  weakOnly,

  /// The device supports biometrics but nothing is enrolled.
  notEnrolled,

  /// No biometric hardware, or the plugin could not be reached.
  unsupported,
}

/// The result of one biometric prompt.
sealed class BiometricOutcome {
  const BiometricOutcome();
}

final class BiometricPassed extends BiometricOutcome {
  const BiometricPassed();
}

/// Wrong finger or face too many times, or the sensor is locked out.
final class BiometricFailed extends BiometricOutcome {
  const BiometricFailed();
}

/// The user dismissed the prompt.
final class BiometricCancelled extends BiometricOutcome {
  const BiometricCancelled();
}

/// Biometrics turned out not to be usable; [reason] is the platform code
/// (for the log, never for the screen).
final class BiometricUnavailable extends BiometricOutcome {
  const BiometricUnavailable(this.reason);

  final String reason;
}

abstract class BiometricAuth {
  Future<BiometricStrength> strength();

  Future<BiometricOutcome> authenticate({required String reason});
}

/// [BiometricStrength] for what `getAvailableBiometrics()` returned on a
/// device that reports itself supported. Android reports `strong` / `weak`
/// classes; iOS reports `face` / `fingerprint`, which are class 3 there.
@visibleForTesting
BiometricStrength classifyBiometrics(List<BiometricType> available) {
  if (available.contains(BiometricType.strong) ||
      available.contains(BiometricType.face) ||
      available.contains(BiometricType.fingerprint)) {
    return BiometricStrength.strong;
  }
  if (available.contains(BiometricType.weak)) {
    return BiometricStrength.weakOnly;
  }
  return BiometricStrength.notEnrolled;
}

/// [BiometricOutcome] for a `PlatformException` code from `authenticate`.
@visibleForTesting
BiometricOutcome outcomeForError(String code) => switch (code) {
  auth_error.lockedOut ||
  auth_error.permanentlyLockedOut => const BiometricFailed(),
  _ => BiometricUnavailable(code),
};

class LocalBiometricAuth implements BiometricAuth {
  LocalBiometricAuth([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// A platform call that never answers must not leave Login spinning: the
  /// password path shows instead.
  static const checkTimeout = Duration(seconds: 2);

  @override
  Future<BiometricStrength> strength() async {
    try {
      return await _check().timeout(checkTimeout);
    } on Object catch (e) {
      // PlatformException, MissingPluginException off-device, or the
      // timeout.
      Log.w(_tag, 'strength check failed', e);
      return BiometricStrength.unsupported;
    }
  }

  Future<BiometricStrength> _check() async {
    if (!await _auth.isDeviceSupported()) {
      return BiometricStrength.unsupported;
    }
    return classifyBiometrics(await _auth.getAvailableBiometrics());
  }

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      // `false`: the user dismissed the prompt (failed attempts stay inside
      // the system prompt until it locks out, which throws).
      return ok ? const BiometricPassed() : const BiometricCancelled();
    } on PlatformException catch (e) {
      Log.w(_tag, 'authenticate failed: ${e.code}', e);
      return outcomeForError(e.code);
    } on Object catch (e) {
      Log.w(_tag, 'authenticate failed', e);
      return BiometricUnavailable('$e');
    }
  }
}

/// The phone's biometric login; tests override it with a fake.
final biometricAuthProvider = Provider<BiometricAuth>(
  (_) => LocalBiometricAuth(),
);

/// The strength, read once per Login screen.
final biometricStrengthProvider = FutureProvider.autoDispose<BiometricStrength>(
  (ref) => ref.watch(biometricAuthProvider).strength(),
);
