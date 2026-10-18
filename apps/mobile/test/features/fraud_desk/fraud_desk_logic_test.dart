import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/palette.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/features/fraud_desk/logic/fraud_desk_format.dart';
import 'package:bhorosha/features/fraud_desk/logic/fraud_desk_providers.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart'
    show clockProvider;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fraud_desk_test_support.dart' show FakeCaseDesk;

void main() {
  final now = DateTime.utc(2026, 10, 17, 8);

  CaseLink link(String acct, Duration ago, CaseStatus status) => CaseLink(
    caseId: 'CZ-$acct-${ago.inMinutes}',
    acctId: acct,
    openedAt: now.subtract(ago),
    lastStatus: status,
  );

  test('maskId keeps the last four letters or digits', () {
    expect(maskId('acct_01070'), '…1070');
    expect(maskId('acct_till_AG-0192'), '…0192');
    expect(maskId('txn_011308'), '…1308');
    expect(maskId('ab'), '…ab');
    expect(maskId('__'), '…');
  });

  test('poll cadence: 2 s while queued or running, else 10 s', () {
    expect(pollDelayFor(CaseStatus.queued), const Duration(seconds: 2));
    expect(pollDelayFor(CaseStatus.running), const Duration(seconds: 2));
    for (final s in [CaseStatus.done, CaseStatus.failed, CaseStatus.unknown]) {
      expect(pollDelayFor(s), const Duration(seconds: 10));
    }
    expect(pollDelayFor(null), const Duration(seconds: 10));
  });

  group('start guard', () {
    test('no link: may start', () {
      expect(startBlockFor('a', const [], now), isNull);
    });
    test('an open case on the payee blocks', () {
      for (final s in [
        CaseStatus.queued,
        CaseStatus.running,
        CaseStatus.unknown,
      ]) {
        expect(
          startBlockFor('a', [link('a', const Duration(hours: 5), s)], now),
          StartBlock.openCase,
        );
      }
    });
    test('a finished case inside 30 min is a cooldown; after, free', () {
      expect(
        startBlockFor('a', [
          link('a', const Duration(minutes: 29), CaseStatus.done),
        ], now),
        StartBlock.cooldown,
      );
      expect(
        startBlockFor('a', [
          link('a', const Duration(minutes: 30), CaseStatus.failed),
        ], now),
        isNull,
      );
    });
    test('another payee does not count', () {
      expect(
        startBlockFor('a', [
          link('b', const Duration(minutes: 1), CaseStatus.running),
        ], now),
        isNull,
      );
    });
  });

  test('labels and tones', () async {
    final bn = await AppLocalizations.delegate.load(const Locale('bn'));
    expect(roleLabel(bn, 'mule_L1'), 'প্রথম স্তর');
    expect(roleLabel(bn, 'mule_L2'), 'দ্বিতীয় স্তর');
    expect(roleLabel(bn, 'controller'), 'নিয়ন্ত্রক');
    expect(roleLabel(bn, 'cashout_agent'), 'ক্যাশ-আউট এজেন্ট');
    expect(roleLabel(bn, 'victim'), 'ভুক্তভোগী');
    expect(roleLabel(bn, 'mule_L9'), 'অন্যান্য');
    expect(payeeStatusOf(bn, 'suspected').tone, BhStatus.warning);
    expect(payeeStatusOf(bn, 'confirmed').tone, BhStatus.danger);
    expect(payeeStatusOf(bn, 'cleared').tone, BhStatus.success);
    expect(payeeStatusOf(bn, 'new').tone, BhStatus.neutral);
    expect(actionLabel(bn, CaseAction.freeze), 'অ্যাকাউন্ট আটকানো');
    expect(actionLabel(bn, CaseAction.pending), 'অপেক্ষায়');
    expect(actionLabel(bn, CaseAction.unknown), 'পর্যালোচকের কাছে');
    expect(caseStatusOf(bn, CaseStatus.failed).tone, isNot(BhStatus.danger));
    // Degraded: delivered, citations not verified (staff label).
    expect(
      caseStatusOf(bn, CaseStatus.degraded).label,
      'শেষ, সূত্র যাচাই হয়নি',
    );
    expect(caseStatusOf(bn, CaseStatus.degraded).tone, BhStatus.warning);
    expect(pollDelayFor(CaseStatus.degraded), const Duration(seconds: 10));
  });

  test('two start taps in one frame post one investigation: the payee is '
      'busy before the first await', () async {
    SharedPreferences.setMockInitialValues({});
    final desk = FakeCaseDesk();
    final c = ProviderContainer(
      overrides: [
        caseDeskApiProvider.overrideWithValue(desk),
        caseLinkRepoProvider.overrideWithValue(CaseLinkRepo()),
        clockProvider.overrideWithValue(FakeClock(now)),
      ],
    );
    addTearDown(c.dispose);
    final ctl = c.read(startCaseProvider.notifier);
    final first = ctl.start('rina', 'acct_01070');
    expect(c.read(startCaseProvider), {'acct_01070'}, reason: 'synchronous');
    final second = ctl.start('rina', 'acct_01070');
    final outcomes = await Future.wait([first, second]);
    expect(outcomes.first, isA<StartedCase>());
    expect(outcomes.last, isA<StartBlocked>());
    expect(desk.risk.callsTo(RiskRoutes.investigate), hasLength(1));
    expect(c.read(startCaseProvider), isEmpty);
  });
}
