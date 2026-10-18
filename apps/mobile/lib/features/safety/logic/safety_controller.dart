/// Riverpod wiring of the safety badge.
///
/// [SafetyController] holds the last `/v1/appsafety/check` answer for the
/// session. Nothing checks automatically: Home calls [SafetyController.refresh]
/// once on load, the badge and the findings screen only read. When a fresh
/// check fails, the server's standing verdict (`/v1/appsafety/latest/{uid}`)
/// is fetched into [safetyLatestFallbackProvider] so the badge still shows a
/// colour. After the user leaves through an Uninstall button the next resume
/// re-runs the check.
library;

import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/safety/logic/app_safety_flow.dart';
import 'package:bhorosha/features/safety/logic/findings_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `assets/demo/fake_apps.json`, or an empty list when the asset is missing
/// or malformed: the demo escape hatch must never break the real check.
final demoFakeAppsProvider = FutureProvider<List<InstalledApp>>((ref) async {
  try {
    return await ref.watch(demoAssetsProvider).fakeApps();
  } on Object {
    return const <InstalledApp>[];
  }
});

/// One flow per API/native pair; resolves once the fake apps are loaded.
final appSafetyFlowProvider = FutureProvider<AppSafetyFlow>(
  (ref) async => AppSafetyFlow(
    api: ref.watch(riskApiProvider),
    native: ref.watch(nativeProvider),
    demoFakeApps: await ref.watch(demoFakeAppsProvider.future),
  ),
);

/// The server's standing verdict for the signed-in user, fetched only when a
/// fresh check failed; cleared by the next successful check.
class SafetyLatestFallback extends Notifier<AppSafetyLatest?> {
  @override
  AppSafetyLatest? build() => null;

  // ignore: use_setters_to_change_properties, mirrors the notifier API
  void set(AppSafetyLatest? latest) => state = latest;
}

final safetyLatestFallbackProvider =
    NotifierProvider<SafetyLatestFallback, AppSafetyLatest?>(
      SafetyLatestFallback.new,
    );

/// What the user did about individual findings this session, keyed by
/// [FindingKinds.idOf]: [attempted] left the app through a finding's CTA
/// (the resume re-check confirms it; cleared by the next successful check),
/// [acknowledged] tapped "বুঝেছি" on a finding with nothing to switch off.
/// Part of the controller's resolve / re-check flow: written only through
/// [SafetyController.resolveFinding], cleared by [SafetyController.reset].
class FindingResolutions {
  const FindingResolutions({
    this.attempted = const {},
    this.acknowledged = const {},
  });

  final Set<String> attempted;
  final Set<String> acknowledged;
}

class FindingResolutionsNotifier extends Notifier<FindingResolutions> {
  @override
  FindingResolutions build() => const FindingResolutions();

  void _attempt(String id) => state = FindingResolutions(
    attempted: {...state.attempted, id},
    acknowledged: state.acknowledged,
  );

  void _acknowledge(String id) => state = FindingResolutions(
    attempted: state.attempted,
    acknowledged: {...state.acknowledged, id},
  );

  void _clearAttempts() =>
      state = FindingResolutions(acknowledged: state.acknowledged);

  void _clear() => state = const FindingResolutions();
}

final findingResolutionsProvider =
    NotifierProvider<FindingResolutionsNotifier, FindingResolutions>(
      FindingResolutionsNotifier.new,
    );

/// `null` until the first [refresh]; then the last response, or the
/// [ApiFailure] of the last attempt.
class SafetyController extends AsyncNotifier<AppSafetyResponse?> {
  static const _tag = 'appsafety';

  bool _pendingRecheck = false;
  bool _refreshing = false;

  /// Bumped by [reset]; a check that started before it is dropped.
  int _generation = 0;

  /// Synchronous so the first [refresh] is never raced by a pending build.
  @override
  AppSafetyResponse? build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s == AppLifecycleState.resumed) _onResume();
      },
    );
    ref.onDispose(lifecycle.dispose);
    return null;
  }

  /// `true` after [openUninstall] until the next resume re-check.
  bool get pendingRecheck => _pendingRecheck;

  /// Runs the check against the current demo state. Loading while it runs;
  /// then the response, or the failure (an [ApiFailure] from the API, or
  /// whatever the asset loader threw). On failure the standing verdict is
  /// fetched into [safetyLatestFallbackProvider] when a user is signed in.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final generation = _generation;
    state = const AsyncLoading<AppSafetyResponse?>();
    try {
      final next = await AsyncValue.guard<AppSafetyResponse?>(() async {
        final demo = await _demoState();
        final flow = await ref.read(appSafetyFlowProvider.future);
        return flow.check(demo: demo);
      });
      if (!ref.mounted || generation != _generation) return;
      if (next.hasError) {
        await _loadFallback();
        if (!ref.mounted || generation != _generation) return;
      } else {
        ref.read(safetyLatestFallbackProvider.notifier).set(null);
        // The fresh check is the confirmation of every attempt.
        ref.read(findingResolutionsProvider.notifier)._clearAttempts();
      }
      state = next;
    } finally {
      if (generation == _generation) _refreshing = false;
    }
  }

  /// Forgets the last verdict (persona switch, logout, demo login): the next
  /// user's `demo_flags.app_safety_verdict` never carries the previous
  /// user's. A check in flight is dropped when it lands.
  void reset() {
    _generation++;
    _refreshing = false;
    _pendingRecheck = false;
    ref.read(findingResolutionsProvider.notifier)._clear();
    state = const AsyncData<AppSafetyResponse?>(null);
  }

  /// Opens the system app-info page for [target] and arms a re-check for
  /// when the user comes back to the app.
  Future<void> openUninstall(UninstallTarget target) async {
    _pendingRecheck = true;
    final record = ref.read(findingResolutionsProvider.notifier);
    for (final f in state.value?.findings ?? const <Finding>[]) {
      if (f.package == target.package) record._attempt(FindingKinds.idOf(f));
    }
    await ref.read(nativeProvider).openAppDetails(target.package);
  }

  /// Runs the CTA of [finding] ([FindingKinds.actionFor]). An action that
  /// leaves the app is recorded as an attempt and arms the same resume
  /// re-check as [openUninstall]; "বুঝেছি" records the finding as seen.
  Future<void> resolveFinding(Finding finding) async {
    final action = FindingKinds.actionFor(finding);
    final id = FindingKinds.idOf(finding);
    final record = ref.read(findingResolutionsProvider.notifier);
    if (!action.leavesApp) {
      record._acknowledge(id);
      return;
    }
    _pendingRecheck = true;
    record._attempt(id);
    final native = ref.read(nativeProvider);
    final pkg = FindingKinds.hasPackage(finding) ? finding.package : null;
    switch (action) {
      case FindingAction.revokePermission:
        await native.openAppDetails(finding.package);
      case FindingAction.disableService:
      case FindingAction.stopControl:
        await native.openAccessibilitySettings();
      case FindingAction.uninstall:
        await native.uninstallApp(finding.package);
      case FindingAction.stopOverlay:
        await native.openSettingsPanel(SettingsPanel.overlay, package: pkg);
      case FindingAction.stopCapture:
        if (pkg != null) {
          await native.openAppDetails(pkg);
        } else {
          await native.openSettingsPanel(SettingsPanel.cast);
        }
      case FindingAction.fixDeveloper:
        await native.openSettingsPanel(SettingsPanel.developer);
      case FindingAction.fixSecurity:
        await native.openSettingsPanel(SettingsPanel.security);
      case FindingAction.acknowledge:
        break;
    }
  }

  void _onResume() {
    if (!_pendingRecheck) return;
    _pendingRecheck = false;
    Log.i(_tag, 'resumed after uninstall; re-checking');
    // Fire-and-forget: the state carries the outcome.
    refresh().ignore();
  }

  Future<void> _loadFallback() async {
    final uid = ref.read(currentUserProvider).value?.uid;
    if (uid == null) return;
    final flow = await ref.read(appSafetyFlowProvider.future);
    final latest = await flow.latest(uid);
    if (!ref.mounted) return;
    ref
        .read(safetyLatestFallbackProvider.notifier)
        .set(latest != null && latest.known ? latest : null);
  }

  /// The current demo state. When nothing has subscribed yet the stream is
  /// listened to for its first emission (a `StreamProvider.future` can stall
  /// on an already-closed stream); a slow or failing stream falls back to
  /// [DemoState.initial] so the check still runs.
  Future<DemoState> _demoState() async {
    final current = ref.read(demoStateProvider);
    if (current.hasValue) return current.requireValue;
    final first = Completer<DemoState>();
    final sub = ref.listen<AsyncValue<DemoState>>(demoStateProvider, (_, next) {
      if (first.isCompleted) return;
      if (next.hasValue) first.complete(next.requireValue);
      if (next.hasError) first.complete(DemoState.initial);
    }, fireImmediately: true);
    try {
      return await first.future.timeout(
        demoStateWait,
        onTimeout: () => DemoState.initial,
      );
    } finally {
      sub.close();
    }
  }

  /// How long [refresh] waits for the first demo-state emission.
  static const demoStateWait = Duration(milliseconds: 800);
}

final safetyControllerProvider =
    AsyncNotifierProvider<SafetyController, AppSafetyResponse?>(
      SafetyController.new,
    );

/// The verdict of the last successful check, else the server's standing
/// verdict when the last attempt failed, else `null`. Fed into
/// `demo_flags.app_safety_verdict` by the risk flow callers.
final lastSafetyVerdictProvider = Provider<SafetyVerdict?>((ref) {
  final fresh = ref.watch(safetyControllerProvider).value?.verdict;
  if (fresh != null) return fresh;
  return ref.watch(safetyLatestFallbackProvider)?.verdict;
});

/// What the phone tells `/v1/risk/score` about its App Safety Check
/// (`ScoreRequest.app_safety`): the last fresh check, else the
/// standing verdict the server gave as the fallback, else nothing.
final appSafetyContextProvider = Provider<AppSafetyContext?>((ref) {
  final fresh = ref.watch(safetyControllerProvider).value;
  if (fresh != null) return AppSafetyContext.fromResponse(fresh);
  final latest = ref.watch(safetyLatestFallbackProvider);
  return latest == null ? null : AppSafetyContext.fromLatest(latest);
});

/// Package → label from the request most recently posted (the native bundle
/// plus any demo fake apps). Recomputed after every check.
final safetyAppLabelsProvider = Provider<Map<String, String>>((ref) {
  ref.watch(safetyControllerProvider);
  final request = ref.watch(appSafetyFlowProvider).value?.lastRequest;
  if (request == null) return const {};
  return {
    for (final app in request.installedApps)
      if (app.label.isNotEmpty) app.package: app.label,
  };
});
