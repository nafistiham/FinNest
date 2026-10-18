import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approve_test_support.dart';

void main() {
  late ApproveHarness h;
  setUp(() => h = ApproveHarness());
  tearDown(() => h.dispose());

  group('request', () {
    test('posts the request and stores requestId/expiresAt/pending', () async {
      final record = openRecord();
      await h.interventions.upsert(record);
      h.api.trustedResponse = const TrustedContactResponse(
        requestId: 'req_42',
        expiresAt: '2026-10-16T12:10:00+00:00',
      );

      final updated = await h.flow.request(record: record, contactUid: 'rafiq');

      expect(h.api.calls.single.route, RiskRoutes.trustedContact);
      expect(h.api.calls.single.body, {
        'intervention_id': 'int_1',
        'contact_uid': 'rafiq',
      });
      expect(updated.requestId, 'req_42');
      expect(updated.expiresAt, DateTime.utc(2026, 10, 16, 12, 10));
      expect(updated.contactUid, 'rafiq');
      expect(updated.status, InterventionStatus.pending);
      expect(await h.interventions.findByRequestId('req_42'), updated);
    });

    test(
      'falls back to the default expiry when expires_at is unparseable',
      () async {
        final record = openRecord();
        h.api.trustedResponse = const TrustedContactResponse(
          requestId: 'req_x',
          expiresAt: 'soon',
        );
        final updated = await h.flow.request(
          record: record,
          contactUid: 'rafiq',
        );
        expect(updated.expiresAt, t0.add(TrustedContactFlow.fallbackExpiry));
      },
    );

    test('surfaces the API failure and leaves the record alone', () async {
      final record = openRecord();
      await h.interventions.upsert(record);
      h.api.failures[RiskRoutes.trustedContact] = const TimeoutFailure();

      await expectLater(
        h.flow.request(record: record, contactUid: 'rafiq'),
        throwsA(isA<TimeoutFailure>()),
      );
      final stored = (await h.interventions.watch('rina').first).single;
      expect(stored.status, InterventionStatus.open);
      expect(stored.requestId, isNull);
    });
  });

  group('approve', () {
    test('flips the ledger row to done and the record to approved', () async {
      await h.seedPending();
      expect((await h.txn('txn_held_1'))!.status, LedgerStatus.held);

      final decision = await h.flow.approve('req_1');

      expect(decision.status, TrustedContactDecision.statusApproved);
      expect(h.api.calls.single.route, RiskRoutes.trustedApprove);
      expect(h.api.calls.single.body, 'req_1');
      expect((await h.txn('txn_held_1'))!.status, LedgerStatus.done);
      expect(
        (await h.flow.findByRequestId('req_1'))!.status,
        InterventionStatus.approved,
      );
      // A done debit moves the balance (9841 seeded - 5000).
      expect(await h.ledger.watchBalance('rina').first, 4841);
    });

    test(
      'expired answer marks the record expired and keeps the row held',
      () async {
        await h.seedPending();
        h.api.decision = const TrustedContactDecision(
          requestId: 'req_1',
          status: TrustedContactDecision.statusExpired,
        );

        final decision = await h.flow.approve('req_1');

        expect(decision.status, TrustedContactDecision.statusExpired);
        expect(
          (await h.flow.findByRequestId('req_1'))!.status,
          InterventionStatus.expired,
        );
        expect((await h.txn('txn_held_1'))!.status, LedgerStatus.held);
      },
    );

    test('404 surfaces as ServerFailure(404) with nothing changed', () async {
      await h.seedPending();
      h.api.failures[RiskRoutes.trustedApprove] = const ServerFailure(
        404,
        serverMessage: 'unknown trusted-contact request',
      );

      await expectLater(
        h.flow.approve('req_1'),
        throwsA(isA<ServerFailure>().having((f) => f.status, 'status', 404)),
      );
      expect((await h.txn('txn_held_1'))!.status, LedgerStatus.held);
      expect(
        (await h.flow.findByRequestId('req_1'))!.status,
        InterventionStatus.pending,
      );
    });

    test(
      'a request unknown on this device returns the decision only',
      () async {
        final decision = await h.flow.approve('elsewhere');
        expect(decision.status, TrustedContactDecision.statusApproved);
        expect(await h.flow.findByRequestId('elsewhere'), isNull);
      },
    );
  });

  group('decline', () {
    test('keeps the ledger row held and marks the record declined', () async {
      await h.seedPending();

      final decision = await h.flow.decline('req_1');

      expect(decision.status, TrustedContactDecision.statusDeclined);
      expect(h.api.calls.single.route, RiskRoutes.trustedDecline);
      expect((await h.txn('txn_held_1'))!.status, LedgerStatus.held);
      expect(
        (await h.flow.findByRequestId('req_1'))!.status,
        InterventionStatus.declined,
      );
      expect(await h.ledger.watchBalance('rina').first, 9841);
    });

    test('pending after a decision leaves the record untouched', () async {
      await h.seedPending();
      h.api.decision = const TrustedContactDecision(
        requestId: 'req_1',
        status: TrustedContactDecision.statusPending,
      );
      await h.flow.decline('req_1');
      expect(
        (await h.flow.findByRequestId('req_1'))!.status,
        InterventionStatus.pending,
      );
    });
  });

  group('review fixes: server intervention id and contact identity', () {
    test('the create names the server intervention id when the '
        'record has one', () async {
      final record = openRecord().copyWith(serverInterventionId: 'iv-server-1');
      await h.flow.request(record: record, contactUid: 'rafiq');
      expect(h.api.calls.single.body, {
        'intervention_id': 'iv-server-1',
        'contact_uid': 'rafiq',
      });
    });

    test('without a server id the local record id is sent '
        '(demo mode accepts it unverified)', () async {
      await h.flow.request(record: openRecord(), contactUid: 'rafiq');
      expect((h.api.calls.single.body! as Map)['intervention_id'], 'int_1');
    });

    test(
      'approve and decline go out as the given contact uid',
      () async {
        await h.seedPending();
        await h.flow.approve('req_1', asUser: 'rafiq');
        expect(h.api.actingAsFor(RiskRoutes.trustedApprove), 'rafiq');
        await h.flow.decline('req_2', asUser: 'rafiq');
        expect(h.api.actingAsFor(RiskRoutes.trustedDecline), 'rafiq');
      },
    );

    test('an approval with contact_verified false keeps the hold '
        'and the record', () async {
      await h.seedPending();
      h.api.decision = const TrustedContactDecision(
        requestId: 'req_1',
        status: TrustedContactDecision.statusApproved,
        decidedBy: 'rina',
        contactVerified: false,
      );
      final decision = await h.flow.approve('req_1', asUser: 'rina');
      expect(decision.notByContact, isTrue);
      expect((await h.txn('txn_held_1'))!.status, LedgerStatus.held);
      expect(
        (await h.flow.findByRequestId('req_1'))!.status,
        InterventionStatus.pending,
      );
    });

    test('contact_verified true (or absent, an older server) '
        'still releases', () async {
      await h.seedPending();
      h.api.decision = const TrustedContactDecision(
        requestId: 'req_1',
        status: TrustedContactDecision.statusApproved,
        decidedBy: 'rafiq',
        contactVerified: true,
      );
      await h.flow.approve('req_1', asUser: 'rafiq');
      expect((await h.txn('txn_held_1'))!.status, LedgerStatus.done);
    });

    test('contactUidFor: the record names the contact, else the fallback', () {
      final named = openRecord(requestId: 'req_1');
      expect(TrustedContactFlow.contactUidFor(named, 'x'), 'rafiq');
      expect(TrustedContactFlow.contactUidFor(openRecord(), 'rafiq'), 'rafiq');
      expect(TrustedContactFlow.contactUidFor(null, 'rafiq'), 'rafiq');
    });
  });

  test('isExpired follows the injected clock', () async {
    final record = await h.seedPending();
    expect(h.flow.isExpired(record), isFalse);
    h.clock.advance(const Duration(minutes: 10));
    expect(h.flow.isExpired(record), isTrue);
  });
}
