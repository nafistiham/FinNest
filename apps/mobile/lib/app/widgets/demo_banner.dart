import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/firebase/firebase_bootstrap.dart';
import '../../data/providers.dart';
import '../env.dart';
import '../l10n.dart';
import '../theme/theme.dart';

/// Thin strip at the top of every screen that says which mode is running, so
/// nothing is silently substituted (US-1 S2). Hosted once by
/// [DemoBannerShell] above the router.
///
/// While Firebase is not configured: "ডেমো মোড · অফলাইন ডেটা". In a
/// recording build (FLAG_SECURE skipped for the video) the short form
/// "ডেমো মোড · রেকর্ডিং". Renders nothing when Firebase is configured and the
/// build is not recording. TalkBack always hears the data status too.
class DemoBanner extends ConsumerWidget {
  const DemoBanner({this.recording = AppEnv.recording, super.key});

  /// Injectable so a test can show the recording tag without a dart-define.
  final bool recording;

  /// Banner height (dp), below the status-bar inset.
  static const height = 40.0;

  /// Whether the banner shows at all.
  static bool visibleFor(FirebaseStatus status, {required bool recording}) =>
      recording || status != FirebaseStatus.configured;

  /// The Firebase status in words a customer can read.
  static String dataLabel(AppLocalizations l10n, FirebaseStatus status) =>
      switch (status) {
        FirebaseStatus.configured => l10n.demoDataOnline,
        FirebaseStatus.absent || FirebaseStatus.failed => l10n.demoDataOffline,
      };

  /// The visible line; empty when [visibleFor] is false.
  static String textFor(
    AppLocalizations l10n,
    FirebaseStatus status, {
    required bool recording,
  }) {
    if (!visibleFor(status, recording: recording)) return '';
    return [
      l10n.demoMode,
      if (recording) l10n.recordingMode else dataLabel(l10n, status),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(firebaseStatusProvider);
    final l10n = context.l10n;
    if (!visibleFor(status, recording: recording)) {
      return const SizedBox.shrink();
    }
    final text = textFor(l10n, status, recording: recording);
    final spoken = recording ? '$text · ${dataLabel(l10n, status)}' : text;
    // Status containers of the palette: info (data status) or warning
    // (recording), dark tints with light text in dark mode (8.15).
    final p = context.palette;
    final tone = recording ? BhStatus.warning : BhStatus.info;
    return Semantics(
      label: spoken,
      child: ExcludeSemantics(
        child: Material(
          key: const Key('demo_banner'),
          color: p.statusContainer(tone),
          child: Container(
            height: DemoBanner.height,
            padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
            child: Row(
              children: [
                Icon(
                  recording
                      ? Icons.fiber_manual_record
                      : Icons.science_outlined,
                  size: 20,
                  color: recording ? p.danger : p.info,
                ),
                const SizedBox(width: BhSpace.s),
                Expanded(
                  child: Text(
                    text,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: p.onStatusContainer(tone)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps the router's output (`MaterialApp.router(builder:)`) so the
/// [DemoBanner] sits above every route, the PIN pad, the intervention
/// overlay and Result included. When the banner shows, it takes the status
/// bar inset and the screens below lose their top inset, so nothing is drawn
/// twice under the status bar.
class DemoBannerShell extends ConsumerWidget {
  const DemoBannerShell({
    required this.child,
    this.recording = AppEnv.recording,
    super.key,
  });

  final Widget child;
  final bool recording;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(firebaseStatusProvider);
    if (!DemoBanner.visibleFor(status, recording: recording)) return child;
    final media = MediaQuery.of(context);
    return Column(
      children: [
        ColoredBox(
          color: context.palette.statusContainer(
            recording ? BhStatus.warning : BhStatus.info,
          ),
          child: Padding(
            padding: EdgeInsets.only(top: media.padding.top),
            child: DemoBanner(recording: recording),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
