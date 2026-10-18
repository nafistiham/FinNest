/// Locale-aware accessors for the server's bilingual copy (FR-3). Features
/// import this one file and render `reason.text(context)` and friends instead
/// of a `*Bn` field, so English shows the server's `*_en` line and Bangla the
/// `*_bn` line (with a fallback to the other when one is empty). Built on
/// [ServerTextX.serverText] / [pickServerText] in `l10n.dart`.
library;

import 'package:flutter/widgets.dart';

import '../data/contracts/contracts.dart';
import '../data/repos/intervention_repo.dart';
import 'l10n.dart';

export 'l10n.dart' show ServerTextX, pickServerText;

extension ReasonTextX on Reason {
  /// `text_bn` or `text_en` for the app language.
  String text(BuildContext context) => context.serverText(textBn, textEn);
}

extension FindingTextX on Finding {
  /// `title_bn` or `title_en`; empty when the server sent neither.
  String title(BuildContext context) => context.serverText(titleBn, titleEn);

  /// `explanation_bn` or `explanation_en`.
  String explanation(BuildContext context) =>
      context.serverText(explanationBn, explanationEn);
}

extension AppSafetyResponseTextX on AppSafetyResponse {
  /// `user_message_bn` or `user_message_en`.
  String userMessage(BuildContext context) =>
      context.serverText(userMessageBn, userMessageEn);
}

extension InterveneResponseTextX on InterveneResponse {
  /// `script_bn` or `script_en`. Audio is always the Bangla clip; this is
  /// the line shown on screen.
  String script(BuildContext context) => context.serverText(scriptBn, scriptEn);

  /// The other language's line (for the overlay's reveal toggle): `script_en`
  /// in Bangla, `script_bn` in English.
  String otherScript(BuildContext context) =>
      context.banglaDigits ? scriptEn : scriptBn;
}

extension ApaTurnResponseTextX on ApaTurnResponse {
  /// `reply_bn` or `reply_en`.
  String reply(BuildContext context) => context.serverText(replyBn, replyEn);
}

extension InterventionRecordTextX on InterventionRecord {
  /// The stored `script_bn` or `script_en`.
  String script(BuildContext context) => context.serverText(scriptBn, scriptEn);
}
