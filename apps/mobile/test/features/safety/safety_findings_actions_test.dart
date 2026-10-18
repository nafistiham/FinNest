import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/empty_state.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/findings_view.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:bhorosha/features/safety/ui/safety_screen.dart';
import 'package:bhorosha/features/safety/ui/widgets/findings_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'findings_fixtures.dart';
import 'safety_test_support.dart';

void main() {
  setUpAll(loadAppFonts);

  Future<ProviderContainer> pumpRich(
    WidgetTester tester, {
    SafetyHarness? harness,
    // Tall enough that the lazy list builds every row; the render tests use
    // real phone sizes and scroll.
    Size size = const Size(1080, 9000),
    double ratio = 2.625,
    Locale locale = const Locale('bn'),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h =
        harness ??
        SafetyHarness(
          response: richResponse,
          bundle: richBundle,
          demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
        );
    final c = await pumpSafety(
      tester,
      harness: h,
      child: const SafetyScreen(blocked: false),
      locale: locale,
      brightness: brightness,
    );
    await tester.pumpAndSettle();
    expect(h.api.callsTo(RiskRoutes.appSafety), hasLength(1));
    return c;
  }

  Finder card(String pkg) => find.byKey(ValueKey('safety-app-$pkg'));
  Finder cta(Finding f) =>
      find.byKey(ValueKey('finding_cta_${FindingKinds.idOf(f)}'));
  Finder row(Finding f) =>
      find.byKey(ValueKey('finding_row_${FindingKinds.idOf(f)}'));

  final list = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
  );

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(f, 200, scrollable: list.first);
    }
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('search, chips and sort sit between the header and the list', (
    tester,
  ) async {
    await pumpRich(tester);
    final header = tester.getRect(find.byKey(const Key('safety-verdict-card')));
    final search = tester.getRect(find.byKey(FindingsControls.searchKey));
    final filters = tester.getRect(find.byKey(FindingsControls.filtersKey));
    final sort = tester.getRect(find.byKey(FindingsControls.sortKey));
    expect(search.top, greaterThan(header.bottom));
    expect(filters.top, greaterThan(search.bottom));
    expect(sort.top, greaterThan(filters.bottom));
    expect(
      tester.getTopLeft(card('com.demo.takanow')).dy,
      greaterThan(sort.bottom),
    );
    expect(find.text('অ্যাপ বা সমস্যা খুঁজুন'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    // Chip sizes: 32 dp painted, 44 dp hit area; sort 56 dp.
    final chip = find.byKey(
      FindingsControls.severityChipKey(SeverityFilter.danger),
    );
    expect(tester.getSize(chip).height, FilterChipButton.hitHeight);
    expect(
      tester.getSize(find.byKey(FindingsControls.sortKey)).height,
      greaterThanOrEqualTo(BhSize.touch),
    );
    // Severity chips and the categories present; never a raw code.
    for (final label in ['সব', 'বিপজ্জনক', 'সতর্কতা', 'তথ্য', 'অনুমতি']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('_'), findsNothing);
    // The re-check stays in the bottom bar.
    expect(find.byKey(const Key('safety-recheck')), findsOneWidget);
  });

  testWidgets('a single finding gets no search or chips', (tester) async {
    const one = AppSafetyResponse(
      verdict: SafetyVerdict.caution,
      riskScore: 0.4,
      findings: [mediumFinding],
      recommendedAction: 'review',
      appsToUninstall: [],
      userMessageBn: 'সাবধান থাকুন।',
      userMessageEn: 'Be careful.',
      simulatedVerdict: false,
      resolution: 'NONE',
    );
    await pumpRich(tester, harness: SafetyHarness(response: one));
    expect(find.byKey(FindingsControls.searchKey), findsNothing);
    expect(cta(mediumFinding), findsOneWidget);
  });

  testWidgets('search narrows by title and by app name; clear restores', (
    tester,
  ) async {
    await pumpRich(tester);
    await tester.enterText(find.byKey(FindingsControls.searchKey), 'রুট');
    await tester.pumpAndSettle();
    expect(find.text(rootedFinding.titleBn), findsOneWidget);
    expect(card('com.demo.takanow'), findsNothing);
    expect(card('com.demo.flash'), findsNothing);
    expect(row(deviceFinding), findsNothing);

    await tester.enterText(find.byKey(FindingsControls.searchKey), 'FLASH');
    await tester.pumpAndSettle();
    expect(card('com.demo.flash'), findsOneWidget);
    expect(card('com.example.bank'), findsNothing);
    expect(find.text('আপনার ফোন'), findsNothing);

    await tester.tap(find.byKey(FindingsControls.searchClearKey));
    await tester.pumpAndSettle();
    expect(card('com.example.bank'), findsOneWidget);
    expect(card('com.demo.takanow'), findsOneWidget);
  });

  testWidgets('severity and category chips filter the list', (tester) async {
    await pumpRich(tester);
    await tester.tap(
      find.byKey(FindingsControls.severityChipKey(SeverityFilter.caution)),
    );
    await tester.pumpAndSettle();
    expect(card('com.demo.takanow'), findsNothing);
    expect(card('com.example.bank'), findsOneWidget);
    expect(row(overlayFinding), findsOneWidget);
    expect(row(dropperFinding), findsNothing);
    expect(find.text('আপনার ফোন'), findsNothing);

    await tester.tap(
      find.byKey(FindingsControls.severityChipKey(SeverityFilter.all)),
    );
    await tester.pumpAndSettle();
    final phone = find.byKey(
      FindingsControls.categoryChipKey(FindingCategory.phone),
    );
    await tester.ensureVisible(phone);
    await tester.pumpAndSettle();
    await tester.tap(phone);
    await tester.pumpAndSettle();
    expect(find.text('যা পাওয়া গেছে'), findsNothing);
    expect(row(rootedFinding), findsOneWidget);
    expect(row(deviceFinding), findsOneWidget);
    expect(row(capturingFinding), findsNothing);
    expect(tester.widget<FilterChipButton>(phone).selected, isTrue);
  });

  testWidgets('sort: danger first by default, by name A-Z on request', (
    tester,
  ) async {
    await pumpRich(tester);
    double y(String pkg) => tester.getTopLeft(card(pkg)).dy;
    expect(y('com.demo.takanow'), lessThan(y('com.demo.flash')));
    expect(y('com.demo.flash'), lessThan(y('com.example.bank')));

    await tester.tap(
      find.byKey(FindingsControls.sortSegmentKey(FindingSort.name)),
    );
    await tester.pumpAndSettle();
    expect(y('com.example.bank'), lessThan(y('com.demo.flash')));
    expect(y('com.demo.flash'), lessThan(y('com.demo.takanow')));
  });

  testWidgets('nothing found: the empty state clears the filters', (
    tester,
  ) async {
    await pumpRich(tester);
    await tester.tap(
      find.byKey(FindingsControls.severityChipKey(SeverityFilter.danger)),
    );
    await tester.enterText(find.byKey(FindingsControls.searchKey), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('কিছু পাওয়া যায়নি'), findsOneWidget);
    expect(card('com.demo.takanow'), findsNothing);

    await tapVisible(tester, find.text('ফিল্টার সরান'));
    expect(find.byType(EmptyState), findsNothing);
    expect(card('com.demo.takanow'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(FindingsControls.searchKey))
          .controller!
          .text,
      isEmpty,
    );
    final all = tester.widget<FilterChipButton>(
      find.byKey(FindingsControls.severityChipKey(SeverityFilter.all)),
    );
    expect(all.selected, isTrue);
  });

  group('every finding has a CTA that does what it says', () {
    final cases = <(Finding, String, void Function(SafetyHarness h))>[
      (
        blockFinding,
        'সার্ভিস বন্ধ করুন',
        (h) => expect(h.native.accessibilitySettingsCalls, 1),
      ),
      (
        dropperFinding,
        'আনইনস্টল করুন',
        (h) => expect(h.native.uninstalledPackages, ['com.demo.flash']),
      ),
      (
        overlayFinding,
        'এখনই বন্ধ করুন',
        (h) => expect(h.native.settingsPanels, [
          (SettingsPanel.overlay, 'com.demo.flash'),
        ]),
      ),
      (
        mediumFinding,
        'অনুমতি বন্ধ করুন',
        (h) => expect(h.native.openedPackages, ['com.example.bank']),
      ),
      (
        deviceFinding,
        'সেটিংস ঠিক করুন',
        (h) =>
            expect(h.native.settingsPanels, [(SettingsPanel.developer, null)]),
      ),
      (
        capturingFinding,
        'এখনই বন্ধ করুন',
        (h) => expect(h.native.settingsPanels, [(SettingsPanel.cast, null)]),
      ),
    ];
    for (final (finding, label, check) in cases) {
      testWidgets('${finding.signal}: "$label"', (tester) async {
        final h = SafetyHarness(
          response: richResponse,
          bundle: richBundle,
          demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
        );
        final c = await pumpRich(tester, harness: h);
        final button = cta(finding);
        expect(button, findsOneWidget);
        expect(
          find.descendant(of: button, matching: find.text(label)),
          findsOneWidget,
        );
        expect(
          tester.getSize(button).height,
          greaterThanOrEqualTo(BhSize.touch),
        );
        await tapVisible(tester, button);
        check(h);
        // Leaving the app arms the resume re-check and records the attempt.
        expect(
          c.read(safetyControllerProvider.notifier).pendingRecheck,
          isTrue,
        );
        expect(c.read(findingResolutionsProvider).attempted, {
          FindingKinds.idOf(finding),
        });
      });
    }

    testWidgets('DEVICE_ROOTED: "বুঝেছি" marks it seen, nothing opens', (
      tester,
    ) async {
      final h = SafetyHarness(
        response: richResponse,
        bundle: richBundle,
        demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
      );
      final c = await pumpRich(tester, harness: h);
      final button = cta(rootedFinding);
      expect(
        find.descendant(of: button, matching: find.text('বুঝেছি')),
        findsOneWidget,
      );
      await tapVisible(tester, button);
      expect(cta(rootedFinding), findsNothing);
      expect(
        find.byKey(
          ValueKey('finding_done_${FindingKinds.idOf(rootedFinding)}'),
        ),
        findsOneWidget,
      );
      expect(find.text('দেখা হয়েছে'), findsOneWidget);
      expect(c.read(findingResolutionsProvider).acknowledged, {
        FindingKinds.idOf(rootedFinding),
      });
      expect(c.read(safetyControllerProvider.notifier).pendingRecheck, isFalse);
      expect(h.native.openedPackages, isEmpty);
      expect(h.native.settingsPanels, isEmpty);
    });
  });

  testWidgets('a target\'s uninstall finding uses the card\'s one button', (
    tester,
  ) async {
    const sideloaded = Finding(
      package: 'com.demo.takanow',
      signal: 'SIDELOADED_DATA_REACH',
      severity: 'high',
      evidence: 'installer=null',
      explanationBn: 'বাইরে থেকে বসানো।',
      explanationEn: 'Installed from outside the store.',
      titleBn: 'বাইরে থেকে ইনস্টল',
      titleEn: 'Installed from outside the store',
    );
    const response = AppSafetyResponse(
      verdict: SafetyVerdict.block,
      riskScore: 0.9,
      findings: [blockFinding, sideloaded],
      recommendedAction: 'uninstall',
      appsToUninstall: ['com.demo.takanow'],
      userMessageBn: 'TakaNow সরান।',
      userMessageEn: 'Remove TakaNow.',
      simulatedVerdict: false,
      resolution: 'UNINSTALL_AND_RECHECK',
      recheckLiftsBlock: true,
      uninstallTargets: [takaNowTarget],
    );
    final h = SafetyHarness(response: response);
    final c = await pumpRich(tester, harness: h);
    expect(find.text('আনইনস্টল করুন'), findsOneWidget);
    expect(find.byType(UninstallButton), findsOneWidget);
    expect(
      tester.widget<UninstallButton>(cta(sideloaded)).target.package,
      'com.demo.takanow',
    );
    expect(cta(blockFinding), findsOneWidget);
    await tapVisible(tester, cta(sideloaded));
    expect(h.native.openedPackages, ['com.demo.takanow']);
    expect(c.read(findingResolutionsProvider).attempted, {
      FindingKinds.idOf(blockFinding),
      FindingKinds.idOf(sideloaded),
    });
  });

  testWidgets('tapping a finding opens its full detail with the same CTA', (
    tester,
  ) async {
    final h = SafetyHarness(
      response: richResponse,
      bundle: richBundle,
      demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
    );
    await pumpRich(tester, harness: h);
    await tapVisible(tester, row(overlayFinding));
    final sheet = find.byKey(
      ValueKey('finding_sheet_${FindingKinds.idOf(overlayFinding)}'),
    );
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text(overlayFinding.evidence)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text('ফিরে এলে আবার যাচাই হবে।'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        ValueKey('finding_sheet_cta_${FindingKinds.idOf(overlayFinding)}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(h.native.settingsPanels, [
      (SettingsPanel.overlay, 'com.demo.flash'),
    ]);
  });

  testWidgets('English: labels and CTAs in English', (tester) async {
    await pumpRich(tester, locale: const Locale('en'));
    expect(find.text('Search apps or issues'), findsOneWidget);
    expect(find.text('Danger first'), findsOneWidget);
    expect(
      find.descendant(
        of: cta(blockFinding),
        matching: find.text('Turn off service'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: cta(rootedFinding), matching: find.text('Got it')),
      findsOneWidget,
    );
  });

  group('renders without overflow', () {
    for (final (size, ratio, dp) in const [
      (Size(1080, 1920), 3.0, 360),
      (Size(1236, 2745), 3.0, 412),
    ]) {
      for (final brightness in Brightness.values) {
        for (final locale in const [Locale('bn'), Locale('en')]) {
          testWidgets('${locale.languageCode}/${brightness.name} at $dp dp', (
            tester,
          ) async {
            await pumpRich(
              tester,
              size: size,
              ratio: ratio,
              locale: locale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            // Scroll the whole list and open a sheet: still clean.
            await tapVisible(tester, row(capturingFinding));
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const Key('sheet_close')));
            await tester.pumpAndSettle();
            await tester.drag(list.first, const Offset(0, 6000));
            await tester.pumpAndSettle();
            await tapVisible(
              tester,
              find.byKey(FindingsControls.sortSegmentKey(FindingSort.name)),
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
