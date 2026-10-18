/// Motion tokens: the ONE source of every duration
/// and curve in the app. Every animation goes through [BhMotion.of], which
/// returns zero durations when the system asks for reduced motion
/// (`MediaQuery.disableAnimationsOf`). Feature files never write a raw
/// `Duration(milliseconds: …)` for motion.
///
/// The animated component library (`lib/app/widgets/animated`) reads the
/// same tokens through `lib/app/motion/motion_specs.dart`, which only
/// re-exports them under the library's names (`Motion` = [BhMotion],
/// `MotionCurves` = [BhCurves]).
library;

import 'package:flutter/widgets.dart';

abstract final class BhCurves {
  /// Key and tile press-in.
  static const press = Curves.easeOut;

  /// Press-out, cross-fades, chip selection, count-up.
  static const release = Curves.easeOutCubic;

  /// M3 emphasised decelerate: step transitions, panels, list inserts.
  static const enter = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Anything leaving.
  static const exit = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Theme change, success check draw.
  static const slow = Curves.easeInOutCubic;

  /// Loops: Apa speaking ring, skeleton shimmer, breathing status dot.
  static const pulse = Curves.easeInOut;

  /// Odometer roll and count-up (same as [release]).
  static const counter = Curves.easeOutCubic;

  /// Hold / block entrances: decisive deceleration, no overshoot (same as
  /// [enter]).
  static const firm = enter;

  /// "easeOutBack-lite": about 4 % overshoot instead of easeOutBack's 10 %.
  /// For friendly emphasis (check mark, a value settling, a sheet arriving),
  /// never for hold or block.
  static const emphasis = Cubic(0.34, 1.26, 0.64, 1.0);
}

@immutable
class BhMotion {
  const BhMotion._({
    required this.press,
    required this.release,
    required this.fast,
    required this.normal,
    required this.exit,
    required this.slow,
    required this.counter,
    required this.pulse,
    required this.nudge,
    required this.caretBlink,
    required this.emphasis,
    required this.checkDraw,
    required this.stagger,
    required this.prepare,
    required this.overlay,
    required this.keyTint,
    required this.shimmer,
    required this.breathe,
    required this.shake,
    required this.reduced,
  });

  /// Full motion.
  static const standard = BhMotion._(
    press: Duration(milliseconds: 90),
    release: Duration(milliseconds: 150),
    fast: Duration(milliseconds: 150),
    normal: Duration(milliseconds: 240),
    exit: Duration(milliseconds: 200),
    slow: Duration(milliseconds: 360),
    counter: Duration(milliseconds: 600),
    pulse: Duration(milliseconds: 1200),
    nudge: Duration(milliseconds: 120),
    caretBlink: Duration(milliseconds: 530),
    emphasis: Duration(milliseconds: 400),
    checkDraw: Duration(milliseconds: 480),
    stagger: Duration(milliseconds: 40),
    prepare: Duration(milliseconds: 180),
    overlay: Duration(milliseconds: 280),
    keyTint: Duration(milliseconds: 120),
    shimmer: Duration(milliseconds: 1200),
    breathe: Duration(milliseconds: 1600),
    shake: Duration(milliseconds: 420),
    reduced: false,
  );

  /// Reduce motion: every duration is zero; loops show their final frame.
  static const none = BhMotion._(
    press: Duration.zero,
    release: Duration.zero,
    fast: Duration.zero,
    normal: Duration.zero,
    exit: Duration.zero,
    slow: Duration.zero,
    counter: Duration.zero,
    pulse: Duration.zero,
    nudge: Duration.zero,
    caretBlink: Duration.zero,
    emphasis: Duration.zero,
    checkDraw: Duration.zero,
    stagger: Duration.zero,
    prepare: Duration.zero,
    overlay: Duration.zero,
    keyTint: Duration.zero,
    shimmer: Duration.zero,
    breathe: Duration.zero,
    shake: Duration.zero,
    reduced: true,
  );

  static BhMotion of(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? none : standard;

  final Duration press, release, fast, normal, exit, slow, counter, pulse;

  /// Amount-over-max horizontal nudge (6 dp, 2 oscillations).
  final Duration nudge;

  /// Caret on/off period; zero means a static (hidden) caret.
  final Duration caretBlink;

  /// Emphasis moments (a value settles, the check overshoot).
  final Duration emphasis;

  /// Success circle + check draw (`SuccessCheck`).
  final Duration checkDraw;

  /// Gap between staggered list items on first paint (max 5 items).
  final Duration stagger;

  /// The preparation beat before the balance reveals (blur to sharp).
  final Duration prepare;

  /// Overlay and sheet entrance (`SlideFadeIn`: slide-up + scrim).
  final Duration overlay;

  /// Numpad key background tint (`KeyFeedback`).
  final Duration keyTint;

  /// One skeleton shimmer sweep (linear, looping).
  final Duration shimmer;

  /// One breathing cycle of the status dot (`StatusPulse`, looping).
  final Duration breathe;

  /// Wrong-PIN shake (3 oscillations, 12 dp).
  final Duration shake;

  /// True when the system asked for reduced motion.
  final bool reduced;

  /// Fade and rise of an entering element (= [normal]).
  Duration get enter => normal;

  /// Press-in of tiles, rows and buttons (= [press]).
  Duration get pressDown => press;

  /// Press-out (= [release]).
  Duration get pressUp => release;

  /// Opacity-only swap used as the reduce-motion fallback for value changes
  /// (amount roll, balance mask). A fade is not movement, so it stays short
  /// but non-zero in both modes.
  static const crossfade = Duration(milliseconds: 120);
}
