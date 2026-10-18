/// A scripted [BiometricAuth] for widget tests. Not a test file.
library;

import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;

/// Reports [strengthValue] and answers every prompt with [outcome]
/// (passed by default), counting the prompts.
class FakeBiometricAuth implements BiometricAuth {
  FakeBiometricAuth({
    this.strengthValue = BiometricStrength.strong,
    this.outcome = const BiometricPassed(),
  });

  BiometricStrength strengthValue;
  BiometricOutcome outcome;
  int authenticateCalls = 0;
  String? lastReason;

  @override
  Future<BiometricStrength> strength() => SynchronousFuture(strengthValue);

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    authenticateCalls++;
    lastReason = reason;
    return outcome;
  }
}
