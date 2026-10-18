import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/motion/motion_specs.dart';
import '../../../app/router.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/skeleton.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/brand_mark.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/feature_tile.dart';
import '../../../app/widgets/hero_balance.dart';
import '../../../app/widgets/language_toggle.dart';
import '../../../app/widgets/section_header.dart';
import '../../../app/widgets/txn_row.dart';
import '../../../core/haptics.dart';
import '../../../core/log.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../apa/logic/apa_insights.dart';
import '../../apa/logic/apa_insights_provider.dart';
import '../../apa/ui/widgets/apa_insight_card.dart';
import '../../demo_panel/ui/demo_panel_sheet.dart';
import '../../history/logic/history_providers.dart';
import '../../pay/logic/pay_intent.dart';
import '../../safety/logic/safety_controller.dart';
import '../logic/home_providers.dart';
import 'widgets/pending_card.dart';

/// One tile of the Home grid: fixed order, most
/// frequent first. Send money is one feature among nine (eight without the
/// demo panel, which hides the staff Fraud desk).
class HomeFeature {
  const HomeFeature(this.id, this.icon, this.route, this.label);

  /// Stable id for keys (`home_tile_<id>`).
  final String id;
  final IconData icon;
  final String route;
  final String Function(AppLocalizations) label;

  Key get key => Key('home_tile_$id');
}

/// The Home grid of this build: the staff Fraud desk tile only with the
/// demo panel on, like its route.
final homeFeatures = homeFeaturesFor(demoPanel: AppEnv.demoPanel);

/// The tiles in order; [demoPanel] off leaves out the Fraud desk.
List<HomeFeature> homeFeaturesFor({required bool demoPanel}) => [
  for (final f in _allHomeFeatures)
    if (demoPanel || f.id != 'fraud_desk') f,
];

/// The icon-well tone of each Home feature: money out, money in,
/// bills, savings, history, security.
const homeFeatureTones = <String, FeatureTone>{
  'send': FeatureTone.primary,
  'cashout': FeatureTone.primary,
  'cashin': FeatureTone.success,
  'recharge': FeatureTone.info,
  'bill': FeatureTone.warning,
  'loans': FeatureTone.info,
  'savings': FeatureTone.success,
  'history': FeatureTone.neutral,
  'fraud_desk': FeatureTone.warning,
};

final _allHomeFeatures = <HomeFeature>[
  HomeFeature('send', Icons.send, Routes.send, (l) => l.featureSend),
  HomeFeature(
    'cashout',
    Icons.south,
    Routes.payFor(PayKind.cashOut),
    (l) => l.featureCashOut,
  ),
  HomeFeature(
    'cashin',
    Icons.north,
    Routes.payFor(PayKind.cashIn),
    (l) => l.featureCashIn,
  ),
  HomeFeature(
    'recharge',
    Icons.phone_android,
    Routes.payFor(PayKind.recharge),
    (l) => l.featureRecharge,
  ),
  HomeFeature(
    'bill',
    Icons.receipt_long,
    Routes.payFor(PayKind.bill),
    (l) => l.featureBill,
  ),
  HomeFeature(
    'loans',
    Icons.account_balance,
    Routes.loans,
    (l) => l.financeTileLoans,
  ),
  HomeFeature(
    'savings',
    Icons.savings_outlined,
    Routes.savings,
    (l) => l.financeTileSavings,
  ),
  HomeFeature(
    'history',
    Icons.history,
    Routes.history,
    (l) => l.featureHistory,
  ),
  HomeFeature(
    'fraud_desk',
    Icons.policy_outlined,
    Routes.fraudDesk,
    (l) => l.fraudDesk,
  ),
];

/// Home is a hub: how much do I have (hero balance),
/// am I safe (the one security card: Apa's insight with the phone-safety
/// status row), what do I want to do (the 3 x 3 feature grid), then the
/// three newest transactions with a link to History. Apa sits in the bottom
/// bar; Settings and the language toggle in the app bar. A long press on
/// the wordmark opens the demo panel. Pull to refresh re-runs the safety
/// check and reloads the ledger.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({this.haptics = const SystemHaptics(), super.key});

  static const recentCount = 3;

  /// The FinNest mark beside the wordmark in the app bar.
  static const markSize = 28.0;

  /// `warning()` once when the security card turns urgent (6.3).
  final Haptics haptics;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// The uid whose stale cash-in codes were expired on this Home load.
  String? _expiredFor;

  @override
  void initState() {
    super.initState();
    // One safety check per Home load (US-4); the card only reads.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(safetyControllerProvider.notifier).refresh();
    });
  }

  /// Cash-in codes the agent never confirmed within 15 minutes turn
  /// `cancelled` when Home loads (1.4), once per signed-in user.
  void _expireCashIns(String uid) {
    if (_expiredFor == uid) return;
    _expiredFor = uid;
    final ledger = ref.read(ledgerRepoProvider);
    final now = ref.read(homeClockProvider)();
    unawaited(
      ledger
          .expireCashIns(uid, now: now)
          .then<void>(
            (_) {},
            onError: (Object e) => Log.w('bhorosha.home', 'expireCashIns: $e'),
          ),
    );
  }

  Future<void> _refresh(String uid) async {
    ref
      ..invalidate(balanceProvider(uid))
      ..invalidate(recentTxnsProvider(uid))
      ..invalidate(pendingInterventionsProvider(uid));
    await ref.read(safetyControllerProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;
    final p = context.palette;
    if (user != null) _expireCashIns(user.uid);
    // The security card turned urgent (held money, a live scam, a BLOCK):
    // one warning haptic per new urgent insight, never on every rebuild.
    ref.listen<List<ApaInsight>>(apaInsightsProvider, (before, now) {
      final top = now.isEmpty ? null : now.first;
      if (top == null || top.severity != ApaSeverity.danger) return;
      final was = (before == null || before.isEmpty) ? null : before.first;
      if (was?.id == top.id && was?.severity == ApaSeverity.danger) return;
      unawaited(widget.haptics.warning());
    });
    return Scaffold(
      bottomNavigationBar: const BhBottomBar.apa(apaScreen: 'home'),
      // No user yet (the first frame after login): the hub's shape as
      // skeletons, never a spinner.
      body: user == null
          ? const _HomeSkeleton()
          : RefreshIndicator(
              color: p.primary,
              onRefresh: () => _refresh(user.uid),
              child: _HomeBody(user: user),
            ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.user});

  final UserProfile user;

  String _firstName(BuildContext context) {
    final full = context.localName(user.nameBn, user.nameEn).trim();
    return full.split(RegExp(r'\s+')).first;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final balance = ref.watch(balanceProvider(user.uid));
    final recent = ref.watch(recentTxnsProvider(user.uid));
    final pending = ref.watch(pendingInterventionsProvider(user.uid));
    final namesEn = ref.watch(payeeNamesEnProvider);
    final namesBn = ref.watch(payeeNamesBnProvider);
    // One "now" for the row dates (tests pin it through homeClockProvider).
    final now = ref.watch(homeClockProvider)();
    final motion = BhMotion.of(context);
    final pendingRows = pending.value ?? const <InterventionRecord>[];

    // Vertical rhythm (compact so the nine tiles fit the first screen at
    // 412 x 915 with the system bars): greeting 28, 4, balance 84, 16,
    // cards, 12, section header 48, grid 3 x 100 + 2 x 8.
    final top = <Widget>[
      SizedBox(
        height: 28,
        child: Text(
          l10n.greetingShort(_firstName(context)),
          key: const Key('home_greeting'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.titleMedium?.copyWith(color: p.mutedText),
        ),
      ),
      const SizedBox(height: BhSpace.xs),
      HeroBalance(
        key: const Key('home_balance'),
        balance: balance,
        onRetry: () => ref.invalidate(balanceProvider(user.uid)),
      ),
      const SizedBox(height: BhSpace.m),
      // Two or more held transfers fold into one card, so Home keeps
      // its first screen.
      if (pendingRows.length >= 2) ...[
        PendingSummaryCard(records: pendingRows),
        const SizedBox(height: BhSpace.s),
      ] else
        for (final r in pendingRows) ...[
          PendingCard(record: r),
          const SizedBox(height: BhSpace.s),
        ],
      if ((pending.value ?? const []).isNotEmpty)
        const SizedBox(height: BhSpace.s),
      // The pending card already says the money is held: the security card
      // shows the next insight instead of repeating it.
      ApaInsightCard(
        key: const Key('home_security_card'),
        withoutHeld: (pending.value ?? const []).isNotEmpty,
      ),
      const SizedBox(height: BhSpace.s + BhSpace.xs),
      SectionHeader(title: l10n.homeWhatToDo),
      FeatureGrid(
        key: const Key('home_feature_grid'),
        // The tiles cascade once the greeting, balance, cards and header
        // above them have risen (one beat each).
        revealDelay: motion.stagger * (4 + pendingRows.length.clamp(0, 1)),
        children: [
          for (final f in homeFeatures)
            FeatureTile(
              key: f.key,
              icon: f.icon,
              tone: homeFeatureTones[f.id] ?? FeatureTone.primary,
              label: f.label(l10n),
              // The pay flow navigates between its steps with `go`, which
              // rebuilds the page stack from the location; a flow opened
              // with `push` would get a new start page on the first step
              // change and lose the intent. Other features pop back here.
              onTap: () => f.route.startsWith('/pay/')
                  ? context.go(f.route)
                  : context.push(f.route),
            ),
        ],
      ),
      const SizedBox(height: BhSpace.l),
      SectionHeader(
        key: const Key('home_recent_header'),
        title: l10n.recentTransactions,
        actionLabel: l10n.homeSeeAll,
        onAction: () => context.push(Routes.history),
      ),
    ];

    final List<Widget> rows = switch (recent) {
      AsyncData(:final value) when value.isEmpty => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
          child: EmptyState(
            key: const Key('home_recent_empty'),
            icon: Icons.receipt_long,
            title: l10n.noRecentTransactions,
            inline: true,
          ),
        ),
      ],
      // First paint: the rows rise in one after another (6.2); later
      // rebuilds show them settled.
      AsyncData(:final value) => [
        StaggeredReveal(
          key: const Key('home_recent_rows'),
          children: [
            for (final (i, t) in value.take(HomeScreen.recentCount).indexed)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: BhSpace.m + BhSize.avatar + BhSpace.m,
                      endIndent: BhSpace.m,
                      color: p.outlineVariant,
                    ),
                  TxnRow(
                    key: ValueKey('home_txn_${t.txnId}'),
                    txn: t,
                    acctId: user.acctId,
                    now: now,
                    nameEn: englishNameFor(t, user.acctId, namesEn),
                    fromName: senderNameFor(
                      t,
                      user.acctId,
                      namesBn: namesBn,
                      namesEn: namesEn,
                      english: !context.banglaDigits,
                    ),
                    onTap: () => context.push(
                      '${Routes.history}?txn=${Uri.encodeQueryComponent(t.txnId)}',
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
      // A failed load is not "no transactions": say so and offer a retry.
      AsyncError() => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
          child: EmptyState(
            key: const Key('home_recent_failed'),
            icon: Icons.cloud_off,
            title: l10n.recentLoadFailed,
            actionLabel: l10n.retry,
            onAction: () => ref.invalidate(recentTxnsProvider(user.uid)),
            inline: true,
          ),
        ),
      ],
      // Loading: three skeleton rows in the shape of the real ones.
      _ => [
        Semantics(
          key: const Key('home_recent_loading'),
          label: l10n.loadingList,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: Column(
              children: [SkeletonRow(), SkeletonRow(), SkeletonRow()],
            ),
          ),
        ),
      ],
    };

    return CustomScrollView(
      key: const Key('home_scroll'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // One line, 56 dp: the mark and wordmark, the 32 dp language pill
        // and an icon-only Settings action.
        SliverAppBar(
          pinned: true,
          toolbarHeight: BhSize.appBarCompact,
          automaticallyImplyLeading: false,
          titleSpacing: BhSpace.m,
          title: DemoLongPressTarget(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  brandMarkAsset,
                  key: const Key('home_mark'),
                  width: HomeScreen.markSize,
                  height: HomeScreen.markSize,
                  filterQuality: FilterQuality.medium,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                const SizedBox(width: BhSpace.s),
                // Scales down rather than wrapping when the title slot is
                // narrow (large text, a wide language pill).
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      l10n.appName,
                      key: const Key('home_logo'),
                      maxLines: 1,
                      softWrap: false,
                      style: text.titleLarge?.copyWith(color: p.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: const [
            // Judges switch language live: one tap away on Home.
            LanguageToggle(compact: true),
            SizedBox(width: BhSpace.xs),
            _SettingsButton(),
            SizedBox(width: BhSpace.s),
          ],
        ),
        // First paint: the page cascades down (greeting, balance, cards,
        // header, then the tiles) once the route has entered.
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
          sliver: SliverToBoxAdapter(
            child: StaggeredReveal(
              key: const Key('home_top_reveal'),
              offset: 12,
              maxStaggered: 8,
              children: top,
            ),
          ),
        ),
        SliverList.list(children: rows),
        const SliverToBoxAdapter(child: SizedBox(height: BhSpace.m)),
      ],
    );
  }
}

/// Icon-only Settings action (56 dp square): the label is the tooltip and
/// the semantics label, so TalkBack still reads "সেটিংস" and a long press
/// shows it.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  static const buttonKey = Key('home_settings');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return Semantics(
      button: true,
      label: l10n.settings,
      child: ExcludeSemantics(
        child: Tooltip(
          message: l10n.settings,
          child: SizedBox(
            key: buttonKey,
            width: BhSize.touch,
            height: BhSize.touch,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => context.push(Routes.settings),
                child: Center(
                  child: Icon(
                    Icons.settings_outlined,
                    size: 24,
                    color: p.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Home before the signed-in user has resolved: the hub's shape (balance,
/// one card, three rows) as skeletons under the same app bar height.
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      key: const Key('home_loading'),
      label: l10n.loadingList,
      child: const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            BhSpace.m,
            BhSize.appBarCompact + BhSpace.m,
            BhSpace.m,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 160, height: 16),
              SizedBox(height: BhSpace.m),
              Skeleton.amount(),
              SizedBox(height: BhSpace.l),
              Skeleton(height: 120),
              SizedBox(height: BhSpace.l),
              SkeletonRow(),
              SkeletonRow(),
              SkeletonRow(),
            ],
          ),
        ),
      ),
    );
  }
}
