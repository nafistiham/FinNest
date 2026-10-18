/// One confirm attempt of the PIN pad and the writes its hold path makes
/// (moved out of `pin_pad_screen.dart` so the release rules have unit
/// tests).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/legacy.dart' show StateController;

import '../../../app/env.dart';
import '../../../core/clock.dart';
import '../../../core/ids.dart';
import '../../../core/log.dart';
import '../../../data/contracts/contracts.dart';
import '../../../data/repos/repos.dart';
import '../../../domain/behaviour/behaviour_mode.dart';
import '../../../domain/risk/cooldown.dart';
import '../../login/logic/biometric_auth.dart';
import '../../pay/logic/pay_intent.dart';
import '../../pay/logic/pay_ledger.dart';
import '../../send_money/logic/risk_outcome.dart';

const _tag = 'pin_pad';

/// Longest the PIN flow waits on one store write before moving on; the
/// write itself carries on in the background.
const pinWriteBudget = Duration(seconds: 1);

/// One confirm attempt: the ids, the futures the overlay waits on and the
/// stores it writes through, all captured before `scoreTransfer` is awaited
/// so the writes never depend on the PIN pad still being mounted. Most
/// writes are logged and swallowed on failure (a Firestore rejection after
/// a failed sign-in must not leave the pad on "যাচাই হচ্ছে…"); [release]
/// is the exception: it says whether it landed.
class PendingHold {
  PendingHold({
    required this.user,
    required this.intent,
    required this.clock,
    required this.ledger,
    required this.interventions,
    required this.cooldown,
    required this.lastScore,
    this.mode = BehaviourMode.live,
    this.releaseAllowed = AppEnv.demoPanel,
  }) : scoreArrivedAtMs = clock.nowMs();

  final UserProfile user;
  final PayIntent intent;
  final Clock clock;
  final LedgerRepo ledger;
  final InterventionRepo interventions;
  final Cooldown cooldown;
  final StateController<ScoreResponse?> lastScore;

  /// The behaviour mode this attempt was scored with; anything but live
  /// tags the row and the record `simulated`.
  final BehaviourMode mode;

  /// Whether [release] may write at all: only a build with the demo panel
  /// (`AppEnv.demoPanel`), because the server-side step-up release does not
  /// exist yet and the server never hears of a release decided here
  /// (see `stepUpFor`).
  final bool releaseAllowed;

  /// The merged `call_active` flag `RiskFlow` sent (step-up condition b).
  bool callActiveLocal = false;

  /// The phone's biometric, once known (step-up condition d).
  BiometricStrength strength = BiometricStrength.unsupported;

  /// Set after a failed fingerprint step-up (or a release that did not
  /// land); the overlay listens.
  final ValueNotifier<bool> stepUpFailed = ValueNotifier(false);

  /// Set once the session's step-up prompts are used up (cancels count).
  final ValueNotifier<bool> stepUpExhausted = ValueNotifier(false);

  /// Set once the record is no longer open (trusted contact asked,
  /// released, decided): the overlay drops the step-up.
  final ValueNotifier<bool> stepUpClosed = ValueNotifier(false);

  final String recordId = newId('int');
  final String txnId = newId('txn');
  final Completer<InterveneResponse?> intervene = Completer();
  final Completer<InterventionRecord> record = Completer();
  int scoreArrivedAtMs;
  bool overlayOpened = false;

  /// The held row and the open record, written by [startHold]; `null` until
  /// a hold or delay is predicted.
  Future<InterventionRecord>? _opened;

  /// Set once the trusted-contact request went out; the overlay listens.
  final ValueNotifier<bool> trustedSent = ValueNotifier(false);

  /// The newest version of the record this attempt wrote, and the queue
  /// every record write goes through (the `/v1/intervene` patch, the
  /// trusted-contact request and a step-up release may race; none may drop
  /// another's fields, and a release must see the request).
  InterventionRecord? _latest;
  Future<void> _patches = Future<void>.value();

  Future<void> _serial(Future<void> Function() write) {
    final next = _patches.then((_) => write());
    _patches = next.catchError((Object _) {});
    return next;
  }

  /// The open record, once [startHold] wrote it.
  Future<InterventionRecord> get opened =>
      _opened ?? Future.error(StateError('no hold started'));

  /// The server's id for this hold, once known: from
  /// `/v1/intervene`, else the score's actions. `null` before a hold.
  String? get serverInterventionId => _latest?.serverInterventionId;

  /// Whether the step-up may still release this hold: a hold was started,
  /// the trusted contact was not asked and the record this attempt last
  /// wrote is still `open`.
  bool get stepUpOpen =>
      _opened != null &&
      !trustedSent.value &&
      (_latest?.status ?? InterventionStatus.open) == InterventionStatus.open;

  /// Writes the `held` ledger row and the `open` record (reasons and score
  /// actions; `script_bn` follows in [finishHold]). Idempotent.
  void startHold(String trigger, ScoreResponse score) {
    _opened ??= _writeOpened(trigger, score);
  }

  Future<InterventionRecord> _writeOpened(
    String trigger,
    ScoreResponse score,
  ) async {
    final opened = _record(trigger, score, InterventionStatus.open);
    _latest ??= opened;
    await createTxn(LedgerStatus.held, interventionId: recordId);
    await boundedWrite(
      () => interventions.upsert(opened),
      'intervention record write',
    );
    return opened;
  }

  InterventionRecord _record(
    String trigger,
    ScoreResponse score,
    String status, {
    StepUpRecord? stepUp,
  }) => InterventionRecord(
    id: recordId,
    uid: user.uid,
    txnId: txnId,
    trigger: trigger,
    scriptBn: '',
    reasons: score.reasons,
    actions: score.actions,
    status: status,
    createdAt: clock.now(),
    simulated: mode.simulated,
    signalSources: score.signalSources,
    stepUp: stepUp,
    serverInterventionId: interventionIdOf(score.actions),
  );

  /// `/v1/intervene` answered (or failed): patch `script_bn`/`script_en`
  /// and the merged actions onto the record and hand it to the
  /// trusted-contact action.
  Future<void> finishHold(Intervened outcome) async {
    startHold(outcome.trigger, outcome.score);
    final opened = await _opened!;
    late InterventionRecord patched;
    await _serial(() async {
      // copyWith keeps every other field (status, simulated, step-up ...).
      patched = (_latest ?? opened).copyWith(
        scriptBn: outcome.intervene?.scriptBn ?? '',
        scriptEn: outcome.intervene?.scriptEn ?? '',
        actions: outcome.actions,
        audioAssetId: outcome.intervene?.audioAssetId,
        // The id the server opened for this call wins over the hold's id
        // from the score; copyWith keeps the stored one when both are null.
        serverInterventionId:
            outcome.intervene?.serverInterventionId ??
            interventionIdOf(outcome.actions),
      );
      _latest = patched;
      await boundedWrite(
        () => interventions.upsert(patched),
        'intervention record patch',
      );
    });
    if (!record.isCompleted) record.complete(patched);
  }

  /// Asks the trusted contact through [send] (which stores the request on
  /// the record it is given and returns it), in the same queue as every
  /// other record write: a release queued behind it sees the request and
  /// refuses. Throws what [send] throws.
  Future<InterventionRecord> requestTrusted(
    Future<InterventionRecord> Function(InterventionRecord) send,
  ) async {
    final opened = await this.opened;
    late InterventionRecord updated;
    await _serial(() async {
      updated = await send(_latest ?? opened);
      _latest = updated;
    });
    trustedSent.value = true;
    stepUpClosed.value = true;
    return updated;
  }

  /// The owner passed the biometric step-up on a held transfer: the held row
  /// and the record both become `released_by_step_up` with [stepUp].
  ///
  /// Refused (`false`, nothing written) without the demo panel
  /// ([releaseAllowed]), and unless the stored record and this attempt's
  /// latest copy are both still `open` and the trusted contact was not
  /// asked: a request, an approval or a decline is never
  /// overwritten. `false` too when a write was rejected or not acknowledged
  /// within [pinWriteBudget] (M3; the Firestore writes here await the
  /// server's ack, critical 3); a release that did not fully land puts the
  /// row back to `held`. `true` only when both writes landed.
  Future<bool> release(StepUpRecord stepUp) async {
    if (!releaseAllowed) {
      Log.w(_tag, 'step-up release refused: no server-side release yet');
      stepUpClosed.value = true;
      return false;
    }
    final pendingOpen = _opened;
    if (pendingOpen == null) return false;
    final opened = await pendingOpen;
    var ok = false;
    await _serial(() async {
      final current = _latest ?? opened;
      final stored = await _stored();
      if (trustedSent.value ||
          current.status != InterventionStatus.open ||
          (stored != null && stored.status != InterventionStatus.open)) {
        Log.i(
          _tag,
          'step-up release refused: record is '
          '${stored?.status ?? current.status}',
        );
        stepUpClosed.value = true;
        return;
      }
      final rowReleased = await _tryWrite(
        () => ledger.patch(
          txnId,
          LedgerPatch(status: LedgerStatus.releasedByStepUp, stepUp: stepUp),
        ),
        'ledger release',
      );
      if (!rowReleased) {
        // Firestore applied the patch to its cache already; a rejected or
        // unacknowledged one must not leave the row reading as released.
        await boundedWrite(
          () => ledger.setStatus(txnId, LedgerStatus.held),
          'ledger release undo',
        );
        return;
      }
      final released = current.copyWith(
        status: InterventionStatus.releasedByStepUp,
        stepUp: stepUp,
      );
      final recordReleased = await _tryWrite(
        () => interventions.upsertAcked(released),
        'intervention record release',
      );
      if (!recordReleased) {
        await boundedWrite(
          () => ledger.setStatus(txnId, LedgerStatus.held),
          'ledger release undo',
        );
        return;
      }
      _latest = released;
      ok = true;
    });
    return ok;
  }

  /// Entry point A (the server's `step_up`, passed on the PIN pad; code
  /// review m1): a closed record carrying [stepUp] so its `decisionId`
  /// points at something, then the `done` row with the same step-up.
  Future<void> recordStepUpPassed(
    String trigger,
    ScoreResponse score,
    StepUpRecord stepUp,
  ) async {
    final passed = _record(
      trigger,
      score,
      InterventionStatus.stepUpPassed,
      stepUp: stepUp,
    );
    _latest = passed;
    await boundedWrite(
      () => interventions.upsert(passed),
      'intervention record (step-up passed)',
    );
    await createTxn(LedgerStatus.done, stepUp: stepUp);
  }

  /// The stored record, or `null` when it cannot be read now.
  Future<InterventionRecord?> _stored() async {
    try {
      return await interventions.byId(recordId).timeout(pinWriteBudget);
    } on Object catch (e) {
      Log.w(_tag, 'stored record unreadable before the release', e);
      return null;
    }
  }

  /// Ledger row for this attempt; a store failure is logged, never thrown.
  /// Carries the amount step's warning fields, the simulated tag and, after
  /// a step-up, its record.
  Future<void> createTxn(
    String status, {
    String? interventionId,
    StepUpRecord? stepUp,
  }) => boundedWrite(
    () => ledger.create(
      user.uid,
      PayLedger.rowFor(
        intent,
        user,
        txnId: txnId,
        ts: clock.now(),
        status: status,
        interventionId: interventionId,
      ).copyWith(
        stepUp: stepUp,
        warningShown: intent.warningShown,
        warningChoice: intent.warningChoice,
        simulated: mode.simulated,
      ),
    ),
    'ledger write ($status)',
  );
}

/// Runs one store write for the PIN flow: waits at most [pinWriteBudget]
/// (the write carries on in the background after that), and logs and
/// swallows any failure, synchronous or not.
Future<void> boundedWrite(Future<Object?> Function() write, String what) async {
  await _tryWrite(write, what);
}

/// [boundedWrite] that says whether the write answered in time without an
/// error.
Future<bool> _tryWrite(Future<Object?> Function() write, String what) async {
  try {
    await write().timeout(pinWriteBudget);
    return true;
  } on TimeoutException {
    Log.w(
      _tag,
      '$what still pending after ${pinWriteBudget.inMilliseconds} ms',
    );
  } on Object catch (e) {
    Log.w(_tag, '$what failed', e);
  }
  return false;
}
