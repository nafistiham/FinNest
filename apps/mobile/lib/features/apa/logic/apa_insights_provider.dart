/// Riverpod wiring of the insight engine: [apaSnapshotProvider] gathers the
/// customer's state from the app's providers, [apaInsightsProvider] ranks
/// what Apa should say. Both recompute when any input changes.
library;

import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:bhorosha/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
// `apaInsightsProvider` selects `insightFacts` so a balance tick never
// recomputes the list.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// ARB strings in both languages, for logic code that carries both.
final apaL10nBnProvider = Provider<AppLocalizations>(
  (_) => lookupAppLocalizations(const Locale('bn')),
);
final apaL10nEnProvider = Provider<AppLocalizations>(
  (_) => lookupAppLocalizations(const Locale('en')),
);

/// Interventions still waiting (overlay shown or trusted contact asked),
/// newest first.
final apaHeldItemsProvider = StreamProvider<List<ApaHeldItem>>((ref) {
  final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
  if (uid == null) return Stream.value(const <ApaHeldItem>[]);
  return ref.watch(interventionRepoProvider).watch(uid).map((rows) {
    final waiting =
        rows
            .where(
              (r) =>
                  r.status == InterventionStatus.open ||
                  r.status == InterventionStatus.pending,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return [
      for (final r in waiting)
        ApaHeldItem(
          txnId: r.txnId,
          reasons: r.reasons,
          requestId: r.requestId,
          waitingForTrustedContact: r.status == InterventionStatus.pending,
        ),
    ];
  });
});

final apaBalanceProvider = StreamProvider<double?>((ref) {
  final uid = ref.watch(currentUserProvider.select((u) => u.value?.uid));
  if (uid == null) return Stream.value(null);
  return ref.watch(ledgerRepoProvider).watchBalance(uid);
});

/// The customer's state as Apa sees it.
final apaSnapshotProvider = Provider<ApaContextSnapshot>((ref) {
  final safety = ref.watch(safetyControllerProvider);
  final fresh = safety.value;
  final verdict = ref.watch(lastSafetyVerdictProvider);
  final demo = ref.watch(demoStateProvider).value ?? DemoState.initial;
  final user = ref.watch(currentUserProvider).value;
  final balance = ref.watch(apaBalanceProvider).value ?? user?.balanceBdt;
  return ApaContextSnapshot(
    verdict: verdict,
    safetyMessageBn: fresh?.userMessageBn ?? '',
    safetyMessageEn: fresh?.userMessageEn ?? '',
    findings: fresh?.findings ?? const [],
    uninstallTargets: fresh?.uninstallTargets ?? const [],
    resolution: fresh?.resolution ?? 'NONE',
    safetyChecking: safety.isLoading,
    lastScore: ref.watch(lastScoreProvider),
    held: ref.watch(apaHeldItemsProvider).value ?? const [],
    callActive: demo.callActive,
    simSwap: demo.simSwap,
    screenShare: demo.screenShare,
    evidenceQuote: ref.watch(lastEvidenceQuoteProvider),
    scamScore: demo.scamScore,
    nameBn: user?.nameBn,
    nameEn: user?.nameEn,
    balanceBdt: balance,
    locale: ref.watch(localeProvider).languageCode,
  );
});

/// Day of the month: the tip rotates once a day. Tests override it.
final apaTipSeedProvider = Provider<int>((_) => DateTime.now().day);

/// Recomputed only when a fact the engine reads changes (`insightFacts` has
/// value equality and leaves out name and balance), never on a balance tick.
/// Watchers that need one field `select` it (`ApaInsight` has `==` too).
final apaInsightsProvider = Provider<List<ApaInsight>>(
  (ref) => buildApaInsights(
    ref.watch(apaSnapshotProvider.select((s) => s.insightFacts)),
    bn: ref.watch(apaL10nBnProvider),
    en: ref.watch(apaL10nEnProvider),
    content: ref.watch(apaContentSyncProvider),
    tipSeed: ref.watch(apaTipSeedProvider),
  ),
);

/// The list Home's security card ranks from. `withoutHeld` (a pending
/// intervention card is on screen and already says the money is held)
/// leaves out `held_transfer` / `call_transfer` so the card shows the next
/// insight; the FNA sheet keeps reading [apaInsightsProvider].
final apaCardInsightsProvider = Provider.family<List<ApaInsight>, bool>((
  ref,
  withoutHeld,
) {
  if (!withoutHeld) return ref.watch(apaInsightsProvider);
  return buildApaInsights(
    ref.watch(apaSnapshotProvider.select((s) => s.insightFacts)),
    bn: ref.watch(apaL10nBnProvider),
    en: ref.watch(apaL10nEnProvider),
    content: ref.watch(apaContentSyncProvider),
    tipSeed: ref.watch(apaTipSeedProvider),
    withoutHeld: true,
  );
});
