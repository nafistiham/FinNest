/// The staff Fraud desk: two tabs under the persistent
/// "স্টাফ ভিউ · ডেমো" tag, the Case Zero watch-list and the investigations
/// this phone opened, with the bottom bar's primary "কনসোল খুলুন" beside
/// the Apa square. Masked ids only; nothing here reaches a customer screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dates.dart';
import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/router.dart' show Routes;
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/skeleton.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/sheet_header.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/providers.dart';
import '../../../data/repos/case_link_repo.dart';
import '../../send_money/logic/risk_providers.dart' show clockProvider;
import '../logic/fraud_desk_format.dart';
import '../logic/fraud_desk_providers.dart';
import 'case_screen.dart';
import 'widgets/console_button.dart';
import 'widgets/staff_tag.dart';

export 'widgets/console_button.dart' show UrlOpener, externalBrowser;

/// Opens the case screen of `caseId`.
typedef CaseOpener = void Function(BuildContext context, String caseId);

class FraudDeskScreen extends ConsumerWidget {
  const FraudDeskScreen({
    this.consoleUrl = AppEnv.consoleUrl,
    this.open = externalBrowser,
    this.initialTab = 0,
    this.openCase,
    super.key,
  });

  final String consoleUrl;

  /// Injectable for tests (url_launcher has no channel under `flutter test`).
  final UrlOpener open;

  /// 0 = watch-list, 1 = investigations.
  final int initialTab;

  /// `null`: push `/fraud-desk/case/<id>` when a router is above, else a
  /// plain route with this screen's console settings.
  final CaseOpener? openCase;

  static const tabWatchList = Key('fraud_desk_tab_watch');
  static const tabCases = Key('fraud_desk_tab_cases');

  void _openCase(BuildContext context, String caseId) {
    if (openCase != null) return openCase!(context, caseId);
    if (GoRouter.maybeOf(context) != null) {
      context.push(Routes.fraudDeskCase(caseId));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CaseScreen(caseId: caseId, consoleUrl: consoleUrl, open: open),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: BhSize.appBar,
          title: Text(l10n.fraudDesk),
          bottom: TabBar(
            tabs: [
              Tab(key: tabWatchList, text: l10n.fraudDeskTabWatchList),
              Tab(key: tabCases, text: l10n.fraudDeskTabCases),
            ],
          ),
        ),
        bottomNavigationBar: BhBottomBar(
          apaScreen: 'fraud_desk',
          primary: ConsoleButton(url: consoleUrl, open: open),
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  BhSpace.m,
                  BhSpace.s,
                  BhSpace.m,
                  0,
                ),
                child: StaffTag(),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _WatchListTab(openCase: _openCase),
                    _CasesTab(openCase: _openCase),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Watch-list -------------------------------------------------------------

class _WatchListTab extends ConsumerWidget {
  const _WatchListTab({required this.openCase});

  final CaseOpener openCase;

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    PayeeRiskEntry entry,
  ) async {
    final caseId = entry.caseId;
    if (caseId == null) return;
    final uid = ref.read(fraudDeskUidProvider);
    final repo = ref.read(caseLinkRepoProvider);
    final known = (await repo.all(uid)).any((l) => l.caseId == caseId);
    if (!known) {
      await repo.upsert(
        uid,
        // Not started here: shown on the desk, never a customer's review.
        CaseLink(
          caseId: caseId,
          acctId: entry.acctId,
          openedAt: ref.read(clockProvider).now(),
          adopted: true,
        ),
      );
    }
    if (context.mounted) openCase(context, caseId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final list = ref.watch(watchListProvider);
    return switch (list) {
      AsyncData(:final value) when value.payees.isEmpty => ListView(
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
        children: [
          EmptyState(
            key: const Key('watch_list_empty'),
            icon: Icons.visibility_outlined,
            title: l10n.fraudDeskWatchListEmpty,
            body: l10n.fraudDeskWatchListEmptyBody,
          ),
        ],
      ),
      AsyncData(:final value) => RefreshIndicator(
        onRefresh: () => ref.refresh(watchListProvider.future),
        child: ListView.separated(
          key: const Key('watch_list'),
          padding: const EdgeInsets.only(top: BhSpace.s, bottom: BhSpace.l),
          itemCount: value.payees.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final entry = value.payees[i];
            return _PayeeRow(
              entry: entry,
              onTap: entry.caseId == null
                  ? null
                  : () => _open(context, ref, entry),
            );
          },
        ),
      ),
      AsyncError() => ListView(
        padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
        children: [
          EmptyState(
            key: const Key('watch_list_error'),
            icon: Icons.cloud_off_outlined,
            title: l10n.fraudDeskWatchListError,
            actionLabel: l10n.fraudDeskRetry,
            onAction: () => ref.invalidate(watchListProvider),
          ),
        ],
      ),
      _ => ListView(
        key: const Key('watch_list_loading'),
        padding: const EdgeInsets.all(BhSpace.m),
        children: const [SkeletonRow(), SkeletonRow(), SkeletonRow()],
      ),
    };
  }
}

class _PayeeRow extends StatelessWidget {
  const _PayeeRow({required this.entry, required this.onTap});

  final PayeeRiskEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final status = payeeStatusOf(l10n, entry.status);
    final masked = context.digits(maskId(entry.acctId));
    return Material(
      key: Key('payee_${entry.acctId}'),
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: BhSize.rowHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: BhSpace.m,
            vertical: 12,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusTag.header(
                      title: Semantics(
                        label: l10n.fraudDeskAccount(masked),
                        child: ExcludeSemantics(
                          child: Text(masked, style: text.titleMedium),
                        ),
                      ),
                      tag: StatusTag(label: status.label, status: status.tone),
                    ),
                    Text(
                      roleLabel(l10n, entry.role),
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                    if (entry.analystApproved)
                      Row(
                        key: Key('approved_${entry.acctId}'),
                        children: [
                          Icon(
                            Icons.verified_outlined,
                            size: 16,
                            color: p.statusText(BhStatus.success),
                          ),
                          const SizedBox(width: BhSpace.xs),
                          Flexible(
                            child: Text(
                              l10n.fraudDeskAnalystApproved,
                              style: text.bodySmall?.copyWith(
                                color: p.statusText(BhStatus.success),
                              ),
                            ),
                          ),
                        ],
                      ),
                    // The row's own facts, at most two, ids masked; the
                    // server writes them in English, so they keep their
                    // language behind a "তথ্য:" label.
                    for (final (i, fact) in factsFor(entry).indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: BhSpace.xs),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${l10n.fraudDeskFactPrefix} ',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: maskFactText(
                                  fact,
                                  bangla: context.banglaDigits,
                                ),
                              ),
                            ],
                          ),
                          key: Key('fact_${entry.acctId}_$i'),
                          style: text.labelSmall?.copyWith(color: p.mutedText),
                        ),
                      ),
                    if (entry.caseId == null)
                      Padding(
                        padding: const EdgeInsets.only(top: BhSpace.xs),
                        child: Text(
                          l10n.fraudDeskNoCase,
                          style: text.bodySmall?.copyWith(color: p.mutedText),
                        ),
                      ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: BhSpace.s),
                Icon(Icons.chevron_right, color: p.mutedText),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// --- Investigations ---------------------------------------------------------

class _CasesTab extends ConsumerWidget {
  const _CasesTab({required this.openCase});

  final CaseOpener openCase;

  static const startKey = Key('start_case');

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final uid = ref.read(fraudDeskUidProvider);
    final acct = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => _StartPicker(uid: uid),
    );
    if (acct == null || !context.mounted) return;
    final outcome = await ref.read(startCaseProvider.notifier).start(uid, acct);
    if (!context.mounted) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    switch (outcome) {
      case StartedCase(:final link):
        messenger.showSnackBar(SnackBar(content: Text(l10n.fraudDeskStarted)));
        openCase(context, link.caseId);
      case StartBlocked():
        messenger.showSnackBar(SnackBar(content: Text(l10n.fraudDeskCooldown)));
      case StartFailed():
        messenger.showSnackBar(
          SnackBar(
            key: const Key('start_failed'),
            content: Text(
              '${l10n.fraudDeskStartFailed} ${l10n.czReviewerLine}',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final uid = ref.watch(fraudDeskUidProvider);
    final links = ref.watch(caseLinksProvider(uid)).value ?? const [];
    final busy = ref.watch(startCaseProvider).isNotEmpty;
    return ListView(
      key: const Key('cases_list'),
      padding: const EdgeInsets.only(top: BhSpace.m, bottom: BhSpace.l),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
          child: BhButton(
            key: startKey,
            label: l10n.fraudDeskStartCase,
            icon: Icons.manage_search,
            variant: BhButtonVariant.outlined,
            loading: busy,
            onPressed: () => _pick(context, ref),
          ),
        ),
        const SizedBox(height: BhSpace.s),
        if (links.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: EmptyState(
              key: const Key('cases_empty'),
              icon: Icons.folder_open_outlined,
              title: l10n.fraudDeskCasesEmpty,
              body: l10n.fraudDeskCasesEmptyBody,
            ),
          )
        else
          for (final (i, link) in links.indexed) ...[
            if (i > 0) const Divider(height: 1),
            _CaseRow(link: link, onTap: () => openCase(context, link.caseId)),
          ],
      ],
    );
  }
}

class _CaseRow extends ConsumerWidget {
  const _CaseRow({required this.link, required this.onTap});

  final CaseLink link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final status = caseStatusOf(l10n, link.lastStatus);
    final masked = context.digits(maskId(link.acctId));
    final opened = BhDates.rowLabel(
      link.openedAt,
      Localizations.localeOf(context),
      now: ref.read(clockProvider).now(),
    );
    return Material(
      key: Key('case_${link.caseId}'),
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: BhSize.rowHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: BhSpace.m,
            vertical: 12,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusTag.header(
                      title: Semantics(
                        label: l10n.fraudDeskAccount(masked),
                        child: ExcludeSemantics(
                          child: Text(masked, style: text.titleMedium),
                        ),
                      ),
                      tag: StatusTag(label: status.label, status: status.tone),
                    ),
                    Text(
                      l10n.fraudDeskOpenedAt(opened),
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                    if ((link.lastStatus == CaseStatus.done ||
                            link.lastStatus == CaseStatus.degraded) &&
                        link.lastAction.isNotEmpty)
                      Text(
                        l10n.czRecommendation(
                          actionLabel(
                            l10n,
                            CaseAction.fromWire(link.lastAction),
                          ),
                        ),
                        style: text.bodySmall,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: BhSpace.s),
              Icon(Icons.chevron_right, color: p.mutedText),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "তদন্ত শুরু করুন" picker: watch-list payees without an open case;
/// those inside the 30-minute window are listed disabled with the reason.
class _StartPicker extends ConsumerWidget {
  const _StartPicker({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final links = ref.watch(caseLinksProvider(uid)).value ?? const [];
    final now = ref.read(clockProvider).now();
    final payees = ref.watch(watchListProvider).value?.payees ?? const [];
    final rows = [
      for (final e in payees)
        if (startBlockFor(e.acctId, links, now) != StartBlock.openCase)
          (entry: e, block: startBlockFor(e.acctId, links, now)),
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              title: l10n.fraudDeskPickTitle,
              icon: Icons.manage_search,
            ),
            Flexible(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(BhSpace.m),
                      child: EmptyState(
                        key: const Key('picker_empty'),
                        inline: true,
                        icon: Icons.check_circle_outline,
                        title: l10n.fraudDeskPickEmpty,
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final r in rows)
                          InkWell(
                            key: Key('pick_${r.entry.acctId}'),
                            onTap: r.block == null
                                ? () =>
                                      Navigator.of(context).pop(r.entry.acctId)
                                : null,
                            child: Container(
                              constraints: const BoxConstraints(
                                minHeight: BhSize.touch,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: BhSpace.m,
                                vertical: BhSpace.s,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${context.digits(maskId(r.entry.acctId))}'
                                    ' · ${roleLabel(l10n, r.entry.role)}',
                                    style: text.titleSmall?.copyWith(
                                      color: r.block == null
                                          ? null
                                          : p.mutedText,
                                    ),
                                  ),
                                  if (r.block != null)
                                    Text(
                                      l10n.fraudDeskCooldown,
                                      style: text.bodySmall?.copyWith(
                                        color: p.mutedText,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: BhSpace.m),
          ],
        ),
      ),
    );
  }
}
