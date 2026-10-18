/// Search, filter, sort and the per-finding action of the findings screen:
/// filters and search, a meaningful call to action for every item, and a
/// sort by severity or category.
///
/// Pure Dart: the screen passes the labels and the localised titles in, so
/// everything here is unit-testable. `Finding.signal` is the kind the server
/// sends (the `Signal` literal of `bhorosha_app_safety_check/schema.py`); it
/// is grouped into six human-readable categories and never shown.
library;

import 'package:bhorosha/data/contracts/contracts.dart';

/// Single-select severity chip. `low` and anything unknown count as info.
enum SeverityFilter { all, danger, caution, info }

/// At most six categories the chips show (only those present in the data).
enum FindingCategory {
  permissions,
  accessibility,
  screen,
  unknownApps,
  phone,
  other,
}

enum FindingSort { severity, name }

/// The one action of a finding row (its CTA).
enum FindingAction {
  /// App-info page, where the permission is switched off.
  revokePermission,

  /// Accessibility settings, where the service is switched off.
  disableService,

  /// The system uninstall dialog.
  uninstall,

  /// "Display over other apps" page of the app.
  stopOverlay,

  /// Accessibility settings: a remote controller drives the phone through a
  /// service.
  stopControl,

  /// Cast settings (device-wide), or the app-info page of the capturing app.
  stopCapture,

  /// Developer options.
  fixDeveloper,

  /// Security settings (Play Protect).
  fixSecurity,

  /// Nothing to switch off: "বুঝেছি" marks it seen.
  acknowledge;

  /// Whether the action leaves the app (and so arms the resume re-check).
  bool get leavesApp => this != acknowledge;
}

abstract final class FindingKinds {
  static const _category = <String, FindingCategory>{
    'LOAN_APP_DATA_HARVEST': FindingCategory.permissions,
    'CLASSIFIER_HIGH': FindingCategory.permissions,
    'NOTIFICATION_LISTENER': FindingCategory.permissions,
    'SMS_ROLE_TAKEOVER': FindingCategory.permissions,
    'NFC_RELAY_CAPABLE': FindingCategory.permissions,
    'DEVICE_ADMIN': FindingCategory.permissions,
    'SIDELOADED_ACCESSIBILITY': FindingCategory.accessibility,
    'OVERLAY_CAPABLE': FindingCategory.screen,
    'INTEGRITY_CONTROLLING': FindingCategory.screen,
    'INTEGRITY_CAPTURING': FindingCategory.screen,
    'KNOWN_RAT': FindingCategory.screen,
    'SIDELOADED_DATA_REACH': FindingCategory.unknownApps,
    'DROPPER_INSTALLED': FindingCategory.unknownApps,
    'BRAND_IMPERSONATION': FindingCategory.unknownApps,
    'ICON_HIDDEN': FindingCategory.unknownApps,
    'DEVICE_ROOTED': FindingCategory.phone,
    'DEV_OPTIONS_ON': FindingCategory.phone,
    'PLAY_PROTECT_OFF': FindingCategory.phone,
    'INTEGRITY_PLAY_PROTECT': FindingCategory.phone,
    'DEVICE_INTEGRITY_FAILED': FindingCategory.phone,
    'UNATTESTED_CLIENT': FindingCategory.phone,
  };

  static const _action = <String, FindingAction>{
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
  };

  /// Actions that need the app's package; without one they fall back to
  /// [FindingAction.acknowledge].
  static const _needsPackage = {
    FindingAction.revokePermission,
    FindingAction.uninstall,
  };

  /// The finding's category: by signal; an unknown device-scoped signal is a
  /// phone setting, anything else unknown is "other".
  static FindingCategory categoryOf(Finding f) =>
      _category[f.signal.toUpperCase()] ??
      (f.scope == Finding.scopeDevice
          ? FindingCategory.phone
          : FindingCategory.other);

  /// The row's CTA. A package-bound action on a finding with no real package
  /// (device scope) becomes "বুঝেছি".
  static FindingAction actionFor(Finding f) {
    final action = _action[f.signal.toUpperCase()] ?? FindingAction.acknowledge;
    if (_needsPackage.contains(action) && !hasPackage(f)) {
      return FindingAction.acknowledge;
    }
    return action;
  }

  static bool hasPackage(Finding f) =>
      f.scope != Finding.scopeDevice &&
      f.package.isNotEmpty &&
      f.package != Finding.scopeDevice;

  static SeverityFilter bucketOf(String severity) =>
      switch (severity.toLowerCase()) {
        'critical' || 'high' => SeverityFilter.danger,
        'medium' => SeverityFilter.caution,
        _ => SeverityFilter.info,
      };

  /// Most severe first (critical, high, medium, low, unknown).
  static int rank(String severity) => switch (severity.toLowerCase()) {
    'critical' => 0,
    'high' => 1,
    'medium' => 2,
    'low' => 3,
    _ => 4,
  };

  /// A stable id for keys and the resolution record: package (or `device`)
  /// and signal, lower-case. Never shown.
  static String idOf(Finding f) {
    final owner = hasPackage(f) ? f.package : Finding.scopeDevice;
    return '${owner}_${f.signal.toLowerCase()}';
  }
}

/// The screen's search, chips and sort. Lives in the screen state only.
class FindingsQuery {
  const FindingsQuery({
    this.text = '',
    this.severity = SeverityFilter.all,
    this.categories = const {},
    this.sort = FindingSort.severity,
  });

  final String text;
  final SeverityFilter severity;
  final Set<FindingCategory> categories;
  final FindingSort sort;

  /// Whether any search or filter (not the sort) narrows the list.
  bool get narrows =>
      text.trim().isNotEmpty ||
      severity != SeverityFilter.all ||
      categories.isNotEmpty;

  FindingsQuery copyWith({
    String? text,
    SeverityFilter? severity,
    Set<FindingCategory>? categories,
    FindingSort? sort,
  }) => FindingsQuery(
    text: text ?? this.text,
    severity: severity ?? this.severity,
    categories: categories ?? this.categories,
    sort: sort ?? this.sort,
  );

  /// Search and filters cleared; the sort is kept.
  FindingsQuery cleared() => FindingsQuery(sort: sort);

  FindingsQuery toggle(FindingCategory c) {
    final next = {...categories};
    if (!next.remove(c)) next.add(c);
    return copyWith(categories: next);
  }
}

/// One app card: its label, findings (filtered and sorted) and target.
class AppGroup {
  const AppGroup({
    required this.package,
    required this.label,
    required this.findings,
    this.target,
  });

  final String package;
  final String label;
  final List<Finding> findings;
  final UninstallTarget? target;
}

class FindingsView {
  const FindingsView({required this.apps, required this.device});

  final List<AppGroup> apps;
  final List<Finding> device;

  bool get isEmpty => apps.isEmpty && device.isEmpty;
}

/// Categories present in [findings], in enum order (the chip order).
List<FindingCategory> categoriesPresent(Iterable<Finding> findings) {
  final present = {for (final f in findings) FindingKinds.categoryOf(f)};
  return [
    for (final c in FindingCategory.values)
      if (present.contains(c)) c,
  ];
}

/// Applies [query] to the response's findings.
///
/// [labelOf] is the app's display name for a package; [titleOf] the
/// finding's title in the app language (the device rows' name sort).
/// Search is case-insensitive over the app label, the target label and the
/// finding's title and explanation in both languages.
FindingsView buildFindingsView({
  required List<Finding> findings,
  required List<UninstallTarget> targets,
  required String Function(String package) labelOf,
  required String Function(Finding finding) titleOf,
  required FindingsQuery query,
}) {
  final needle = query.text.trim().toLowerCase();
  bool contains(String s) => s.toLowerCase().contains(needle);

  bool passesChips(Finding f) =>
      (query.severity == SeverityFilter.all ||
          FindingKinds.bucketOf(f.severity) == query.severity) &&
      (query.categories.isEmpty ||
          query.categories.contains(FindingKinds.categoryOf(f)));

  bool textMatches(Finding f) =>
      needle.isEmpty ||
      contains(f.titleBn) ||
      contains(f.titleEn) ||
      contains(f.explanationBn) ||
      contains(f.explanationEn);

  int byRank(Finding a, Finding b) =>
      FindingKinds.rank(a.severity).compareTo(FindingKinds.rank(b.severity));

  List<Finding> stableSorted(
    List<Finding> list,
    int Function(Finding, Finding) cmp,
  ) {
    final indexed = list.indexed.toList()
      ..sort((a, b) {
        final c = cmp(a.$2, b.$2);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  final appRows = findings
      .where((f) => f.scope != Finding.scopeDevice)
      .toList();
  final deviceRows = findings
      .where((f) => f.scope == Finding.scopeDevice)
      .toList();

  // One card per app: the apps to remove first, then the rest in order.
  final packages = <String>{
    for (final t in targets) t.package,
    for (final f in appRows) f.package,
  }.toList();

  final groups = <(int, AppGroup, int)>[];
  for (final (i, pkg) in packages.indexed) {
    final target = targets.where((t) => t.package == pkg).firstOrNull;
    final label = labelOf(pkg);
    final labelHit =
        needle.isEmpty ||
        contains(label) ||
        (target != null && contains(target.label));
    final own = [
      for (final f in appRows)
        if (f.package == pkg) f,
    ];
    final kept = own
        .where((f) => passesChips(f) && (labelHit || textMatches(f)))
        .toList();
    if (own.isEmpty) {
      // A target without findings (legacy `apps_to_uninstall`): counted as a
      // dangerous unknown app.
      final chipsOk =
          (query.severity == SeverityFilter.all ||
              query.severity == SeverityFilter.danger) &&
          (query.categories.isEmpty ||
              query.categories.contains(FindingCategory.unknownApps));
      if (!chipsOk || !labelHit) continue;
    } else if (kept.isEmpty) {
      continue;
    }
    final sorted = stableSorted(kept, byRank);
    final worst = sorted.isEmpty ? 0 : FindingKinds.rank(sorted.first.severity);
    groups.add((
      i,
      AppGroup(package: pkg, label: label, findings: sorted, target: target),
      worst,
    ));
  }

  groups.sort((a, b) {
    final c = switch (query.sort) {
      FindingSort.severity => a.$3.compareTo(b.$3),
      FindingSort.name => a.$2.label.toLowerCase().compareTo(
        b.$2.label.toLowerCase(),
      ),
    };
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });

  final device = stableSorted(
    deviceRows.where((f) => passesChips(f) && textMatches(f)).toList(),
    switch (query.sort) {
      FindingSort.severity => byRank,
      FindingSort.name => (a, b) => titleOf(
        a,
      ).toLowerCase().compareTo(titleOf(b).toLowerCase()),
    },
  );

  return FindingsView(apps: [for (final g in groups) g.$2], device: device);
}
