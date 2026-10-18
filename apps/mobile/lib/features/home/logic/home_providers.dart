/// Streams the Home screen watches, keyed by uid so a persona switch swaps
/// them cleanly.
library;

import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final balanceProvider = StreamProvider.autoDispose.family<double, String>(
  (ref, uid) => ref.watch(ledgerRepoProvider).watchBalance(uid),
);

final recentTxnsProvider = StreamProvider.autoDispose
    .family<List<LedgerTxn>, String>(
      (ref, uid) => ref.watch(ledgerRepoProvider).watchRecent(uid),
    );

/// Interventions waiting on the trusted contact, newest first.
final pendingInterventionsProvider = StreamProvider.autoDispose
    .family<List<InterventionRecord>, String>(
      (ref, uid) => ref
          .watch(interventionRepoProvider)
          .watch(uid)
          .map(
            (rows) => rows
                .where((r) => r.status == InterventionStatus.pending)
                .toList(growable: false),
          ),
    );

/// Amount of the ledger row [key].txnId for user [key].uid (the held
/// transfer behind a pending trusted-contact card); `null` when not among
/// the last 100 rows.
final txnAmountProvider = StreamProvider.autoDispose
    .family<double?, ({String uid, String txnId})>(
      (ref, key) => ref
          .watch(ledgerRepoProvider)
          .watchRecent(key.uid, limit: 100)
          .map(
            (rows) =>
                rows.where((t) => t.txnId == key.txnId).firstOrNull?.amountBdt,
          ),
    );

/// The ledger row [key].txnId of user [key].uid (amount and payee of the
/// held transfer behind a pending trusted-contact card); `null` when not
/// among the last 100 rows.
final txnByIdProvider = StreamProvider.autoDispose
    .family<LedgerTxn?, ({String uid, String txnId})>(
      (ref, key) => ref
          .watch(ledgerRepoProvider)
          .watchRecent(key.uid, limit: 100)
          .map((rows) => rows.where((t) => t.txnId == key.txnId).firstOrNull),
    );

/// "Now" for Home's housekeeping (cash-in expiry); tests pin it.
final homeClockProvider = Provider<DateTime Function()>((_) => DateTime.now);
