import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n.dart';
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/pressable.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/section_header.dart';
import '../../../app/widgets/status_tag.dart';
import '../../../data/contracts/contracts.dart';
import '../../send_money/logic/risk_providers.dart';
import '../logic/external_links.dart';
import '../logic/findings_view.dart';
import '../logic/safety_controller.dart';
import 'widgets/finding_cta.dart';
import 'widgets/findings_controls.dart';
import 'widgets/safety_badge.dart';
import 'widgets/verdict_style.dart';

/// Findings screen for US-4. Renders the last
/// `/v1/appsafety/check` response as sent: the verdict card (status row with
/// the "সিমুলেটেড" tag top-right, then `user_message_*`), one card per app
/// with its findings (`title_*`, `explanation_*`; the technical `evidence`
/// behind a collapsed "বিস্তারিত") and, for `uninstall_targets[]`, an inline
/// "আনইনস্টল করুন"; device-scoped findings under "আপনার ফোন" as rows; and the
/// `resolution` as one short ARB line. Only labels keyed by enums and screen
/// chrome come from the ARB.
///
/// The app bar holds only back and the title. The bottom bar holds at most
/// two buttons: the resolution's one action (re-check only when
/// `recheck_lifts_block`; Play Store; call the bank) beside Apa, or, when
/// opened as `/safety?block=1` after a blocked transfer, "হোমে ফিরুন" as the
/// primary with that action above it. That route replaces the whole stack,
/// so the screen is never a dead end.
///
/// With two or more items the list gets search, severity and category chips
/// and a sort (`FindingsControls`), and every finding gets one CTA mapped
/// from its signal (`FindingKinds.actionFor`); tapping a finding opens its
/// full detail in a sheet. The query lives in this screen's state only.
class SafetyScreen extends ConsumerStatefulWidget {
  const SafetyScreen({required this.blocked, super.key});

  final bool blocked;

  /// `Routes.home`. A literal so this feature does not import the router
  /// (which imports every screen of the app).
  static const homeRoute = '/home';

  @override
  ConsumerState<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends ConsumerState<SafetyScreen> {
  /// Search, chips and sort; kept across re-checks (held here, not in the
  /// list, which the loading state replaces).
  FindingsQuery _query = const FindingsQuery();
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Deep-linked here before Home ran the check: start one. Home's own
    // refresh is otherwise the single trigger.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(safetyControllerProvider);
      if (state.value == null && !state.isLoading && !state.hasError) {
        ref.read(safetyControllerProvider.notifier).refresh();
      }
    });
  }

  void _refresh() => ref.read(safetyControllerProvider.notifier).refresh();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(safetyControllerProvider);
    final response = state.value;
    final labels = ref.watch(safetyAppLabelsProvider);
    final failed = state.hasError && !state.isLoading;
    // The blocked transfer's own reasons (server text), under the title.
    final blockReasons = widget.blocked
        ? (ref.watch(lastScoreProvider)?.reasons ?? const <Reason>[])
        : const <Reason>[];

    final Widget body;
    if (failed) {
      body = ListView(
        padding: const EdgeInsets.all(BhSpace.m),
        children: [
          EmptyState(
            key: const Key('safety-error'),
            icon: Icons.cloud_off,
            title: l10n.safetyCheckFailedShort,
            body: l10n.safetyErrorBody,
          ),
        ],
      );
    } else if (response == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(BhSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: BhSpace.m),
              Text(
                l10n.safetyChecking,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      );
    } else {
      final controller = ref.read(safetyControllerProvider.notifier);
      body = _Findings(
        response: response,
        blocked: widget.blocked,
        blockReasons: blockReasons,
        labels: labels,
        query: _query,
        searchController: _search,
        onQuery: (q) => setState(() => _query = q),
        resolutions: ref.watch(findingResolutionsProvider),
        onResolve: controller.resolveFinding,
        onUninstall: controller.openUninstall,
      );
    }

    // The one action of this state (or none).
    final Widget? action = failed
        ? _ActionButton(
            key: const Key('safety-retry'),
            label: l10n.retry,
            icon: Icons.refresh,
            onPressed: _refresh,
            outlined: widget.blocked,
          )
        : response == null
        ? null
        : resolutionAction(
            context,
            response,
            onRecheck: _refresh,
            launch: ref.watch(uriLauncherProvider),
            outlined: widget.blocked,
          );

    final Widget bar;
    if (widget.blocked) {
      bar = BhBottomBar(
        apaScreen: 'safety',
        secondary: action,
        primary: BhButton(
          key: const Key('safety-go-home'),
          label: l10n.goHome,
          icon: Icons.home_outlined,
          onPressed: () => context.go(SafetyScreen.homeRoute),
        ),
      );
    } else if (action != null) {
      bar = BhBottomBar(apaScreen: 'safety', primary: action);
    } else {
      bar = const BhBottomBar.apa(
        apaScreen: 'safety',
        style: ApaBarStyle.secondary,
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: BhSize.appBar,
        title: Text(l10n.safety, key: const Key('safety-title')),
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: bar,
    );
  }

  /// The `resolution`'s one action: re-check (only when the server says a
  /// re-check from this client can lift the verdict), the Play Store, or
  /// the bank's helpline. `null` for NONE, WAIT and anything newer.
  static Widget? resolutionAction(
    BuildContext context,
    AppSafetyResponse response, {
    required VoidCallback onRecheck,
    required UriLauncher launch,
    bool outlined = false,
  }) {
    final l10n = context.l10n;
    switch (response.resolution) {
      case ResolutionCodes.uninstallAndRecheck:
      case ResolutionCodes.fixPhoneAndRecheck:
        // A kept BLOCK must not offer a re-check (recheck_lifts_block).
        if (!response.recheckLiftsBlock) return null;
        return _ActionButton(
          key: const Key('safety-recheck'),
          label: l10n.safetyRecheck,
          icon: Icons.refresh,
          onPressed: onRecheck,
          outlined: outlined,
        );
      case ResolutionCodes.reinstallFromPlay:
        return _ActionButton(
          key: const Key('safety-open-play'),
          label: l10n.safetyOpenPlay,
          icon: Icons.shop,
          onPressed: () => ExternalLinks.openPlayStore(launch),
          outlined: outlined,
        );
      case ResolutionCodes.callBank:
        return _ActionButton(
          key: const Key('safety-call-bank'),
          label: l10n.safetyCallBank,
          icon: Icons.call,
          onPressed: () => ExternalLinks.callBank(launch),
          outlined: outlined,
        );
      default:
        return null;
    }
  }
}

/// Wire values of `AppSafetyResponse.resolution`.
abstract final class ResolutionCodes {
  static const uninstallAndRecheck = 'UNINSTALL_AND_RECHECK';
  static const fixPhoneAndRecheck = 'FIX_PHONE_AND_RECHECK';
  static const reinstallFromPlay = 'REINSTALL_FROM_PLAY';
  static const callBank = 'CALL_BANK';
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.outlined = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) => BhButton(
    label: label,
    icon: icon,
    onPressed: onPressed,
    variant: outlined ? BhButtonVariant.outlined : BhButtonVariant.primary,
  );
}

class _Findings extends StatelessWidget {
  const _Findings({
    required this.response,
    required this.blocked,
    required this.blockReasons,
    required this.labels,
    required this.query,
    required this.searchController,
    required this.onQuery,
    required this.resolutions,
    required this.onResolve,
    required this.onUninstall,
  });

  final AppSafetyResponse response;
  final bool blocked;
  final List<Reason> blockReasons;
  final Map<String, String> labels;
  final FindingsQuery query;
  final TextEditingController searchController;
  final ValueChanged<FindingsQuery> onQuery;
  final FindingResolutions resolutions;
  final void Function(Finding finding) onResolve;
  final void Function(UninstallTarget target) onUninstall;

  /// Search and chips appear from this many listed items on.
  static const controlsFrom = 2;

  static const emptyFilteredKey = Key('safety_empty_filtered');

  /// `uninstall_targets[]`, or the older `apps_to_uninstall[]` when a server
  /// sends only that.
  List<UninstallTarget> get _targets => response.uninstallTargets.isNotEmpty
      ? response.uninstallTargets
      : [
          for (final pkg in response.appsToUninstall)
            UninstallTarget(
              package: pkg,
              label: labels[pkg] ?? '',
              primarySignal: '',
              deepLink: 'package:$pkg',
            ),
        ];

  String? _resolutionLine(AppLocalizations l10n) =>
      switch (response.resolution) {
        ResolutionCodes.uninstallAndRecheck => l10n.safetyUninstallLine,
        ResolutionCodes.fixPhoneAndRecheck => l10n.safetyFixPhoneLine,
        ResolutionCodes.reinstallFromPlay => l10n.safetyReinstallLine,
        ResolutionCodes.callBank => l10n.safetyCallBankLine,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final targets = _targets;
    final view = buildFindingsView(
      findings: response.findings,
      targets: targets,
      labelOf: (pkg) => _label(l10n, pkg, targets),
      titleOf: (f) => f.title(context),
      query: query,
    );
    final listed = {
      for (final f in response.findings) FindingKinds.idOf(f),
      for (final t in targets) 'target_${t.package}',
    }.length;
    final line = _resolutionLine(l10n);

    final items = <Widget>[
      _VerdictHeader(
        response: response,
        blocked: blocked,
        blockReasons: blockReasons,
      ),
      if (line != null)
        Row(
          key: const Key('safety-resolution-line'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.task_alt, size: 24, color: p.primary),
            ),
            const SizedBox(width: BhSpace.s),
            Expanded(child: Text(line, style: text.bodyMedium)),
          ],
        ),
      if (response.findings.isEmpty && targets.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: BhSpace.l),
          child: Column(
            children: [
              Icon(Icons.verified_user, size: 56, color: p.success),
              const SizedBox(height: BhSpace.m),
              Text(
                l10n.safetyNoFindings,
                textAlign: TextAlign.center,
                style: text.bodyLarge,
              ),
            ],
          ),
        ),
      if (listed >= controlsFrom)
        FindingsControls(
          key: const Key('safety_controls'),
          query: query,
          categories: categoriesPresent(response.findings),
          searchController: searchController,
          onChanged: onQuery,
        ),
      if (view.isEmpty && query.narrows)
        EmptyState(
          key: emptyFilteredKey,
          icon: Icons.search_off,
          title: l10n.safetyNothingFound,
          body: l10n.safetyNothingFoundBody,
          actionLabel: l10n.safetyClearFilters,
          onAction: () {
            searchController.clear();
            onQuery(query.cleared());
          },
        ),
      if (view.apps.isNotEmpty) ...[
        SectionHeader(title: l10n.safetyFindingsTitle),
        for (final g in view.apps)
          AppFindingsCard(
            key: ValueKey('safety-app-${g.package}'),
            label: g.label,
            findings: g.findings,
            target: g.target,
            onUninstall: onUninstall,
            resolutions: resolutions,
            onResolve: onResolve,
          ),
      ],
      if (view.device.isNotEmpty) ...[
        Row(
          children: [
            Icon(Icons.phone_android, color: p.mutedText, size: 24),
            const SizedBox(width: BhSpace.s),
            Expanded(child: SectionHeader(title: l10n.safetyDeviceSection)),
          ],
        ),
        for (final f in view.device)
          DeviceFindingRow(
            finding: f,
            acknowledged: resolutions.acknowledged.contains(
              FindingKinds.idOf(f),
            ),
            onResolve: () => onResolve(f),
          ),
      ],
    ];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.m,
        BhSpace.m,
        BhSpace.m,
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: BhSpace.m),
      itemBuilder: (_, i) => items[i],
    );
  }

  /// The app's display name: the posted bundle's label, the target's, or
  /// "নাম না জানা অ্যাপ" (a package name is a developer string and is never
  /// shown bare).
  String _label(
    AppLocalizations l10n,
    String pkg,
    List<UninstallTarget> targets,
  ) {
    final fromBundle = labels[pkg];
    if (fromBundle != null && fromBundle.isNotEmpty) return fromBundle;
    final fromTarget = targets
        .where((t) => t.package == pkg && t.label.isNotEmpty)
        .firstOrNull
        ?.label;
    return fromTarget ?? l10n.safetyUnknownApp;
  }
}

class _VerdictHeader extends StatelessWidget {
  const _VerdictHeader({
    required this.response,
    required this.blocked,
    this.blockReasons = const [],
  });

  final AppSafetyResponse response;
  final bool blocked;

  /// `reasons[].text_*` of the blocked transfer's score, shown as sent.
  final List<Reason> blockReasons;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final style = VerdictStyle.of(context, response.verdict);
    final onFill = p.onStatusContainer(style.status);
    return SafetyVerdictCard(
      key: const Key('safety-verdict-card'),
      verdict: response.verdict,
      simulated: response.simulatedVerdict,
      message: response.userMessage(context),
      large: true,
      // The app bar already says "ফোনের নিরাপত্তা".
      showPrefix: false,
      above: [
        if (blocked) ...[
          const SizedBox(height: BhSpace.s),
          Row(
            children: [
              Icon(Icons.block, color: p.danger, size: 24),
              const SizedBox(width: BhSpace.s),
              Expanded(
                child: Text(
                  l10n.safetyBlockedTitle,
                  style: text.titleMedium?.copyWith(color: p.danger),
                ),
              ),
            ],
          ),
          for (final r in blockReasons)
            Padding(
              padding: const EdgeInsets.only(top: BhSpace.xs),
              child: Text(
                r.text(context),
                key: ValueKey('safety_block_reason_${r.code}'),
                style: text.bodyLarge?.copyWith(color: onFill),
              ),
            ),
          const SizedBox(height: BhSpace.s),
          Divider(height: 1, color: p.outlineVariant),
        ],
      ],
    );
  }
}

/// One app with its findings (8.8): the app label and the highest severity
/// tag in the header row (tag at the card's trailing padding line), each
/// finding's `title_*` and `explanation_*`, the technical `evidence` behind
/// a collapsed "বিস্তারিত", and for an uninstall target a full-width
/// outlined danger "আনইনস্টল করুন" at the bottom.
///
/// Each finding carries its CTA. In an uninstall target's card the one
/// "আনইনস্টল করুন" at the bottom is the CTA of every finding that maps to
/// uninstall (it takes the first one's `finding_cta_<id>` key), so the card
/// never shows two uninstall buttons.
class AppFindingsCard extends StatelessWidget {
  const AppFindingsCard({
    required this.label,
    required this.findings,
    required this.onUninstall,
    this.target,
    this.resolutions = const FindingResolutions(),
    this.onResolve,
    super.key,
  });

  final String label;
  final List<Finding> findings;
  final UninstallTarget? target;
  final void Function(UninstallTarget target) onUninstall;
  final FindingResolutions resolutions;

  /// Runs a finding's CTA; `null` hides the CTAs.
  final void Function(Finding finding)? onResolve;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final worst =
        ([...findings]..sort(
              (a, b) =>
                  SeverityStyle.rank(a.severity)
                      .compareTo(SeverityStyle.rank(b.severity)),
            ))
            .firstOrNull;
    final severity = worst == null
        ? null
        : SeverityStyle.of(context, worst.severity);
    final t = target;
    final resolve = onResolve;
    // An uninstall CTA inside a target's card is the card's own button.
    final coveredByTarget = t != null && resolve != null;
    final covered = coveredByTarget
        ? findings
              .where(
                (f) => FindingKinds.actionFor(f) == FindingAction.uninstall,
              )
              .firstOrNull
        : null;
    return Container(
      color: p.surfaceVariant,
      padding: const EdgeInsets.all(BhSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusTag.header(
            key: const Key('safety-app-header'),
            title: Text(
              label,
              style: text.titleSmall?.copyWith(color: p.onSurface),
            ),
            tag: severity == null
                ? null
                : StatusTag(label: severity.label, status: severity.status),
          ),
          for (final f in findings) ...[
            const SizedBox(height: BhSpace.s),
            FindingCard(
              finding: f,
              label: label,
              acknowledged: resolutions.acknowledged.contains(
                FindingKinds.idOf(f),
              ),
              onResolve:
                  resolve == null ||
                      (coveredByTarget &&
                          FindingKinds.actionFor(f) == FindingAction.uninstall)
                  ? null
                  : () => resolve(f),
            ),
          ],
          if (t != null) ...[
            const SizedBox(height: BhSpace.m),
            UninstallButton(
              key: covered == null ? null : FindingCta.keyFor(covered),
              target: t,
              onPressed: () => onUninstall(t),
            ),
          ],
        ],
      ),
    );
  }
}

/// One `findings[]` entry inside its app card: `title_*` when sent and not
/// just the app label again, `explanation_*`, and `evidence` behind
/// "বিস্তারিত", every string as sent.
///
/// With [onResolve] the finding gets its CTA ([FindingCta]) under the text,
/// and tapping the text opens the full detail sheet.
class FindingCard extends StatefulWidget {
  const FindingCard({
    required this.finding,
    required this.label,
    this.onResolve,
    this.acknowledged = false,
    super.key,
  });

  final Finding finding;

  /// The app's label; a title equal to it is not repeated.
  final String label;

  /// Runs the finding's CTA; `null` shows no CTA and no sheet.
  final VoidCallback? onResolve;

  /// "বুঝেছি" was tapped on this finding.
  final bool acknowledged;

  @override
  State<FindingCard> createState() => _FindingCardState();
}

class _FindingCardState extends State<FindingCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final f = widget.finding;
    final title = f.title(context);
    final resolve = widget.onResolve;
    final Widget copy = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty && title != widget.label)
          Text(title, style: text.bodyMedium?.copyWith(color: p.onSurface)),
        Text(
          f.explanation(context),
          style: text.bodySmall?.copyWith(color: p.mutedText),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (resolve == null)
          copy
        else
          Pressable(
            key: ValueKey('finding_row_${FindingKinds.idOf(f)}'),
            onTap: () => showFindingSheet(
              context,
              finding: f,
              appLabel: widget.label,
              acknowledged: widget.acknowledged,
              onAction: resolve,
            ),
            child: copy,
          ),
        if (f.evidence.isNotEmpty)
          _EvidenceToggle(
            open: _open,
            evidence: f.evidence,
            onToggle: () => setState(() => _open = !_open),
          ),
        if (resolve != null) ...[
          const SizedBox(height: BhSpace.xs),
          FindingCta(
            finding: f,
            acknowledged: widget.acknowledged,
            onPressed: resolve,
          ),
        ],
      ],
    );
  }
}

class _EvidenceToggle extends StatelessWidget {
  const _EvidenceToggle({
    required this.open,
    required this.evidence,
    required this.onToggle,
  });

  final bool open;
  final String evidence;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final motion = BhMotion.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          expanded: open,
          child: TextButton.icon(
            key: const Key('safety-evidence-toggle'),
            style: TextButton.styleFrom(
              minimumSize: const Size(BhSize.touch, BhSize.touch),
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.xs),
              foregroundColor: p.mutedText,
              textStyle: text.bodySmall,
            ),
            onPressed: onToggle,
            icon: AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: motion.fast,
              child: const Icon(Icons.expand_more, size: 20),
            ),
            label: Text(l10n.safetyDetails),
          ),
        ),
        AnimatedSize(
          duration: motion.normal,
          curve: BhCurves.enter,
          alignment: Alignment.topLeft,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(left: BhSpace.xs),
                  child: Text(
                    evidence,
                    key: const Key('safety-evidence'),
                    style: text.bodySmall?.copyWith(color: p.mutedText),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A device-scoped finding under "আপনার ফোন": a row, not a card.
class DeviceFindingRow extends StatelessWidget {
  const DeviceFindingRow({
    required this.finding,
    this.onResolve,
    this.acknowledged = false,
    super.key,
  });

  final Finding finding;
  final VoidCallback? onResolve;
  final bool acknowledged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final severity = SeverityStyle.of(context, finding.severity);
    final title = finding.title(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: BhSpace.s),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusTag.header(
            title: Text(
              title.isNotEmpty ? title : l10n.safetyDeviceSection,
              style: text.bodyMedium?.copyWith(color: p.onSurface),
            ),
            tag: StatusTag(label: severity.label, status: severity.status),
          ),
          FindingCard(
            finding: finding,
            label: title,
            onResolve: onResolve,
            acknowledged: acknowledged,
          ),
        ],
      ),
    );
  }
}

/// Full-width 56 dp outlined danger "আনইনস্টল করুন" for one
/// `uninstall_targets[]` entry, at the bottom of that app's card; the
/// caller opens the system app-info page for [target].
class UninstallButton extends StatelessWidget {
  const UninstallButton({
    required this.target,
    required this.onPressed,
    super.key,
  });

  final UninstallTarget target;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    // A package name is a developer string: never shown bare.
    final label = target.label.isNotEmpty
        ? target.label
        : l10n.safetyUnknownApp;
    return Semantics(
      label: '${l10n.safetyUninstall} $label',
      button: true,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: BhSize.touch,
            minWidth: double.infinity,
          ),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: p.danger,
              side: BorderSide(color: p.danger),
              minimumSize: const Size(BhSize.touch, BhSize.touch),
            ),
            onPressed: onPressed,
            icon: const Icon(Icons.delete_outline),
            label: Text(l10n.safetyUninstallApp),
          ),
        ),
      ),
    );
  }
}
