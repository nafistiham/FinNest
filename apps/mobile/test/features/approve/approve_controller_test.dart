import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/approve_controller.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approve_test_support.dart';

void main() {
  late ApproveHarness h;
  late ProviderContainer container;

  setUp(() {
    h = ApproveHarness();
    container = ProviderContainer(
      overrides: [
        approveViewerUidProvider.overrideWithValue('rafiq'),
        trustedContactFlowProvider.overrideWithValue(h.flow),
        approveClockProvider.overrideWithValue(h.clock),
        ledgerRepoProvider.overrideWithValue(h.ledger),
        interventionRepoProvider.overrideWithValue(h.interventions),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await h.dispose();
  });

  /// Keeps the family alive for the test and waits for the local lookup.
  Future<ApproveController> start(String requestId) async {
    final provider = approveControllerProvider(requestId);
    container.listen(provider, (_, _) {});
    final notifier = container.read(provider.notifier);
    await pumpEventQueue();
    return notifier;
  }

  test(
    'loads the local record, its ledger row and the remaining time',
    () async {
      await h.seedPending();
      final c = await start('req_1');
      final s = container.read(approveControllerProvider('req_1'));

      expect(s.loaded, isTrue);
      expect(s.record?.id, 'int_1');
      expect(s.txn?.txnId, 'txn_held_1');
      expect(s.txn?.amountBdt, 5000);
      expect(s.remaining, const Duration(minutes: 10));
      expect(s.outcome, isNull);
      expect(s.canDecide, isTrue);
      expect(c.requestId, 'req_1');
    },
  );

  test('the decision goes out as the '
      "record's contact, not as the viewer's persona", () async {
    await h.seedPending();
    final c = await start('req_1');
    await c.approve();
    expect(h.api.actingAsFor(RiskRoutes.trustedApprove), 'rafiq');
  });

  test('a request from another phone is decided as the seed '
      'contact (approveContactFallbackProvider)', () async {
    final c = await start('elsewhere');
    await c.decline();
    expect(h.api.actingAsFor(RiskRoutes.trustedDecline), 'rafiq');
  });

  test('contact_verified false → not confirmed, no buttons, the '
      'record keeps waiting', () async {
    await h.seedPending();
    h.api.decision = const TrustedContactDecision(
      requestId: 'req_1',
      status: TrustedContactDecision.statusApproved,
      decidedBy: 'rina',
      contactVerified: false,
    );
    final c = await start('req_1');
    await c.approve();
    final s = container.read(approveControllerProvider('req_1'));
    expect(s.notConfirmed, isTrue);
    expect(s.outcome, ApproveState.notConfirmedOutcome);
    expect(s.approved, isFalse);
    expect(s.canDecide, isFalse);
    expect(s.record?.status, InterventionStatus.pending);
  });

  test('unknown id loads with no record and stays decidable', () async {
    await start('elsewhere');
    final s = container.read(approveControllerProvider('elsewhere'));
    expect(s.loaded, isTrue);
    expect(s.record, isNull);
    expect(s.txn, isNull);
    expect(s.remaining, isNull);
    expect(s.canDecide, isTrue);
  });

  test('countdown follows the FakeClock and expires at zero', () async {
    await h.seedPending();
    final c = await start('req_1');
    final provider = approveControllerProvider('req_1');

    h.clock.advance(const Duration(minutes: 9, seconds: 1));
    c.tick();
    expect(container.read(provider).remaining, const Duration(seconds: 59));
    expect(container.read(provider).expired, isFalse);

    h.clock.advance(const Duration(minutes: 2));
    c.tick();
    final s = container.read(provider);
    expect(s.remaining, Duration.zero);
    expect(s.expired, isTrue);
    expect(s.canDecide, isFalse);

    // Buttons stay disabled: approve is a no-op once expired.
    await c.approve();
    expect(h.api.calls, isEmpty);
  });

  test(
    'approve calls the flow, flips the row and records the decision',
    () async {
      await h.seedPending();
      final c = await start('req_1');

      await c.approve();
      await pumpEventQueue();

      final s = container.read(approveControllerProvider('req_1'));
      expect(s.busy, isFalse);
      expect(s.decision?.status, TrustedContactDecision.statusApproved);
      expect(s.approved, isTrue);
      expect(s.canDecide, isFalse);
      expect(s.record?.status, 'approved');
      expect((await h.txn('txn_held_1'))!.status, 'done');
    },
  );

  test('decline records the decision and keeps the row held', () async {
    await h.seedPending();
    final c = await start('req_1');

    await c.decline();

    final s = container.read(approveControllerProvider('req_1'));
    expect(s.declined, isTrue);
    expect((await h.txn('txn_held_1'))!.status, 'held');
  });

  test('busy while the call is in flight, then settles', () async {
    await h.seedPending();
    final c = await start('req_1');
    final release = h.api.hold(RiskRoutes.trustedApprove);

    final pending = c.approve();
    await pumpEventQueue();
    final mid = container.read(approveControllerProvider('req_1'));
    expect(mid.busy, isTrue);
    expect(mid.canDecide, isFalse);

    // A second tap while busy is ignored.
    await c.decline();
    expect(h.api.callsTo(RiskRoutes.trustedDecline), isEmpty);

    release();
    await pending;
    expect(container.read(approveControllerProvider('req_1')).busy, isFalse);
  });

  test(
    'API failure shows an error and retry repeats the same action',
    () async {
      await h.seedPending();
      final c = await start('req_1');
      h.api.failures[RiskRoutes.trustedApprove] = const NetworkFailure();

      await c.approve();
      var s = container.read(approveControllerProvider('req_1'));
      expect(s.error, isNotNull);
      expect(s.busy, isFalse);
      expect(s.canDecide, isTrue);

      h.api.failures.clear();
      await c.retry();
      s = container.read(approveControllerProvider('req_1'));
      expect(s.error, isNull);
      expect(s.approved, isTrue);
      expect(h.api.callsTo(RiskRoutes.trustedApprove), hasLength(2));
    },
  );

  test('404 from the server surfaces as an error line', () async {
    await start('ghost');
    h.api.failures[RiskRoutes.trustedApprove] = const ServerFailure(404);
    await container.read(approveControllerProvider('ghost').notifier).approve();
    final s = container.read(approveControllerProvider('ghost'));
    expect(s.error, contains('404'));
    expect(s.outcome, isNull);
  });

  test('a record already approved locally renders as approved', () async {
    await h.ledger.create('rina', heldTxn());
    await h.interventions.upsert(
      openRecord(
        status: 'approved',
        requestId: 'req_done',
        expiresAt: t0.add(const Duration(minutes: 10)),
      ),
    );
    await start('req_done');
    final s = container.read(approveControllerProvider('req_done'));
    expect(s.approved, isTrue);
    expect(s.canDecide, isFalse);
  });

  test('the requester opening her own request cannot decide', () async {
    await h.seedPending();
    final own = ProviderContainer(
      overrides: [
        approveViewerUidProvider.overrideWithValue('rina'),
        trustedContactFlowProvider.overrideWithValue(h.flow),
        approveClockProvider.overrideWithValue(h.clock),
        ledgerRepoProvider.overrideWithValue(h.ledger),
        interventionRepoProvider.overrideWithValue(h.interventions),
      ],
    );
    addTearDown(own.dispose);
    final provider = approveControllerProvider('req_1');
    own.listen(provider, (_, _) {});
    final c = own.read(provider.notifier);
    await pumpEventQueue();

    final s = own.read(provider);
    expect(s.notYours, isTrue);
    expect(s.canDecide, isFalse);
    await c.approve();
    expect(h.api.callsTo(RiskRoutes.trustedApprove), isEmpty);
    expect((await h.txn('txn_held_1'))!.status, 'held');
  });

  test('a request from another phone (no local record) stays decidable '
      'whoever is signed in', () async {
    await start('elsewhere');
    expect(
      container.read(approveControllerProvider('elsewhere')).notYours,
      isFalse,
    );
  });

  test('a local store error after the server answered never leaves the '
      'screen busy', () async {
    await h.seedPending();
    final broken = ProviderContainer(
      overrides: [
        approveViewerUidProvider.overrideWithValue('rafiq'),
        trustedContactFlowProvider.overrideWithValue(_StoreFailingFlow(h)),
        approveClockProvider.overrideWithValue(h.clock),
        ledgerRepoProvider.overrideWithValue(h.ledger),
        interventionRepoProvider.overrideWithValue(h.interventions),
      ],
    );
    addTearDown(broken.dispose);
    final provider = approveControllerProvider('req_1');
    broken.listen(provider, (_, _) {});
    final c = broken.read(provider.notifier);
    await pumpEventQueue();

    await c.approve();
    final s = broken.read(provider);
    expect(s.busy, isFalse);
    expect(s.error, 'local');
    expect(s.canDecide, isTrue, reason: 'retry stays possible');
  });
}

/// A flow whose decision calls fail in the local store, not the API.
class _StoreFailingFlow extends TrustedContactFlow {
  _StoreFailingFlow(ApproveHarness h)
    : super(
        api: h.api,
        interventions: h.interventions,
        ledger: h.ledger,
        clock: h.clock,
      );

  @override
  Future<TrustedContactDecision> approve(String requestId, {String? asUser}) =>
      Future.error(StateError('disk full'));
}
