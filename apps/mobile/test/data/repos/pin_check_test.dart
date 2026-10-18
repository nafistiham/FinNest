import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rinaHash =
      '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4';

  test('1234 matches its SHA-256', () {
    expect(PinCheck.matches('1234', rinaHash), isTrue);
    expect(PinCheck.matches('1234', rinaHash.toUpperCase()), isTrue);
    expect(PinCheck.hashPin('1234'), rinaHash);
  });

  test('1235 and an empty PIN do not match', () {
    expect(PinCheck.matches('1235', rinaHash), isFalse);
    expect(PinCheck.matches('', rinaHash), isFalse);
    expect(PinCheck.matches('1234', ''), isFalse);
  });
}
