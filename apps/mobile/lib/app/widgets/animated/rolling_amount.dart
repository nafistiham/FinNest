/// An odometer amount: `৳ ৯,৮৪১` whose digits roll vertically to a new value.
///
/// - Every digit sits in a fixed-width slot measured from the widest digit
///   of the active script ([DigitSlotMetrics]), so nothing jitters while it
///   rolls; grouping commas and the prefix stay static.
/// - A change rolls each changed digit over [Motion.counter] (600 ms,
///   easeOutCubic). The leading digits settle first (the most significant
///   finishes at 65 % of the run, the last at 100 %), so the eye reads the
///   magnitude before the detail. Unchanged digits do not move. A digit
///   slot that is new (999 -> 1,000) rolls up from 0 and fades in.
/// - The whole row breathes 1.0 -> 1.02 -> 1.0 once per change.
/// - Semantics announce only the final value (one node, slots excluded).
/// - Lakh grouping and the active digits come from `lib/app/l10n.dart`.
///
/// Reduce motion: no roll and no scale; the old value cross-fades to the new
/// one ([Motion.crossfade], opacity only).
library;

import 'package:flutter/widgets.dart';

import '../../l10n.dart';
import '../../motion/motion_specs.dart';
import '../../theme/palette.dart';
import 'expressive_text.dart';

class RollingAmount extends StatefulWidget {
  const RollingAmount(
    this.amount, {
    this.style,
    this.prefix = '৳ ',
    this.prefixStyle,
    this.from,
    this.semanticsLabel,
    this.scaleDown = true,
    super.key,
  });

  /// Whole taka (fractions are dropped, as everywhere in the app).
  final num amount;

  /// Digit style; defaults to [DisplayAmountStyle].
  final TextStyle? style;

  /// Static text before the digits ('৳ ' by default; '' for none).
  final String prefix;

  /// Style of [prefix]; defaults to [style].
  final TextStyle? prefixStyle;

  /// When set, the first build rolls from this value to [amount]
  /// (e.g. 0 on a confirmation). Otherwise the first build shows [amount].
  final num? from;

  /// Spoken label; defaults to "৫,০০০ টাকা" for the taka prefix, else the
  /// visible text.
  final String? semanticsLabel;

  /// Shrink (never wrap or clip) when the row is wider than the space
  /// available, e.g. a 9-digit amount at 44 sp on a 360 dp phone.
  final bool scaleDown;

  @override
  State<RollingAmount> createState() => _RollingAmountState();
}

class _RollingAmountState extends State<RollingAmount>
    with SingleTickerProviderStateMixin {
  // A first-build roll ([RollingAmount.from]) shows `from` until it starts.
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: widget.from == null ? 1 : 0,
  );
  late int _from = (widget.from ?? widget.amount).round();
  late int _to = widget.amount.round();
  bool _started = false;

  static const _bn = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

  static final _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.02,
      ).chain(CurveTween(curve: MotionCurves.enter)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.02,
        end: 1.0,
      ).chain(CurveTween(curve: MotionCurves.release)),
      weight: 60,
    ),
  ]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.duration = Motion.of(context).counter;
    if (!_started) {
      _started = true;
      if (widget.from == null) {
        _run();
      } else {
        // Seen, not buried under the push: wait for the route to enter.
        afterRouteEntrance(context, () {
          if (mounted) _run();
        });
      }
    }
  }

  @override
  void didUpdateWidget(RollingAmount old) {
    super.didUpdateWidget(old);
    final next = widget.amount.round();
    if (next != _to) {
      _from = _to;
      _to = next;
      _run();
    }
  }

  void _run() {
    if (_from == _to || Motion.of(context).reduced) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? DisplayAmountStyle(context);
    final prefixStyle = widget.prefixStyle ?? style;
    final bangla = context.banglaDigits;
    final finalText = context.digits(groupLakh(_to.abs()));
    final sign = _to < 0 ? '−' : '';
    final label =
        widget.semanticsLabel ??
        (widget.prefix.trim() == '৳'
            ? context.takaSpoken(_to)
            : '${widget.prefix}$sign$finalText');

    Widget row;
    if (Motion.of(context).reduced) {
      row = AnimatedSwitcher(
        duration: Motion.crossfade,
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [...previous, ?current],
        ),
        child: Row(
          key: ValueKey(_to),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (widget.prefix.isNotEmpty)
              Text(widget.prefix, style: prefixStyle),
            TabularBangla('$sign$finalText', style: style),
          ],
        ),
      );
    } else {
      final metrics = DigitSlotMetrics.of(
        style,
        MediaQuery.textScalerOf(context),
        bangla: bangla,
      );
      row = AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Transform.scale(
          scale: _c.isAnimating ? _scale.transform(_c.value) : 1,
          alignment: AlignmentDirectional.centerStart.resolve(
            Directionality.maybeOf(context) ?? TextDirection.ltr,
          ),
          child: _odometer(style, prefixStyle, metrics, bangla, sign),
        ),
      );
    }
    if (widget.scaleDown) {
      row = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: row,
      );
    }
    return Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(child: row),
    );
  }

  Widget _odometer(
    TextStyle style,
    TextStyle prefixStyle,
    DigitSlotMetrics m,
    bool bangla,
    String sign,
  ) {
    final to = _to.abs().toString();
    final from = _from.abs().toString();
    final grouped = groupLakh(_to.abs());
    final up = _to >= _from;
    final n = to.length;
    final children = <Widget>[
      if (widget.prefix.isNotEmpty) Text(widget.prefix, style: prefixStyle),
      if (sign.isNotEmpty) Text(sign, style: style),
    ];
    var k = 0; // digit index from the left of [to]
    for (final ch in grouped.characters) {
      if (ch == ',') {
        children.add(Text(',', style: style));
        continue;
      }
      final target = int.parse(to[k]);
      final fromIndex = k - (n - from.length);
      final fromDigit = fromIndex >= 0 && fromIndex < from.length
          ? int.parse(from[fromIndex])
          : null;
      final start = fromDigit ?? 0;
      var end = target;
      if (up && end < start) end += 10;
      if (!up && end > start) end -= 10;
      final settleAt = n <= 1 ? 1.0 : 0.65 + 0.35 * k / (n - 1);
      final t = MotionCurves.counter.transform(
        Interval(0, settleAt).transform(_c.value),
      );
      final pos = start + (end - start) * t;
      children.add(
        _DigitWheel(
          position: pos,
          opacity: fromDigit == null ? t : 1,
          metrics: m,
          style: style,
          glyph: (d) => bangla ? _bn[d % 10] : '${d % 10}',
        ),
      );
      k++;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: children,
    );
  }
}

/// One digit slot showing [position] on a vertical wheel: the digit at
/// `floor(position)` moving up and out while the next one comes in from
/// below, each faded by its distance from the centre.
class _DigitWheel extends StatelessWidget {
  const _DigitWheel({
    required this.position,
    required this.opacity,
    required this.metrics,
    required this.style,
    required this.glyph,
  });

  final double position;
  final double opacity;
  final DigitSlotMetrics metrics;
  final TextStyle style;
  final String Function(int digit) glyph;

  @override
  Widget build(BuildContext context) {
    final base = position.floor();
    final frac = position - base;
    final pitch = metrics.height * 1.1;
    // No colour on the style: inherit, never black (invisible in dark mode).
    final color =
        style.color ??
        DefaultTextStyle.of(context).style.color ??
        context.palette.onSurface;
    TextStyle faded(double a) =>
        style.copyWith(color: color.withValues(alpha: color.a * a * opacity));
    Widget digit(int d, double dy, double a) => Transform.translate(
      offset: Offset(0, dy),
      child: Text(
        glyph(d), // Dart's % is Euclidean: -1 % 10 == 9
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        style: faded(a),
      ),
    );
    return SizedBox(
      width: metrics.width,
      height: metrics.height,
      child: ClipRect(
        clipper: _Bleed(metrics.height * 0.12),
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            digit(base, -frac * pitch, 1 - frac),
            if (frac > 0) digit(base + 1, (1 - frac) * pitch, frac),
          ],
        ),
      ),
    );
  }
}

/// Clips to the slot plus a little vertical bleed so tall glyphs (and the
/// tight display line height) never lose their tops.
class _Bleed extends CustomClipper<Rect> {
  const _Bleed(this.bleed);

  final double bleed;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-2, -bleed, size.width + 2, size.height + bleed);

  @override
  bool shouldReclip(_Bleed old) => old.bleed != bleed;
}
