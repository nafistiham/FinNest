/// Helpers for the animated component tests. Not a test file.
library;

import 'package:bhorosha/core/haptics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The visible text under [root], in paint order ("৳ ১২,৩৪৫").
String shownText(WidgetTester tester, Finder root) => tester
    .widgetList<Text>(find.descendant(of: root, matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join();

/// The x scale of the first [Transform] under [root] (`getMaxScaleOnAxis`
/// would include z, which `Transform.scale` leaves at 1).
double scaleUnder(WidgetTester tester, Finder root) => tester
    .widget<Transform>(
      find.descendant(of: root, matching: find.byType(Transform)).first,
    )
    .transform
    .entry(0, 0);

/// Counts `success()` calls.
class RecordingHaptics extends NoHaptics {
  RecordingHaptics();

  int successes = 0;

  @override
  Future<void> success() async => successes++;
}
