/// Riverpod wiring of the risk flow.
///
/// Per-user risk state lives here: the cooldown windows, the last score (so
/// Apa can read it) and the last scam-replay `evidence_quote` (so
/// `/v1/intervene` can carry it). The demo panel clears all three on a
/// persona switch through [RiskSession.reset] or [resetRiskSession]
///.
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/core/ids.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:bhorosha/features/send_money/logic/risk_flow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

/// Last `evidence_quote` from the scam replay; the demo panel writes it.
final lastEvidenceQuoteProvider = StateProvider<String?>((_) => null);

final clockProvider = Provider<Clock>((_) => const SystemClock());

final cooldownProvider = Provider<Cooldown>(
  (ref) => Cooldown(ref.watch(clockProvider), alwaysSpeak: AppEnv.demoPanel),
);

/// The most recent `ScoreResponse`; the PIN screen sets it after each score.
final lastScoreProvider = StateProvider<ScoreResponse?>((_) => null);

final riskFlowProvider = Provider<RiskFlow>(
  (ref) => RiskFlow(
    api: ref.watch(riskApiProvider),
    native: ref.watch(nativeProvider),
    cooldown: ref.watch(cooldownProvider),
    clock: ref.watch(clockProvider),
    nonce: newId,
    lastEvidenceQuote: () => ref.read(lastEvidenceQuoteProvider),
    enrolment: ref.watch(enrolmentStoreProvider),
    enrolling: () => ref.read(behaviourEnrollingProvider),
  ),
);

/// Clears cooldowns, the last score and the last evidence quote.
void resetRiskSession(Ref ref) {
  ref.read(cooldownProvider).reset();
  ref.read(lastScoreProvider.notifier).state = null;
  ref.read(lastEvidenceQuoteProvider.notifier).state = null;
}

/// Widget-side handle on the same reset: the demo panel calls
/// `ref.read(riskSessionProvider.notifier).reset()` on persona switch. The
/// state is a generation counter that bumps on every reset.
class RiskSession extends Notifier<int> {
  @override
  int build() => 0;

  void reset() {
    resetRiskSession(ref);
    state = state + 1;
  }
}

final riskSessionProvider = NotifierProvider<RiskSession, int>(RiskSession.new);
