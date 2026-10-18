import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/l10n.dart';
import '../../../../app/server_text.dart';
import '../../../../app/theme/theme.dart';
import '../../../../data/contracts/contracts.dart';
import '../../logic/safety_controller.dart';
import 'safety_status_row.dart';
import 'verdict_style.dart';

/// The phone-safety verdict card (US-4, 8.8): the
/// [SafetyStatusRow] (with the "সিমুলেটেড" tag at the top-right) above the
/// server's `user_message_*` in the app language. Home shows the same status
/// row inside Apa's card instead; this full card heads the Safety screen
/// and serves any screen that wants the verdict on its own.
///
/// While loading or before the first check it shows the checking line; on
/// failure the whole card is the retry, coloured by the server's standing
/// verdict when one is known. Otherwise a tap opens the findings screen.
class SafetyBadge extends ConsumerWidget {
  const SafetyBadge({super.key});

  /// Route of the findings screen (`Routes.safety` in the router).
  static const String route = '/safety';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(safetyControllerProvider);
    final l10n = context.l10n;
    final response = state.value;

    if (state.hasError && !state.isLoading) {
      final latest = ref.watch(safetyLatestFallbackProvider);
      void retry() => ref.read(safetyControllerProvider.notifier).refresh();
      return SafetyVerdictCard(
        verdict: latest?.verdict,
        failed: true,
        message: latest != null
            ? l10n.safetyFromLastCheck
            : l10n.safetyCheckFailed,
        onTap: retry,
      );
    }
    if (response == null) {
      return SafetyVerdictCard(
        checking: true,
        onTap: () => context.push(route),
      );
    }
    return SafetyVerdictCard(
      verdict: response.verdict,
      simulated: response.simulatedVerdict,
      message: response.userMessage(context),
      onTap: () => context.push(route),
    );
  }
}

/// The card itself: `<status>Container` fill with a 4 dp status stripe (dark
/// tints in dark mode), 16 dp padding, the status row as the padded box's
/// first child, then [message] in `bodyLarge`. [above] goes over the status
/// row (the Safety screen's blocked-transfer line).
class SafetyVerdictCard extends StatelessWidget {
  const SafetyVerdictCard({
    this.verdict,
    this.checking = false,
    this.failed = false,
    this.simulated = false,
    this.message,
    this.onTap,
    this.above = const [],
    this.large = false,
    this.showPrefix = true,
    super.key,
  });

  final SafetyVerdict? verdict;
  final bool checking;
  final bool failed;
  final bool simulated;
  final String? message;
  final VoidCallback? onTap;
  final List<Widget> above;
  final bool large;

  /// See [SafetyStatusRow.showPrefix].
  final bool showPrefix;

  static const contentKey = Key('safety_verdict_card_content');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final status = verdict == null
        ? BhStatus.neutral
        : VerdictStyle.of(context, verdict!).status;
    final fill = p.statusContainer(status);
    final stripe = p.statusFill(status);
    final body = Container(
      key: const Key('safety_badge_card'),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: stripe, width: BhSize.stripe),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m - BhSize.stripe,
        BhSpace.s,
        BhSpace.m,
        BhSpace.m,
      ),
      child: Column(
        key: contentKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...above,
          SafetyStatusRow(
            verdict: verdict,
            checking: checking,
            failed: failed,
            simulated: simulated,
            large: large,
            showPrefix: showPrefix,
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: BhSpace.xs),
            Text(
              message!,
              style: (large ? text.bodyLarge : text.bodyMedium)?.copyWith(
                color: p.onStatusContainer(status) == p.mutedText
                    ? p.onSurface
                    : p.onStatusContainer(status),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return Material(color: fill, child: body);
    // A tappable card reads as one button: status, message, what a tap does.
    final l10n = context.l10n;
    final label = verdict != null
        ? VerdictStyle.of(context, verdict!).label
        : checking
        ? l10n.safetyChecking
        : failed
        ? l10n.safetyCheckFailedShort
        : l10n.safetyNotCheckedShort;
    final semantics = [
      l10n.safety,
      label,
      if (simulated) l10n.safetySimulatedTag,
      ?message,
      if (!failed) l10n.safetyOpenDetails,
    ].join('. ');
    return Semantics(
      button: true,
      label: semantics,
      child: ExcludeSemantics(
        child: Material(
          color: fill,
          child: InkWell(onTap: onTap, child: body),
        ),
      ),
    );
  }
}
