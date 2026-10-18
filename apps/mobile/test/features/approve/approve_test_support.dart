import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_intervention_repo.dart';
import 'package:bhorosha/data/local/local_ledger_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/trusted_contact_flow.dart';

import '../../data/local/test_bundle.dart';

/// 2026-10-16 12:00 UTC, the moment every approve test starts at.
final DateTime t0 = DateTime.utc(2026, 10, 16, 12);

const reasonCall = Reason(
  code: 'call_active',
  weight: 0.6,
  textBn: 'টাকা পাঠানোর সময় আপনি একটি কলে আছেন।',
  textEn: 'You are on a call while sending money.',
);

const reasonNewPayee = Reason(
  code: 'new_payee',
  weight: 0.3,
  textBn: 'এই নম্বরে আগে কখনো টাকা পাঠানো হয়নি।',
  textEn: 'Money has never been sent to this number before.',
);

LedgerTxn heldTxn({
  String txnId = 'txn_held_1',
  double amount = 5000,
  String uid = 'rina',
}) => LedgerTxn(
  txnId: txnId,
  ts: t0,
  type: 'send_money',
  amountBdt: amount,
  fromAcct: 'acct_$uid',
  toAcct: 'acct_01999',
  status: LedgerStatus.held,
  counterpartyNameBn: 'নতুন নম্বর',
  interventionId: 'int_1',
);

InterventionRecord openRecord({
  String id = 'int_1',
  String uid = 'rina',
  String txnId = 'txn_held_1',
  String status = InterventionStatus.open,
  String? requestId,
  DateTime? expiresAt,
  List<Reason> reasons = const [reasonCall, reasonNewPayee],
  String scriptEn = '',
}) => InterventionRecord(
  id: id,
  uid: uid,
  txnId: txnId,
  trigger: 'call_active',
  scriptBn: 'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন, আগে যাচাই করে নিন।',
  scriptEn: scriptEn,
  reasons: reasons,
  actions: const [ActionItem(type: 'trusted_contact_check')],
  status: status,
  createdAt: t0,
  requestId: requestId,
  expiresAt: expiresAt,
  contactUid: requestId == null ? null : 'rafiq',
);

/// Fake API plus the real local repos, seeded from the bundled demo assets.
class ApproveHarness {
  ApproveHarness({DateTime? now})
    : clock = FakeClock(now ?? t0),
      api = FakeRiskApi(),
      interventions = LocalInterventionRepo(),
      ledger = LocalLedgerRepo(DemoAssets(bundle: DiskAssetBundle())) {
    flow = TrustedContactFlow(
      api: api,
      interventions: interventions,
      ledger: ledger,
      clock: clock,
    );
  }

  final FakeClock clock;
  final FakeRiskApi api;
  final LocalInterventionRepo interventions;
  final LocalLedgerRepo ledger;
  late final TrustedContactFlow flow;

  /// A held row and a pending record pointing at it, expiring ten minutes
  /// after [t0]; returns the stored record.
  Future<InterventionRecord> seedPending({
    String requestId = 'req_1',
    Duration ttl = const Duration(minutes: 10),
  }) async {
    await ledger.create('rina', heldTxn());
    final record = openRecord(
      status: InterventionStatus.pending,
      requestId: requestId,
      expiresAt: t0.add(ttl),
    );
    await interventions.upsert(record);
    return record;
  }

  /// Reads the bundled seed once, in a real async zone. Widget tests call
  /// this from `setUp` so nothing inside `testWidgets` does file I/O.
  Future<void> warm() async {
    await ledger.watchRecent('rina', limit: 1).first;
  }

  Future<LedgerTxn?> txn(String txnId) async {
    final rows = await ledger.watchRecent('rina', limit: 100).first;
    for (final t in rows) {
      if (t.txnId == txnId) return t;
    }
    return null;
  }

  Future<void> dispose() async {
    await interventions.dispose();
    await ledger.dispose();
  }
}
