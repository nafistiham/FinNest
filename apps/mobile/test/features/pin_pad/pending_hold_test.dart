// The hold path's record writes: the
// trusted-contact request and a step-up release go through one queue, a
// release refuses anything that is not `open`, merges keep the request, and
// a release that did not land says so.

import 'dart:async';

import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/risk/cooldown.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';
import 'package:bhorosha/features/pay/logic/pay_intent.dart';
import 'package:bhorosha/features/pin_pad/logic/pending_hold.dart';
import 'package:bhorosha/features/send_money/logic/risk_outcome.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:flutter_test/flutter_test.dart';

import '../../data/local/test_bundle.dart';

const mismatch = Reason(
  code: 'ATO_BEHAVIOUR_MISMATCH',
  weight: 1,
  textBn: 'নিরাপত্তার জন্য একবার আপনার পরিচয় নিশ্চিত করতে চাই।',
  textEn: 'For your safety we want to confirm it is you.',
);

const hold = ScoreResponse(
  decision: Decision.hold,
  riskScore: 1,
  band: Band.critical,
  reasons: [mismatch],
  actions: [ActionItem(type: 'trusted_contact_check')],
  modelVersion: 'rules-v1',
  signalSources: SignalSources(),
);

const rina = UserProfile(
  uid: 'rina',
  nameBn: 'রিনা',
  nameEn: 'Rina',
  phoneMasked: '017XXXXX412',
  persona: Persona.rina,
  trustedContactUid: 'rahima',
  p95SendBdt: 5000,
  acctId: 'acct_rina',
  balanceBdt: 9841,
);

final at = DateTime.utc(2026, 10, 17, 9);

StepUpRecord stepUp(String decisionId) => StepUpRecord(
  method: StepUpRecord.biometric,
  at: at,
  decisionId: decisionId,
  serverDecision: 'hold',
  reasonCodes: const ['ATO_BEHAVIOUR_MISMATCH'],
);

/// Rejects the release write of a record (the open record still lands).
class _RejectingRelease extends LocalInterventionRepo {
  @override
  Future<void> upsert(InterventionRecord r) =>
      r.status == InterventionStatus.releasedByStepUp
      ? Future.error(StateError('PERMISSION_DENIED'))
      : super.upsert(r);
}

/// A Firestore-like ledger: the patch
/// lands in the local cache at once, but the server's acknowledgement is
/// [ack]: never (offline), or a rejection (the rules' owner check).
class _FirestoreLikeLedger extends LocalLedgerRepo {
  _FirestoreLikeLedger(this.ack) : super(DemoAssets(bundle: DiskAssetBundle()));

  final Future<void> Function() ack;

  @override
  Future<void> patch(String txnId, LedgerPatch patch) async {
    await super.patch(txnId, patch); // the cache, as Firestore does
    await ack();
  }
}

/// A Firestore-like intervention store whose acknowledged write is [ack];
/// the unacknowledged `upsert` still lands at once.
class _FirestoreLikeInterventions extends LocalInterventionRepo {
  _FirestoreLikeInterventions(this.ack);

  final Future<void> Function() ack;

  @override
  Future<void> upsertAcked(InterventionRecord r) => ack();
}

Future<void> _neverAcked() => Completer<void>().future;
Future<void> _denied() => Future.error(StateError('PERMISSION_DENIED'));

void main() {
  late LocalLedgerRepo ledger;
  late LocalInterventionRepo interventions;
  late FakeRiskApi api;
  late TrustedContactFlow flow;
  late PendingHold pending;

  PendingHold newHold({bool releaseAllowed = true}) {
    final clock = FakeClock(at);
    return PendingHold(
      user: rina,
      intent: const PayIntent(
        kind: PayKind.send,
        sessionId: 's1',
        counterparty: Counterparty(
          acctId: 'acct_rafiq',
          nameBn: 'রফিক ইসলাম',
          subtitle: '017XXXXX001',
        ),
        amountBdt: 500,
      ),
      clock: clock,
      ledger: ledger,
      interventions: interventions,
      cooldown: Cooldown(clock),
      lastScore: StateController<ScoreResponse?>(null),
      releaseAllowed: releaseAllowed,
    );
  }

  void setUpWith(LocalInterventionRepo repo, {LocalLedgerRepo? ledgerRepo}) {
    ledger =
        ledgerRepo ?? LocalLedgerRepo(DemoAssets(bundle: DiskAssetBundle()));
    interventions = repo;
    api = FakeRiskApi();
    flow = TrustedContactFlow(
      api: api,
      interventions: interventions,
      ledger: ledger,
      clock: FakeClock(at),
    );
    pending = newHold();
  }

  Future<LedgerTxn> row() async =>
      (await ledger.watchRecent('rina', limit: 50).first).firstWhere(
        (t) => t.txnId == pending.txnId,
      );

  Future<InterventionRecord> stored() async =>
      (await interventions.byId(pending.recordId))!;

  Future<InterventionRecord> ask() => pending.requestTrusted(
    (r) => flow.request(record: r, contactUid: rina.trustedContactUid),
  );

  group('with working stores', () {
    setUp(() => setUpWith(LocalInterventionRepo()));
    tearDown(() async {
      await ledger.dispose();
      await interventions.dispose();
    });

    test(
      'an open hold releases: row and record both carry the step-up',
      () async {
        pending.startHold('behaviour_mismatch', hold);
        expect(pending.stepUpOpen, isTrue);
        expect(await pending.release(stepUp(pending.recordId)), isTrue);
        expect((await row()).status, LedgerStatus.releasedByStepUp);
        final r = await stored();
        expect(r.status, InterventionStatus.releasedByStepUp);
        expect(r.stepUp?.decisionId, pending.recordId);
        expect(pending.stepUpOpen, isFalse);
      },
    );

    test('trusted contact asked, then the step-up: refused, the row stays '
        'held and the request stays on the record', () async {
      pending.startHold('behaviour_mismatch', hold);
      final asked = await ask();
      expect(pending.trustedSent.value, isTrue);
      expect(pending.stepUpClosed.value, isTrue);
      expect(pending.stepUpOpen, isFalse);

      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.held);
      final r = await stored();
      expect(r.status, InterventionStatus.pending);
      expect(r.requestId, asked.requestId);
      expect(r.contactUid, 'rahima');
      expect(r.stepUp, isNull);
    });

    test(
      'a release queued behind an in-flight request sees it and refuses; '
      'the later approval still finds the record by request_id',
      () async {
        pending.startHold('behaviour_mismatch', hold);
        await pending.opened;
        final asking = ask(); // in flight
        final releasing = pending.release(stepUp(pending.recordId));
        await asking;
        expect(await releasing, isFalse);

        final requestId = (await stored()).requestId!;
        final decision = await flow.approve(requestId);
        expect(decision.status, TrustedContactDecision.statusApproved);
        final r = await stored();
        expect(r.status, InterventionStatus.approved);
        expect(r.requestId, requestId, reason: 'request history kept');
        expect((await row()).status, LedgerStatus.done);
      },
    );

    test('approval first, then a release: refused, the ledger stays done '
        '(the stored record is read, M1)', () async {
      pending.startHold('behaviour_mismatch', hold);
      await ask();
      await flow.approve((await stored()).requestId!);
      expect((await row()).status, LedgerStatus.done);

      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.done);
      expect((await stored()).status, InterventionStatus.approved);
    });

    test('a record changed elsewhere (declined on the stored copy) is never '
        'released, even though this attempt still thinks it open', () async {
      pending.startHold('behaviour_mismatch', hold);
      final opened = await pending.opened;
      await interventions.upsert(
        opened.copyWith(status: InterventionStatus.declined),
      );
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.held);
    });

    test('no hold started: nothing to release', () async {
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
    });

    test('entry A pass writes a closed step_up_passed record the step-up '
        'points at, then the done row', () async {
      await pending.recordStepUpPassed(
        'behaviour_mismatch',
        hold.copyWithDecision(Decision.stepUp),
        stepUp(pending.recordId),
      );
      final r = await stored();
      expect(r.status, InterventionStatus.stepUpPassed);
      expect(r.status, 'step_up_passed');
      expect(r.stepUp?.decisionId, r.id);
      final t = await row();
      expect(t.status, LedgerStatus.done);
      expect(t.stepUp?.decisionId, r.id);
    });
  });

  group('with a store that rejects the release', () {
    setUp(() => setUpWith(_RejectingRelease()));
    tearDown(() async {
      await ledger.dispose();
      await interventions.dispose();
    });

    test('release says false and puts the row back to held', () async {
      pending.startHold('behaviour_mismatch', hold);
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.held);
      expect((await stored()).status, InterventionStatus.open);
      expect(pending.stepUpOpen, isTrue, reason: 'still open: may retry');
    });
  });

  group('review fixes: release failures and hold id', () {
    tearDown(() async {
      await ledger.dispose();
      await interventions.dispose();
    });

    test('without the demo panel the release is refused and '
        'nothing is written', () async {
      setUpWith(LocalInterventionRepo());
      pending = newHold(releaseAllowed: false);
      pending.startHold('behaviour_mismatch', hold);
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.held);
      expect((await stored()).status, InterventionStatus.open);
      expect(pending.stepUpClosed.value, isTrue);
    });

    test('a ledger patch the server rejects is a failed release; '
        'the cached row goes back to held', () async {
      setUpWith(
        LocalInterventionRepo(),
        ledgerRepo: _FirestoreLikeLedger(_denied),
      );
      pending.startHold('behaviour_mismatch', hold);
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.held);
      expect((await stored()).status, InterventionStatus.open);
    });

    test('a ledger patch never acknowledged within the budget is '
        'a failed release, not a sent one', () async {
      setUpWith(
        LocalInterventionRepo(),
        ledgerRepo: _FirestoreLikeLedger(_neverAcked),
      );
      pending.startHold('behaviour_mismatch', hold);
      final watch = Stopwatch()..start();
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect(watch.elapsed, greaterThanOrEqualTo(pinWriteBudget));
      expect((await row()).status, LedgerStatus.held);
    });

    test('a record write the server delays past the budget '
        'is a failed release; the row goes back to held', () async {
      setUpWith(_FirestoreLikeInterventions(_neverAcked));
      pending.startHold('behaviour_mismatch', hold);
      expect(await pending.release(stepUp(pending.recordId)), isFalse);
      expect((await row()).status, LedgerStatus.held);
      expect((await stored()).status, InterventionStatus.open);
    });

    test(
      'a record write the server rejects is a failed release',
      () async {
        setUpWith(_FirestoreLikeInterventions(_denied));
        pending.startHold('behaviour_mismatch', hold);
        expect(await pending.release(stepUp(pending.recordId)), isFalse);
        expect((await row()).status, LedgerStatus.held);
      },
    );

    test('the record keeps the hold id from the score, then the '
        'id /v1/intervene opened', () async {
      setUpWith(LocalInterventionRepo());
      const held = ScoreResponse(
        decision: Decision.hold,
        riskScore: 1,
        band: Band.critical,
        reasons: [mismatch],
        actions: [
          ActionItem(
            type: 'trusted_contact_check',
            params: {'intervention_id': 'iv-hold', 'contact_uid': 'rafiq'},
          ),
        ],
        modelVersion: 'rules-v1',
        signalSources: SignalSources(),
      );
      pending.startHold('behaviour_mismatch', held);
      expect(pending.serverInterventionId, 'iv-hold');
      await pending.opened;
      expect((await stored()).serverInterventionId, 'iv-hold');

      await pending.finishHold(
        const Held(
          score: held,
          trigger: 'behaviour_mismatch',
          predictedAsset: 'apa_generic_caution',
          intervene: InterveneResponse(
            intervene: true,
            scriptBn: '',
            scriptEn: '',
            ui: UiMode.fullscreen,
            actions: [],
            cooldownS: 60,
            interventionId: 'iv-opened',
          ),
          speak: false,
        ),
      );
      expect(pending.serverInterventionId, 'iv-opened');
      expect((await stored()).serverInterventionId, 'iv-opened');

      await ask();
      expect(
        (api.calls.last.body! as Map)['intervention_id'],
        'iv-opened',
        reason: 'the trusted-contact create names the server id',
      );
    });

    test(
      'an intervene failure keeps the hold id from the score',
      () async {
        setUpWith(LocalInterventionRepo());
        const held = ScoreResponse(
          decision: Decision.hold,
          riskScore: 1,
          band: Band.critical,
          reasons: [mismatch],
          actions: [
            ActionItem(type: 'hold', params: {'intervention_id': 'iv-hold'}),
          ],
          modelVersion: 'rules-v1',
        );
        await pending.finishHold(
          const Held(
            score: held,
            trigger: 'behaviour_mismatch',
            predictedAsset: 'apa_generic_caution',
            intervene: null,
            speak: false,
          ),
        );
        expect((await stored()).serverInterventionId, 'iv-hold');
      },
    );
  });
}

extension on ScoreResponse {
  ScoreResponse copyWithDecision(Decision d) => ScoreResponse(
    decision: d,
    riskScore: riskScore,
    band: band,
    reasons: reasons,
    actions: actions,
    modelVersion: modelVersion,
    signalSources: signalSources,
  );
}
