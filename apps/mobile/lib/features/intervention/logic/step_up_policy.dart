/// The interim identity step-up: when a
/// server `hold` rests on the behaviour model alone, the owner may confirm
/// with a strong biometric and send the money locally. Seven conditions, all
/// required; [stepUpFor] is pure so each has its own test.
///
/// The release is decided on this phone alone: risk-mw has no step-up
/// release route yet, so the server's intervention (and its PIN freeze)
/// stays open after a local release and the server never hears of it.
/// Until that route exists the step-up is offered only in a build with the
/// demo panel (`AppEnv.demoPanel`, condition 0); every other build keeps the hold for the trusted contact.
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/intervention/logic/reason_kind.dart';
import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why the hold stays, in the order the conditions are checked.
enum StepUpBlock {
  /// (0) not a demo-panel build: there is no server-side step-up release
  /// yet, so a release decided here would never reach risk-mw.
  serverReleaseMissing,

  /// (a) some reason is not an identity reason (payee, mule, scam, SIM,
  /// screen share, coaching ...), or there is no reason at all.
  notIdentityOnly,

  /// (b) a call is live, or the server did not say `none` for the call
  /// signal (`signal_sources` missing, or a value the client does not know,
  /// counts as unknown and keeps the hold).
  callActive,

  /// (c) the amount is above the persona's p95.
  overP95,

  /// (d) no strong biometric on this phone.
  biometricWeak,

  /// (e) the behaviour was replayed (any replay mode) or switched off: a
  /// demo story ends at the hold.
  replayed,

  /// (f) three step-ups already tried in this session.
  attemptsExhausted,
}

sealed class StepUpDecision {
  const StepUpDecision();

  bool get offered => this is StepUpOffer;
}

final class StepUpOffer extends StepUpDecision {
  const StepUpOffer();

  @override
  bool operator ==(Object other) => other is StepUpOffer;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'StepUpOffer()';
}

final class StepUpKeep extends StepUpDecision {
  const StepUpKeep(this.reason);

  final StepUpBlock reason;

  @override
  bool operator ==(Object other) =>
      other is StepUpKeep && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'StepUpKeep(${reason.name})';
}

/// At most this many biometric prompts per session (D2 f).
const int maxStepUpAttempts = 3;

/// Offer the biometric step-up for [score], or keep the hold and say why.
StepUpDecision stepUpFor({
  required ScoreResponse score,
  required bool callActiveLocal,
  required double amountBdt,
  required double personaP95,
  required BiometricStrength strength,
  required BehaviourMode mode,
  required int attempts,
  bool demoPanel = AppEnv.demoPanel,
}) {
  if (!demoPanel) return const StepUpKeep(StepUpBlock.serverReleaseMissing);
  if (score.reasons.isEmpty ||
      score.reasons.any((r) => ReasonKind.of(r.code) != ReasonKind.identity)) {
    return const StepUpKeep(StepUpBlock.notIdentityOnly);
  }
  if (score.signalSources?.callActive != SignalSource.none || callActiveLocal) {
    return const StepUpKeep(StepUpBlock.callActive);
  }
  if (amountBdt > personaP95) return const StepUpKeep(StepUpBlock.overP95);
  if (strength != BiometricStrength.strong) {
    return const StepUpKeep(StepUpBlock.biometricWeak);
  }
  if (mode.simulated) return const StepUpKeep(StepUpBlock.replayed);
  if (attempts >= maxStepUpAttempts) {
    return const StepUpKeep(StepUpBlock.attemptsExhausted);
  }
  return const StepUpOffer();
}

class StepUpAttempts extends Notifier<int> {
  @override
  int build() {
    // Per session: a sign-in or persona switch starts again at zero.
    ref.watch(currentUserProvider.select((u) => u.value?.uid));
    return 0;
  }

  void record() => state = state + 1;
}

/// Biometric step-up prompts shown in this session.
final stepUpAttemptsProvider = NotifierProvider<StepUpAttempts, int>(
  StepUpAttempts.new,
);
