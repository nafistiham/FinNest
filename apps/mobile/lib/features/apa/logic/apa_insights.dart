/// The Apa insight engine: what Apa should tell this customer right now,
/// computed from the app's real state (verdict, last score, held transfers,
/// call/SIM/screen signals, the last scam check). Pure functions over an
/// [ApaContextSnapshot]; the Riverpod wiring is in `apa_insights_provider.dart`.
///
/// Server copy is quoted verbatim (`user_message_*`, `reasons[].text_*`,
/// `evidence_quote`); everything else comes from the ARBs (FR-3). Every
/// insight carries both languages and the UI picks by the app locale.
library;

import 'dart:ui' show Locale;

import 'package:bhorosha/app/l10n.dart' show pickServerText;
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart' show listEquals;

const _bn = Locale('bn');
const _en = Locale('en');

/// Ranked most severe first.
enum ApaSeverity { danger, caution, ok, info }

/// Where an Apa sentence came from.
enum ApaSource {
  /// The server's risk reasons.
  server,

  /// The app-safety check.
  phone,

  /// Call, SIM and screen signals.
  signal,

  /// The scam-call classifier.
  scam,

  /// Apa's curated rules and the offline guide.
  rules,

  /// Gemini.
  ai,
}

/// What an insight's button (or a bubble's button) does.
enum ApaAction {
  /// Push the phone-safety screen.
  openSafety,

  /// Open the Apa sheet in scam-check mode.
  openApaScamCheck,

  /// The trusted-contact request of a held transfer, else "why held".
  openApproveOrHeld,

  /// The five rules in the sheet.
  learnRules,

  /// Dial the bank hotline.
  callHelpline,
  none,
}

/// One held or delayed transfer that is still waiting.
class ApaHeldItem {
  const ApaHeldItem({
    required this.txnId,
    this.reasons = const [],
    this.requestId,
    this.waitingForTrustedContact = false,
  });

  final String txnId;

  /// The server's reasons stored with the intervention (FR-3).
  final List<Reason> reasons;

  /// Trusted-contact request id, when one was sent.
  final String? requestId;
  final bool waitingForTrustedContact;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaHeldItem &&
          txnId == other.txnId &&
          listEquals(reasons, other.reasons) &&
          requestId == other.requestId &&
          waitingForTrustedContact == other.waitingForTrustedContact;

  @override
  int get hashCode => Object.hash(
    txnId,
    Object.hashAll(reasons),
    requestId,
    waitingForTrustedContact,
  );
}

/// Everything Apa may know about the customer. Built by
/// `apaSnapshotProvider`; tests construct it directly.
class ApaContextSnapshot {
  const ApaContextSnapshot({
    this.verdict,
    this.safetyMessageBn = '',
    this.safetyMessageEn = '',
    this.findings = const [],
    this.uninstallTargets = const [],
    this.resolution = 'NONE',
    this.safetyChecking = false,
    this.lastScore,
    this.held = const [],
    this.callActive = false,
    this.simSwap = false,
    this.screenShare = false,
    this.evidenceQuote,
    this.scamScore = 0.0,
    this.nameBn,
    this.nameEn,
    this.balanceBdt,
    this.locale = 'bn',
    this.screen = 'home',
  });

  /// Last app-safety verdict (fresh, else the server's standing one).
  final SafetyVerdict? verdict;
  final String safetyMessageBn;
  final String safetyMessageEn;
  final List<Finding> findings;
  final List<UninstallTarget> uninstallTargets;

  /// `NONE|UNINSTALL_AND_RECHECK|FIX_PHONE_AND_RECHECK|...` (wire value).
  final String resolution;

  /// A safety check is running now.
  final bool safetyChecking;

  final ScoreResponse? lastScore;
  final List<ApaHeldItem> held;
  final bool callActive;
  final bool simSwap;
  final bool screenShare;

  /// Last scam-check `evidence_quote` (demo replay or Apa's scam check).
  final String? evidenceQuote;
  final double scamScore;
  final String? nameBn;
  final String? nameEn;
  final double? balanceBdt;

  /// `bn` or `en`.
  final String locale;
  final String screen;

  bool get english => locale == 'en';

  /// The same snapshot for the screen the sheet was opened on.
  ApaContextSnapshot withScreen(String screen) => copyWith(screen: screen);

  /// The facts the insight engine reads: everything but the customer's name
  /// and balance (which change on every ledger tick and never change an
  /// insight) and the screen. `apaInsightsProvider` selects this, so with
  /// [==] a balance tick does not rebuild the list.
  ApaContextSnapshot get insightFacts => ApaContextSnapshot(
    verdict: verdict,
    safetyMessageBn: safetyMessageBn,
    safetyMessageEn: safetyMessageEn,
    findings: findings,
    uninstallTargets: uninstallTargets,
    resolution: resolution,
    safetyChecking: safetyChecking,
    lastScore: lastScore,
    held: held,
    callActive: callActive,
    simSwap: simSwap,
    screenShare: screenShare,
    evidenceQuote: evidenceQuote,
    scamScore: scamScore,
    locale: locale,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaContextSnapshot &&
          verdict == other.verdict &&
          safetyMessageBn == other.safetyMessageBn &&
          safetyMessageEn == other.safetyMessageEn &&
          listEquals(findings, other.findings) &&
          listEquals(uninstallTargets, other.uninstallTargets) &&
          resolution == other.resolution &&
          safetyChecking == other.safetyChecking &&
          lastScore == other.lastScore &&
          listEquals(held, other.held) &&
          callActive == other.callActive &&
          simSwap == other.simSwap &&
          screenShare == other.screenShare &&
          evidenceQuote == other.evidenceQuote &&
          scamScore == other.scamScore &&
          nameBn == other.nameBn &&
          nameEn == other.nameEn &&
          balanceBdt == other.balanceBdt &&
          locale == other.locale &&
          screen == other.screen;

  @override
  int get hashCode => Object.hashAll([
    verdict,
    safetyMessageBn,
    safetyMessageEn,
    Object.hashAll(findings),
    Object.hashAll(uninstallTargets),
    resolution,
    safetyChecking,
    lastScore,
    Object.hashAll(held),
    callActive,
    simSwap,
    screenShare,
    evidenceQuote,
    scamScore,
    nameBn,
    nameEn,
    balanceBdt,
    locale,
    screen,
  ]);

  /// The same facts with the volatile customer fields (name, balance) or the
  /// screen replaced. `apaSnapshotProvider` adds name and balance this way so
  /// the insight engine never recomputes on a balance tick.
  ApaContextSnapshot copyWith({
    String? nameBn,
    String? nameEn,
    double? balanceBdt,
    String? screen,
  }) => ApaContextSnapshot(
    verdict: verdict,
    safetyMessageBn: safetyMessageBn,
    safetyMessageEn: safetyMessageEn,
    findings: findings,
    uninstallTargets: uninstallTargets,
    resolution: resolution,
    safetyChecking: safetyChecking,
    lastScore: lastScore,
    held: held,
    callActive: callActive,
    simSwap: simSwap,
    screenShare: screenShare,
    evidenceQuote: evidenceQuote,
    scamScore: scamScore,
    nameBn: nameBn ?? this.nameBn,
    nameEn: nameEn ?? this.nameEn,
    balanceBdt: balanceBdt ?? this.balanceBdt,
    locale: locale,
    screen: screen ?? this.screen,
  );

  static const _stopping = {
    Decision.hold,
    Decision.delay,
    Decision.block,
    Decision.stepUp,
  };

  /// The last score stopped a transfer.
  bool get lastScoreStopped =>
      lastScore != null && _stopping.contains(lastScore!.decision);

  /// A transfer is held, delayed or waiting on the trusted contact.
  bool get transferPending => held.isNotEmpty || lastScoreStopped;

  /// The server's reasons for the pending transfer: the last score's when it
  /// stopped one, else the newest held record's.
  List<Reason> get heldReasons {
    final score = lastScore;
    if (score != null && lastScoreStopped && score.reasons.isNotEmpty) {
      return score.reasons;
    }
    for (final h in held) {
      if (h.reasons.isNotEmpty) return h.reasons;
    }
    return const [];
  }

  /// First trusted-contact request id among the held transfers.
  String? get pendingRequestId =>
      held.map((h) => h.requestId).nonNulls.firstOrNull;

  /// The app language's text with the usual fallback (`pickServerText`).
  String _pick(String bn, String en) =>
      pickServerText(english ? _en : _bn, bn, en);

  /// The CONTEXT block for Gemini: only facts, in the app language.
  Map<String, dynamic> toContextJson() => <String, dynamic>{
    'app_language': english ? 'English' : 'Bangla',
    'screen': screen,
    'customer': {
      'name': english ? (nameEn ?? nameBn) : (nameBn ?? nameEn),
      'balance_bdt': balanceBdt,
    },
    'phone_safety_check': verdict == null
        ? {'status': safetyChecking ? 'checking' : 'not_checked_yet'}
        : {
            'verdict': verdict!.wire,
            'message': _pick(safetyMessageBn, safetyMessageEn),
            'findings': [
              for (final f in findings.take(5))
                _pick(f.titleBn, f.titleEn).isNotEmpty
                    ? _pick(f.titleBn, f.titleEn)
                    : _pick(f.explanationBn, f.explanationEn),
            ],
            'apps_to_uninstall': [
              for (final t in uninstallTargets)
                if (t.label.isNotEmpty) t.label,
            ],
            'what_to_do': resolution,
          },
    'last_payment_check': lastScore == null
        ? null
        : {
            'decision': lastScore!.decision.wire,
            'reasons': [
              for (final r in lastScore!.reasons) _pick(r.textBn, r.textEn),
            ],
          },
    'held_payments': held.length,
    'waiting_for_trusted_contact': held.any((h) => h.waitingForTrustedContact),
    'signals': {
      'on_a_call_now': callActive,
      'sim_changed_recently': simSwap,
      'screen_being_shared': screenShare,
    },
    'last_scam_check': (evidenceQuote ?? '').isEmpty
        ? null
        : {'caller_said': evidenceQuote, 'scam_score': scamScore},
  };
}

/// One thing Apa wants the customer to know.
class ApaInsight {
  const ApaInsight({
    required this.id,
    required this.severity,
    required this.priority,
    required this.titleBn,
    required this.titleEn,
    required this.bodyBn,
    required this.bodyEn,
    this.action = ApaAction.none,
    this.actionLabelBn = '',
    this.actionLabelEn = '',
    this.source = ApaSource.rules,
  });

  /// Stable id (`app_block`, `scam_call`, `call_transfer`, `held_transfer`,
  /// `app_caution`, `sim_swap`, `screen_share`, `all_clear`, `unchecked`,
  /// `tip_*`).
  final String id;
  final ApaSeverity severity;

  /// Order inside one severity; lower first.
  final int priority;
  final String titleBn;
  final String titleEn;
  final String bodyBn;
  final String bodyEn;
  final ApaAction action;
  final String actionLabelBn;
  final String actionLabelEn;

  /// Where the body came from.
  final ApaSource source;

  String title(bool english) =>
      pickServerText(english ? _en : _bn, titleBn, titleEn);
  String body(bool english) =>
      pickServerText(english ? _en : _bn, bodyBn, bodyEn);
  String actionLabel(bool english) =>
      pickServerText(english ? _en : _bn, actionLabelBn, actionLabelEn);

  /// Value equality, so watchers that `select` an insight (or a record of
  /// insights) do not rebuild when the engine returns the same content.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaInsight &&
          id == other.id &&
          severity == other.severity &&
          priority == other.priority &&
          titleBn == other.titleBn &&
          titleEn == other.titleEn &&
          bodyBn == other.bodyBn &&
          bodyEn == other.bodyEn &&
          action == other.action &&
          actionLabelBn == other.actionLabelBn &&
          actionLabelEn == other.actionLabelEn &&
          source == other.source;

  @override
  int get hashCode => Object.hash(
    id,
    severity,
    priority,
    titleBn,
    titleEn,
    bodyBn,
    bodyEn,
    action,
    actionLabelBn,
    actionLabelEn,
    source,
  );

  @override
  String toString() => 'ApaInsight($id, ${severity.name})';
}

/// The ARB label of [action] in [l].
String apaActionLabel(AppLocalizations l, ApaAction action) => switch (action) {
  ApaAction.openSafety => l.apaActionOpenSafety,
  ApaAction.openApaScamCheck => l.apaActionScamCheck,
  ApaAction.openApproveOrHeld => l.apaActionHeld,
  ApaAction.learnRules => l.apaActionRules,
  ApaAction.callHelpline => l.apaActionCallHelpline(ApaHelpline.of(l)),
  ApaAction.none => l.apaActionAskApa,
};

/// Display names of the apps to uninstall; never a package name.
String apaUninstallList(AppLocalizations l, List<UninstallTarget> targets) =>
    targets
        .map((t) => t.label.trim().isEmpty ? l.safetyUnknownApp : t.label)
        .toSet()
        .join(', ');

String _join(Iterable<String> parts) =>
    parts.where((p) => p.trim().isNotEmpty).join(' ');

/// The insights for [s], most severe first. Danger and caution insights come
/// from the state; when there are none, an `all_clear` (verdict SAFE) or an
/// `unchecked` insight, plus one tip from [content] picked by [tipSeed].
List<ApaInsight> buildApaInsights(
  ApaContextSnapshot s, {
  required AppLocalizations bn,
  required AppLocalizations en,
  required ApaContent content,
  int tipSeed = 0,
  bool withoutHeld = false,
}) {
  final out = <ApaInsight>[];

  ApaInsight make(
    String id,
    ApaSeverity severity,
    int priority, {
    required String Function(AppLocalizations) title,
    required String bodyBn,
    required String bodyEn,
    required ApaSource source,
    ApaAction action = ApaAction.none,
  }) => ApaInsight(
    source: source,
    id: id,
    severity: severity,
    priority: priority,
    titleBn: title(bn),
    titleEn: title(en),
    bodyBn: bodyBn,
    bodyEn: bodyEn,
    action: action,
    actionLabelBn: apaActionLabel(bn, action),
    actionLabelEn: apaActionLabel(en, action),
  );

  // 0. A risky app: the server's message, then the apps to remove.
  final blocked = s.verdict == SafetyVerdict.block;
  if (blocked) {
    final has = s.uninstallTargets.isNotEmpty;
    out.add(
      make(
        'app_block',
        ApaSeverity.danger,
        0,
        title: (l) => l.apaInsightBlockTitle,
        bodyBn: _join([
          s.safetyMessageBn,
          if (has)
            bn.apaInsightUninstallApps(
              apaUninstallList(bn, s.uninstallTargets),
            ),
        ]),
        bodyEn: _join([
          s.safetyMessageEn,
          if (has)
            en.apaInsightUninstallApps(
              apaUninstallList(en, s.uninstallTargets),
            ),
        ]),
        source: ApaSource.phone,
        action: ApaAction.openSafety,
      ),
    );
  }

  // 1. A scam check found the caller's words: quote them verbatim.
  final quote = (s.evidenceQuote ?? '').trim();
  if (quote.isNotEmpty) {
    out.add(
      make(
        'scam_call',
        ApaSeverity.danger,
        1,
        title: (l) => l.apaInsightScamTitle,
        bodyBn: _join([
          bn.apaScamLineQuote(quote),
          bn.apaScamHotline(ApaHelpline.bn),
        ]),
        bodyEn: _join([
          en.apaScamLineQuote(quote),
          en.apaScamHotline(ApaHelpline.en),
        ]),
        source: ApaSource.scam,
        action: ApaAction.callHelpline,
      ),
    );
  }

  final reasons = s.heldReasons;
  // Empty fields are dropped, so two blank `text_en` never give " ".
  final reasonsBn = _join(reasons.map((r) => r.textBn));
  final reasonsEn = _join(reasons.map((r) => r.textEn));
  // The only stop is the app block already shown above.
  final onlyAppBlock =
      blocked && s.held.isEmpty && s.lastScore?.decision == Decision.block;

  // 2. On a call with a transfer waiting: the coached-payment pattern.
  // `withoutHeld`: Home's pending-intervention card already says it, so the
  // security card skips it and shows the next thing (the sheet keeps it).
  final showHeld = s.transferPending && !onlyAppBlock && !withoutHeld;
  if (s.callActive && showHeld) {
    out.add(
      make(
        'call_transfer',
        ApaSeverity.danger,
        2,
        title: (l) => l.apaInsightCallTransferTitle,
        bodyBn: reasons.isEmpty ? bn.apaInsightCallTransferBody : reasonsBn,
        bodyEn: reasons.isEmpty ? en.apaInsightCallTransferBody : reasonsEn,
        source: ApaSource.server,
        action: ApaAction.openApproveOrHeld,
      ),
    );
  } else if (showHeld) {
    // 3. A held or delayed transfer: the server's reasons only.
    out.add(
      make(
        'held_transfer',
        ApaSeverity.caution,
        3,
        title: (l) => l.apaInsightHeldTitle,
        bodyBn: reasons.isEmpty ? bn.apaInsightHeldNoReasons : reasonsBn,
        bodyEn: reasons.isEmpty ? en.apaInsightHeldNoReasons : reasonsEn,
        source: ApaSource.server,
        action: ApaAction.openApproveOrHeld,
      ),
    );
  }

  // 4. Caution verdict.
  if (s.verdict == SafetyVerdict.caution) {
    out.add(
      make(
        'app_caution',
        ApaSeverity.caution,
        4,
        title: (l) => l.apaInsightCautionTitle,
        bodyBn: s.safetyMessageBn,
        bodyEn: s.safetyMessageEn,
        source: ApaSource.phone,
        action: ApaAction.openSafety,
      ),
    );
  }

  // 5. SIM changed recently.
  if (s.simSwap) {
    out.add(
      make(
        'sim_swap',
        ApaSeverity.caution,
        5,
        title: (l) => l.apaInsightSimSwapTitle,
        bodyBn: bn.apaInsightSimSwapBody(ApaHelpline.bn),
        bodyEn: en.apaInsightSimSwapBody(ApaHelpline.en),
        source: ApaSource.signal,
        action: ApaAction.callHelpline,
      ),
    );
  }

  // 6. Screen being shared.
  if (s.screenShare) {
    out.add(
      make(
        'screen_share',
        ApaSeverity.caution,
        6,
        title: (l) => l.apaInsightScreenShareTitle,
        bodyBn: bn.apaInsightScreenShareBody,
        bodyEn: en.apaInsightScreenShareBody,
        source: ApaSource.signal,
        action: ApaAction.learnRules,
      ),
    );
  }

  if (out.isEmpty) {
    // 7. Nothing wrong. "Safe" only when the phone check said so.
    if (s.verdict == SafetyVerdict.safe) {
      out.add(
        make(
          'all_clear',
          ApaSeverity.ok,
          7,
          title: (l) => l.apaInsightAllClearTitle,
          bodyBn: bn.apaInsightAllClearBody,
          bodyEn: en.apaInsightAllClearBody,
          source: ApaSource.phone,
          action: ApaAction.learnRules,
        ),
      );
    } else {
      out.add(
        make(
          'unchecked',
          ApaSeverity.info,
          7,
          title: (l) => l.apaInsightUncheckedTitle,
          bodyBn: bn.apaInsightUncheckedBody,
          bodyEn: en.apaInsightUncheckedBody,
          source: ApaSource.phone,
          action: ApaAction.openSafety,
        ),
      );
    }
    if (content.tips.isNotEmpty) {
      final tip = content.tips[tipSeed.abs() % content.tips.length];
      out.add(
        ApaInsight(
          id: tip.id,
          severity: ApaSeverity.info,
          priority: 8,
          titleBn: tip.titleBn,
          titleEn: tip.titleEn,
          bodyBn: tip.bodyBn,
          bodyEn: tip.bodyEn,
          source: ApaSource.rules,
        ),
      );
    }
  }

  out.sort((a, b) {
    final bySeverity = a.severity.index.compareTo(b.severity.index);
    return bySeverity != 0 ? bySeverity : a.priority.compareTo(b.priority);
  });
  return List.unmodifiable(out);
}
