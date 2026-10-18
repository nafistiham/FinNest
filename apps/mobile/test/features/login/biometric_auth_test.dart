import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

void main() {
  test('class-3 or a named face/fingerprint is strong; weak alone is not', () {
    expect(
      classifyBiometrics([BiometricType.strong]),
      BiometricStrength.strong,
    );
    expect(
      classifyBiometrics([BiometricType.weak, BiometricType.strong]),
      BiometricStrength.strong,
    );
    expect(classifyBiometrics([BiometricType.face]), BiometricStrength.strong);
    expect(
      classifyBiometrics([BiometricType.fingerprint]),
      BiometricStrength.strong,
    );
    expect(
      classifyBiometrics([BiometricType.weak]),
      BiometricStrength.weakOnly,
    );
    expect(classifyBiometrics([]), BiometricStrength.notEnrolled);
  });

  test('lockouts are failures; other platform codes make it unavailable', () {
    expect(outcomeForError('LockedOut'), isA<BiometricFailed>());
    expect(outcomeForError('PermanentlyLockedOut'), isA<BiometricFailed>());
    for (final code in ['NotEnrolled', 'NotAvailable', 'PasscodeNotSet']) {
      final o = outcomeForError(code);
      expect(o, isA<BiometricUnavailable>());
      expect((o as BiometricUnavailable).reason, code);
    }
  });

  test(
    'off-device (no plugin) the strength is unsupported, not a crash',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(
        await LocalBiometricAuth().strength(),
        BiometricStrength.unsupported,
      );
    },
  );
}
