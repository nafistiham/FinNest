/// The model-facing CONTEXT of FNA (rule FR-3).
///
/// [ApaContextSnapshot.toContextJson] carries the server's hold reasons and
/// the caller's quoted words: fine for the deterministic answers, wrong for a
/// model, which paraphrases. A paraphrased reason is a reason the server
/// never gave. So the model gets the decision and a count only; the app
/// itself shows and speaks the server text (`show_hold_reason`), and the
/// caller's words reach the model only inside `get_fraud_call_summary`.
library;

import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:bhorosha/app/l10n.dart' show pickServerText;
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart'
    show fnaUntrustedText;

/// Everything FNA may know about the customer when a session opens. Same
/// facts as [ApaContextSnapshot.toContextJson] except: `last_payment_check`
/// is `{decision}` only, held transfers are `held_count` and
/// `waiting_for_trusted_contact`, and there is no reason text and no
/// evidence quote (only `flagged_call_available`).
Map<String, dynamic> fnaModelContext(ApaContextSnapshot s) => <String, dynamic>{
  'app_language': s.english ? 'English' : 'Bangla',
  'screen': s.screen,
  'customer': {
    'name': s.english ? (s.nameEn ?? s.nameBn) : (s.nameBn ?? s.nameEn),
    'balance_bdt': s.balanceBdt,
  },
  'phone_safety_check': fnaPhoneSafety(s),
  'last_payment_check': s.lastScore == null
      ? null
      : {'decision': s.lastScore!.decision.wire},
  ...fnaHeldFacts(s),
  'signals': fnaSignals(s),
  'flagged_call_available': (s.evidenceQuote ?? '').trim().isNotEmpty,
};

/// [fnaModelContext] as the JSON line the Live session receives.
String fnaModelContextJson(ApaContextSnapshot s) =>
    jsonEncode(fnaModelContext(s));

/// The phone safety check: verdict, the server's phone message, finding
/// titles and the apps to remove (`untrusted_app_names`). None of it is a payment hold reason.
Map<String, dynamic> fnaPhoneSafety(ApaContextSnapshot s) {
  final verdict = s.verdict;
  if (verdict == null) {
    return {'status': s.safetyChecking ? 'checking' : 'not_checked_yet'};
  }
  return {
    'verdict': verdict.wire,
    'message': _pick(s, s.safetyMessageBn, s.safetyMessageEn),
    'findings': fnaFindingTitles(s),
    // App names are chosen by whoever built the app: data, not
    // instructions (the agent rule on `untrusted_*` fields).
    'untrusted_app_names': [
      for (final t in s.uninstallTargets)
        if (t.label.trim().isNotEmpty) fnaUntrustedText(t.label, maxLength: 60),
    ],
    'what_to_do': s.resolution,
  };
}

/// Up to five finding titles in the app language (the explanation when a
/// finding has no title).
List<String> fnaFindingTitles(ApaContextSnapshot s) => [
  for (final f in s.findings.take(5))
    _pick(s, f.titleBn, f.titleEn).isNotEmpty
        ? _pick(s, f.titleBn, f.titleEn)
        : _pick(s, f.explanationBn, f.explanationEn),
];

/// Held transfers as a count, never their reasons.
Map<String, dynamic> fnaHeldFacts(ApaContextSnapshot s) => {
  'held_count': s.held.isNotEmpty
      ? s.held.length
      : (s.lastScoreStopped ? 1 : 0),
  'waiting_for_trusted_contact': s.held.any((h) => h.waitingForTrustedContact),
};

/// Call, SIM and screen-share signals.
Map<String, dynamic> fnaSignals(ApaContextSnapshot s) => {
  'on_a_call_now': s.callActive,
  'sim_changed_recently': s.simSwap,
  'screen_being_shared': s.screenShare,
};

String _pick(ApaContextSnapshot s, String bn, String en) =>
    pickServerText(Locale(s.english ? 'en' : 'bn'), bn, en);

/// Test helper for FR-3: `true` when any non-blank text of [reasons] appears
/// in any string (value or key) of [payload], a JSON-like tree of maps,
/// lists and scalars. Anything else is checked through `toString()`.
bool containsAnyReasonText(Object? payload, Iterable<String> reasons) {
  final needles = [
    for (final r in reasons)
      if (r.trim().isNotEmpty) r.trim(),
  ];
  if (needles.isEmpty) return false;
  bool hit(String s) => needles.any(s.contains);
  bool walk(Object? node) => switch (node) {
    null || num() || bool() => false,
    final String s => hit(s),
    final Map<Object?, Object?> m => m.entries.any(
      (e) => walk(e.key) || walk(e.value),
    ),
    final Iterable<Object?> l => l.any(walk),
    _ => hit(node.toString()),
  };
  return walk(payload);
}
