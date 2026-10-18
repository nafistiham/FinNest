import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/animated/pressable.dart';
import '../../../../app/widgets/settings_row.dart';
import '../../logic/findings_view.dart';

/// Search, filter chips and sort between the verdict header and the findings
/// list: a 56 dp search field, a horizontally scrolling 44 dp chip row (32 dp
/// chips, 8 dp apart: severity single-select, then the categories present,
/// multi-select) and the 56 dp sort segments.
class FindingsControls extends StatelessWidget {
  const FindingsControls({
    required this.query,
    required this.categories,
    required this.searchController,
    required this.onChanged,
    super.key,
  });

  final FindingsQuery query;

  /// Categories present in the response (chip order).
  final List<FindingCategory> categories;
  final TextEditingController searchController;
  final ValueChanged<FindingsQuery> onChanged;

  static const searchKey = Key('safety_search');
  static const searchClearKey = Key('safety_search_clear');
  static const filtersKey = Key('safety_filters');
  static const sortKey = Key('safety_sort');

  static Key severityChipKey(SeverityFilter s) =>
      ValueKey('safety_filter_${s.name}');
  static Key categoryChipKey(FindingCategory c) =>
      ValueKey('safety_category_${c.name}');
  static Key sortSegmentKey(FindingSort s) => ValueKey('safety_sort_${s.name}');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: searchKey,
          controller: searchController,
          textInputAction: TextInputAction.search,
          onChanged: (v) => onChanged(query.copyWith(text: v)),
          decoration: InputDecoration(
            hintText: l10n.safetySearchHint,
            prefixIcon: Icon(Icons.search, color: p.mutedText),
            suffixIcon: query.text.isEmpty
                ? null
                : IconButton(
                    key: searchClearKey,
                    tooltip: l10n.safetySearchClear,
                    constraints: const BoxConstraints(
                      minWidth: BhSize.touch,
                      minHeight: BhSize.touch,
                    ),
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      searchController.clear();
                      onChanged(query.copyWith(text: ''));
                    },
                  ),
          ),
        ),
        const SizedBox(height: BhSpace.s),
        Semantics(
          container: true,
          label: l10n.safetyFiltersLabel,
          child: SingleChildScrollView(
            key: filtersKey,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in SeverityFilter.values) ...[
                  if (s != SeverityFilter.values.first)
                    const SizedBox(width: BhSpace.s),
                  FilterChipButton(
                    key: severityChipKey(s),
                    label: _severityLabel(l10n, s),
                    selected: query.severity == s,
                    dot: _severityStatus(s),
                    onTap: () => onChanged(query.copyWith(severity: s)),
                  ),
                ],
                if (categories.length > 1) ...[
                  Container(
                    width: 1,
                    height: 24,
                    margin: const EdgeInsets.symmetric(horizontal: BhSpace.s),
                    color: p.outlineVariant,
                  ),
                  for (final (i, c) in categories.indexed) ...[
                    if (i > 0) const SizedBox(width: BhSpace.s),
                    FilterChipButton(
                      key: categoryChipKey(c),
                      label: categoryLabel(l10n, c),
                      selected: query.categories.contains(c),
                      onTap: () => onChanged(query.toggle(c)),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: BhSpace.s),
        Semantics(
          container: true,
          label: l10n.safetySortLabel,
          child: BhSegmented<FindingSort>(
            key: sortKey,
            selected: query.sort,
            onChanged: (s) => onChanged(query.copyWith(sort: s)),
            segments: [
              BhSegment(
                value: FindingSort.severity,
                label: l10n.safetySortSeverity,
                key: sortSegmentKey(FindingSort.severity),
              ),
              BhSegment(
                value: FindingSort.name,
                label: l10n.safetySortName,
                key: sortSegmentKey(FindingSort.name),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _severityLabel(AppLocalizations l10n, SeverityFilter s) =>
      switch (s) {
        SeverityFilter.all => l10n.safetyFilterAll,
        SeverityFilter.danger => l10n.safetyFilterDanger,
        SeverityFilter.caution => l10n.safetyFilterCaution,
        SeverityFilter.info => l10n.safetyFilterInfo,
      };

  static BhStatus? _severityStatus(SeverityFilter s) => switch (s) {
    SeverityFilter.all => null,
    SeverityFilter.danger => BhStatus.danger,
    SeverityFilter.caution => BhStatus.warning,
    SeverityFilter.info => BhStatus.neutral,
  };

  static String categoryLabel(AppLocalizations l10n, FindingCategory c) =>
      switch (c) {
        FindingCategory.permissions => l10n.safetyCategoryPermissions,
        FindingCategory.accessibility => l10n.safetyCategoryAccessibility,
        FindingCategory.screen => l10n.safetyCategoryScreen,
        FindingCategory.unknownApps => l10n.safetyCategoryUnknownApps,
        FindingCategory.phone => l10n.safetyCategoryPhone,
        FindingCategory.other => l10n.safetyCategoryOther,
      };
}

/// A 32 dp square chip in a 44 dp hit area: selected = `primaryContainer`
/// fill with a 1 dp `primary` edge, else a 1 dp `outline` hairline. [dot] is
/// an 8 dp status square before the label (severity chips only); status
/// colours never fill the chip.
class FilterChipButton extends StatelessWidget {
  const FilterChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final BhStatus? dot;

  static const height = 32.0;
  static const hitHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final d = dot;
    return Pressable(
      selected: selected,
      semanticLabel: label,
      onTap: onTap,
      child: SizedBox(
        height: hitHeight,
        child: Center(
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? p.primaryContainer : Colors.transparent,
              border: Border.all(color: selected ? p.primary : p.outline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (d != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    color: d == BhStatus.neutral
                        ? p.mutedText
                        : p.statusFill(d),
                  ),
                  const SizedBox(width: BhSpace.s),
                ],
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: text.labelSmall?.copyWith(
                    color: selected ? p.onPrimaryContainer : p.onSurface,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
