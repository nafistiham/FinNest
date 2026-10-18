import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/features/safety/logic/review_state.dart';
import 'package:bhorosha/features/safety/ui/widgets/review_lines.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app/theme_harness.dart';

void main() {
  const bn = {
    ReviewState.none: <String>[],
    ReviewState.moneySafe: ['টাকা পাঠানো হয়নি, আপনার কাছেই আছে।'],
    ReviewState.inReview: [
      'টাকা পাঠানো হয়নি, আপনার কাছেই আছে।',
      'যাচাই চলছে।',
    ],
    ReviewState.finished: [
      'টাকা পাঠানো হয়নি, আপনার কাছেই আছে।',
      'যাচাই শেষ, টাকা আপনার কাছেই।',
    ],
  };

  for (final MapEntry(key: state, value: lines) in bn.entries) {
    testWidgets('$state renders its Bangla lines', (tester) async {
      await tester.pumpWidget(themedApp(ReviewLines(state: state)));
      await tester.pump();
      for (final line in lines) {
        expect(find.text(line), findsOneWidget);
      }
      expect(
        find.byKey(const Key('review_lines')),
        lines.isEmpty ? findsNothing : findsOneWidget,
      );
    });
  }

  testWidgets('English lines', (tester) async {
    await tester.pumpWidget(
      themedApp(
        const ReviewLines(state: ReviewState.finished),
        locale: const Locale('en'),
      ),
    );
    await tester.pump();
    expect(
      find.text('The money was not sent. It is still with you.'),
      findsOneWidget,
    );
    expect(
      find.text('The review is finished. The money is still with you.'),
      findsOneWidget,
    );
  });

  test('linesOf matches the widget in both languages', () async {
    for (final l in const [Locale('bn'), Locale('en')]) {
      final l10n = await AppLocalizations.delegate.load(l);
      expect(ReviewLines.linesOf(l10n, ReviewState.none), isEmpty);
      expect(ReviewLines.linesOf(l10n, ReviewState.inReview), [
        l10n.reviewMoneySafe,
        l10n.reviewInReview,
      ]);
    }
  });

  testWidgets('no overflow at 360/412, both themes and languages', (
    tester,
  ) async {
    for (final s in ReviewState.values) {
      await pumpEverywhere(tester, () => ReviewLines(state: s));
    }
  });
}
