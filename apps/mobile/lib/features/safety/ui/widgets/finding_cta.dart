import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/server_text.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/bh_button.dart';
import '../../../../app/widgets/sheet_header.dart';
import '../../../../app/widgets/status_tag.dart';
import '../../../../data/contracts/contracts.dart';
import '../../logic/findings_view.dart';
import 'verdict_style.dart';

/// Label and icon of a finding's CTA ([FindingKinds.actionFor]).
({String label, IconData icon}) findingActionCopy(
  AppLocalizations l10n,
  FindingAction action,
) => switch (action) {
  FindingAction.revokePermission => (
    label: l10n.safetyCtaRevokePermission,
    icon: Icons.lock_outline,
  ),
  FindingAction.disableService => (
    label: l10n.safetyCtaDisableService,
    icon: Icons.accessibility_new,
  ),
  FindingAction.uninstall => (
    label: l10n.safetyUninstallApp,
    icon: Icons.delete_outline,
  ),
  FindingAction.stopOverlay ||
  FindingAction.stopControl ||
  FindingAction.stopCapture => (
    label: l10n.safetyCtaStopNow,
    icon: Icons.stop_circle_outlined,
  ),
  FindingAction.fixDeveloper || FindingAction.fixSecurity => (
    label: l10n.safetyCtaFixSetting,
    icon: Icons.settings_outlined,
  ),
  FindingAction.acknowledge => (
    label: l10n.safetyCtaAcknowledge,
    icon: Icons.check,
  ),
};

/// The one action of a finding row (key `finding_cta_<id>`): a 56 dp
/// outlined button, danger-outlined for uninstall. Once a "বুঝেছি" finding
/// is acknowledged the button gives way to a muted "দেখা হয়েছে" line.
class FindingCta extends StatelessWidget {
  const FindingCta({
    required this.finding,
    required this.onPressed,
    this.acknowledged = false,
    this.fullWidth = false,
    this.keyPrefix = 'finding_cta_',
    super.key,
  });

  final Finding finding;
  final VoidCallback onPressed;
  final bool acknowledged;
  final bool fullWidth;
  final String keyPrefix;

  static Key keyFor(Finding f) =>
      ValueKey('finding_cta_${FindingKinds.idOf(f)}');
  static Key doneKeyFor(Finding f) =>
      ValueKey('finding_done_${FindingKinds.idOf(f)}');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final action = FindingKinds.actionFor(finding);
    final id = FindingKinds.idOf(finding);
    if (acknowledged && action == FindingAction.acknowledge) {
      return ConstrainedBox(
        key: ValueKey('finding_done_$id'),
        constraints: const BoxConstraints(minHeight: BhSize.touch),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 24, color: p.mutedText),
            const SizedBox(width: BhSpace.s),
            Expanded(
              child: Text(
                l10n.safetyAcknowledged,
                style: text.bodySmall?.copyWith(color: p.mutedText),
              ),
            ),
          ],
        ),
      );
    }
    final copy = findingActionCopy(l10n, action);
    final key = ValueKey('$keyPrefix$id');
    final Widget button;
    if (action == FindingAction.uninstall) {
      button = ConstrainedBox(
        key: key,
        constraints: BoxConstraints(
          minHeight: BhSize.touch,
          minWidth: fullWidth ? double.infinity : BhSize.touch,
        ),
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: p.danger,
            side: BorderSide(color: p.danger),
            minimumSize: const Size(BhSize.touch, BhSize.touch),
          ),
          onPressed: onPressed,
          icon: Icon(copy.icon),
          label: Text(copy.label, maxLines: 2),
        ),
      );
    } else {
      button = BhButton(
        key: key,
        label: copy.label,
        icon: copy.icon,
        onPressed: onPressed,
        variant: BhButtonVariant.outlined,
        fullWidth: fullWidth,
      );
    }
    return fullWidth
        ? button
        : Align(alignment: AlignmentDirectional.centerStart, child: button);
  }
}

/// The finding's full detail in a bottom sheet (tap on the row): the title,
/// the severity tag, `explanation_*`, the technical `evidence` under
/// "বিস্তারিত", and the same CTA full width. Leaving the app says that the
/// check runs again on return.
Future<void> showFindingSheet(
  BuildContext context, {
  required Finding finding,
  required String appLabel,
  required bool acknowledged,
  required VoidCallback onAction,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheet) {
    final l10n = sheet.l10n;
    final p = sheet.palette;
    final text = Theme.of(sheet).textTheme;
    final title = finding.title(sheet);
    final severity = SeverityStyle.of(sheet, finding.severity);
    final action = FindingKinds.actionFor(finding);
    return SafeArea(
      child: SingleChildScrollView(
        key: ValueKey('finding_sheet_${FindingKinds.idOf(finding)}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: title.isNotEmpty ? title : appLabel),
            Padding(
              padding: const EdgeInsets.all(BhSpace.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatusTag.header(
                    title: Text(
                      appLabel,
                      style: text.titleSmall?.copyWith(color: p.onSurface),
                    ),
                    tag: StatusTag(
                      label: severity.label,
                      status: severity.status,
                    ),
                  ),
                  const SizedBox(height: BhSpace.s),
                  Text(
                    finding.explanation(sheet),
                    style: text.bodyMedium?.copyWith(color: p.onSurface),
                  ),
                  if (finding.evidence.isNotEmpty) ...[
                    const SizedBox(height: BhSpace.m),
                    Text(
                      l10n.safetyDetails,
                      style: text.labelSmall?.copyWith(color: p.mutedText),
                    ),
                    const SizedBox(height: BhSpace.xs),
                    Text(
                      finding.evidence,
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                  ],
                  const SizedBox(height: BhSpace.l),
                  FindingCta(
                    finding: finding,
                    acknowledged: acknowledged,
                    fullWidth: true,
                    keyPrefix: 'finding_sheet_cta_',
                    onPressed: () {
                      Navigator.of(sheet).pop();
                      onAction();
                    },
                  ),
                  if (action.leavesApp) ...[
                    const SizedBox(height: BhSpace.s),
                    Text(
                      l10n.safetyCtaReturnHint,
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(color: p.mutedText),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  },
);
