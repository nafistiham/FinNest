import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n.dart';
import '../../../app/router.dart';
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/animated/expressive_text.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/recipient_row.dart';
import '../../../app/widgets/section_header.dart';
import '../../../app/widgets/status_tag.dart';
import '../logic/approve_controller.dart';

/// Trusted contact's view of a held transaction.
///
/// Data source is the local intervention record whose `requestId` matches:
/// the payee and amount come from the ledger row, the explanation lines are
/// the server's `reasons[].text_bn` verbatim (FR-3). Layout: "রিনা আপনার মত
/// চাইছেন" (`titleMedium`), then the held-money card: a header row with a
/// countdown `StatusTag(warning)` "৯:৪২ বাকি" pinned to the card's trailing
/// padding line (digits in fixed slots, ticking every second), and a
/// `ConfirmSummary` with the amount in `amountHero` and "মা-কে …"; then
/// Apa's script and "কেন আটকানো হয়েছে" with the server reasons. A request
/// created on another phone is an `EmptyState` (`phonelink_lock`) with the
/// reference only as a muted suffix, never the raw id as a title.
///
/// Button order: the money-moving "অনুমোদন করুন" is the
/// outlined one on top, the protective "প্রত্যাখ্যান করুন" is filled and
/// lowest, in the thumb zone. Once decided, both give way to "হোমে ফিরুন".
class ApproveScreen extends ConsumerWidget {
  const ApproveScreen({required this.requestId, super.key});

  /// Height of the two decision buttons (dp); above the 56 dp minimum on
  /// purpose, this is the one tap that moves money.
  static const buttonHeight = 64.0;

  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final provider = approveControllerProvider(requestId);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: BhSize.appBar,
        title: Text(l10n.approveTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  BhSpace.m,
                  BhSpace.m,
                  BhSpace.m,
                  BhSpace.l,
                ),
                children: [
                  if (!state.loaded)
                    _Loading(label: l10n.approveLoading)
                  else if (state.record == null)
                    _UnknownRequest(requestId: requestId)
                  else ...[
                    if (state.notYours) const _NotYoursNotice(),
                    _RequestDetails(state: state),
                  ],
                ],
              ),
            ),
            // The outcome stays pinned above the buttons so it is visible
            // without scrolling, whatever the list height.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
              child: _Outcome(state: state, onRetry: controller.retry),
            ),
            _DecisionButtons(
              state: state,
              onApprove: controller.approve,
              onDecline: controller.decline,
            ),
          ],
        ),
      ),
    );
  }
}

/// The request lives on this phone but is addressed to the trusted
/// contact: say so above the read-only details.
class _NotYoursNotice extends StatelessWidget {
  const _NotYoursNotice();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    const status = BhStatus.warning;
    return Container(
      key: const Key('approve_not_yours'),
      margin: const EdgeInsets.only(bottom: BhSpace.m),
      padding: const EdgeInsets.all(BhSpace.m),
      decoration: BoxDecoration(
        color: p.statusContainer(status),
        border: BorderDirectional(
          start: BorderSide(color: p.statusText(status), width: BhSize.stripe),
        ),
      ),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.approveNotYoursTitle,
              style: text.titleMedium?.copyWith(
                color: p.onStatusContainer(status),
              ),
            ),
            const SizedBox(height: BhSpace.s),
            Text(
              l10n.approveNotYoursBody,
              style: text.bodyMedium?.copyWith(
                color: p.onStatusContainer(status),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: BhSpace.xl),
    child: Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: BhSpace.m),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}

class _UnknownRequest extends StatelessWidget {
  const _UnknownRequest({required this.requestId});

  final String requestId;

  /// The last six letters and digits of [requestId] (dashes dropped),
  /// uppercased ASCII ([referenceCode]): enough to match a support call,
  /// and a code, so its digits never follow the locale.
  static String reference(String requestId) => referenceCode(requestId);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final ref = reference(requestId);
    return Column(
      key: const Key('approve_header'),
      children: [
        EmptyState(
          icon: Icons.phonelink_lock,
          title: l10n.approveHeaderUnknown,
          body: l10n.approveUnknownBody,
        ),
        if (ref.isNotEmpty) ...[
          const SizedBox(height: BhSpace.s),
          Text(
            l10n.approveRefSuffix(ref),
            key: const Key('approve_reference'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: p.mutedText),
          ),
        ],
      ],
    );
  }
}

class _RequestDetails extends StatelessWidget {
  const _RequestDetails({required this.state});

  final ApproveState state;

  /// The requester's first name from the record's uid, or null.
  static String? requester(AppLocalizations l10n, String uid) => switch (uid) {
    'rina' => l10n.demoPersonaRina,
    'rahima' => l10n.demoPersonaRahima,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final record = state.record!;
    final txn = state.txn;
    final payee = (txn?.counterpartyNameBn ?? '').trim();
    final who = requester(l10n, record.uid);
    final header = who == null
        ? l10n.approveAsksSomeone
        : l10n.approveAsks(who);
    final tag = _CountdownTag(state: state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Without a ledger row the countdown sits top-right of the header.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  header,
                  key: const Key('approve_header'),
                  style: text.titleMedium,
                ),
              ),
            ),
            if (txn == null) ...[const SizedBox(width: BhSpace.s), tag],
          ],
        ),
        const SizedBox(height: BhSpace.m),
        if (txn != null)
          Container(
            key: const Key('approve_summary'),
            color: p.surfaceVariant,
            padding: const EdgeInsets.all(BhSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The tag row is the direct child of the padded box, so the
                // tag's trailing edge is the card's 16 dp padding line.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        l10n.approveHeldLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(
                          color: p.statusText(BhStatus.warning),
                        ),
                      ),
                    ),
                    const SizedBox(width: BhSpace.s),
                    tag,
                  ],
                ),
                const SizedBox(height: BhSpace.s),
                KeyedSubtree(
                  key: const Key('approve_amount'),
                  child: ConfirmSummary(
                    kindLine: payee.isEmpty
                        ? l10n.approveHeaderAmount(context.taka(txn.amountBdt))
                        : l10n.approveToPayee(context.digits(payee)),
                    amountBdt: txn.amountBdt.round(),
                  ),
                ),
              ],
            ),
          ),
        if (record.script(context).isNotEmpty) ...[
          const SizedBox(height: BhSpace.l),
          Text(
            record.script(context),
            key: const Key('approve_script'),
            style: BhType.script.copyWith(color: p.onSurface),
          ),
        ],
        if (record.reasons.isNotEmpty) ...[
          const SizedBox(height: BhSpace.l),
          SectionHeader(title: l10n.approveWhyHeld),
          for (final (i, reason) in record.reasons.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: _Reason(reason.text(context)),
            ),
        ],
      ],
    );
  }
}

/// One server reason with a 12 dp `warning` square as its bullet, aligned
/// to the first line's middle.
class _Reason extends StatelessWidget {
  const _Reason(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodyLarge!;
    final line = (style.fontSize ?? 18) * (style.height ?? 1.4);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: ((line - 12) / 2).clamp(0, 24)),
          child: SizedBox.square(
            dimension: 12,
            child: ColoredBox(color: p.statusText(BhStatus.warning)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}

/// "৯:৪২ বাকি" in a warning tag; every digit in a fixed slot so the tag
/// keeps its width as it ticks. Hidden once there is an outcome.
class _CountdownTag extends StatelessWidget {
  const _CountdownTag({required this.state});

  final ApproveState state;

  /// `m:ss` in ASCII digits; the caller puts it in the active digits.
  static String format(Duration d) {
    final total = d.isNegative ? 0 : d.inSeconds;
    final ss = (total % 60).toString().padLeft(2, '0');
    return '${total ~/ 60}:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final remaining = state.remaining;
    if (remaining == null || state.outcome != null) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final l10n = context.l10n;
    final label = l10n.approveTimeLeftTag(context.digits(format(remaining)));
    const status = BhStatus.warning;
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(
      color: p.onStatusContainer(status),
      fontWeight: FontWeight.w700,
      height: 1.2,
    );
    return Semantics(
      key: const Key('approve_countdown'),
      container: true,
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: StatusTag.minHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: BhSpace.s,
            vertical: BhSpace.xxs,
          ),
          decoration: BoxDecoration(
            color: p.statusContainer(status),
            border: Border.all(
              color: p.statusText(status).withValues(alpha: 0.6),
            ),
          ),
          alignment: Alignment.center,
          child: TabularBangla(label, style: style),
        ),
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.state, required this.onRetry});

  final ApproveState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;

    if (state.notConfirmed) {
      return _ResultLine(
        l10n.approveNotConfirmedLine,
        status: BhStatus.warning,
        icon: Icons.person_off_outlined,
      );
    }
    if (state.approved) {
      return _ResultLine(
        l10n.approvedLine,
        status: BhStatus.success,
        icon: Icons.check_circle_outline,
      );
    }
    if (state.declined) {
      return _ResultLine(
        l10n.declinedLine,
        status: BhStatus.danger,
        icon: Icons.block,
      );
    }
    if (state.expired) {
      return _ResultLine(
        l10n.expiredLine,
        status: BhStatus.neutral,
        icon: Icons.timer_off_outlined,
      );
    }
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: BhSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.approveFailed,
              key: const Key('approve_error'),
              style: text.bodyMedium?.copyWith(
                color: context.palette.statusText(BhStatus.danger),
              ),
            ),
            const SizedBox(height: BhSpace.s),
            Semantics(
              button: true,
              label: l10n.approveRetry,
              child: TextButton.icon(
                key: const Key('approve_retry'),
                onPressed: state.busy ? null : onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.approveRetry),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine(this.text, {required this.status, required this.icon});

  final String text;
  final BhStatus status;
  final IconData icon;

  /// A static line (no motion): an approval is relief, not a celebration,
  /// and a decline must not read as one.
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ink = status == BhStatus.neutral
        ? p.onSurface
        : p.onStatusContainer(status);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('approve_result'),
        margin: const EdgeInsets.only(top: BhSpace.m),
        padding: const EdgeInsets.all(BhSpace.m),
        decoration: BoxDecoration(
          color: p.statusContainer(status),
          border: BorderDirectional(
            start: BorderSide(
              color: status == BhStatus.neutral
                  ? p.outline
                  : p.statusText(status),
              width: BhSize.stripe,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: ink, size: 24),
            const SizedBox(width: BhSpace.s),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecisionButtons extends StatelessWidget {
  const _DecisionButtons({
    required this.state,
    required this.onApprove,
    required this.onDecline,
  });

  final ApproveState state;
  final Future<void> Function() onApprove;
  final Future<void> Function() onDecline;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = state.canDecide;
    // Read-only for anyone but the contact: Home is the only way on.
    final decided =
        state.notYours ||
        state.notConfirmed ||
        state.approved ||
        state.declined ||
        state.expired;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.s,
        BhSpace.m,
        BhSpace.m,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.busy)
            Padding(
              padding: const EdgeInsets.only(bottom: BhSpace.s),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: BhSpace.s),
                  Text(
                    l10n.approveSending,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          if (decided)
            SizedBox(
              height: ApproveScreen.buttonHeight,
              child: BhButton(
                key: const Key('approve_go_home'),
                label: l10n.goHome,
                icon: Icons.home_outlined,
                onPressed: () => context.go(Routes.home),
              ),
            )
          else ...[
            SizedBox(
              width: double.infinity,
              height: ApproveScreen.buttonHeight,
              child: Semantics(
                button: true,
                enabled: enabled,
                label: l10n.approveButton,
                child: OutlinedButton(
                  key: const Key('approve_approve'),
                  onPressed: enabled ? onApprove : null,
                  child: Text(l10n.approveButton),
                ),
              ),
            ),
            const SizedBox(height: BhSpace.s),
            SizedBox(
              width: double.infinity,
              height: ApproveScreen.buttonHeight,
              child: Semantics(
                button: true,
                enabled: enabled,
                label: l10n.declineButton,
                child: FilledButton(
                  key: const Key('approve_decline'),
                  onPressed: enabled ? onDecline : null,
                  child: Text(l10n.declineButton),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
