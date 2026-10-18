// `ApaSheet.show` from any entry point: one sheet at a time and the
// light haptic of the 6.3 map.

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../intervention/intervention_fakes.dart' show RecordingHaptics;
import 'apa_test_doubles.dart';

class _Host extends StatelessWidget {
  const _Host({required this.haptics, required this.taps});

  final RecordingHaptics haptics;

  /// How many times one press calls `ApaSheet.show` (a tap burst).
  final int taps;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        key: const Key('open'),
        onPressed: () {
          for (var i = 0; i < taps; i++) {
            ApaSheet.show(context, screen: 'home', haptics: haptics);
          }
        },
        child: const Icon(Icons.open_in_new),
      ),
    ),
  );
}

Widget _app(ApaHarness h, Widget home) => ProviderScope(
  overrides: h.overrides,
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: const Locale('bn'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: home,
  ),
);

void main() {
  testWidgets('two quick taps open one sheet; closing it frees the slot', (
    tester,
  ) async {
    final h = ApaHarness();
    final haptics = RecordingHaptics();
    await tester.pumpWidget(_app(h, _Host(haptics: haptics, taps: 2)));

    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byType(ApaSheetBody), findsOneWidget);
    expect(haptics.lights, 1, reason: 'one haptic for the one sheet');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(_Host)),
    );
    expect(container.read(apaControllerProvider.notifier).sheetOpen, isTrue);

    await tester.tap(find.byKey(const Key('apa_close')));
    await tester.pumpAndSettle();
    expect(find.byType(ApaSheetBody), findsNothing);
    expect(container.read(apaControllerProvider.notifier).sheetOpen, isFalse);

    // The slot is free again: the next tap opens a sheet and buzzes once.
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byType(ApaSheetBody), findsOneWidget);
    expect(haptics.lights, 2);
  });

  testWidgets('the haptic fires inside show, so every entry point gets it', (
    tester,
  ) async {
    final h = ApaHarness();
    final haptics = RecordingHaptics();
    await tester.pumpWidget(_app(h, _Host(haptics: haptics, taps: 1)));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    expect(haptics.lights, 1);
    expect(haptics.warnings, 0);
  });
}
