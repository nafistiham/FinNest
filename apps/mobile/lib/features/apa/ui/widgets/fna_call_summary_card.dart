/// The call summary card: what a flagged caller
/// asked for and said, what to do now and next time. Amber (the call has
/// ended; red is only for blocks), square, no confidence value. Built from
/// the stored scam-check result, so it works without a network.
library;

import 'package:bhorosha/app/dates.dart';
import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:flutter/material.dart';

class FnaCallSummaryCard extends StatelessWidget {
  const FnaCallSummaryCard({
    required this.summary,
    required this.onHear,
    required this.onCallHelpline,
    this.nextTime,
    this.hearing = false,
    super.key,
  });

  final FnaCallSummary summary;

  /// The playbook's prevent line for this scam; the row is left out when
  /// `null` or empty.
  final String? nextTime;

  /// "Hear it" toggles: while FNA reads the card it shows Stop, and the
  /// same tap stops it.
  final VoidCallback onHear;
  final VoidCallback onCallHelpline;

  /// FNA is reading this card aloud (`ApaState.hearingSummary`).
  final bool hearing;

  /// The secret the caller asked for, in the app's label words; `null` for
  /// none.
  static String? secretLabel(AppLocalizations l, String secret) =>
      switch (secret.trim().toLowerCase()) {
        'none' || '' => null,
        'otp' || 'code' => l.apaSecretOtp,
        'pin' => l.apaSecretPin,
        'password' => l.apaSecretPassword,
        'card' || 'card_number' => l.fnaSecretCard,
        _ => l.apaSecretOther,
      };

  /// The server's recommended action in plain words: a known action code is
  /// mapped, free advice text is shown as it came.
  static String todoLine(AppLocalizations l, FnaCallSummary s) {
    final action = s.recommendedAction.trim();
    if (secretLabel(l, s.requestedSecret) != null) return l.fnaCallDoHangUp;
    return switch (action) {
      'hold_and_warn' || 'hang_up' || 'hold' || 'block' => l.fnaCallDoHangUp,
      '' || 'none' || 'warn' || 'caution' => l.fnaCallDoCareful,
      _ when action.contains(' ') => action,
      _ => l.fnaCallDoCareful,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final ink = p.onWarningContainer;
    final secret = secretLabel(l10n, summary.requestedSecret);
    // The caller's words can hold a code the customer repeated: digits are
    // masked before they reach the screen.
    final quote = ApaAnswers.redactSecrets(summary.evidenceQuote.trim()).$1;
    final prevent = nextTime?.trim() ?? '';
    final title = l10n.fnaCallCardTitle(
      BhDates.time(summary.at, Localizations.localeOf(context)),
    );

    Widget row(String key, String label, String value) => Padding(
      key: Key('fna_call_row_$key'),
      padding: const EdgeInsets.only(top: BhSpace.s),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(color: ink),
            ),
            const SizedBox(height: BhSpace.xxs),
            Text(value, style: theme.textTheme.bodyLarge?.copyWith(color: ink)),
          ],
        ),
      ),
    );

    return Container(
      key: const Key('fna_call_summary_card'),
      padding: const EdgeInsets.fromLTRB(BhSpace.m, 12, BhSpace.m, BhSpace.m),
      decoration: BoxDecoration(
        color: p.warningContainer,
        border: Border(
          left: BorderSide(color: p.warningFill, width: BhSize.stripe),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Row(
              children: [
                Icon(Icons.phone_in_talk_outlined, color: ink),
                const SizedBox(width: BhSpace.s),
                Expanded(
                  child: Text(
                    title,
                    key: const Key('fna_call_title'),
                    style: theme.textTheme.titleMedium?.copyWith(color: ink),
                  ),
                ),
              ],
            ),
          ),
          if (secret != null) row('asked', l10n.fnaCallAskedFor, secret),
          if (quote.isNotEmpty) row('said', l10n.fnaCallTheySaid, '“$quote”'),
          row('now', l10n.fnaCallDoNow, todoLine(l10n, summary)),
          if (prevent.isNotEmpty) row('next', l10n.fnaCallNextTime, prevent),
          const SizedBox(height: BhSpace.m),
          Wrap(
            spacing: BhSpace.s,
            runSpacing: BhSpace.s,
            children: [
              Semantics(
                container: true,
                button: true,
                label: hearing
                    ? l10n.fnaHearStopLabel(title)
                    : l10n.fnaHearItLabel(title),
                excludeSemantics: true,
                child: OutlinedButton.icon(
                  key: Key(hearing ? 'fna_call_hear_stop' : 'fna_call_hear'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ink,
                    side: BorderSide(color: ink),
                    minimumSize: const Size(BhSize.touch, BhSize.touch),
                  ),
                  onPressed: onHear,
                  icon: Icon(hearing ? Icons.stop : Icons.volume_up_outlined),
                  label: Text(hearing ? l10n.fnaHearStop : l10n.fnaHearIt),
                ),
              ),
              FilledButton.icon(
                key: const Key('fna_call_helpline'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(BhSize.touch, BhSize.touch),
                ),
                onPressed: onCallHelpline,
                icon: const Icon(Icons.call),
                label: Text(l10n.fnaCallHelpline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
