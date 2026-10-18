import 'package:bhorosha/domain/behaviour/behaviour_sample.dart';
import 'package:bhorosha/domain/behaviour/pin_pad_recorder.dart';
import 'package:bhorosha/domain/behaviour/swipe_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PinPadRecorder', () {
    test('pairs down and up per key and never stores the key index', () {
      final r = PinPadRecorder()
        ..keyDown(7, const Point2(10, 20), 0.5, 1000)
        ..keyUp(7, 1120)
        ..keyDown(2, const Point2(30, 40), 0.7, 1300)
        ..keyUp(2, 1400);

      expect(r.keys, hasLength(2));
      expect(r.keys[0].downMs, 1000);
      expect(r.keys[0].upMs, 1120);
      expect(r.keys[0].position, const Point2(10, 20));
      expect(r.keys[0].pressure, 0.5);
      expect(r.keys[0].isBackspace, isFalse);
      expect(r.keys[1].holdMs, 100);
      // The only thing a KeyEvent exposes about identity is nothing at all.
      expect(r.keys[0].toString(), isNot(contains('7')));
    });

    test('keyDown size is carried to the KeyEvent; defaults to 0.0', () {
      final r = PinPadRecorder()
        ..keyDown(1, const Point2(1, 2), 0.5, 100, size: 12.5)
        ..keyUp(1, 200)
        ..keyDown(2, const Point2(3, 4), 0.5, 300)
        ..keyUp(2, 400)
        ..backspace(500);
      expect(r.keys.map((k) => k.size), [12.5, 0.0, 0.0]);
    });

    test('overlapping fingers are paired by key index', () {
      final r = PinPadRecorder()
        ..keyDown(1, const Point2(0, 0), 1, 100)
        ..keyDown(2, const Point2(5, 5), 1, 150)
        ..keyUp(1, 200)
        ..keyUp(2, 260);
      expect(r.keys.map((k) => k.holdMs), [100, 110]);
    });

    test('up without a down is ignored; backspace is flagged', () {
      final r = PinPadRecorder()
        ..keyUp(3, 500)
        ..backspace(700);
      expect(r.keys, hasLength(1));
      expect(r.keys.single.isBackspace, isTrue);
      expect(r.keys.single.downMs, 700);
      expect(r.keys.single.upMs, 700);
    });

    test('reset drops completed and pending presses', () {
      final r = PinPadRecorder()
        ..keyDown(1, Point2.zero, 1, 100)
        ..keyUp(1, 200)
        ..keyDown(2, Point2.zero, 1, 300)
        ..reset()
        ..keyUp(2, 400);
      expect(r.keys, isEmpty);
    });

    test('keys is a snapshot, not a live view', () {
      final r = PinPadRecorder()
        ..keyDown(1, Point2.zero, 1, 100)
        ..keyUp(1, 200);
      final snapshot = r.keys;
      r.backspace(300);
      expect(snapshot, hasLength(1));
      expect(() => snapshot.clear(), throwsUnsupportedError);
    });
  });

  group('SwipeRecorder', () {
    test('start/move/end builds one stroke in order', () {
      final r = SwipeRecorder()
        ..start(const Point2(0, 0), 0.4, 0)
        ..move(const Point2(50, 0), 0.5, 50)
        ..end(const Point2(100, 0), 0.6, 100);
      expect(r.isActive, isFalse);
      expect(r.strokes, hasLength(1));
      expect(r.strokes.single.points.map((p) => p.tMs), [0, 50, 100]);
      expect(r.strokes.single.points.last.p, const Point2(100, 0));
    });

    test('size rides on every stroke point; defaults to 0.0', () {
      final r = SwipeRecorder()
        ..start(const Point2(0, 0), 1, 0, size: 9)
        ..move(const Point2(5, 0), 1, 5)
        ..end(const Point2(10, 0), 1, 10, size: 11);
      expect(r.strokes.single.points.map((p) => p.size), [9.0, 0.0, 11.0]);
    });

    test('move and end without start are ignored', () {
      final r = SwipeRecorder()
        ..move(const Point2(1, 1), 1, 10)
        ..end(const Point2(2, 2), 1, 20);
      expect(r.strokes, isEmpty);
    });

    test('a second start closes the open stroke', () {
      final r = SwipeRecorder()
        ..start(const Point2(0, 0), 1, 0)
        ..start(const Point2(9, 9), 1, 500)
        ..end(const Point2(10, 10), 1, 600);
      expect(r.strokes, hasLength(2));
      expect(r.strokes.first.points, hasLength(1));
      expect(r.strokes.last.points, hasLength(2));
    });

    test('reset clears strokes and the open one', () {
      final r = SwipeRecorder()
        ..start(const Point2(0, 0), 1, 0)
        ..end(const Point2(1, 0), 1, 10)
        ..start(const Point2(0, 0), 1, 20)
        ..reset()
        ..end(const Point2(1, 0), 1, 30);
      expect(r.strokes, isEmpty);
    });
  });
}
