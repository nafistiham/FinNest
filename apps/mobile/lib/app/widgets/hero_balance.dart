/// The Home balance, Wise style (7.2): no card, a 24 dp
/// caption row ("মোট ব্যালেন্স" + a "লুকান / দেখুন" text button), a 4 dp gap,
/// then the amount in the heavy, tight [DisplayAmountStyle] at 44 sp with
/// the `৳` at 60 % in muted text, left-aligned on the screen surface; 76 dp
/// in all ([height]).
///
/// States ([balance]):
/// - loading: a 160 x 44 [Skeleton.amount] shimmer, never a spinner;
/// - error (no value yet): the caption says "ব্যালেন্স দেখা যাচ্ছে না"
///   with a 56 dp "আবার চেষ্টা করুন" when [onRetry] is set;
/// - data: a one-shot 180 ms blur-to-sharp preparation beat
///   ([Motion.prepare]), then later values roll in place ([RollingAmount],
///   600 ms, fixed digit slots); the eye toggle cross-fades the digits to
///   `৳ • • • • •` and back.
///
/// [revealed] null = the widget keeps its own show / hide state (visible
/// first, not persisted: privacy on a shared phone is per session). Non-null
/// = controlled; the toggle calls [onRevealedChanged].
///
/// Semantics: "মোট ব্যালেন্স ৯,৮৪১ টাকা" as one node; hidden: "ব্যালেন্স
/// লুকানো".
///
/// Reduce motion: no blur beat and no roll; the value and the mask swap with
/// a short opacity cross-fade ([Motion.crossfade]).
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../motion/motion_specs.dart';
import '../theme/theme.dart';
import 'animated/expressive_text.dart';
import 'animated/pressable.dart';
import 'animated/rolling_amount.dart';
import 'animated/skeleton.dart';

class HeroBalance extends StatefulWidget {
  const HeroBalance({
    required this.balance,
    this.captionOverride,
    this.onRetry,
    this.onTap,
    this.revealed,
    this.onRevealedChanged,
    this.showToggle = true,
    super.key,
  });

  /// A settled amount (no loading or error state).
  HeroBalance.value(
    num amountBdt, {
    this.captionOverride,
    this.onTap,
    this.revealed,
    this.onRevealedChanged,
    this.showToggle = true,
    super.key,
  }) : balance = AsyncValue.data(amountBdt.toDouble()),
       onRetry = null;

  final AsyncValue<double> balance;

  /// Caption above the amount; defaults to "মোট ব্যালেন্স".
  final String? captionOverride;

  /// The error state's "আবার চেষ্টা করুন"; hidden when null.
  final VoidCallback? onRetry;

  /// Tapping the amount (e.g. open History). Null = not tappable.
  final VoidCallback? onTap;

  /// Controlled visibility; null = internal state, visible first.
  final bool? revealed;
  final ValueChanged<bool>? onRevealedChanged;

  /// Whether the "লুকান / দেখুন" toggle shows.
  final bool showToggle;

  static const toggleKey = Key('hero_balance_toggle');
  static const amountKey = Key('hero_balance_amount');
  static const maskKey = Key('hero_balance_mask');
  static const skeletonKey = Key('hero_balance_skeleton');

  /// The masked digits (5 dots).
  static const mask = '• • • • •';

  /// Digit size of the amount (`amountHero`): 52 sp in the display face, so
  /// the balance reads big and bold.
  static const amountSize = 52.0;

  /// Caption row, 4 dp gap, amount row: 84 dp in all (no padding of its
  /// own; the screen puts 16 dp around it).
  static const captionHeight = 24.0;
  static const amountHeight = 56.0;
  static const height = captionHeight + BhSpace.xs + amountHeight;

  @override
  State<HeroBalance> createState() => _HeroBalanceState();
}

class _HeroBalanceState extends State<HeroBalance> {
  bool _revealed = true;

  /// The first amount counts up from 0 ([RollingAmount.from]); later ones
  /// (a refresh, un-hiding) roll from the previous value or just show.
  bool _countedUp = false;

  bool get _shown => widget.revealed ?? _revealed;

  void _toggle() {
    final next = !_shown;
    if (widget.revealed == null) setState(() => _revealed = next);
    widget.onRevealedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final m = Motion.of(context);
    final b = widget.balance;
    final error = b.hasError && !b.hasValue;
    final value = b.value;
    final canToggle =
        widget.showToggle &&
        value != null &&
        (widget.revealed == null || widget.onRevealedChanged != null);

    final caption = ExcludeSemantics(
      excluding: !error,
      child: Text(
        error
            ? l10n.balanceUnavailable
            : (widget.captionOverride ?? l10n.balanceTotal),
        style: text.bodySmall?.copyWith(color: p.mutedText),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final Widget? trailing = error
        ? (widget.onRetry == null
              ? null
              : _CaptionButton(label: l10n.retry, onPressed: widget.onRetry!))
        : !canToggle
        ? null
        : _CaptionButton(
            key: HeroBalance.toggleKey,
            label: _shown ? l10n.balanceHide : l10n.balanceShow,
            icon: _shown
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            onPressed: _toggle,
          );

    Widget amount;
    if (value != null) {
      amount = _amount(context, value, m);
    } else if (error) {
      amount = const SizedBox(height: HeroBalance.amountHeight);
    } else {
      amount = Semantics(
        label: l10n.balanceTotal,
        child: const Skeleton.amount(key: HeroBalance.skeletonKey),
      );
    }

    return SizedBox(
      height: HeroBalance.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: HeroBalance.captionHeight,
            child: Row(
              children: [
                Expanded(child: caption),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: BhSpace.xs),
          SizedBox(
            height: HeroBalance.amountHeight,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: amount,
            ),
          ),
        ],
      ),
    );
  }

  Widget _amount(BuildContext context, double value, Motion m) {
    final l10n = context.l10n;
    final p = context.palette;
    final digits = DisplayAmountStyle(
      context,
      size: HeroBalance.amountSize,
      color: p.onSurface,
    );
    final sign = digits.copyWith(
      fontSize: HeroBalance.amountSize * 0.6,
      color: p.mutedText,
    );
    final spoken = context.takaSpoken(value);
    final caption = widget.captionOverride;
    final label = !_shown
        ? l10n.balanceHidden
        : caption == null
        ? l10n.balanceSemantics(spoken)
        : '$caption $spoken';

    final from = _countedUp || value == 0 ? null : 0;
    if (_shown) _countedUp = true;
    final Widget shown = _shown
        ? RollingAmount(
            value,
            key: HeroBalance.amountKey,
            style: digits,
            prefix: '৳ ',
            prefixStyle: sign,
            from: from,
            semanticsLabel: label,
          )
        : Semantics(
            key: HeroBalance.maskKey,
            label: label,
            container: true,
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('৳ ', style: sign),
                  Text(
                    HeroBalance.mask,
                    style: digits,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              ),
            ),
          );

    Widget amount = _Prepare(
      duration: m.prepare,
      child: AnimatedSwitcher(
        duration: m.reduced ? Motion.crossfade : m.enter,
        switchInCurve: MotionCurves.enter,
        switchOutCurve: MotionCurves.exit,
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [...previous, ?current],
        ),
        child: shown,
      ),
    );
    amount = FittedBox(fit: BoxFit.scaleDown, child: amount);
    if (widget.onTap != null) {
      amount = Pressable(onTap: widget.onTap, shade: false, child: amount);
    }
    return amount;
  }
}

/// A text button whose 56 dp hit area overflows the 24 dp caption row.
class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    super.key,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextButton.styleFrom(
      minimumSize: const Size(BhSize.touch, BhSize.touch),
      padding: const EdgeInsets.symmetric(horizontal: BhSpace.s),
      foregroundColor: p.primary,
      textStyle: Theme.of(context).textTheme.labelMedium,
    );
    return IntrinsicWidth(
      child: OverflowBox(
        maxHeight: BhSize.touch,
        child: icon == null
            ? TextButton(onPressed: onPressed, style: style, child: Text(label))
            : TextButton.icon(
                onPressed: onPressed,
                style: style,
                icon: Icon(icon, size: 20),
                label: Text(label),
              ),
      ),
    );
  }
}

/// One-shot blur-to-sharp and fade-in. The tree shape never changes (the
/// filter is disabled, not removed), so the child keeps its state.
class _Prepare extends StatelessWidget {
  const _Prepare({required this.duration, required this.child});

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: duration == Duration.zero ? 1.0 : 0.0, end: 1.0),
    duration: duration,
    curve: MotionCurves.enter,
    child: child,
    builder: (context, t, child) {
      final sigma = 6 * (1 - t);
      return Opacity(
        opacity: t,
        child: ImageFiltered(
          enabled: sigma > 0.01,
          imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: child,
        ),
      );
    },
  );
}
