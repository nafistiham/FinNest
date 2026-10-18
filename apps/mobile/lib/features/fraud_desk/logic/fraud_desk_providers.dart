/// State of the staff Fraud desk: the
/// watch-list, the start-case guard and the case polling cadence.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/log.dart';
import '../../../data/api/api_failure.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/providers.dart';
import '../../../data/repos/case_link_repo.dart';
import '../../send_money/logic/risk_providers.dart' show clockProvider;

/// The Case Zero watch-list, kept for 60 s after it loaded. A failure is
/// shown with a retry button (no automatic retry: the list is staff data).
final watchListProvider = FutureProvider.autoDispose<PayeeRisk>((ref) async {
  final list = await ref.watch(caseDeskApiProvider).getPayeeRisk();
  final link = ref.keepAlive();
  final timer = Timer(const Duration(seconds: 60), link.close);
  ref.onDispose(timer.cancel);
  return list;
}, retry: (_, _) => null);

/// Masked phone numbers of the demo accounts this app knows (the personas
/// and their saved payees), so a named id like `acct_rina` is masked to its
/// number ("…412") on staff screens, never shown by name.
final knownPhonesProvider = FutureProvider.autoDispose<Map<String, String>>((
  ref,
) async {
  final seeds = await ref.watch(demoAssetsProvider).personas();
  return {
    for (final seed in seeds.values) ...{
      for (final p in seed.savedPayees)
        if (p.phoneMasked.isNotEmpty) p.acctId: p.phoneMasked,
      if (seed.profile.phoneMasked.isNotEmpty)
        seed.profile.acctId: seed.profile.phoneMasked,
    },
  };
});

/// The signed-in persona whose links the desk reads and writes.
final fraudDeskUidProvider = Provider.autoDispose<String>(
  (ref) => ref.watch(currentUserProvider).value?.uid ?? 'staff',
);

/// Waits before the one retry of a rate-limited start; tests override it.
final fraudDeskDelayProvider = Provider<Future<void> Function(Duration)>(
  (_) => Future<void>.delayed,
);

/// How often the case screen re-reads a case: every 2 s while it is queued
/// or running, every 10 s otherwise (and before the first read).
Duration pollDelayFor(CaseStatus? status) => switch (status) {
  CaseStatus.queued || CaseStatus.running => const Duration(seconds: 2),
  _ => const Duration(seconds: 10),
};

/// One investigation per payee per this window.
const startCooldown = Duration(minutes: 30);

/// The longest `Retry-After` the desk waits out before its one retry.
const maxRetryAfter = Duration(seconds: 30);

/// Why a payee cannot be investigated now.
enum StartBlock {
  /// A case on this payee is still queued or running.
  openCase,

  /// A case on this payee was opened less than [startCooldown] ago.
  cooldown,
}

/// The guard of "তদন্ত শুরু করুন" for [acctId] at [now], given the links
/// this phone holds; `null` when a case may be started.
StartBlock? startBlockFor(String acctId, List<CaseLink> links, DateTime now) {
  StartBlock? block;
  for (final l in links) {
    if (l.acctId != acctId) continue;
    if (l.isOpen) return StartBlock.openCase;
    if (now.difference(l.openedAt) < startCooldown) {
      block = StartBlock.cooldown;
    }
  }
  return block;
}

/// What a start attempt came to.
sealed class StartOutcome {
  const StartOutcome();
}

final class StartedCase extends StartOutcome {
  const StartedCase(this.link);
  final CaseLink link;
}

final class StartBlocked extends StartOutcome {
  const StartBlocked(this.reason);
  final StartBlock reason;
}

/// Rate-limited twice, 5xx, unreachable: the reviewer copy.
final class StartFailed extends StartOutcome {
  const StartFailed(this.failure);
  final Object failure;
}

/// The payees with a start in flight (the busy state).
class StartCaseController extends Notifier<Set<String>> {
  static const _tag = 'fraud_desk';

  @override
  Set<String> build() => const {};

  /// Starts a case on [acctId] for persona [uid]: the guard first, then
  /// `POST /v1/investigate`; a 429 is retried once after its `Retry-After`
  /// when that is at most 30 s; any other failure is a [StartFailed].
  Future<StartOutcome> start(String uid, String acctId) async {
    if (state.contains(acctId)) {
      return const StartBlocked(StartBlock.openCase);
    }
    // Busy before the first await: a second tap in the same frame sees it
    // and never posts a second investigation.
    state = {...state, acctId};
    final repo = ref.read(caseLinkRepoProvider);
    final Clock clock = ref.read(clockProvider);
    try {
      final block = startBlockFor(acctId, await repo.all(uid), clock.now());
      if (block != null) return StartBlocked(block);
      final res = await _postWithOneRetry(acctId);
      final link = CaseLink(
        caseId: res.caseId,
        acctId: acctId,
        openedAt: clock.now(),
      );
      await repo.upsert(uid, link);
      return StartedCase(link);
    } on Object catch (e) {
      Log.w(_tag, 'investigation start failed', e);
      return StartFailed(e);
    } finally {
      if (ref.mounted) state = {...state}..remove(acctId);
    }
  }

  Future<InvestigateResponse> _postWithOneRetry(String acctId) async {
    final api = ref.read(caseDeskApiProvider);
    try {
      return await api.postInvestigate(acctId);
    } on RateLimited catch (e) {
      final wait = e.retryAfterSeconds;
      if (wait == null || Duration(seconds: wait) > maxRetryAfter) rethrow;
      await ref.read(fraudDeskDelayProvider)(Duration(seconds: wait));
      return api.postInvestigate(acctId);
    }
  }
}

final startCaseProvider = NotifierProvider<StartCaseController, Set<String>>(
  StartCaseController.new,
);
