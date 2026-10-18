import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/firebase/firebase_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // No TestWidgetsFlutterBinding on purpose: a Firebase call would throw
  // because no platform channel exists, so this also proves nothing is touched.
  test('without the FIREBASE_* defines the app runs unconfigured', () {
    // `flutter test` passes no defines, so the options are absent.
    expect(BhoroshaFirebaseOptions.isConfigured, isFalse);
    expect(BhoroshaFirebaseOptions.current, isNull);
  });

  test('tryInit() falls back to local demo mode without options', () async {
    expect(await FirebaseBootstrap.tryInit(), FirebaseStatus.absent);
  });

  test(
    'tryInit() returns absent without calling Firebase when told to',
    () async {
      expect(
        await FirebaseBootstrap.tryInit(useBundledOptions: false),
        FirebaseStatus.absent,
      );
      expect(
        await FirebaseBootstrap.tryInit(
          options: null,
          useBundledOptions: false,
        ),
        FirebaseStatus.absent,
      );
    },
  );
}
