import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';
import 'animated/numpad_key_feedback.dart';

/// Raw pointer-down on a key: [keyIndex] identifies the key only so a
/// touch-up can be paired with its touch-down (see `PinPadRecorder`),
/// [position] is the touch point in **global logical px** (callers multiply
/// by `devicePixelRatio` for the extractor), [pressure] 0..1 (1.0 on the
/// emulator), [size] the normalised 0..1 touch area (`PointerEvent.size`,
/// HMOG's Contact_size), [tMs] wall-clock milliseconds.
typedef NumpadKeyDown = void Function(
  int keyIndex,
  Offset position,
  double pressure,
  double size,
  int tMs,
);
typedef NumpadKeyUp = void Function(int keyIndex, int tMs);

/// Bottom row of the pad:
/// - [amount]: `০০ ০ ⌫`
/// - [number]: `পেস্ট ০ ⌫`
/// - [pin]: `⌫ ০ (lock glyph, inert)`; the key indices and positions are
///   unchanged because the behaviour features are position-based. With an
///   `onConfirm` the bottom-right key is a confirm key instead (legacy).
enum NumpadVariant { amount, number, pin }

/// The legacy name; same widget, same callbacks.
typedef BanglaNumpad = Numpad;

/// The app's own 3x4 numeric keypad with digits in the active style (০-৯ in
/// Bangla, 0-9 in English; system keyboards show Latin digits). Keys fill
/// `surfaceVariant`, square, no border; pressed keys fill toward
/// `primaryContainer` and scale to 0.96 (no ink ripple: the fill is the
/// feedback). Digits use `TextScaler.noScaling` (they are already 32 sp).
///
/// The PIN pad wires the raw [onKeyDown] / [onKeyUp] callbacks to record
/// behaviour; the amount and number pads leave them null.
class Numpad extends StatelessWidget {
  const Numpad({
    required this.onDigit,
    required this.onBackspace,
    this.variant = NumpadVariant.pin,
    this.onConfirm,
    this.confirmIcon = Icons.check,
    this.onDoubleZero,
    this.onPaste,
    this.onClear,
    this.onKeyDown,
    this.onKeyUp,
    this.enabled = true,
    this.keyHeight = BhSize.key,
    this.gap = BhSpace.s,
    super.key,
  });

  /// Key indices of the non-digit keys (digits use their own value).
  static const backspaceIndex = 10;
  static const confirmIndex = 11;
  static const doubleZeroIndex = 12;
  static const pasteIndex = 13;

  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  final NumpadVariant variant;

  /// Pin variant only: when set, the bottom-right slot is a confirm key.
  final VoidCallback? onConfirm;
  final IconData confirmIcon;

  /// Amount variant: the "০০" key. Null sends two `onDigit(0)` calls.
  final VoidCallback? onDoubleZero;

  /// Number variant: the "পেস্ট" key. Null disables that key.
  final VoidCallback? onPaste;

  /// Long press on ⌫ ("সব মুছুন"). Null: long press does nothing.
  final VoidCallback? onClear;
  final NumpadKeyDown? onKeyDown;
  final NumpadKeyUp? onKeyUp;
  final bool enabled;

  /// Key height: 72 regular PIN, 64 amount, 56 compact.
  final double keyHeight;

  /// Gap between keys and at the pad's edges: 8 regular, 4 compact.
  final double gap;

  static const _rows = [
    [1, 2, 3],
    [4, 5, 6],
    [7, 8, 9],
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final backspace = _NumpadKey(
      keyIndex: backspaceIndex,
      semanticsLabel: l10n.backspace,
      longPressLabel: onClear == null ? null : l10n.numpadClearAll,
      height: keyHeight,
      enabled: enabled,
      onTap: onBackspace,
      onLongPress: onClear,
      onKeyDown: onKeyDown,
      onKeyUp: onKeyUp,
      child: const Icon(Icons.backspace_outlined, size: 28),
    );
    final List<Widget> bottom = switch (variant) {
      NumpadVariant.pin => [
        backspace,
        _digitKey(context, 0),
        if (onConfirm != null)
          _NumpadKey(
            keyIndex: confirmIndex,
            semanticsLabel: l10n.ok,
            height: keyHeight,
            enabled: enabled,
            onTap: onConfirm!,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp,
            emphasised: true,
            child: Icon(confirmIcon, size: 32),
          )
        else
          _InertLock(height: keyHeight),
      ],
      NumpadVariant.amount => [
        _NumpadKey(
          keyIndex: doubleZeroIndex,
          semanticsLabel: l10n.numpadDoubleZero,
          height: keyHeight,
          enabled: enabled,
          onTap:
              onDoubleZero ??
              () {
                onDigit(0);
                onDigit(0);
              },
          onKeyDown: onKeyDown,
          onKeyUp: onKeyUp,
          child: _Glyph(context.digits('00')),
        ),
        _digitKey(context, 0),
        backspace,
      ],
      NumpadVariant.number => [
        _NumpadKey(
          keyIndex: pasteIndex,
          semanticsLabel: l10n.numpadPaste,
          height: keyHeight,
          enabled: enabled && onPaste != null,
          onTap: onPaste ?? () {},
          onKeyDown: onKeyDown,
          onKeyUp: onKeyUp,
          child: Text(
            l10n.paste,
            textScaler: TextScaler.noScaling,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        _digitKey(context, 0),
        backspace,
      ],
    };
    final half = gap / 2;
    return Padding(
      padding: EdgeInsets.all(half),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in _rows)
            Row(
              children: [
                for (final d in row)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(half),
                      child: _digitKey(context, d),
                    ),
                  ),
              ],
            ),
          Row(
            children: [
              for (final k in bottom)
                Expanded(
                  child: Padding(padding: EdgeInsets.all(half), child: k),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _digitKey(BuildContext context, int d) {
    final glyph = context.digits('$d');
    return _NumpadKey(
      keyIndex: d,
      semanticsLabel: glyph,
      height: keyHeight,
      enabled: enabled,
      onTap: () => onDigit(d),
      onKeyDown: onKeyDown,
      onKeyUp: onKeyUp,
      child: _Glyph(glyph),
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textScaler: TextScaler.noScaling,
    style: context.textRoles.numpadDigit.copyWith(
      color: DefaultTextStyle.of(context).style.color,
    ),
  );
}

/// The PIN pad's bottom-right cell: a dim lock so the gap reads as
/// intentional. No tap target.
class _InertLock extends StatelessWidget {
  const _InertLock({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      key: const Key('numpad_lock'),
      height: height,
      child: Center(
        child: Icon(
          Icons.lock_outline,
          size: 24,
          color: context.palette.onSurface.withValues(alpha: 0.38),
        ),
      ),
    ),
  );
}

class _NumpadKey extends StatefulWidget {
  const _NumpadKey({
    required this.keyIndex,
    required this.semanticsLabel,
    required this.height,
    required this.enabled,
    required this.onTap,
    required this.child,
    this.longPressLabel,
    this.onLongPress,
    this.onKeyDown,
    this.onKeyUp,
    this.emphasised = false,
  });

  final int keyIndex;
  final String semanticsLabel;
  final String? longPressLabel;
  final double height;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final NumpadKeyDown? onKeyDown;
  final NumpadKeyUp? onKeyUp;
  final bool emphasised;

  @override
  State<_NumpadKey> createState() => _NumpadKeyState();
}

class _NumpadKeyState extends State<_NumpadKey> {
  static int _now() => DateTime.now().millisecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final w = widget;
    final ink = w.enabled
        ? (w.emphasised ? p.onPrimaryContainer : p.onSurface)
        : p.onSurface.withValues(alpha: 0.38);
    final base = w.emphasised ? p.primaryContainer : p.surfaceVariant;
    return Semantics(
      button: true,
      enabled: w.enabled,
      label: w.semanticsLabel,
      onLongPressHint: w.longPressLabel,
      child: ExcludeSemantics(
        // The Listener sees every pointer before the gesture arena, so a
        // touch-up is recorded before InkWell reports the tap.
        child: Listener(
          onPointerDown: w.enabled
              ? (e) => w.onKeyDown?.call(
                  w.keyIndex,
                  e.position,
                  e.pressure,
                  e.size,
                  _now(),
                )
              : null,
          onPointerUp: w.enabled
              ? (e) => w.onKeyUp?.call(w.keyIndex, _now())
              : null,
          onPointerCancel: w.enabled
              ? (e) => w.onKeyUp?.call(w.keyIndex, _now())
              : null,
          // Press feedback (6.2): fill to primaryContainer 60 % and 0.96
          // scale from raw pointers; never joins the gesture arena.
          child: KeyFeedback(
            color: base,
            enabled: w.enabled,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.transparent,
                onTap: w.enabled ? w.onTap : null,
                onLongPress: w.enabled ? w.onLongPress : null,
                child: SizedBox(
                  height: w.height,
                  child: Center(
                    child: IconTheme.merge(
                      data: IconThemeData(color: ink),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(color: ink),
                        child: w.child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
