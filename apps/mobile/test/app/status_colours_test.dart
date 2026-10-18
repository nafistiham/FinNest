// Status colours per the design system (skill section 2): red = block or
// danger only, amber = hold / wait / step-up, info blue = neutral facts.
// ux-review 2b, 6, 7, 8: a blue "অপেক্ষায়" tag and an amber "সিমুলেটেড"
// tag; a held History row lost its time to the tag. (The FNA-bar dot is gone.)
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/status_tag.dart';
import 'package:bhorosha/app/widgets/txn_row.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/ui/widgets/safety_status_row.dart';
import 'package:bhorosha/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/safety/safety_test_support.dart' show loadAppFonts;
import 'theme_harness.dart';

void main() {
  setUpAll(loadAppFonts);

  test('TxnRow.tagFor: a cash-in waiting is amber like a hold', () {
    final l10n = lookupAppLocalizations(const Locale('bn'));
    expect(TxnRow.tagFor(l10n, 'requested')?.$2, BhStatus.warning);
    expect(TxnRow.tagFor(l10n, LedgerStatus.held)?.$2, BhStatus.warning);
    expect(TxnRow.tagFor(l10n, LedgerStatus.blocked)?.$2, BhStatus.danger);
  });

  testWidgets('the "সিমুলেটেড" tag is info, not amber', (tester) async {
    useViewport(tester);
    await tester.pumpWidget(
      themedApp(
        const SafetyStatusRow(verdict: SafetyVerdict.block, simulated: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<StatusTag>(find.byKey(SafetyStatusRow.tagKey)).status,
      BhStatus.info,
    );
  });

  for (final locale in const [Locale('bn'), Locale('en')]) {
    testWidgets('held send row at 360 dp (${locale.languageCode}): the '
        'subtitle wraps beside "আটকে আছে" instead of cutting the time', (
      tester,
    ) async {
      useViewport(tester, width: 360);
      final now = DateTime(2026, 10, 17, 5, 59);
      await tester.pumpWidget(
        themedApp(
          TxnRow(
            txn: LedgerTxn(
              txnId: 't1',
              // "আজ, ভোর ৫:৫৮": the longest Bangla time-of-day label.
              ts: now.subtract(const Duration(minutes: 1)),
              type: 'send_money',
              amountBdt: 1234567,
              fromAcct: 'acct_rina',
              toAcct: 'acct_x',
              status: LedgerStatus.held,
              counterpartyNameBn: 'নতুন নম্বর',
            ),
            acctId: 'acct_rina',
            now: now,
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final subtitle = find.byKey(const Key('txn_row_subtitle'));
      final r = tester.renderObject<RenderParagraph>(
        find.descendant(of: subtitle, matching: find.byType(RichText)),
      );
      expect(
        r.didExceedMaxLines,
        isFalse,
        reason: '"${r.text.toPlainText()}" is cut',
      );
      expect(find.byType(StatusTag), findsOneWidget);
      // The tag keeps its intrinsic width, beside the subtitle.
      expect(
        tester.getRect(find.byType(StatusTag)).left,
        greaterThan(tester.getRect(subtitle).right),
      );
    });
  }
}
