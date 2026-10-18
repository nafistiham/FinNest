/// One Case Zero investigation, staff view: the
/// header, the agent's recommendation (labelled as one), the model score,
/// the summary with a language toggle, the evidence and the masked ring.
/// Polled every 2 s while queued or running and every 10 s otherwise, only
/// while this route is on top and the app is in the foreground.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dates.dart';
import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/router.dart' show routeObserverProvider;
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/skeleton.dart';
import '../../../app/widgets/animated/status_pulse.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/demo_note.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../core/log.dart';
import '../../../data/api/api_failure.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/providers.dart';
import '../../../data/repos/case_link_repo.dart';
import '../../send_money/logic/risk_providers.dart' show clockProvider;
import '../logic/fraud_desk_format.dart';
import '../logic/fraud_desk_providers.dart';
import 'widgets/console_button.dart';
import 'widgets/staff_tag.dart';

class CaseScreen extends ConsumerStatefulWidget {
  const CaseScreen({
    required this.caseId,
    this.consoleUrl = AppEnv.consoleUrl,
    this.open = externalBrowser,
    super.key,
  });

  final String caseId;
  final String consoleUrl;
  final UrlOpener open;

  @override
  ConsumerState<CaseScreen> createState() => _CaseScreenState();
}

class _CaseScreenState extends ConsumerState<CaseScreen>
    with WidgetsBindingObserver, RouteAware {
  static const _tag = 'fraud_desk';

  CaseReport? _report;
  bool _stale = false;
  bool _refreshFailed = false;
  bool _inFlight = false;
  bool _foreground = true;
  bool _visible = true;
  bool _showOther = false;
  Timer? _timer;
  RouteObserver<ModalRoute<void>>? _observer;
  late final String _uid = ref.read(fraudDeskUidProvider);

  bool get _active => _foreground && _visible && !_stale && mounted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed => true,
      _ => false,
    };
    unawaited(_fetch());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_observer == null && route != null) {
      final observer = ref.read(routeObserverProvider);
      observer.subscribe(this, route);
      _observer = observer;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _observer?.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      unawaited(_fetch());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void didPushNext() {
    _visible = false;
    _timer?.cancel();
  }

  @override
  void didPopNext() {
    _visible = true;
    unawaited(_fetch());
  }

  void _schedule() {
    _timer?.cancel();
    if (!_active) return;
    _timer = Timer(pollDelayFor(_report?.status), () => unawaited(_fetch()));
  }

  Future<void> _fetch() async {
    _timer?.cancel();
    if (!_active || _inFlight) return;
    _inFlight = true;
    final repo = ref.read(caseLinkRepoProvider);
    try {
      final report = await ref.read(caseDeskApiProvider).getCase(widget.caseId);
      if (!mounted) return;
      setState(() {
        _report = report;
        _refreshFailed = false;
      });
      final link = await _linkOf(repo);
      await repo.upsert(
        _uid,
        (link ??
                // A case this phone holds no link for was not started here.
                CaseLink(
                  caseId: widget.caseId,
                  acctId: report.acctId,
                  openedAt: ref.read(clockProvider).now(),
                  adopted: true,
                ))
            .withReport(report),
      );
    } on CaseNotFound {
      if (!mounted) return;
      setState(() => _stale = true);
      // A case the server forgot is never "under review" for the customer.
      final link = await _linkOf(repo);
      if (link != null) {
        await repo.upsert(_uid, link.withStatus(CaseStatus.failed));
      }
    } on Object catch (e) {
      Log.w(_tag, 'case refresh failed', e);
      if (mounted) setState(() => _refreshFailed = true);
    } finally {
      _inFlight = false;
      if (mounted) _schedule();
    }
  }

  Future<CaseLink?> _linkOf(CaseLinkRepo repo) async {
    for (final l in await repo.all(_uid)) {
      if (l.caseId == widget.caseId) return l;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final report = _report;
    final link = ref
        .watch(caseLinksProvider(_uid))
        .value
        ?.where((l) => l.caseId == widget.caseId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: BhSize.appBar,
        title: Text(l10n.czCaseTitle),
      ),
      bottomNavigationBar: BhBottomBar(
        apaScreen: 'fraud_desk',
        primary: ConsoleButton(url: widget.consoleUrl, open: widget.open),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          key: const Key('case_body'),
          padding: const EdgeInsets.fromLTRB(
            BhSpace.m,
            BhSpace.s,
            BhSpace.m,
            BhSpace.l,
          ),
          children: [
            const Align(alignment: Alignment.centerLeft, child: StaffTag()),
            const SizedBox(height: BhSpace.m),
            if (_stale)
              _Notice(
                key: const Key('case_stale'),
                title: l10n.czStale,
                body: l10n.czReviewerLine,
              )
            else if (report == null)
              ..._loading()
            else
              ..._content(context, report, link),
            if (_refreshFailed && !_stale) ...[
              const SizedBox(height: BhSpace.m),
              Text(
                l10n.czRefreshFailed,
                key: const Key('case_refresh_failed'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.palette.mutedText),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _loading() => const [
    Skeleton(width: 160, height: 28),
    SizedBox(height: BhSpace.m),
    Skeleton(height: 96),
    SizedBox(height: BhSpace.m),
    Skeleton(height: 120),
  ];

  List<Widget> _content(
    BuildContext context,
    CaseReport report,
    CaseLink? link,
  ) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context);
    final status = caseStatusOf(l10n, report.status);
    final running = !report.status.isTerminal;
    final approved =
        ref
            .watch(watchListProvider)
            .value
            ?.entryFor(link?.acctId ?? report.acctId)
            ?.analystApproved ??
        false;
    // The summary as staff should read it: ids
    // masked, transfer ids moved to the evidence list, readable times.
    final phones = ref.watch(knownPhonesProvider).value ?? const {};
    final now = ref.read(clockProvider).now();
    final bn = maskCaseText(
      report.summaryBn,
      bangla: true,
      phones: phones,
      now: now,
    );
    final en = maskCaseText(
      report.summaryEn,
      bangla: false,
      phones: phones,
      now: now,
    );
    final summaryPrimary = context.serverText(bn, en);
    final summaryOther = context.banglaDigits ? en : bn;
    final evidenceIds = {for (final e in report.evidence) e.rowId};
    final cited = [
      for (final id in citedTxnIds([report.summaryBn, report.summaryEn]))
        if (!evidenceIds.contains(id)) id,
    ];
    final watch = ref.watch(watchListProvider).value;
    final opened = link?.openedAt;
    return [
      // Header: masked account, status, opened time, model version.
      StatusTag.header(
        key: const Key('case_header'),
        title: Text(
          context.digits(maskId(report.acctId)),
          style: text.titleLarge,
        ),
        tag: StatusTag(label: status.label, status: status.tone),
      ),
      if (opened != null)
        Text(
          l10n.fraudDeskOpenedAt(
            BhDates.rowLabel(
              opened,
              locale,
              now: ref.read(clockProvider).now(),
            ),
          ),
          style: text.bodySmall?.copyWith(color: p.mutedText),
        ),
      Text(
        l10n.czModelVersion(report.modelVersion),
        key: const Key('case_model_version'),
        style: text.labelSmall?.copyWith(color: p.mutedText),
      ),
      const SizedBox(height: BhSpace.m),
      if (report.isStubFallback) ...[
        DemoNote(l10n.czStubFallback, icon: Icons.info_outline),
        const SizedBox(height: BhSpace.m),
      ],
      if (report.status == CaseStatus.failed)
        _Notice(
          key: const Key('case_failed'),
          title: l10n.czFailed,
          body: l10n.czReviewerLine,
        )
      else if (running)
        Row(
          key: const Key('case_running'),
          children: [
            const StatusPulse(status: BhStatus.info, active: true),
            const SizedBox(width: BhSpace.s),
            Expanded(child: Text(l10n.czRunningLine, style: text.bodyMedium)),
          ],
        )
      else ...[
        _RecommendationCard(report: report, approved: approved),
        const SizedBox(height: BhSpace.l),
        _Heading(l10n.czSummary),
        Text(
          _showOther ? summaryOther : summaryPrimary,
          key: const Key('case_summary'),
          style: text.bodyMedium,
        ),
        if (summaryOther.trim().isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            // On the 16 dp text gutter: no inner padding.
            child: TextButton(
              key: const Key('case_summary_toggle'),
              style: TextButton.styleFrom(
                minimumSize: const Size(BhSize.touch, BhSize.touch),
                padding: EdgeInsets.zero,
                alignment: AlignmentDirectional.centerStart,
              ),
              onPressed: () => setState(() => _showOther = !_showOther),
              child: Text(
                _showOther ? l10n.czShowAppLanguage : l10n.czShowOtherLanguage,
              ),
            ),
          ),
        const SizedBox(height: BhSpace.m),
        // A zero count reads as a finding, not a number.
        Text(
          report.evidence.isEmpty
              ? l10n.czCountsNoEvidence(context.digits('${report.ring.length}'))
              : l10n.czCounts(
                  context.digits('${report.evidence.length}'),
                  context.digits('${report.ring.length}'),
                ),
          key: const Key('case_counts'),
          style: text.titleSmall,
        ),
        if (report.evidence.isNotEmpty || cited.isNotEmpty) ...[
          const SizedBox(height: BhSpace.l),
          _Heading(l10n.czEvidence),
          for (final e in report.evidence)
            Padding(
              padding: const EdgeInsets.only(bottom: BhSpace.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.digits(maskId(e.rowId)),
                    style: text.labelSmall?.copyWith(color: p.mutedText),
                  ),
                  Text(e.claim, style: text.bodyMedium),
                ],
              ),
            ),
          // The transfers the summary named, out of its prose.
          if (cited.isNotEmpty)
            Padding(
              key: const Key('case_cited'),
              padding: const EdgeInsets.only(bottom: BhSpace.m),
              child: Text(
                '${l10n.czCitedTxns}: '
                '${cited.map((id) => context.digits(maskId(id))).join(', ')}',
                style: text.labelSmall?.copyWith(color: p.mutedText),
              ),
            ),
        ],
        if (report.ring.isNotEmpty) ...[
          const SizedBox(height: BhSpace.m),
          _Heading(l10n.czRing),
          // Plain left-aligned rows with the role, not button-like chips.
          Column(
            key: const Key('case_ring'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final id in report.ring)
                Container(
                  key: Key('ring_$id'),
                  constraints: const BoxConstraints(minHeight: BhSize.touch),
                  alignment: AlignmentDirectional.centerStart,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.outlineVariant)),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: BhSpace.s),
                  child: Row(
                    children: [
                      Text(context.digits(maskId(id)), style: text.titleSmall),
                      const SizedBox(width: BhSpace.m),
                      Expanded(
                        child: Text(
                          roleLabel(l10n, watch?.entryFor(id)?.role ?? ''),
                          style: text.bodySmall?.copyWith(color: p.mutedText),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    ];
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.report, required this.approved});

  final CaseReport report;
  final bool approved;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final score = (report.confidence.clamp(0.0, 1.0) * 100).round();
    return Container(
      key: const Key('case_recommendation'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: p.surfaceVariant,
        border: BorderDirectional(
          start: BorderSide(color: p.primary, width: BhSize.stripe),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m - BhSize.stripe + BhSpace.xs,
        BhSpace.m,
        BhSpace.m,
        BhSpace.m,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.czRecommendation(actionLabel(l10n, report.action)),
            style: text.titleMedium,
          ),
          const SizedBox(height: BhSpace.xs),
          Text(
            approved ? l10n.fraudDeskAnalystApproved : l10n.czPendingApproval,
            key: const Key('case_approval'),
            style: text.bodySmall?.copyWith(
              color: approved ? p.statusText(BhStatus.success) : p.mutedText,
            ),
          ),
          const SizedBox(height: BhSpace.s),
          Text(
            l10n.czModelScore(context.digits('$score')),
            key: const Key('case_score'),
            style: text.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: BhSpace.s),
    child: Semantics(
      header: true,
      child: Text(label, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

/// A neutral strip with a title and the reviewer line.
class _Notice extends StatelessWidget {
  const _Notice({required this.title, required this.body, super.key});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      color: p.surfaceVariant,
      padding: const EdgeInsets.all(BhSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          const SizedBox(height: BhSpace.xs),
          Text(body, style: text.bodyMedium?.copyWith(color: p.mutedText)),
        ],
      ),
    );
  }
}
