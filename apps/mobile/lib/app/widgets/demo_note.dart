import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// A one- or two-line demo strip (7.13): `infoContainer` fill, 4 dp `info`
/// stripe, `science` icon, `bodySmall` text. On every dummy feature's first
/// step, the cash-in code and the Login screen.
class DemoNote extends StatelessWidget {
  const DemoNote(this.text, {this.icon = Icons.science_outlined, super.key});

  final String text;

  /// `science` by default; `info_outline` for a plain information strip.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.infoContainer,
        border: BorderDirectional(
          start: BorderSide(color: p.info, width: BhSize.stripe),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: BhSpace.m - BhSize.stripe,
        vertical: BhSpace.s,
      ).copyWith(left: BhSpace.m - BhSize.stripe + BhSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: BhSpace.xxs),
            child: Icon(icon, size: 20, color: p.info),
          ),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: p.onInfoContainer),
            ),
          ),
        ],
      ),
    );
  }
}
