import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../data/contracts/contracts.dart';

/// Status, icon and chrome label for a server verdict (green safe,
/// amber caution, red reserved for block). Colours come from the
/// palette's status tokens, which differ only by brightness (dark tints in
/// dark mode). The label is keyed by the enum; the risk copy itself is
/// `user_message_*`.
class VerdictStyle {
  const VerdictStyle._({
    required this.status,
    required this.icon,
    required this.label,
  });

  factory VerdictStyle.of(BuildContext context, SafetyVerdict verdict) {
    final l10n = context.l10n;
    return switch (verdict) {
      SafetyVerdict.safe => VerdictStyle._(
        status: BhStatus.success,
        icon: Icons.verified_user,
        label: l10n.safetyVerdictSafe,
      ),
      SafetyVerdict.caution => VerdictStyle._(
        status: BhStatus.warning,
        icon: Icons.warning_amber_rounded,
        label: l10n.safetyVerdictCaution,
      ),
      SafetyVerdict.block => VerdictStyle._(
        status: BhStatus.danger,
        icon: Icons.gpp_bad,
        label: l10n.safetyVerdictBlock,
      ),
    };
  }

  final BhStatus status;
  final IconData icon;
  final String label;
}

/// Status and chrome label for a finding's `severity` as sent on the wire
/// (`low|medium|high|critical`). An unknown value gets the generic "ঝুঁকি"
/// tag; the wire value never reaches the screen.
class SeverityStyle {
  const SeverityStyle._({required this.status, required this.label});

  factory SeverityStyle.of(BuildContext context, String severity) {
    final l10n = context.l10n;
    return switch (severity.toLowerCase()) {
      'low' => SeverityStyle._(
        status: BhStatus.success,
        label: l10n.safetySeverityLow,
      ),
      'medium' => SeverityStyle._(
        status: BhStatus.warning,
        label: l10n.safetySeverityMedium,
      ),
      'high' => SeverityStyle._(
        status: BhStatus.danger,
        label: l10n.safetySeverityHigh,
      ),
      'critical' => SeverityStyle._(
        status: BhStatus.danger,
        label: l10n.safetySeverityCritical,
      ),
      _ => SeverityStyle._(
        status: BhStatus.neutral,
        label: l10n.safetySeverityOther,
      ),
    };
  }

  /// Most severe first, for picking the tag of an app with several findings.
  static int rank(String severity) => switch (severity.toLowerCase()) {
    'critical' => 0,
    'high' => 1,
    'medium' => 2,
    'low' => 3,
    _ => 4,
  };

  final BhStatus status;
  final String label;
}
