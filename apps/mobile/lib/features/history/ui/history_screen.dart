/// History (`/history`): every ledger row of the
/// signed-in user grouped by day under sticky day headers, a row of type
/// filters, a detail sheet per row, and Apa in the bottom bar.
///
/// Router: `HistoryScreen(highlightTxnId: q['txn'])`, or
/// [HistoryScreen.fromQuery] to also honour `?filter=` (a [HistoryFilter.id]).
/// `?txn=` opens that row's detail sheet (Home's recent rows link here).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n.dart';
import '../../../app/motion/motion_specs.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/pressable.dart';
import '../../../app/widgets/animated/sheet_reveal.dart';
import '../../../app/widgets/animated/skeleton.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/txn_row.dart';
import '../../../core/haptics.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../send_money/logic/risk_providers.dart' show clockProvider;
import '../logic/history_providers.dart';
import 'widgets/txn_detail_sheet.dart';

/// Row divider inset (4.3): 16 + 48 + 16.
const historyDividerInset = BhSpace.m + BhSize.avatar + BhSpace.m;

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({
    this.initialFilter = HistoryFilter.all,
    this.highlightTxnId,
    this.now,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  /// From the route's query parameters (`filter`, `txn`).
  factory HistoryScreen.fromQuery(Map<String, String> q) => HistoryScreen(
    initialFilter: HistoryFilter.parse(q['filter']),
    highlightTxnId: q['txn'],
  );

  final HistoryFilter initialFilter;

  /// Row whose detail sheet opens once the list has loaded.
  final String? highlightTxnId;

  /// "Today" for the day headers and rows; null = `clockProvider`.
  final DateTime? now;

  /// `key()` on a filter chip tap.
  final Haptics haptics;

  static const filterKeyPrefix = 'history_filter_';

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  late HistoryFilter _filter = widget.initialFilter;
  bool _opened = false;

  /// The list's first paint rises in (6.2); every later build is settled.
  bool _revealed = false;

  void _maybeOpen(List<LedgerTxn> rows, String acctId) {
    final id = widget.highlightTxnId;
    if (_opened || id == null) return;
    final t = rows.where((r) => r.txnId == id).firstOrNull;
    if (t == null) return;
    _opened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final namesEn = ref.read(payeeNamesEnProvider);
      TxnDetailSheet.show(
        context,
        txn: t,
        acctId: acctId,
        nameEn: englishNameFor(t, acctId, namesEn),
        fromName: senderNameFor(
          t,
          acctId,
          namesBn: ref.read(payeeNamesBnProvider),
          namesEn: namesEn,
          english: !context.banglaDigits,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final user = ref.watch(currentUserProvider).value;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: BhSize.appBar,
        title: Text(l10n.historyTitle),
      ),
      // Filled tonal, the same FNA bar as Home.
      bottomNavigationBar: const BhBottomBar.apa(apaScreen: 'history'),
      // No user yet: the list's shape as skeletons, never a spinner.
      body: user == null
          ? Semantics(
              key: const Key('history_loading'),
              label: l10n.loadingList,
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
                children: const [
                  SkeletonRow(),
                  SkeletonRow(),
                  SkeletonRow(),
                  SkeletonRow(),
                  SkeletonRow(),
                ],
              ),
            )
          : _body(context, user),
    );
  }

  Widget _body(BuildContext context, UserProfile user) {
    final l10n = context.l10n;
    final rows = ref.watch(historyTxnsProvider(user.uid));
    final locale = Localizations.localeOf(context);
    // One "now" per build for the headers and the rows (injected clock).
    final now = widget.now ?? ref.watch(clockProvider).now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FilterRow(
          selected: _filter,
          onSelected: (f) {
            // A chip tap is a key press, like the Settings segments (6.3).
            unawaited(widget.haptics.key());
            setState(() => _filter = f);
          },
        ),
        Expanded(
          child: switch (rows) {
            AsyncData(:final value) => () {
              _maybeOpen(value, user.acctId);
              if (value.isEmpty) {
                return EmptyState(
                  key: const Key('history_empty'),
                  icon: Icons.receipt_long,
                  title: l10n.noRecentTransactions,
                  body: l10n.historyEmptyBody,
                );
              }
              final shown = value
                  .where((t) => _filter.matches(t, user.acctId))
                  .toList();
              if (shown.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.all(BhSpace.m),
                  children: [
                    EmptyState(
                      key: const Key('history_empty_filter'),
                      icon: Icons.filter_alt_off_outlined,
                      title: l10n.historyEmptyFilter,
                      body: l10n.historyEmptyFilterBody,
                      inline: true,
                    ),
                  ],
                );
              }
              final reveal = !_revealed;
              if (reveal) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _revealed = true;
                });
              }
              return _DayList(
                days: groupByDay(shown, locale, now: now),
                acctId: user.acctId,
                now: now,
                namesEn: ref.watch(payeeNamesEnProvider),
                namesBn: ref.watch(payeeNamesBnProvider),
                reveal: reveal,
              );
            }(),
            AsyncError() => Center(
              child: EmptyState(
                key: const Key('history_failed'),
                icon: Icons.cloud_off,
                title: l10n.recentLoadFailed,
                actionLabel: l10n.retry,
                onAction: () => ref.invalidate(historyTxnsProvider(user.uid)),
              ),
            ),
            // Loading: skeleton rows in the shape of the real ones.
            _ => Semantics(
              key: const Key('history_loading'),
              label: l10n.loadingList,
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
                children: const [
                  SkeletonRow(),
                  SkeletonRow(),
                  SkeletonRow(),
                  SkeletonRow(),
                  SkeletonRow(),
                ],
              ),
            ),
          },
        ),
      ],
    );
  }
}

/// The filter chips: 56 dp square choice tiles, scrolling sideways. 16 dp
/// at both ends inside the scroll view, so the last chip never touches the
/// screen edge, and a 24 dp fade on the trailing edge while more chips sit
/// past it.
class _FilterRow extends StatefulWidget {
  const _FilterRow({required this.selected, required this.onSelected});

  final HistoryFilter selected;
  final ValueChanged<HistoryFilter> onSelected;

  /// Width of the trailing fade.
  static const fade = BhSpace.l;

  static String label(AppLocalizations l10n, HistoryFilter f) => switch (f) {
    HistoryFilter.all => l10n.historyFilterAll,
    HistoryFilter.sent => l10n.historyFilterSent,
    HistoryFilter.cashOut => l10n.historyFilterCashOut,
    HistoryFilter.cashIn => l10n.historyFilterCashIn,
    HistoryFilter.recharge => l10n.historyFilterRecharge,
    HistoryFilter.bill => l10n.historyFilterBill,
    HistoryFilter.received => l10n.historyFilterReceived,
    HistoryFilter.held => l10n.historyFilterHeld,
  };

  @override
  State<_FilterRow> createState() => _FilterRowState();
}

class _FilterRowState extends State<_FilterRow> {
  /// More chips past the trailing edge: show the fade.
  bool _more = true;

  bool _onMetrics(ScrollMetrics m) {
    final more = m.extentAfter > 0.5;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final row = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: SingleChildScrollView(
          key: const Key('history_filter_scroll'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsetsDirectional.fromSTEB(
            BhSpace.m,
            BhSpace.s,
            BhSpace.m,
            BhSpace.s,
          ),
          child: Row(
            children: [
              for (final (i, f) in HistoryFilter.values.indexed) ...[
                if (i > 0) const SizedBox(width: BhSpace.s),
                _Chip(
                  key: Key('${HistoryScreen.filterKeyPrefix}${f.id}'),
                  label: _FilterRow.label(l10n, f),
                  on: f == widget.selected,
                  onTap: () => widget.onSelected(f),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      label: l10n.historyFiltersLabel,
      child: SizedBox(
        height: BhSize.touch + BhSpace.s * 2,
        // Seven chips: built eagerly, scrolled sideways when they overflow.
        child: Stack(
          children: [
            Positioned.fill(child: row),
            PositionedDirectional(
              top: 0,
              bottom: 0,
              end: 0,
              width: _FilterRow.fade,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  key: const Key('history_filter_fade'),
                  opacity: _more ? 1 : 0,
                  duration: BhMotion.of(context).fast,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: rtl
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        end: rtl ? Alignment.centerLeft : Alignment.centerRight,
                        colors: [p.surface.withValues(alpha: 0), p.surface],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One 56 dp square choice chip; the selected one is filled `primary`.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.on,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final motion = BhMotion.of(context);
    return Pressable(
      onTap: onTap,
      selected: on,
      semanticLabel: label,
      child: AnimatedContainer(
        duration: motion.fast,
        curve: BhCurves.release,
        constraints: const BoxConstraints(
          minWidth: BhSize.touch,
          minHeight: BhSize.touch,
        ),
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? p.primary : Colors.transparent,
          border: Border.all(color: on ? p.primary : p.outline),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: text.labelMedium?.copyWith(
            color: on ? p.onPrimary : p.onSurface,
          ),
        ),
      ),
    );
  }
}

class _DayList extends StatelessWidget {
  const _DayList({
    required this.days,
    required this.acctId,
    required this.namesEn,
    required this.reveal,
    this.namesBn = const {},
    this.now,
  });

  final List<HistoryDay> days;
  final String acctId;
  final DateTime? now;
  final Map<String, String> namesEn;

  /// The viewer's Bangla names by account (received rows' senders).
  final Map<String, String> namesBn;

  /// First paint: the first five rows fade in and rise 8 dp, 40 ms apart.
  final bool reveal;

  static const _staggered = 5;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final m = Motion.of(context);
    // Global row index of each day's first row (for the stagger).
    final starts = <int>[];
    var n = 0;
    for (final d in days) {
      starts.add(n);
      n += d.rows.length;
    }
    return CustomScrollView(
      key: const Key('history_list'),
      slivers: [
        for (final (di, day) in days.indexed)
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _DayHeader(day.header, p.surface),
              ),
              SliverList.separated(
                itemCount: day.rows.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  indent: historyDividerInset,
                  endIndent: BhSpace.m,
                  color: p.outlineVariant,
                ),
                itemBuilder: (context, i) {
                  final t = day.rows[i];
                  final nameEn = englishNameFor(t, acctId, namesEn);
                  final fromName = senderNameFor(
                    t,
                    acctId,
                    namesBn: namesBn,
                    namesEn: namesEn,
                    english: !context.banglaDigits,
                  );
                  final Widget row = TxnRow(
                    key: ValueKey('history_row_${t.txnId}'),
                    txn: t,
                    acctId: acctId,
                    now: now,
                    nameEn: nameEn,
                    fromName: fromName,
                    onTap: () => TxnDetailSheet.show(
                      context,
                      txn: t,
                      acctId: acctId,
                      nameEn: nameEn,
                      fromName: fromName,
                    ),
                  );
                  final k = starts[di] + i;
                  if (!reveal || m.reduced || k >= _staggered) return row;
                  return SlideFadeIn(
                    offset: 8,
                    firm: true,
                    delay: m.stagger * k,
                    duration: m.enter,
                    child: row,
                  );
                },
              ),
            ],
          ),
        const SliverToBoxAdapter(child: SizedBox(height: BhSpace.m)),
      ],
    );
  }
}

/// Sticky day header ("আজ", "গতকাল", "১০ নভেম্বর"): the 40 dp section
/// title on the surface colour so rows scroll under it.
class _DayHeader extends SliverPersistentHeaderDelegate {
  _DayHeader(this.title, this.background);

  final String title;
  final Color background;

  static const _height = 48.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final text = Theme.of(context).textTheme;
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
      alignment: Alignment.centerLeft,
      child: Semantics(
        header: true,
        child: Text(
          title,
          key: ValueKey('history_day_$title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.titleMedium?.copyWith(color: context.palette.onSurface),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DayHeader old) =>
      old.title != title || old.background != background;
}
