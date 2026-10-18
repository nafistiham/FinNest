/// The one per-user reset, shared by every place the signed
/// in persona changes: the demo panel's persona switch, Home's logout and the
/// Login screen's demo login. Nothing of the previous persona survives it:
/// session id, cooldowns, last score, evidence quote, the app-safety verdict,
/// wrong-PIN counters, and the previous uid's local ledger, interventions and
/// finance rows.
library;

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/features/finance/logic/finance_providers.dart';
import 'package:bhorosha/features/pin_pad/logic/pin_attempts.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// `ref.read` of either a `Ref` or a `WidgetRef`.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

const _tag = 'session';

/// Rotates the session id, clears the risk session (cooldowns, last score,
/// evidence quote), the app-safety verdict and its fallback (so the previous
/// persona's verdict never reaches the next one's `demo_flags`) and the
/// wrong-PIN counters and, when [previousUid] is given, resets that uid's
/// ledger, interventions and finance rows. Each store is reset on its own:
/// one failure is logged and never skips the others.
Future<void> resetSessionState(
  ProviderReader read, {
  String? previousUid,
}) async {
  // Synchronous handles first, read before any await so a disposed scope
  // half-way through cannot leave them stale.
  _guard('session id', () => read(sessionRepoProvider).rotate());
  _guard('risk session', () => read(riskSessionProvider.notifier).reset());
  _guard('safety', () => read(safetyControllerProvider.notifier).reset());
  _guard(
    'safety fallback',
    () => read(safetyLatestFallbackProvider.notifier).set(null),
  );
  _guard('pin attempts', () => read(pinAttemptsProvider.notifier).clearAll());
  if (previousUid == null) return;
  final ledger = read(ledgerRepoProvider);
  final interventions = read(interventionRepoProvider);
  final finance = read(financeRepoProvider);
  await _guardAsync('ledger', () => ledger.reset(previousUid));
  await _guardAsync('interventions', () => interventions.reset(previousUid));
  await _guardAsync('finance', () => finance.reset(previousUid));
}

void _guard(String what, void Function() reset) {
  try {
    reset();
  } on Object catch (e) {
    Log.w(_tag, '$what reset failed', e);
  }
}

Future<void> _guardAsync(String what, Future<void> Function() reset) async {
  try {
    await reset();
  } on Object catch (e) {
    Log.w(_tag, '$what reset failed', e);
  }
}
