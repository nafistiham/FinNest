/// Injectable time source so cooldowns and countdowns are testable.
abstract class Clock {
  const Clock();
  DateTime now();
  int nowMs() => now().millisecondsSinceEpoch;
}

class SystemClock extends Clock {
  const SystemClock();
  @override
  DateTime now() => DateTime.now();
}

class FakeClock extends Clock {
  FakeClock(this._now);
  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration d) => _now = _now.add(d);
  set current(DateTime t) => _now = t;
}
