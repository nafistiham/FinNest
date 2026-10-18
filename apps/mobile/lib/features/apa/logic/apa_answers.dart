/// Apa's deterministic answers: the four quick actions, the scam-check
/// reply, the insight bubble and the offline coach's keyword intents. Every
/// answer is built from the [ApaContextSnapshot] (facts), the server's own
/// texts (quoted verbatim) and the ARB strings / guide content, in both
/// languages. Nothing here touches the network.
library;

import 'dart:ui' show Locale;

import 'package:bhorosha/app/l10n.dart' show bnDigits, pickServerText;
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:bhorosha/l10n/app_localizations.dart';

/// The offline coach's intents, in matching order (most protective first).
enum ApaIntent {
  code,
  hold,
  safe,
  app,
  loan,
  trusted,
  lottery,
  blockThreat,
  generic,
}

class ApaAnswers {
  const ApaAnswers({required this.bn, required this.en, required this.content});

  final AppLocalizations bn;
  final AppLocalizations en;
  final ApaContent content;

  ApaTurn _apa(
    String textBn,
    String textEn, {
    ApaSeverity? tone,
    ApaAction action = ApaAction.none,
    ApaSource source = ApaSource.rules,
  }) => ApaTurn(
    speaker: ApaTurn.apa,
    textBn: textBn,
    textEn: textEn,
    path: ApaTurn.guide,
    tone: tone,
    action: action,
    source: source,
  );

  /// A user bubble in both languages (a quick-action label).
  ApaTurn userLabel(String Function(AppLocalizations) label) => ApaTurn(
    speaker: ApaTurn.user,
    textBn: label(bn),
    textEn: label(en),
    path: ApaTurn.guide,
  );

  static String _lines(Iterable<String> parts) =>
      parts.where((p) => p.trim().isNotEmpty).join('\n');

  static String _verdictLabel(AppLocalizations l, SafetyVerdict v) =>
      switch (v) {
        SafetyVerdict.safe => l.safetyVerdictSafe,
        SafetyVerdict.caution => l.safetyVerdictCaution,
        SafetyVerdict.block => l.safetyVerdictBlock,
      };

  // ------------------------------------------------------------ insight

  /// The insight as a bubble: title, then body.
  ApaTurn insightTurn(ApaInsight i) => _apa(
    _lines([i.titleBn, i.bodyBn]),
    _lines([i.titleEn, i.bodyEn]),
    tone: i.severity,
    action: i.action,
    source: i.source,
  );

  // -------------------------------------------------- "আমার ফোন কি নিরাপদ?"

  List<ApaTurn> phoneSafe(ApaContextSnapshot s) {
    final v = s.verdict;
    if (v == null) {
      return [
        _apa(
          bn.apaAnswerPhoneUnchecked,
          en.apaAnswerPhoneUnchecked,
          tone: ApaSeverity.info,
          action: ApaAction.openSafety,
          source: ApaSource.phone,
        ),
      ];
    }
    String body(AppLocalizations l, bool english) {
      // Server texts in the app language, with the usual fallback to the
      // other language when a field is empty.
      final locale = Locale(english ? 'en' : 'bn');
      final titles = <String>{
        for (final f in s.findings)
          if (pickServerText(locale, f.titleBn, f.titleEn).trim().isNotEmpty)
            pickServerText(locale, f.titleBn, f.titleEn).trim(),
      }.take(4).toList();
      return _lines([
        l.apaAnswerVerdictLine(_verdictLabel(l, v)),
        pickServerText(locale, s.safetyMessageBn, s.safetyMessageEn),
        if (titles.isNotEmpty) ...[
          l.apaAnswerFindingsIntro,
          for (final t in titles) '• $t',
        ] else if (v == SafetyVerdict.safe)
          l.safetyNoFindings,
        if (s.uninstallTargets.isNotEmpty)
          l.apaInsightUninstallApps(apaUninstallList(l, s.uninstallTargets)),
      ]);
    }

    return [
      _apa(
        body(bn, false),
        body(en, true),
        tone: switch (v) {
          SafetyVerdict.block => ApaSeverity.danger,
          SafetyVerdict.caution => ApaSeverity.caution,
          SafetyVerdict.safe => ApaSeverity.ok,
        },
        action: ApaAction.openSafety,
        source: ApaSource.phone,
      ),
    ];
  }

  // ------------------------------------------------------ "টাকা কেন আটকাল?"

  /// Server reasons only (FR-3): the first bubble is exactly the reasons'
  /// texts joined with a space. Nothing held: say so and list what would
  /// hold a transfer, from the guide.
  List<ApaTurn> whyHeld(ApaContextSnapshot s) {
    final reasons = s.heldReasons;
    if (s.transferPending) {
      return [
        if (reasons.isNotEmpty)
          ApaTurn(
            speaker: ApaTurn.apa,
            textBn: reasons.map((r) => r.textBn).join(' '),
            textEn: reasons.map((r) => r.textEn).join(' '),
            path: ApaTurn.held,
            source: ApaSource.server,
          ),
        _apa(
          bn.apaAnswerHeldNext,
          en.apaAnswerHeldNext,
          action: s.pendingRequestId != null
              ? ApaAction.openApproveOrHeld
              : ApaAction.none,
        ),
      ];
    }
    return [
      _apa(
        bn.apaAnswerNothingHeld,
        en.apaAnswerNothingHeld,
        tone: ApaSeverity.ok,
      ),
      _apa(
        _lines([
          bn.apaAnswerHoldsIntro,
          for (final h in content.holds) '• ${h.bodyBn}',
        ]),
        _lines([
          en.apaAnswerHoldsIntro,
          for (final h in content.holds) '• ${h.bodyEn}',
        ]),
      ),
    ];
  }

  // ---------------------------------------------------- "নিরাপদ থাকার ৫ নিয়ম"

  List<ApaTurn> rules() => [
    for (final (i, r) in content.rules.indexed)
      _apa(
        _lines(['${bnDigits('${i + 1}')}. ${r.titleBn}', r.bodyBn]),
        _lines(['${i + 1}. ${r.titleEn}', r.bodyEn]),
      ),
  ];

  // ------------------------------------------------------ "কেউ ফোনে কোড চাইছে"

  ApaTurn scamPrompt() => _apa(bn.apaScamPrompt, en.apaScamPrompt);

  /// `true` when the classification found nothing to act on.
  static bool isBenign(ScamTurnResponse r) =>
      _benignTypes.contains(r.scamType) &&
      r.requestedSecret == 'none' &&
      (r.recommendedAction == 'none' || r.recommendedAction.isEmpty);

  static const _benignTypes = {'benign', 'none', ''};

  static String _scamType(AppLocalizations l, String type) => switch (type) {
    'fake_customer_care' ||
    'customer_care' ||
    'impersonation' => l.apaScamTypeFakeCare,
    'pressure' || 'urgency' => l.apaScamTypePressure,
    'lottery' || 'prize' => l.apaScamTypeLottery,
    'benign' || 'none' || '' => l.apaScamTypeBenign,
    _ => l.apaScamTypeOther,
  };

  static String? _secret(AppLocalizations l, String secret) => switch (secret) {
    'none' || '' => null,
    'otp' => l.apaSecretOtp,
    'pin' => l.apaSecretPin,
    'password' => l.apaSecretPassword,
    _ => l.apaSecretOther,
  };

  static String? _urgency(AppLocalizations l, String urgency) =>
      switch (urgency) {
        'high' => l.apaUrgencyHigh,
        'medium' => l.apaUrgencyMedium,
        _ => null,
      };

  static String _todo(AppLocalizations l, ScamTurnResponse r) {
    if (r.requestedSecret != 'none' && r.requestedSecret.isNotEmpty) {
      return l.apaScamDoHangUp;
    }
    return switch (r.recommendedAction) {
      'hold_and_warn' || 'hang_up' || 'hold' || 'block' => l.apaScamDoHangUp,
      'none' || '' => isBenign(r) ? l.apaScamDoNothing : l.apaScamDoCareful,
      _ => l.apaScamDoCareful,
    };
  }

  /// What the caller asked for in the app language (`otp` gives "OTP"), or
  /// `null` when nothing was asked (the spoken call summary).
  String? secretLabel(String requestedSecret, {required bool english}) =>
      _secret(english ? en : bn, requestedSecret);

  /// The "what to do now" line for a classification (the spoken call
  /// summary uses the same advice the scam-check bubble shows).
  String scamAdvice(ScamTurnResponse r, {required bool english}) =>
      _todo(english ? en : bn, r);

  /// The classification in plain words; `evidence_quote` verbatim. [saved]
  /// says the quote will travel with the next transfer.
  ApaTurn scamResult(ScamTurnResponse r, {required bool saved}) {
    final benign = isBenign(r);
    final quote = r.evidenceQuote.trim();
    String body(AppLocalizations l) {
      final secret = _secret(l, r.requestedSecret);
      final urgency = _urgency(l, r.urgency);
      return _lines([
        l.apaScamLineType(_scamType(l, r.scamType)),
        if (quote.isNotEmpty) l.apaScamLineQuote(quote),
        if (secret != null) l.apaScamLineSecret(secret),
        if (urgency != null) l.apaScamLineUrgency(urgency),
        _todo(l, r),
        if (!benign) l.apaScamHotline(ApaHelpline.of(l)),
        if (saved) l.apaScamSaved,
      ]);
    }

    final asksSecret =
        r.requestedSecret != 'none' && r.requestedSecret.isNotEmpty;
    return _apa(
      body(bn),
      body(en),
      tone: benign
          ? ApaSeverity.ok
          : (asksSecret || r.recommendedAction == 'hold_and_warn'
                ? ApaSeverity.danger
                : ApaSeverity.caution),
      action: benign ? ApaAction.none : ApaAction.callHelpline,
      source: ApaSource.scam,
    );
  }

  /// The check could not run: the standing rule, and the hotline.
  ApaTurn scamFailed() => _apa(
    _lines([bn.apaScamFailed, bn.apaScamHotline(ApaHelpline.bn)]),
    _lines([en.apaScamFailed, en.apaScamHotline(ApaHelpline.en)]),
    tone: ApaSeverity.caution,
    action: ApaAction.callHelpline,
  );

  // ------------------------------------------------------------- secrets

  /// [text] with code-like numbers masked (`••••`), and whether any were.
  /// One detector for every typed path (chat, typed-in-voice, the text
  /// agent, `check_caller_words`, the spoken call summary):
  /// [FnaTranscriptGuard.redact]. It joins digits and Bangla or English
  /// number words across spaces and punctuation ("১২ ৩৪", "চার আট দুই নয়"),
  /// and leaves amounts, dates and the public helplines alone.
  static (String, bool) redactSecrets(String text) =>
      FnaTranscriptGuard.redact(text);

  ApaTurn secretRedacted() => _apa(
    bn.apaSecretRedacted,
    en.apaSecretRedacted,
    tone: ApaSeverity.danger,
  );

  // ---------------------------------------------------- the offline coach

  static const _keywords = <ApaIntent, List<String>>{
    ApaIntent.code: [
      'কোড',
      'ওটিপি',
      'পিন',
      'পাসওয়ার্ড',
      'কল',
      'কলার',
      'otp',
      'pin',
      'code',
      'password',
      'call',
      'caller',
      'calling',
    ],
    ApaIntent.hold: [
      'আটক',
      'আটকে',
      'আটকাল',
      'আটকেছে',
      'আটকানো',
      'দেরি',
      'hold',
      'held',
      'delay',
      'delayed',
      'stopped',
      'stuck',
    ],
    ApaIntent.safe: [
      'নিরাপদ',
      'সেফ',
      'ঝুঁকি',
      'safe',
      'safety',
      'risk',
      'risky',
    ],
    ApaIntent.app: [
      'অ্যাপ',
      'এপ',
      'অ্যাপস',
      'ইনস্টল',
      'app',
      'apps',
      'apk',
      'install',
    ],
    ApaIntent.loan: ['লোন', 'ঋণ', 'loan', 'loans'],
    ApaIntent.trusted: ['আপনজন', 'বিশ্বস্ত', 'trusted', 'contact'],
    ApaIntent.lottery: ['লটারি', 'পুরস্কার', 'lottery', 'prize'],
    ApaIntent.blockThreat: [
      'বন্ধ',
      'ব্লক',
      'block',
      'blocked',
      'suspend',
      'closed',
    ],
  };

  static final _split = RegExp(r'''[\s,.;:!?।"'“”‘’()\-]+''');

  /// The first intent whose keyword starts a word of [text] (Bangla
  /// suffixes: "কলে", "পিনটা", "অ্যাপটা").
  static ApaIntent intentOf(String text) {
    final words = text.toLowerCase().split(_split).where((w) => w.isNotEmpty);
    for (final entry in _keywords.entries) {
      for (final w in words) {
        if (entry.value.any(w.startsWith)) return entry.key;
      }
    }
    return ApaIntent.generic;
  }

  /// `true` when [text] asks why money is held, delayed or stopped (a word
  /// starting with one of the coach's hold keywords) and is not about a
  /// code (a caller "holding" for an OTP is a scam question). FNA answers
  /// it from the server's reasons only, never from a model (FR-3).
  static bool asksWhyHeld(String text) {
    final words = text
        .toLowerCase()
        .split(_split)
        .where((w) => w.isNotEmpty)
        .toList();
    bool any(List<String> keys) => words.any((w) => keys.any(w.startsWith));
    return any(_keywords[ApaIntent.hold]!) && !any(_secretWords);
  }

  static const _secretWords = [
    'কোড',
    'ওটিপি',
    'পিন',
    'পাসওয়ার্ড',
    'otp',
    'pin',
    'code',
    'password',
  ];

  List<ApaTurn> coach(String text, ApaContextSnapshot s) {
    switch (intentOf(text)) {
      case ApaIntent.code:
        return [
          _apa(
            bn.apaCoachCode(ApaHelpline.bn),
            en.apaCoachCode(ApaHelpline.en),
            tone: ApaSeverity.danger,
            action: ApaAction.openApaScamCheck,
          ),
        ];
      case ApaIntent.hold:
        return whyHeld(s);
      case ApaIntent.safe:
        return phoneSafe(s);
      case ApaIntent.app:
        return [
          _apa(bn.apaCoachApp, en.apaCoachApp, action: ApaAction.openSafety),
        ];
      case ApaIntent.loan:
        return [_apa(bn.apaCoachLoan, en.apaCoachLoan)];
      case ApaIntent.trusted:
        return [_apa(bn.apaCoachTrusted, en.apaCoachTrusted)];
      case ApaIntent.lottery:
        return [
          _apa(
            bn.apaCoachLottery,
            en.apaCoachLottery,
            tone: ApaSeverity.caution,
          ),
        ];
      case ApaIntent.blockThreat:
        final rule = content.rule('ignore_block_threat');
        return [
          _apa(
            rule?.bodyBn ?? bn.apaCoachCode(ApaHelpline.bn),
            rule?.bodyEn ?? en.apaCoachCode(ApaHelpline.en),
            tone: ApaSeverity.caution,
            action: ApaAction.openApaScamCheck,
          ),
        ];
      case ApaIntent.generic:
        return [_apa(bn.apaCoachGeneric, en.apaCoachGeneric)];
    }
  }
}
