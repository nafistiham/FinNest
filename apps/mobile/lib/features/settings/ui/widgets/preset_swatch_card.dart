import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';

/// The preset's name in the active language.
String presetLabel(AppLocalizations l10n, BhPreset preset) => switch (preset) {
  BhPreset.teal => l10n.presetTeal,
  BhPreset.padma => l10n.presetPadma,
  BhPreset.jamdani => l10n.presetJamdani,
  BhPreset.shapla => l10n.presetShapla,
  BhPreset.slate => l10n.presetSlate,
};

/// A mini preview of one preset in the current brightness (5.4): a 40 dp
/// band in its `primary`, then on its `surface` a `primaryContainer`
/// square, an `onSurface` bar and the three status dots (to show they stay
/// the same), and the name. Selected: 3 dp border in the current theme's
/// `primary` and a check in `accent` on the band.
class PresetSwatchCard extends StatelessWidget {
  const PresetSwatchCard({
    required this.preset,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final BhPreset preset;
  final bool selected;
  final VoidCallback onTap;

  static const height = 112.0;

  @override
  Widget build(BuildContext context) {
    final current = context.palette;
    final p = BhPalette.of(preset, current.brightness);
    final label = presetLabel(context.l10n, preset);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: p.surface,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: height,
              foregroundDecoration: BoxDecoration(
                border: Border.all(
                  color: selected ? current.primary : current.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 40,
                    color: p.primary,
                    alignment: AlignmentDirectional.topEnd,
                    padding: const EdgeInsets.all(BhSpace.xs),
                    child: selected
                        ? Container(
                            color: current.surface,
                            child: Icon(
                              Icons.check,
                              size: 24,
                              color: current.accent,
                            ),
                          )
                        : null,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        BhSpace.s,
                        BhSpace.s,
                        BhSpace.s,
                        BhSpace.xs,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                color: p.primaryContainer,
                              ),
                              const SizedBox(width: BhSpace.s),
                              Flexible(
                                child: Container(
                                  width: 64,
                                  height: 8,
                                  color: p.onSurface,
                                ),
                              ),
                              const Spacer(),
                              for (final c in [p.danger, p.warning, p.success])
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    start: 2,
                                  ),
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    color: c,
                                  ),
                                ),
                            ],
                          ),
                          const Spacer(),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              label,
                              maxLines: 1,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: p.onSurface),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
