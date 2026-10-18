/// Lines FNA speaks or shows that come from the logic, not the screens
///: the voice greeting, the guard's safe line and the spoken call
/// summary template.
///
/// Why not the ARBs: these are spoken (and the safe line also replaces a
/// model bubble), they are built by code from server fields, and the model
/// instructions quote the same wording. The UI's own labels stay in the ARBs.
library;

import 'package:bhorosha/features/apa/logic/apa_helpline.dart';

abstract final class FnaVoiceLines {
  /// The first voice greeting of an app run.
  static const greetingFirstBn =
      'আমি ফিননেস্ট সহকারী বলছি। নিরাপত্তা নিয়ে কিছু জানতে চাইলে বলুন।';
  static const greetingFirstEn =
      'This is FinNest Assistant. Ask me anything about staying safe.';

  /// Every later voice greeting of the same app run: short, the customer
  /// already knows who is talking.
  static const greetingLaterBn = 'বলুন।';
  static const greetingLaterEn = 'Go ahead.';

  /// Replaces an FNA answer the transcript guard stopped (a code asked for,
  /// "send it" while money is held, a digit run read back). It refuses and
  /// points to people who can help; it repeats nothing of the stopped answer.
  static final safeLineBn =
      'এফএনএ এটা বলতে পারে না। এফএনএ কখনো টাকা পাঠায় না, আর কখনো পিন বা '
      'কোড চায় না। বিশ্বস্ত মানুষের মত নিন, বা ${ApaHelpline.bn} নম্বরে কল করুন।';
  static const safeLineEn =
      'FNA cannot say that. FNA never moves money and never asks for a PIN '
      'or code. Ask your trusted person, or call ${ApaHelpline.en}.';

  /// What the "Someone is asking for a code" chip asks Live in voice mode.
  static const codeAskedBn = 'ফোনে একজন আমার কাছে একটা কোড চাইছে। আমি কী করব?';
  static const codeAskedEn =
      'Someone on the phone is asking me for a code. What should I do?';

  // ------------------------------------------- spoken call summary labels

  static const summaryTitleBn = 'সন্দেহজনক কল।';
  static const summaryTitleEn = 'Suspicious call.';
  static const summaryAskedBn = 'কলার চেয়েছিল:';
  static const summaryAskedEn = 'The caller asked for:';
  static const summaryWordsBn = 'কলারের কথা:';
  static const summaryWordsEn = 'Their words:';
  static const summaryNowBn = 'এখন যা করবেন:';
  static const summaryNowEn = 'What to do now:';
  static const summaryNextBn = 'পরের বার:';
  static const summaryNextEn = 'Next time:';

  static String greeting({required bool first, required bool english}) =>
      switch ((first, english)) {
        (true, false) => greetingFirstBn,
        (true, true) => greetingFirstEn,
        (false, false) => greetingLaterBn,
        (false, true) => greetingLaterEn,
      };

  static String codeAsked({required bool english}) =>
      english ? codeAskedEn : codeAskedBn;

  static String safeLine({required bool english}) =>
      english ? safeLineEn : safeLineBn;
}
