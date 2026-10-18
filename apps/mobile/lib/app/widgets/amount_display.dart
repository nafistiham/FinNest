import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/theme.dart';
import 'animated/rolling_amount.dart';
import 'digit_slots.dart';

/// The amount being typed: `৳` at 60 % of the digit
/// size in muted text, then the digits in fixed-width slots so the sign never
/// moves, centred, shrinking (never wrapping) so nine digits fit at 360 dp.
/// Zero shows a muted "৳ ০". A 2 dp caret blinks after the last digit
/// (hidden with reduce motion, or when [caret] is false: pass false in
/// widget tests that `pumpAndSettle`).
///
/// [caption] sits above (regular only), [status] below (regular only).
/// Change [nudge] to play the 6 dp "over the maximum" nudge.
///
/// [rollFrom]: a jump (a quick amount) rolls the digits odometer-style from
/// that value ([RollingAmount], fixed slots, the ৳ still never moves);
/// typing passes null and the digits change in place. Reduce motion: a
/// short cross-fade.
class AmountDisplay extends StatelessWidget {
  const AmountDisplay({
    required this.amount,
    required this.compact,
    this.caption,
    this.status,
    this.caret = true,
    this.nudge = 0,
    this.rollFrom,
    super.key,
  });

  /// Roll from this value (a quick-amount jump); null while typing.
  final int? rollFrom;

  final int amount;
  final bool compact;
  final String? caption;
  final Widget? status;
  final bool caret;

  /// Each new value plays one nudge (refused key press).
  final int nudge;

  static const amountKey = Key('amount_display_amount');
  static const signKey = Key('amount_display_sign');
  static const rollKey = Key('amount_display_roll');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final roles = context.textRoles;
    final motion = BhMotion.of(context);
    final base = compact ? roles.amountEntryCompact : roles.amountEntry;
    final style = base.copyWith(color: amount == 0 ? p.mutedText : p.onSurface);
    final text = Theme.of(context).textTheme;
    final digitsRow = Row(
      key: amountKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '৳',
          key: signKey,
          style: style.copyWith(
            fontSize: (style.fontSize ?? 48) * 0.6,
            color: p.mutedText,
          ),
        ),
        const SizedBox(width: BhSpace.xs),
        if (rollFrom == null)
          DigitSlots(context.digits(groupLakh(amount)), style: style)
        else
          RollingAmount(
            amount,
            key: rollKey,
            from: rollFrom,
            prefix: '',
            style: style,
            scaleDown: false,
          ),
        if (caret && !motion.reduced)
          _Caret(height: (style.fontSize ?? 48) * 0.8, color: p.primary),
      ],
    );
    final amountLine = TweenAnimationBuilder<double>(
      key: ValueKey(nudge),
      tween: Tween(begin: nudge == 0 ? 1 : 0, end: 1),
      duration: motion.nudge,
      builder: (context, t, child) => Transform.translate(
        // Two oscillations of 6 dp, damped to rest at t = 1.
        offset: Offset(math.sin(t * 4 * math.pi) * 6 * (1 - t), 0),
        child: child,
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: digitsRow),
    );
    return Semantics(
      liveRegion: true,
      label: context.l10n.amountSemantics(context.takaSpoken(amount)),
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (caption != null && !compact) ...[
              Text(
                caption!,
                style: text.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: BhSpace.s),
            ],
            amountLine,
            if (status != null && !compact) ...[
              const SizedBox(height: BhSpace.s),
              SizedBox(
                height: 24,
                child: DefaultTextStyle.merge(
                  style: text.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: status!,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Caret extends StatefulWidget {
  const _Caret({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: BhMotion.standard.caretBlink * 2,
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: BhSpace.xxs),
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Opacity(
        opacity: _c.value < 0.5 ? 1 : 0,
        child: Container(
          key: const Key('amount_caret'),
          width: 2,
          height: widget.height,
          color: widget.color,
        ),
      ),
    ),
  );
}
