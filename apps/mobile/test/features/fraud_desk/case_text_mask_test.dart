// Staff text masking and the evidence count
// of the recorded Case Zero report.
import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/fraud_desk/logic/fraud_desk_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17);
  const phones = {'acct_rina': '017XXXXX412'};

  group('maskCaseText', () {
    test('numbered accounts keep their last four digits, in the language', () {
      expect(
        maskCaseText('to acct_01070 and acct_36', bangla: false, now: now),
        'to …1070 and …36',
      );
      expect(maskCaseText('acct_01070-এ', bangla: true, now: now), '…১০৭০-এ');
    });

    test('a named account is masked by its number, never its name', () {
      final out = maskCaseText(
        'ভুক্তভোগী acct_rina',
        bangla: true,
        phones: phones,
        now: now,
      );
      expect(out, 'ভুক্তভোগী …৪১২');
      expect(
        maskCaseText('victim acct_unknown', bangla: false, now: now),
        'victim …••••',
      );
    });

    test('transfer ids leave the prose', () {
      expect(
        maskCaseText('txn_011308 এর মাধ্যমে', bangla: true, now: now),
        'তালিকার লেনদেনের মাধ্যমে',
      );
      expect(
        maskCaseText('in txn_011308.', bangla: false, now: now),
        'in a listed transfer.',
      );
      expect(citedTxnIds(['a txn_1 b txn_2', 'txn_1 again']), [
        'txn_1',
        'txn_2',
      ]);
    });

    test('server times read "১০ নভেম্বর, ১৪:১৩", in either digits', () {
      expect(
        maskCaseText(
          '২০২৬-১১-১০ তারিখে ১৪:১৩:০০ সময়ে',
          bangla: true,
          now: now,
        ),
        '১০ নভেম্বর, ১৪:১৩ সময়ে',
      );
      expect(
        maskCaseText('On 2026-11-10 at 14:13:00, x', bangla: false, now: now),
        'On 10 November, 14:13, x',
      );
      expect(
        maskCaseText('2026-11-10 14:13:00', bangla: true, now: now),
        '১০ নভেম্বর, ১৪:১৩',
      );
      expect(
        maskCaseText('on 2025-11-10', bangla: false, now: now),
        'on 10 November 2025',
      );
      expect(maskCaseText('at 09:05:59', bangla: false, now: now), 'at 09:05');
    });

    test('"ভিকটিম" reads "ভুক্তভোগী"; the rest of the text is kept', () {
      expect(
        maskCaseText('ভিকটিম ও ভিক্টিম, আর সব আগের মতো।', bangla: true),
        'ভুক্তভোগী ও ভুক্তভোগী, আর সব আগের মতো।',
      );
    });
  });

  group('watch-list facts', () {
    const entry = PayeeRiskEntry(
      acctId: 'acct_00036',
      status: 'suspected',
      role: 'mule_L2',
      facts: [
        'acct_01070 received funds.',
        'No ids here.',
        'acct_00036 got Tk 2,000 from acct_01070 in txn_011308.',
        'acct_00036 again.',
      ],
    );

    test('only the row own facts (or facts naming no account), max two', () {
      expect(factsFor(entry), [
        'No ids here.',
        'acct_00036 got Tk 2,000 from acct_01070 in txn_011308.',
      ]);
      expect(factsFor(entry, max: 5), hasLength(3));
    });

    test('ids masked to "…NNNN", agent codes named', () {
      expect(
        maskFactText(
          'acct_00036 got Tk 2,000 from acct_01070 in txn_011308.',
          bangla: true,
        ),
        '…০০৩৬ got Tk 2,000 from …১০৭০ in …১৩০৮.',
      );
      expect(
        maskFactText('cash-out at agent AG-0014 and AG-0192', bangla: true),
        'cash-out at এজেন্ট AG-0014 and এজেন্ট AG-0192',
      );
      expect(
        maskFactText('acct_01070 at agent AG-0014', bangla: false),
        '…1070 at agent AG-0014',
      );
    });
  });

  test('the recorded done report parses every evidence row it carries', () {
    final json = jsonDecode(
      File('test/fixtures/case_zero/case_report_done.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final report = CaseReport.fromJson(json);
    final raw = json['evidence'] as List<dynamic>;
    expect(report.evidence, hasLength(raw.length));
    expect(report.evidence.first.rowId, 'txn_011308');
    expect(report.ring, hasLength(6));
    // A report without evidence rows (risk-mw drops a flag with no cited
    // transfer) parses to an empty list, not a failure.
    final none = CaseReport.fromJson({...json, 'evidence': <Object>[]});
    expect(none.evidence, isEmpty);
  });
}
