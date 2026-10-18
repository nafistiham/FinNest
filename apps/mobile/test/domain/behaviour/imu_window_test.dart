import 'package:bhorosha/domain/behaviour/behaviour_sample.dart';
import 'package:bhorosha/domain/behaviour/imu_window.dart';
import 'package:flutter_test/flutter_test.dart';

ImuSample at(int tMs) =>
    ImuSample(tMs: tMs, ax: 0, ay: 0, az: 9.81, gx: 0, gy: 0, gz: 0);

void main() {
  test('evicts samples older than keep relative to the newest', () {
    final w = ImuWindow(keep: const Duration(seconds: 2))
      ..add(at(0))
      ..add(at(1000))
      ..add(at(2000));
    expect(w.all.map((s) => s.tMs), [0, 1000, 2000]);

    w.add(at(3500));
    expect(w.all.map((s) => s.tMs), [2000, 3500]);
    expect(w.length, 2);
  });

  test('around is inclusive on both edges', () {
    final w = ImuWindow();
    for (final t in [3999, 4000, 4500, 5000, 6000, 6001]) {
      w.add(at(t));
    }
    expect(w.around(5000).map((s) => s.tMs), [4000, 4500, 5000, 6000]);
    expect(w.around(5000, halfWindowMs: 500).map((s) => s.tMs), [4500, 5000]);
    expect(w.around(100000), isEmpty);
  });

  test('default keep is 30 s', () {
    final w = ImuWindow()
      ..add(at(0))
      ..add(at(30000));
    expect(w.length, 2);
    w.add(at(30001));
    expect(w.all.first.tMs, 30000);
  });

  test('clear empties the buffer and resets the newest timestamp', () {
    final w = ImuWindow(keep: const Duration(seconds: 1))
      ..add(at(50000))
      ..clear();
    expect(w.all, isEmpty);
    w.add(at(10));
    expect(w.all.map((s) => s.tMs), [10]);
  });

  test('all returns a snapshot', () {
    final w = ImuWindow()..add(at(1));
    final snapshot = w.all;
    w.add(at(2));
    expect(snapshot, hasLength(1));
    expect(() => snapshot.add(at(3)), throwsUnsupportedError);
  });
}
