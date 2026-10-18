import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A 2-D point in **physical pixels** (logical px x devicePixelRatio).
///
/// Deliberately not `dart:ui` `Offset`, so the behaviour domain and its tests
/// run as plain Dart without Flutter bindings.
@immutable
final class Point2 {
  const Point2(this.x, this.y);

  static const Point2 zero = Point2(0, 0);

  final double x;
  final double y;

  double distanceTo(Point2 other) {
    final dx = other.x - x;
    final dy = other.y - y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  bool operator ==(Object other) =>
      other is Point2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point2($x, $y)';
}

/// One PIN pad key press: timing, where the finger landed, how hard and how
/// big the contact was.
///
/// It never carries which digit was pressed. A backspace is a [KeyEvent] with
/// [isBackspace] set; its position, pressure and size are not meaningful.
@immutable
final class KeyEvent {
  const KeyEvent({
    required this.downMs,
    required this.upMs,
    required this.position,
    required this.pressure,
    this.size = 0.0,
    this.isBackspace = false,
  });

  /// Timestamp of the touch-down, in milliseconds.
  final int downMs;

  /// Timestamp of the touch-up, in milliseconds.
  final int upMs;

  /// Touch-down position in physical pixels.
  final Point2 position;

  /// Contact pressure, 0..1 (1.0 on the emulator).
  final double pressure;

  /// Contact size at touch-down: touch major radius in physical pixels
  /// (Flutter `PointerEvent.radiusMajor`). 0.0 (or any non-positive value)
  /// means "not reported" and is treated as absent by the extractor.
  final double size;

  final bool isBackspace;

  int get holdMs => upMs - downMs;

  @override
  String toString() =>
      'KeyEvent(down: $downMs, up: $upMs, at: $position, p: $pressure, '
      'size: $size'
      '${isBackspace ? ', backspace' : ''})';
}

/// One raw touch sample inside a stroke.
@immutable
final class StrokePoint {
  const StrokePoint({
    required this.tMs,
    required this.p,
    required this.pressure,
    this.size = 0.0,
  });

  final int tMs;
  final Point2 p;
  final double pressure;

  /// Contact size: touch major radius in physical pixels (Flutter
  /// `PointerEvent.radiusMajor`). 0.0 (or any non-positive value) means "not
  /// reported" and is treated as absent by the extractor.
  final double size;

  @override
  String toString() => 'StrokePoint($tMs, $p, $pressure, size: $size)';
}

/// The samples between one touch-down and its touch-up, in time order.
///
/// A tap is a stroke too; a stroke with fewer than two points is kept and
/// the extractor treats everything it cannot support as unmeasurable.
@immutable
final class Stroke {
  Stroke(List<StrokePoint> points) : points = List.unmodifiable(points);

  final List<StrokePoint> points;

  @override
  String toString() => 'Stroke(${points.length} points)';
}

/// One accelerometer + gyroscope reading. Accel in m/s^2, gyro in rad/s.
@immutable
final class ImuSample {
  const ImuSample({
    required this.tMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  final int tMs;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  double get accelMagnitude => math.sqrt(ax * ax + ay * ay + az * az);
  double get gyroMagnitude => math.sqrt(gx * gx + gy * gy + gz * gz);

  @override
  String toString() => 'ImuSample($tMs, a=($ax, $ay, $az), g=($gx, $gy, $gz))';
}

/// Everything captured on the eleven-seconds path that feeds the extractor.
@immutable
final class BehaviourSample {
  BehaviourSample({
    List<KeyEvent> keys = const [],
    List<Stroke> strokes = const [],
    List<ImuSample> imu = const [],
  }) : keys = List.unmodifiable(keys),
       strokes = List.unmodifiable(strokes),
       imu = List.unmodifiable(imu);

  static final BehaviourSample empty = BehaviourSample();

  final List<KeyEvent> keys;
  final List<Stroke> strokes;
  final List<ImuSample> imu;
}
