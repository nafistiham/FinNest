/// What a customer may be told about the review of a held transfer
///: only their own money and the progress
/// of a case this phone opened. Never the payee's status, the ring, the
/// evidence, the summary or the watch-list facts.
library;

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';

/// The customer lines, cumulative: [moneySafe] says one line, [inReview]
/// and [finished] each add one.
enum ReviewState {
  /// Not held (done, released, cancelled, ...): no lines at all.
  none,

  /// "টাকা পাঠানো হয়নি, আপনার কাছেই আছে।"
  moneySafe,

  /// + "যাচাই চলছে।"
  inReview,

  /// + "যাচাই শেষ, টাকা আপনার কাছেই।"
  finished,
}

/// The review state of a ledger row in [rowStatus] held at [heldAt].
///
/// [link] is the newest case this phone opened on the row's payee; it only
/// counts when opened at or after [heldAt] (an older case says nothing about
/// this transfer), and never when it was adopted from the watch-list
/// rather than started here. [report] is the freshest read of that case, when one is
/// at hand; otherwise the link's last seen status and model version stand
/// in. A stub-fallback answer never counts as a finished review. There is
/// deliberately no watch-list input: it carries the payee's status, not the
/// progress of a review, and an empty list must never claim anything.
ReviewState reviewStateFor({
  required String rowStatus,
  required CaseLink? link,
  required CaseReport? report,
  required DateTime heldAt,
}) {
  if (rowStatus != LedgerStatus.held) return ReviewState.none;
  if (link == null || link.adopted || link.openedAt.isBefore(heldAt)) {
    return ReviewState.moneySafe;
  }
  final sameCase = report != null && report.caseId == link.caseId;
  final status = sameCase ? report.status : link.lastStatus;
  final stub = sameCase ? report.isStubFallback : link.isStubFallback;
  return switch (status) {
    // A degraded case was delivered, so the review is over; the
    // customer hears the same "finished, money still with you" line and
    // nothing about why the citations failed.
    CaseStatus.done || CaseStatus.degraded when !stub => ReviewState.finished,
    CaseStatus.done ||
    CaseStatus.degraded ||
    CaseStatus.failed => ReviewState.moneySafe,
    CaseStatus.queued ||
    CaseStatus.running ||
    CaseStatus.unknown => ReviewState.inReview,
  };
}
