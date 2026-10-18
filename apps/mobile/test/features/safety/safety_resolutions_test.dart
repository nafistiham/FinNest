import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/features/safety/logic/findings_view.dart';
import 'package:bhorosha/features/safety/logic/safety_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'findings_fixtures.dart';
import 'safety_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an out-of-app CTA arms the re-check; the next check clears it',
    () async {
      final h = SafetyHarness(response: richResponse, bundle: richBundle);
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});
      final controller = c.read(safetyControllerProvider.notifier);
      await controller.refresh();

      await controller.resolveFinding(dropperFinding);
      expect(h.native.uninstalledPackages, ['com.demo.flash']);
      expect(controller.pendingRecheck, isTrue);
      expect(c.read(findingResolutionsProvider).attempted, {
        FindingKinds.idOf(dropperFinding),
      });

      await controller.resolveFinding(capturingFinding);
      expect(h.native.settingsPanels, [(SettingsPanel.cast, null)]);

      await controller.refresh();
      expect(c.read(findingResolutionsProvider).attempted, isEmpty);
    },
  );

  test('"বুঝেছি" is kept across checks and cleared by reset', () async {
    final h = SafetyHarness(response: richResponse, bundle: richBundle);
    final c = h.container();
    c.listen(safetyControllerProvider, (_, _) {});
    final controller = c.read(safetyControllerProvider.notifier);
    await controller.refresh();

    await controller.resolveFinding(rootedFinding);
    expect(controller.pendingRecheck, isFalse);
    final id = FindingKinds.idOf(rootedFinding);
    expect(c.read(findingResolutionsProvider).acknowledged, {id});

    await controller.refresh();
    expect(c.read(findingResolutionsProvider).acknowledged, {id});

    controller.reset();
    expect(c.read(findingResolutionsProvider).acknowledged, isEmpty);
  });

  test(
    'openUninstall records an attempt for each finding of that app',
    () async {
      final h = SafetyHarness(response: richResponse, bundle: richBundle);
      final c = h.container();
      c.listen(safetyControllerProvider, (_, _) {});
      final controller = c.read(safetyControllerProvider.notifier);
      await controller.refresh();
      await controller.openUninstall(takaNowTarget);
      expect(c.read(findingResolutionsProvider).attempted, {
        FindingKinds.idOf(blockFinding),
      });
    },
  );
}
