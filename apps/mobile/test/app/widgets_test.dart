import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/bangla_numpad.dart';
import 'package:bhorosha/app/widgets/bh_button.dart';
import 'package:bhorosha/app/widgets/demo_banner.dart';
import 'package:bhorosha/app/widgets/persona_avatar.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/intervention/intervention_fakes.dart';

void main() {
  group('BanglaNumpad', () {
    testWidgets('shows the ten Bangla digits and reports taps', (tester) async {
      final digits = <int>[];
      var backspaces = 0;
      var confirms = 0;
      final downs = <(int, Offset, double)>[];
      final ups = <int>[];
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: BanglaNumpad(
              onDigit: digits.add,
              onBackspace: () => backspaces++,
              onConfirm: () => confirms++,
              onKeyDown: (i, pos, pressure, _, _) =>
                  downs.add((i, pos, pressure)),
              onKeyUp: (i, _) => ups.add(i),
            ),
          ),
        ),
      );

      for (final g in ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯']) {
        expect(find.text(g), findsOneWidget);
      }
      expect(find.text('0'), findsNothing);

      await tester.tap(find.text('৭'));
      await tester.tap(find.text('০'));
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();

      expect(digits, [7, 0]);
      expect(backspaces, 1);
      expect(confirms, 1);
      expect(downs.map((d) => d.$1), [
        7,
        0,
        BanglaNumpad.backspaceIndex,
        BanglaNumpad.confirmIndex,
      ]);
      expect(ups, [
        7,
        0,
        BanglaNumpad.backspaceIndex,
        BanglaNumpad.confirmIndex,
      ]);
      expect(downs.first.$3, 1.0, reason: 'test pointer pressure is 1.0');
      expect(downs.first.$2, tester.getCenter(find.text('৭')));

      // Key size: 72 dp tall, well over 56 dp wide on an 800 px canvas.
      final size = tester.getSize(find.text('৭').first);
      final key = tester.getSize(
        find.ancestor(of: find.text('৭'), matching: find.byType(InkWell)),
      );
      expect(key.height, BhSize.key);
      expect(key.width, greaterThanOrEqualTo(BhSize.touch));
      expect(size.height, lessThan(key.height));
    });

    testWidgets('disabled pad ignores taps and raw callbacks', (tester) async {
      var taps = 0;
      var downs = 0;
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: BanglaNumpad(
              enabled: false,
              onDigit: (_) => taps++,
              onBackspace: () => taps++,
              onKeyDown: (_, _, _, _, _) => downs++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('৫'));
      await tester.pump();
      expect(taps, 0);
      expect(downs, 0);
    });
  });

  group('BhButton', () {
    testWidgets('is at least 56 dp tall, full width, and loading disables', (
      tester,
    ) async {
      var pressed = 0;
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: Column(
              children: [
                BhButton(
                  key: const Key('a'),
                  label: 'পাঠান',
                  onPressed: () => pressed++,
                ),
                BhButton(
                  key: const Key('b'),
                  label: 'অপেক্ষা',
                  loading: true,
                  onPressed: () => pressed++,
                ),
                BhButton(
                  key: const Key('c'),
                  label: 'বাতিল',
                  variant: BhButtonVariant.danger,
                  onPressed: () => pressed++,
                ),
              ],
            ),
          ),
        ),
      );
      final a = tester.getSize(find.byKey(const Key('a')));
      expect(a.height, greaterThanOrEqualTo(BhSize.touch));
      expect(a.width, 800);
      await tester.tap(find.byKey(const Key('a')));
      await tester.tap(find.byKey(const Key('b')));
      await tester.pump();
      expect(pressed, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('TakaSlots / PersonaAvatar', () {
    testWidgets('formats with Bangla digits and lakh grouping', (tester) async {
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: Column(
              children: [
                Builder(builder: (c) => Text(c.taka(100000))),
                Builder(builder: (c) => Text(c.taka(9841))),
                const PersonaAvatar(nameBn: 'রিনা আক্তার'),
              ],
            ),
          ),
        ),
      );
      expect(find.text('৳ ১,০০,০০০'), findsOneWidget);
      expect(find.text('৳ ৯,৮৪১'), findsOneWidget);
      expect(find.text('রি'), findsOneWidget);
      expect(PersonaAvatar.initialOf('মা'), 'মা');
    });
  });

  group('DemoBanner', () {
    testWidgets('absent mode: demo text plus the Firebase status', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedApp(const Scaffold(body: DemoBanner(recording: false))),
      );
      final text = allTextsOf(tester).single;
      expect(text, contains('ডেমো মোড'));
      expect(text, 'ডেমো মোড · অফলাইন ডেটা');
      expect(text, isNot(contains('Firebase')));
      expect(text, isNot(contains('রেকর্ডিং')));
      expect(AppEnv.recording, isFalse);
    });

    testWidgets('recording adds the tag', (tester) async {
      await tester.pumpWidget(
        localizedApp(const Scaffold(body: DemoBanner(recording: true))),
      );
      expect(allTextsOf(tester).single, contains('রেকর্ডিং'));
    });

    test(
      'text mapping: Firebase status in Bangla, short recording form',
      () async {
        final l10n = await AppLocalizations.delegate.load(const Locale('bn'));
        String t(FirebaseStatus s, {bool recording = false}) =>
            DemoBanner.textFor(l10n, s, recording: recording);
        expect(t(FirebaseStatus.absent), 'ডেমো মোড · অফলাইন ডেটা');
        expect(t(FirebaseStatus.failed), 'ডেমো মোড · অফলাইন ডেটা');
        expect(t(FirebaseStatus.configured), '');
        expect(
          t(FirebaseStatus.absent, recording: true),
          'ডেমো মোড · রেকর্ডিং',
        );
        expect(
          t(FirebaseStatus.configured, recording: true),
          'ডেমো মোড · রেকর্ডিং',
        );
        expect(
          DemoBanner.dataLabel(l10n, FirebaseStatus.configured),
          'অনলাইন ডেটা',
        );
        expect(
          DemoBanner.dataLabel(l10n, FirebaseStatus.failed),
          'অফলাইন ডেটা',
        );
      },
    );

    testWidgets('readable in dark mode: light text on the dark info tint', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedApp(
          brightness: Brightness.dark,
          const Scaffold(body: DemoBanner(recording: false)),
        ),
      );
      final text = tester.widget<Text>(find.text('ডেমো মোড · অফলাইন ডেটা'));
      final p = BhPalette.of(BhPreset.teal, Brightness.dark);
      expect(text.style?.color, p.onInfoContainer);
      final strip = tester.widget<Material>(
        find.byKey(const Key('demo_banner')),
      );
      expect(strip.color, p.infoContainer);
      expect(text.style?.fontSize, greaterThanOrEqualTo(16));
    });

    testWidgets('configured hides the banner', (tester) async {
      await tester.pumpWidget(
        localizedApp(
          overrides: [
            firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
          ],
          const Scaffold(body: DemoBanner(recording: false)),
        ),
      );
      expect(find.byKey(const Key('demo_banner')), findsNothing);
    });
  });
}

List<String> allTextsOf(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();
