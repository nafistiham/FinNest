/// The one place the assistant's copy reads the helpline from: `AppEnv.helpline`
/// (fictional by design, B4), in the digits of the language it is written in.
/// ARB lines take it as the `{helpline}` placeholder; `rules.json` carries the
/// same placeholder and is filled at parse time; the model instructions
/// interpolate it directly.
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/app/l10n.dart' show bnDigits;
import 'package:bhorosha/l10n/app_localizations.dart';

abstract final class ApaHelpline {
  /// Latin digits, as dialled and as written in English copy.
  static const String en = AppEnv.helpline;

  /// Bangla digits, as written in Bangla copy.
  static final String bn = bnDigits(AppEnv.helpline);

  /// The placeholder the guide content uses.
  static const String placeholder = '{helpline}';

  /// The number in the digits of [l]'s language.
  static String of(AppLocalizations l) =>
      l.localeName.startsWith('en') ? en : bn;

  /// [text] with every [placeholder] replaced; Bangla digits unless [english].
  static String fill(String text, {required bool english}) =>
      text.replaceAll(placeholder, english ? en : bn);

  /// The helpline's digits joined (`09666123456`): the one form of it the
  /// FNA transcript guard allows, as an exact whole number.
  static final String digits = en.replaceAll(RegExp(r'\D'), '');

  /// Every digit run of the helpline (`09666-123456` gives two), and the
  /// digits joined (`09666123456`), for the legacy Gemini reply check
  /// (`ApaGeminiService.failedCheck`), which compares runs one by one.
  /// Do not use it as an allowlist of numbers the assistant may say: a part
  /// such as `123456` is not a public number on its own. The FNA guard uses
  /// [digits] (exact whole number) instead.
  static final Set<String> digitRuns = {
    ...RegExp(r'\d+').allMatches(en).map((m) => m.group(0)!),
    digits,
  }..remove('');
}
