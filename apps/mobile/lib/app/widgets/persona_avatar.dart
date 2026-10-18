import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Square initial tile for a customer or payee: the first Bangla grapheme of
/// [nameBn] on `primaryContainer` (`onPrimaryContainer` ink) unless
/// [color] / [background] say otherwise. Square like everything else.
class PersonaAvatar extends StatelessWidget {
  const PersonaAvatar({
    required this.nameBn,
    this.size = 56,
    this.color,
    this.background,
    super.key,
  });

  final String nameBn;
  final double size;
  final Color? color;
  final Color? background;

  /// The first user-perceived character, so a conjunct is not split.
  static String initialOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.characters.first;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        color: background ?? p.primaryContainer,
        alignment: Alignment.center,
        child: Text(
          initialOf(nameBn),
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: BhType.family,
            fontFamilyFallback: const ['Roboto'],
            fontSize: size * 0.48,
            fontWeight: FontWeight.w700,
            color: color ?? p.onPrimaryContainer,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}
