import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeClock clock;
  late Cooldown cooldown;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 10, 16, 12));
    cooldown = Cooldown(clock);
  });

  test('speaks the first time a trigger is seen', () {
    expect(cooldown.shouldSpeak('call_active'), isTrue);
    expect(cooldown.until('call_active'), isNull);
  });

  test('does not speak again inside the window', () {
    cooldown.arm('call_active', 300);
    expect(cooldown.shouldSpeak('call_active'), isFalse);
    clock.advance(const Duration(seconds: 299));
    expect(cooldown.shouldSpeak('call_active'), isFalse);
  });

  test('speaks again once the window has passed', () {
    cooldown.arm('call_active', 300);
    clock.advance(const Duration(seconds: 300));
    expect(cooldown.shouldSpeak('call_active'), isTrue);
  });

  test('windows are per trigger', () {
    cooldown.arm('call_active', 300);
    expect(cooldown.shouldSpeak('sim_swap'), isTrue);
    expect(cooldown.shouldSpeak('call_active'), isFalse);
  });

  test('arm again extends the window from now', () {
    cooldown.arm('call_active', 60);
    clock.advance(const Duration(seconds: 50));
    cooldown.arm('call_active', 60);
    clock.advance(const Duration(seconds: 50));
    expect(cooldown.shouldSpeak('call_active'), isFalse);
    expect(
      cooldown.until('call_active'),
      DateTime.utc(2026, 10, 16, 12, 1, 50),
    );
  });

  test('a zero cooldown never suppresses', () {
    cooldown.arm('generic', 0);
    expect(cooldown.shouldSpeak('generic'), isTrue);
  });

  test('reset re-enables every trigger', () {
    cooldown.arm('call_active', 300);
    cooldown.arm('sim_swap', 300);
    cooldown.reset();
    expect(cooldown.shouldSpeak('call_active'), isTrue);
    expect(cooldown.shouldSpeak('sim_swap'), isTrue);
    expect(cooldown.until('call_active'), isNull);
  });
}
