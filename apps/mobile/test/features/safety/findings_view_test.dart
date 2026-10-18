import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/safety/logic/findings_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'findings_fixtures.dart';
import 'safety_test_support.dart';

void main() {
  FindingsView view(
    FindingsQuery q, {
    List<Finding> findings = richFindings,
    List<UninstallTarget> targets = const [takaNowTarget],
  }) => buildFindingsView(
    findings: findings,
    targets: targets,
    labelOf: (pkg) => richLabels[pkg] ?? 'Unknown',
    titleOf: (f) => f.titleEn,
    query: q,
  );

  List<String> apps(FindingsView v) => [for (final g in v.apps) g.label];
  List<String> signals(FindingsView v) => [
    for (final g in v.apps)
      for (final f in g.findings) f.signal,
    for (final f in v.device) f.signal,
  ];

  group('search', () {
    test('narrows by finding title, in either language, any case', () {
      final en = view(const FindingsQuery(text: 'DRAWS over'));
      expect(signals(en), ['OVERLAY_CAPABLE']);
      expect(apps(en), ['Flashlight Pro']);
      final bn = view(const FindingsQuery(text: 'রুট'));
      expect(signals(bn), ['DEVICE_ROOTED']);
      expect(bn.apps, isEmpty);
    });

    test('narrows by explanation (the body)', () {
      expect(signals(view(const FindingsQuery(text: 'contacts'))), [
        'LOAN_APP_DATA_HARVEST',
      ]);
    });

    test('an app-name hit keeps all of that app\'s findings', () {
      final v = view(const FindingsQuery(text: 'flash'));
      expect(apps(v), ['Flashlight Pro']);
      expect(v.apps.single.findings, hasLength(2));
      expect(v.device, isEmpty);
    });

    test('nothing matches: empty', () {
      expect(view(const FindingsQuery(text: 'zzzz')).isEmpty, isTrue);
    });
  });

  group('filters', () {
    test('severity is single-select by bucket', () {
      final danger = view(const FindingsQuery(severity: SeverityFilter.danger));
      expect(signals(danger), [
        'SIDELOADED_ACCESSIBILITY',
        'DROPPER_INSTALLED',
        'DEVICE_ROOTED',
        'INTEGRITY_CAPTURING',
      ]);
      final caution = view(
        const FindingsQuery(severity: SeverityFilter.caution),
      );
      expect(signals(caution), ['OVERLAY_CAPABLE', 'LOAN_APP_DATA_HARVEST']);
      final info = view(const FindingsQuery(severity: SeverityFilter.info));
      expect(signals(info), ['DEV_OPTIONS_ON']);
    });

    test('categories are multi-select and combine with severity', () {
      final one = view(
        const FindingsQuery(categories: {FindingCategory.permissions}),
      );
      expect(signals(one), ['LOAN_APP_DATA_HARVEST']);
      final two = const FindingsQuery().toggle(FindingCategory.permissions);
      final both = view(two.toggle(FindingCategory.phone));
      expect(signals(both), [
        'LOAN_APP_DATA_HARVEST',
        'DEVICE_ROOTED',
        'DEV_OPTIONS_ON',
      ]);
      expect(
        signals(
          view(
            two
                .toggle(FindingCategory.phone)
                .copyWith(severity: SeverityFilter.info),
          ),
        ),
        ['DEV_OPTIONS_ON'],
      );
      // Toggling again removes it.
      expect(two.toggle(FindingCategory.permissions).categories, isEmpty);
    });

    test('the chips show only categories present, at most six', () {
      expect(categoriesPresent(richFindings), [
        FindingCategory.permissions,
        FindingCategory.accessibility,
        FindingCategory.screen,
        FindingCategory.unknownApps,
        FindingCategory.phone,
      ]);
      expect(FindingCategory.values.length, lessThanOrEqualTo(6));
      expect(categoriesPresent(const [mediumFinding, deviceFinding]), [
        FindingCategory.permissions,
        FindingCategory.phone,
      ]);
    });

    test('cleared() keeps the sort', () {
      const q = FindingsQuery(
        text: 'x',
        severity: SeverityFilter.danger,
        categories: {FindingCategory.phone},
        sort: FindingSort.name,
      );
      expect(q.narrows, isTrue);
      final c = q.cleared();
      expect(c.narrows, isFalse);
      expect(c.sort, FindingSort.name);
    });
  });

  group('sort', () {
    test('by severity: danger first, apps by their worst finding', () {
      final v = view(const FindingsQuery());
      expect(apps(v), ['TakaNow', 'Flashlight Pro', 'Bank']);
      expect(
        [for (final f in v.apps[1].findings) f.signal],
        ['DROPPER_INSTALLED', 'OVERLAY_CAPABLE'],
      );
      expect([for (final f in v.device) f.severity], ['high', 'high', 'low']);
    });

    test('by name: apps A-Z, device rows by title', () {
      final v = view(const FindingsQuery(sort: FindingSort.name));
      expect(apps(v), ['Bank', 'Flashlight Pro', 'TakaNow']);
      expect(
        [for (final f in v.device) f.titleEn],
        ['Developer options on', 'Phone rooted', 'Screen is being captured'],
      );
    });
  });

  group('CTA mapping', () {
    final expected = <String, FindingAction>{
      'LOAN_APP_DATA_HARVEST': FindingAction.revokePermission,
      'CLASSIFIER_HIGH': FindingAction.revokePermission,
      'NOTIFICATION_LISTENER': FindingAction.revokePermission,
      'SMS_ROLE_TAKEOVER': FindingAction.revokePermission,
      'NFC_RELAY_CAPABLE': FindingAction.revokePermission,
      'DEVICE_ADMIN': FindingAction.revokePermission,
      'SIDELOADED_ACCESSIBILITY': FindingAction.disableService,
      'OVERLAY_CAPABLE': FindingAction.stopOverlay,
      'INTEGRITY_CONTROLLING': FindingAction.stopControl,
      'INTEGRITY_CAPTURING': FindingAction.stopCapture,
      'KNOWN_RAT': FindingAction.uninstall,
      'SIDELOADED_DATA_REACH': FindingAction.uninstall,
      'DROPPER_INSTALLED': FindingAction.uninstall,
      'BRAND_IMPERSONATION': FindingAction.uninstall,
      'ICON_HIDDEN': FindingAction.uninstall,
      'DEV_OPTIONS_ON': FindingAction.fixDeveloper,
      'PLAY_PROTECT_OFF': FindingAction.fixSecurity,
      'INTEGRITY_PLAY_PROTECT': FindingAction.fixSecurity,
      'DEVICE_ROOTED': FindingAction.acknowledge,
      'DEVICE_INTEGRITY_FAILED': FindingAction.acknowledge,
      'UNATTESTED_CLIENT': FindingAction.acknowledge,
      'CLIENT_TAMPERED': FindingAction.acknowledge,
      'BUNDLE_MISMATCH': FindingAction.acknowledge,
      'OTHER': FindingAction.acknowledge,
      'SOMETHING_NEW': FindingAction.acknowledge,
    };
    for (final MapEntry(key: signal, value: action) in expected.entries) {
      test('$signal -> ${action.name}', () {
        expect(FindingKinds.actionFor(appFinding(signal)), action);
      });
    }

    test('a package-bound action without a package is "বুঝেছি"', () {
      final f = appFinding('DROPPER_INSTALLED', package: '');
      expect(FindingKinds.actionFor(f), FindingAction.acknowledge);
      expect(FindingKinds.idOf(f), 'device_dropper_installed');
    });

    test('unknown device signal is a phone setting, unknown app one other', () {
      expect(
        FindingKinds.categoryOf(
          appFinding('NEW_ONE', package: '', scope: Finding.scopeDevice),
        ),
        FindingCategory.phone,
      );
      expect(
        FindingKinds.categoryOf(appFinding('NEW_ONE')),
        FindingCategory.other,
      );
    });
  });
}
