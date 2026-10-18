import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/review_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final heldAt = DateTime.utc(2026, 10, 17, 8);

  CaseLink link({
    Duration after = const Duration(minutes: 1),
    CaseStatus status = CaseStatus.running,
    String model = 'mule-lgbm',
  }) => CaseLink(
    caseId: 'CZ-1',
    acctId: 'acct_01070',
    openedAt: heldAt.add(after),
    lastStatus: status,
    modelVersion: model,
  );

  CaseReport report(CaseStatus status, {String model = 'mule-lgbm'}) =>
      CaseReport(
        caseId: 'CZ-1',
        acctId: 'acct_01070',
        status: status,
        summaryEn: '',
        summaryBn: '',
        evidence: const [],
        ring: const [],
        confidence: 0,
        recommendedAction: 'freeze',
        modelVersion: model,
      );

  ReviewState of(String row, {CaseLink? l, CaseReport? r}) =>
      reviewStateFor(rowStatus: row, link: l, report: r, heldAt: heldAt);

  test('rows that are not held get no lines', () {
    for (final s in [
      LedgerStatus.released,
      LedgerStatus.cancelled,
      LedgerStatus.done,
      LedgerStatus.ok,
      LedgerStatus.blocked,
    ]) {
      expect(of(s, l: link(status: CaseStatus.done)), ReviewState.none);
    }
  });

  test('held without a link: only the money line (empty watch-list claims '
      'nothing)', () {
    expect(of(LedgerStatus.held), ReviewState.moneySafe);
  });

  test('a link adopted from the watch-list says nothing, even when opened '
      'after the hold', () {
    final adopted = CaseLink(
      caseId: 'CZ-1',
      acctId: 'acct_01070',
      openedAt: heldAt.add(const Duration(minutes: 1)),
      lastStatus: CaseStatus.done,
      modelVersion: 'mule-lgbm',
      adopted: true,
    );
    expect(of(LedgerStatus.held, l: adopted), ReviewState.moneySafe);
    expect(
      of(LedgerStatus.held, l: adopted, r: report(CaseStatus.running)),
      ReviewState.moneySafe,
    );
  });

  test('a link opened before the hold says nothing about it', () {
    expect(
      of(LedgerStatus.held, l: link(after: const Duration(seconds: -1))),
      ReviewState.moneySafe,
    );
  });

  test('a link opened exactly at the hold counts', () {
    expect(
      of(LedgerStatus.held, l: link(after: Duration.zero)),
      ReviewState.inReview,
    );
  });

  test('queued, running or unknown → in review', () {
    for (final s in [
      CaseStatus.queued,
      CaseStatus.running,
      CaseStatus.unknown,
    ]) {
      expect(of(LedgerStatus.held, l: link(status: s)), ReviewState.inReview);
    }
  });

  test('done → finished; failed → money only', () {
    expect(
      of(LedgerStatus.held, l: link(status: CaseStatus.done)),
      ReviewState.finished,
    );
    expect(
      of(LedgerStatus.held, l: link(status: CaseStatus.failed)),
      ReviewState.moneySafe,
    );
  });

  test('a stub-fallback done never counts as finished', () {
    expect(
      of(
        LedgerStatus.held,
        l: link(status: CaseStatus.done, model: 'stub-fallback'),
      ),
      ReviewState.moneySafe,
    );
    expect(
      of(
        LedgerStatus.held,
        l: link(),
        r: report(CaseStatus.done, model: 'stub-fallback'),
      ),
      ReviewState.moneySafe,
    );
  });

  test('a fresh report of the same case wins over the link', () {
    expect(
      of(LedgerStatus.held, l: link(), r: report(CaseStatus.done)),
      ReviewState.finished,
    );
    expect(
      of(
        LedgerStatus.held,
        l: link(status: CaseStatus.done),
        r: report(CaseStatus.running),
      ),
      ReviewState.inReview,
    );
    expect(
      of(LedgerStatus.held, l: link(), r: report(CaseStatus.failed)),
      ReviewState.moneySafe,
    );
  });

  test('isStubFallback on the report', () {
    expect(
      report(CaseStatus.done, model: 'stub-fallback').isStubFallback,
      isTrue,
    );
    expect(report(CaseStatus.done).isStubFallback, isFalse);
  });

  test('degraded is terminal and reads as a finished review, money '
      'still with you', () {
    expect(CaseStatus.fromWire('degraded'), CaseStatus.degraded);
    expect(CaseStatus.degraded.isTerminal, isTrue);
    expect(
      of(LedgerStatus.held, l: link(), r: report(CaseStatus.degraded)),
      ReviewState.finished,
    );
    expect(
      of(LedgerStatus.held, l: link(status: CaseStatus.degraded)),
      ReviewState.finished,
    );
    expect(
      of(
        LedgerStatus.held,
        l: link(),
        r: report(CaseStatus.degraded, model: 'stub-fallback'),
      ),
      ReviewState.moneySafe,
    );
  });
}
