// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Bengali Bangla (`bn`).
class AppLocalizationsBn extends AppLocalizations {
  AppLocalizationsBn([String locale = 'bn']) : super(locale);

  @override
  String get appName => 'ফিননেস্ট';

  @override
  String get tagline => 'আপনার টাকার নিরাপদ ঘর';

  @override
  String get login => 'লগইন';

  @override
  String get demoLogin => 'ডেমো লগইন';

  @override
  String get demoLoginHint =>
      'এটি ডেমো লগইন। আপনি একজন নমুনা গ্রাহক হিসেবে ঢুকবেন।';

  @override
  String get home => 'হোম';

  @override
  String get sendMoney => 'টাকা পাঠান';

  @override
  String get apa => 'এফএনএ';

  @override
  String get askApa => 'এফএনএ-কে জিজ্ঞাসা করুন';

  @override
  String get fraudDesk => 'ফ্রড ডেস্ক';

  @override
  String get demoMode => 'ডেমো মোড';

  @override
  String get recordingMode => 'রেকর্ডিং';

  @override
  String get retry => 'আবার চেষ্টা করুন';

  @override
  String get cancel => 'বাতিল করুন';

  @override
  String get ok => 'ঠিক আছে';

  @override
  String get next => 'পরের ধাপ';

  @override
  String get balance => 'ব্যালেন্স';

  @override
  String get recentTransactions => 'সাম্প্রতিক লেনদেন';

  @override
  String get safety => 'ফোনের নিরাপত্তা';

  @override
  String get demoPanel => 'ডেমো প্যানেল';

  @override
  String placeholderScreen(String name) {
    return '$name স্ক্রিন শিগগিরই আসছে';
  }

  @override
  String get safetyChecking => 'যাচাই হচ্ছে…';

  @override
  String get safetyCheckFailed => 'যাচাই করা যায়নি। আবার চেষ্টা করতে চাপুন।';

  @override
  String get safetySimulatedTag => 'সিমুলেটেড';

  @override
  String get safetyUninstall => 'আনইনস্টল';

  @override
  String get safetyNoFindings => 'কোনো ঝুঁকিপূর্ণ অ্যাপ পাওয়া যায়নি';

  @override
  String get safetyBlockedTitle => 'লেনদেন বাতিল করা হয়েছে';

  @override
  String get safetyFindingsTitle => 'যা পাওয়া গেছে';

  @override
  String get safetyVerdictSafe => 'নিরাপদ';

  @override
  String get safetyVerdictCaution => 'সাবধান';

  @override
  String get safetyVerdictBlock => 'ঝুঁকিপূর্ণ';

  @override
  String get safetySeverityLow => 'কম';

  @override
  String get safetySeverityMedium => 'মাঝারি';

  @override
  String get safetySeverityHigh => 'বেশি';

  @override
  String get safetySeverityCritical => 'গুরুতর';

  @override
  String get safetyOpenDetails => 'ফোনের নিরাপত্তা দেখুন';

  @override
  String get approveTitle => 'অনুমোদনের অনুরোধ';

  @override
  String get approveButton => 'অনুমোদন করুন';

  @override
  String get declineButton => 'প্রত্যাখ্যান করুন';

  @override
  String get approvedLine => 'অনুমোদিত। টাকা পাঠানো হয়েছে।';

  @override
  String get declinedLine => 'প্রত্যাখ্যাত। লেনদেন আটকে থাকবে।';

  @override
  String get expiredLine => 'সময় শেষ';

  @override
  String timeLeft(String time) {
    return 'সময় বাকি $time';
  }

  @override
  String get approveRetry => 'আবার চেষ্টা করুন';

  @override
  String get approveFailed => 'এখন পাঠানো যাচ্ছে না';

  @override
  String get approveSending => 'পাঠানো হচ্ছে…';

  @override
  String get approveLoading => 'অনুরোধ খোঁজা হচ্ছে…';

  @override
  String get incomingRequestTitle => 'নতুন অনুমোদনের অনুরোধ';

  @override
  String get openRequest => 'অনুরোধ দেখুন';

  @override
  String get interventionDismiss => 'পরে দেখব';

  @override
  String get interventionEnglish => 'English';

  @override
  String get interventionWaiting => 'এফএনএ বলছে…';

  @override
  String get interventionHeldTitle => 'লেনদেন আটকে রাখা হয়েছে';

  @override
  String get interventionDelayTitle => 'লেনদেন দেরি হবে';

  @override
  String get interventionBlockedTitle => 'লেনদেন বাতিল করা হয়েছে';

  @override
  String get interventionStepUpTitle => 'আবার যাচাই দরকার';

  @override
  String get apaInitial => 'FNA';

  @override
  String actionHoldTransaction(String minutes) {
    return '$minutes মিনিট আটকে রাখুন';
  }

  @override
  String actionFreezePinReset(String minutes) {
    return 'পিন বদল $minutes মিনিট বন্ধ রাখুন';
  }

  @override
  String actionDelayNewPayee(String minutes) {
    return '$minutes মিনিট পরে পাঠান';
  }

  @override
  String actionTrustedContact(String expiresInMinutes) {
    return 'আপনজনের মত নিন ($expiresInMinutes মিনিট)';
  }

  @override
  String get actionStepUp => 'আবার যাচাই করুন';

  @override
  String get actionBlock => 'লেনদেন বাতিল করুন';

  @override
  String get actionUnknown => 'অন্য পদক্ষেপ';

  @override
  String get apaSheetTitle => 'ফিননেস্ট সহকারী';

  @override
  String get apaHoldToTalk => 'চেপে ধরে বলুন';

  @override
  String get apaListening => 'শুনছি…';

  @override
  String get apaPathLive => 'লাইভ';

  @override
  String get apaTypeHint => 'এখানে লিখুন…';

  @override
  String get apaSend => 'পাঠান';

  @override
  String get apaLiveUnavailable => 'লাইভ কথা এখন চালু নেই। লিখে জিজ্ঞাসা করুন।';

  @override
  String get apaMicDenied => 'মাইক্রোফোনের অনুমতি নেই। লিখে জিজ্ঞাসা করুন।';

  @override
  String get apaTextFailed =>
      'ফিননেস্ট সহকারীর সাথে এখন যোগাযোগ করা যাচ্ছে না। আবার চেষ্টা করুন।';

  @override
  String get apaLiveFailed => 'লাইভ কথা বন্ধ হয়ে গেছে। লিখে জিজ্ঞাসা করুন।';

  @override
  String get apaEnglishToggle => 'English';

  @override
  String get apaThinking => 'এফএনএ ভাবছে…';

  @override
  String get apaEmptyTranscript => 'ফিননেস্ট সহকারীকে যা খুশি জিজ্ঞাসা করুন';

  @override
  String get apaYou => 'আপনি';

  @override
  String get demoVideoPreset => 'ভিডিওর জন্য সাজান';

  @override
  String get demoReplayScam => 'প্রতারণার কলটি চালান';

  @override
  String get demoResetCooldown => 'অপেক্ষার সময় মুছে দিন';

  @override
  String get demoResetAll => 'সব শুরুর মতো করুন';

  @override
  String get demoPreviewAudio => 'এফএনএ-র অডিও শুনুন';

  @override
  String get demoForcedVerdict => 'নিরাপত্তার ফল ঠিক করে দিন';

  @override
  String get demoPersona => 'গ্রাহক';

  @override
  String get demoFlagSimSwap => 'সিম বদল';

  @override
  String get demoFlagCallActive => 'কল চলছে';

  @override
  String get demoFlagScreenShare => 'স্ক্রিন শেয়ার';

  @override
  String get demoFlagCallerInContacts => 'কলার কন্ট্যাক্টে আছে';

  @override
  String get demoHealth => 'সার্ভার চালু আছে কি না দেখুন';

  @override
  String get loginChoosePersona => 'কে লগইন করবেন?';

  @override
  String get passkeyUnavailable => 'পাসকি লগইন এখন চালু নেই';

  @override
  String get passkeyPendingLine =>
      'পাসকি কাজ করেছে। এই ডেমোতে ডেমো লগইন ব্যবহার করুন।';

  @override
  String get logout => 'লগ আউট';

  @override
  String get savedPayees => 'সেভ করা প্রাপক';

  @override
  String get newNumber => 'নতুন নম্বর';

  @override
  String get amount => 'পরিমাণ';

  @override
  String get quickAmounts => 'দ্রুত পরিমাণ';

  @override
  String get backspace => 'মুছুন';

  @override
  String get pinTitle => 'পিন দিন';

  @override
  String get pinVerifying => 'যাচাই হচ্ছে…';

  @override
  String get pinWrong => 'পিন ভুল হয়েছে। আবার দিন।';

  @override
  String pinLocked(String seconds) {
    return '$seconds সেকেন্ড পরে আবার চেষ্টা করুন';
  }

  @override
  String get pinObscured =>
      'অন্য একটি অ্যাপ স্ক্রিন ঢেকে রেখেছে। এক মুহূর্ত অপেক্ষা করুন।';

  @override
  String pinDigitsEntered(String count) {
    return '$count সংখ্যা দেওয়া হয়েছে';
  }

  @override
  String get stepUpTitle => 'স্ক্রিন শেয়ার বন্ধ করুন';

  @override
  String get stepUpBody =>
      'স্ক্রিন শেয়ার চলা অবস্থায় টাকা পাঠানো নিরাপদ নয়। শেয়ার বন্ধ করে আবার পিন দিন।';

  @override
  String get stepUpRetry => 'আবার চেষ্টা করুন';

  @override
  String get resultDone => 'টাকা পাঠানো হয়েছে';

  @override
  String get resultHeld => 'আপনার টাকা নিরাপদে আটকে আছে';

  @override
  String get resultBlocked => 'লেনদেন বাতিল করা হয়েছে';

  @override
  String get resultUnavailable => 'এখন যাচাই করা যাচ্ছে না';

  @override
  String get resultUnavailableBody =>
      'আপনার টাকা কোথাও যায়নি, অ্যাকাউন্টেই আছে। একটু পরে আবার চেষ্টা করুন।';

  @override
  String get goHome => 'হোমে ফিরুন';

  @override
  String get fraudDeskBody =>
      'ফ্রড ডেস্ক হলো ব্যাংকের তদন্ত দলের কনসোল। আটকে রাখা লেনদেন, কারণ ও সময়রেখা এখানে দেখা যায়। এটি ব্রাউজারে খুলবে।';

  @override
  String get openConsole => 'কনসোল খুলুন';

  @override
  String get openConsoleFailed => 'কনসোল খোলা যায়নি';

  @override
  String get txnTypeSendMoney => 'টাকা পাঠানো';

  @override
  String get txnTypeCashIn => 'ক্যাশ ইন';

  @override
  String get txnTypeCashOut => 'ক্যাশ আউট';

  @override
  String get txnTypeSalary => 'বেতন';

  @override
  String get txnTypeRecharge => 'রিচার্জ';

  @override
  String get txnTypeOther => 'লেনদেন';

  @override
  String get statusHeld => 'আটকে আছে';

  @override
  String get statusBlocked => 'ঝুঁকিতে বাতিল';

  @override
  String get statusDone => 'সম্পন্ন';

  @override
  String get trustedRequestSent =>
      'আপনজনকে অনুরোধ পাঠানো হয়েছে। উত্তর এলে জানাব।';

  @override
  String get trustedRequestFailed => 'অনুরোধ পাঠানো যায়নি';

  @override
  String get noRecentTransactions => 'এখনো কোনো লেনদেন নেই';

  @override
  String get safetyFromLastCheck =>
      'নতুন যাচাই করা যায়নি। আগের ফলাফল দেখানো হচ্ছে।';

  @override
  String get safetyDeviceSection => 'আপনার ফোন';

  @override
  String get safetyUninstallLine => 'ঝুঁকিপূর্ণ অ্যাপ সরিয়ে আবার যাচাই করুন';

  @override
  String get safetyFixPhoneLine => 'ফোনের সেটিংস ঠিক করে আবার যাচাই করুন';

  @override
  String get safetyReinstallLine => 'প্লে স্টোর থেকে ফিননেস্ট আবার ইনস্টল করুন';

  @override
  String get safetyOpenPlay => 'প্লে স্টোরে যান';

  @override
  String get safetyCallBankLine => 'ফিননেস্টের হেল্পলাইনে কথা বলুন';

  @override
  String get safetyCallBank => 'ফিননেস্টে কল করুন';

  @override
  String get safetyRecheck => 'আবার যাচাই করুন';

  @override
  String get demoIntegrity => 'ফোন যাচাইয়ের ফল · ডেমো';

  @override
  String get demoIntegrityClean => 'স্বাভাবিক';

  @override
  String get demoIntegrityScreenControlled => 'স্ক্রিন অন্যের হাতে';

  @override
  String get demoIntegrityModded => 'বদলানো অ্যাপ';

  @override
  String get demoIntegrityEmulator => 'নকল ফোন (এমুলেটর)';

  @override
  String get demoIntegrityUnbound => 'যাচাই মেলেনি';

  @override
  String get demoRerunSafety => 'নিরাপত্তা যাচাই আবার চালান';

  @override
  String get financeSavingsTitle => 'সঞ্চয়';

  @override
  String get financeLoansTitle => 'ঋণ';

  @override
  String get financeTileLoans => 'ঋণ';

  @override
  String get financeTileSavings => 'সঞ্চয়';

  @override
  String get financeEmpty => 'এখনো কোনো ডিপিএস নেই';

  @override
  String get financeLoadFailed => 'তথ্য আনা যায়নি';

  @override
  String get financeActionFailed => 'হয়নি। আবার চেষ্টা করুন।';

  @override
  String get dpsOpenNew => 'নতুন ডিপিএস খুলুন';

  @override
  String get dpsMonthly => 'মাসিক জমা';

  @override
  String get dpsPaidSoFar => 'এ পর্যন্ত জমা';

  @override
  String get dpsMaturity => 'মেয়াদ শেষে পাবেন';

  @override
  String dpsDemoRate(String rate) {
    return 'ডেমো হার $rate%';
  }

  @override
  String dpsTenureYears(int years) {
    final intl.NumberFormat yearsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String yearsString = yearsNumberFormat.format(years);

    return '$yearsString বছর';
  }

  @override
  String dpsInstalments(String paid, String total) {
    return '$paid/$total কিস্তি';
  }

  @override
  String get dpsChooseAmount => 'মাসে কত জমাবেন?';

  @override
  String get dpsChooseTenure => 'কত বছরের জন্য?';

  @override
  String dpsFirstInstalment(String amount) {
    return 'আজই প্রথম কিস্তি $amount কেটে নেওয়া হবে';
  }

  @override
  String get dpsConfirm => 'ডিপিএস খুলুন';

  @override
  String get dpsOpened => 'ডিপিএস খোলা হয়েছে';

  @override
  String loanIncomeLine(String amount) {
    return 'মাসিক আয় $amount অনুসারে';
  }

  @override
  String get loanProducts => 'ঋণের ধরন';

  @override
  String get loanApply => 'আবেদন করুন';

  @override
  String get loanOverLimit => 'আপনার সীমার বেশি';

  @override
  String get loanNeverAsksOtp =>
      'ফিননেস্ট কখনো ঋণের জন্য ওটিপি (এসএমএসে আসা গোপন কোড) বা পিন চায় না';

  @override
  String get loanStatusPending => 'অনুমোদনের অপেক্ষায়';

  @override
  String get loanStatusApproved => 'অনুমোদিত';

  @override
  String get loanStatusRejected => 'প্রত্যাখ্যাত';

  @override
  String get loanTotalRepayable => 'মোট ফেরত';

  @override
  String loanTenureMonths(int months) {
    final intl.NumberFormat monthsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String monthsString = monthsNumberFormat.format(months);

    return '$monthsString মাস';
  }

  @override
  String loanDemoFee(String pct) {
    return 'ডেমো ফি $pct%';
  }

  @override
  String get loanApplied => 'আবেদন জমা হয়েছে';

  @override
  String get loanApplications => 'আপনার আবেদন';

  @override
  String get trustedRequestSentLine => 'আপনজনকে অনুরোধ পাঠানো হয়েছে';

  @override
  String get loginFailed => 'লগইন হয়নি। আবার চেষ্টা করুন।';

  @override
  String get pinCheckUnavailable => 'পিন এখন যাচাই করা যায়নি। আবার পিন দিন।';

  @override
  String get recentLoadFailed => 'লেনদেন আনা যায়নি';

  @override
  String get resultHeldBody =>
      'টাকা আপনার অ্যাকাউন্টেই আছে, কোথাও যায়নি। কী করবেন জানতে ফিননেস্ট সহকারীকে জিজ্ঞাসা করুন।';

  @override
  String get demoDataOnline => 'অনলাইন ডেটা';

  @override
  String get demoDataOffline => 'অফলাইন ডেটা';

  @override
  String get languageBangla => 'বাংলা';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageToggleLabel => 'ভাষা বেছে নিন';

  @override
  String get loginPersonaRina => 'রিনা আক্তার';

  @override
  String get loginPersonaRahima => 'রহিমা বেগম';

  @override
  String get demoPersonaRina => 'রিনা';

  @override
  String get demoPersonaRahima => 'রহিমা';

  @override
  String approveHeaderAmount(String amount) {
    return 'অনুরোধ · $amount';
  }

  @override
  String get approveHeaderUnknown => 'আপনজনের অনুরোধ';

  @override
  String get safetyUnknownApp => 'নাম না জানা অ্যাপ';

  @override
  String get safetySeverityOther => 'ঝুঁকি';

  @override
  String get loanGeneric => 'ঋণ';

  @override
  String get demoVerdictAuto => 'স্বয়ংক্রিয়';

  @override
  String demoCloudStatus(String status) {
    return 'ক্লাউড: $status';
  }

  @override
  String get demoCloudConfigured => 'সংযুক্ত';

  @override
  String get demoCloudAbsent => 'চালু করা নেই';

  @override
  String get demoCloudFailed => 'চালু হয়নি';

  @override
  String demoScamScore(String score) {
    return 'প্রতারণার স্কোর $score';
  }

  @override
  String demoReplayTurn(String n, String score, String urgency) {
    return '$n. স্কোর $score · তাড়া: $urgency';
  }

  @override
  String get demoUrgencyNone => 'নেই';

  @override
  String get demoActionFailed => 'হয়নি। আবার চেষ্টা করুন।';

  @override
  String get interventionShowBangla => 'বাংলা দেখুন';

  @override
  String get apaPathGemini => 'এআই';

  @override
  String get apaPathGuide => 'অফলাইন গাইড';

  @override
  String get apaQuickPhoneSafe => 'আমার ফোন কি নিরাপদ?';

  @override
  String get apaQuickWhyHeld => 'টাকা কেন আটকাল?';

  @override
  String get apaQuickCodeAsked => 'কেউ ফোনে কোড চাইছে';

  @override
  String get apaQuickRules => 'নিরাপদ থাকার ৫ নিয়ম';

  @override
  String get apaInsightBlockTitle => 'আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে';

  @override
  String apaInsightUninstallApps(String apps) {
    return 'এগুলো আনইনস্টল করুন: $apps';
  }

  @override
  String get apaInsightCautionTitle => 'ফোনে সাবধান হওয়ার মতো কিছু আছে';

  @override
  String get apaInsightScamTitle => 'কলে প্রতারণার লক্ষণ';

  @override
  String get apaInsightCallTransferTitle => 'কলে থাকা অবস্থায় টাকা পাঠাবেন না';

  @override
  String get apaInsightCallTransferBody =>
      'আপনি এখন কলে আছেন আর একটি লেনদেন অপেক্ষায় আছে। আগে কল কেটে দিন।';

  @override
  String get apaInsightHeldTitle => 'আপনার একটি লেনদেন আটকে আছে';

  @override
  String get apaInsightHeldNoReasons =>
      'বিস্তারিত জানতে এফএনএ-কে জিজ্ঞাসা করুন।';

  @override
  String get apaInsightSimSwapTitle => 'আপনার সিম সম্প্রতি বদলেছে';

  @override
  String apaInsightSimSwapBody(String helpline) {
    return '২৪ ঘণ্টা টাকা পাঠানো আটকে থাকতে পারে। আপনি না বদলালে এখনই $helpline নম্বরে কল করুন।';
  }

  @override
  String get apaInsightScreenShareTitle => 'আপনার স্ক্রিন শেয়ার হচ্ছে';

  @override
  String get apaInsightScreenShareBody =>
      'শেয়ার বন্ধ না করে টাকা পাঠাবেন না বা পিন দেবেন না।';

  @override
  String get apaInsightAllClearTitle => 'ফোন ও লেনদেন নিরাপদ দেখাচ্ছে';

  @override
  String get apaInsightAllClearBody => 'কেউ কোড চাইলে এফএনএ-কে জানান।';

  @override
  String get apaInsightUncheckedTitle => 'ফোন এখনো যাচাই হয়নি';

  @override
  String get apaInsightUncheckedBody => 'একবার ফোনের নিরাপত্তা দেখে নিন।';

  @override
  String get apaInsightLoading => 'এফএনএ দেখছে…';

  @override
  String get apaSeverityDanger => 'বিপদ';

  @override
  String get apaSeverityCaution => 'সাবধান';

  @override
  String get apaSeverityOk => 'নিরাপদ';

  @override
  String get apaSeverityInfo => 'জেনে রাখুন';

  @override
  String get apaActionOpenSafety => 'ফোনের নিরাপত্তা দেখুন';

  @override
  String get apaActionScamCheck => 'কলারের কথা যাচাই করুন';

  @override
  String get apaActionHeld => 'আটকে থাকা টাকা দেখুন';

  @override
  String get apaActionRules => 'নিরাপদ থাকার নিয়ম';

  @override
  String get apaActionAskApa => 'এফএনএ-কে জিজ্ঞাসা করুন';

  @override
  String apaActionCallHelpline(String helpline) {
    return '$helpline নম্বরে কল করুন';
  }

  @override
  String get apaAnswerPhoneUnchecked =>
      'ফোন এখনো যাচাই হয়নি। নিচের বোতাম চেপে যাচাই করুন।';

  @override
  String apaAnswerVerdictLine(String verdict) {
    return 'ফোনের অবস্থা: $verdict';
  }

  @override
  String get apaAnswerFindingsIntro => 'যা পাওয়া গেছে:';

  @override
  String get apaAnswerNothingHeld => 'এখন আপনার কোনো টাকা আটকে নেই।';

  @override
  String get apaAnswerHoldsIntro => 'এসব কারণে টাকা আটকাতে পারে:';

  @override
  String get apaAnswerHeldNext =>
      'টাকা পাঠানো হয়নি। আপনজনের অনুমোদন চাইতে পারেন, অথবা কারণটা মিটলে আবার চেষ্টা করুন।';

  @override
  String get apaScamPrompt =>
      'কলার কী বলেছে, যতটা পারেন হুবহু লিখুন। আপনার কোড বা পিন এখানে লিখবেন না।';

  @override
  String get apaScamInputHint => 'কলার যা বলেছে…';

  @override
  String get apaScamCancel => 'বাতিল';

  @override
  String get apaScamTypeFakeCare => 'ভুয়া কাস্টমার কেয়ার কল';

  @override
  String get apaScamTypePressure => 'চাপ দিয়ে তাড়াহুড়ো করানো';

  @override
  String get apaScamTypeLottery => 'লটারি বা পুরস্কারের ফাঁদ';

  @override
  String get apaScamTypeOther => 'সন্দেহজনক কল';

  @override
  String get apaScamTypeBenign => 'প্রতারণার স্পষ্ট লক্ষণ পাওয়া যায়নি';

  @override
  String apaScamLineType(String type) {
    return 'ধরন: $type';
  }

  @override
  String apaScamLineQuote(String quote) {
    return 'কলার বলেছে: “$quote”';
  }

  @override
  String apaScamLineSecret(String secret) {
    return 'চাওয়া হয়েছে: $secret';
  }

  @override
  String apaScamLineUrgency(String level) {
    return 'চাপ: $level';
  }

  @override
  String get apaSecretOtp => 'ওটিপি বা কোড';

  @override
  String get apaSecretPin => 'পিন';

  @override
  String get apaSecretPassword => 'পাসওয়ার্ড';

  @override
  String get apaSecretOther => 'গোপন তথ্য';

  @override
  String get apaUrgencyHigh => 'অনেক বেশি';

  @override
  String get apaUrgencyMedium => 'মাঝারি';

  @override
  String get apaScamDoHangUp =>
      'কী করবেন: কল কেটে দিন, টাকা পাঠাবেন না, কোনো কোড বলবেন না।';

  @override
  String get apaScamDoCareful => 'কী করবেন: সাবধান থাকুন, তাড়াহুড়ো করবেন না।';

  @override
  String get apaScamDoNothing =>
      'কী করবেন: এখন বিশেষ কিছু করার নেই। তবে কেউ কোড চাইলে কল কেটে দিন।';

  @override
  String apaScamHotline(String helpline) {
    return 'কল কেটে দিন, তারপর নিজে $helpline নম্বরে কল করুন।';
  }

  @override
  String get apaScamSaved =>
      'এই কথাটা আপনার পরের লেনদেনের নিরাপত্তা যাচাইয়ে যোগ হবে।';

  @override
  String get apaScamFailed =>
      'এখন যাচাই করা গেল না। মনে রাখবেন: কেউ কোড বা পিন চাইলে সে প্রতারক।';

  @override
  String get apaSecretRedacted =>
      'আপনার লেখায় একটি কোডের মতো নম্বর ছিল, সেটা লুকিয়ে রাখা হয়েছে। কোড বা পিন কাউকে বলবেন না, এফএনএ-কেও না।';

  @override
  String apaCoachCode(String helpline) {
    return 'কেউ কোড, ওটিপি বা পিন চাইলে সে প্রতারক। ফিননেস্ট কখনো এগুলো চায় না। কল কেটে দিন, তারপর $helpline নম্বরে কল করুন।';
  }

  @override
  String get apaCoachApp =>
      'কারো কথায় বা অচেনা লিংক থেকে অ্যাপ নামাবেন না। এমন অ্যাপ আপনার স্ক্রিন দেখতে বা ফোন চালাতে পারে।';

  @override
  String get apaCoachLoan =>
      'ঋণ দেবে বলে আগে টাকা, কোড বা অ্যাপ নামাতে বললে সেটা প্রতারণা। ফিননেস্টের ঋণ শুধু এই অ্যাপের ‘ঋণ’ পাতায়।';

  @override
  String get apaCoachTrusted =>
      'আপনজন হলেন আপনার বিশ্বস্ত একজন মানুষ। সন্দেহজনক লেনদেন আটকালে তাঁর অনুমোদন চাওয়া যায়। তিনি রাজি হলেই টাকা যায়।';

  @override
  String get apaCoachLottery =>
      'লটারি বা পুরস্কার জিতেছেন বলে আগে টাকা বা কোড চাইলে সেটা প্রতারণা।';

  @override
  String get apaCoachGeneric =>
      'আমি ফিননেস্ট সহকারী বলছি। সংক্ষেপে আমাকে এফএনএ বলতে পারেন। নিচের চারটি বোতামের যেকোনোটা চাপুন: ফোন নিরাপদ কি না, টাকা কেন আটকাল, কেউ কোড চাইলে কী করবেন, আর নিরাপদ থাকার নিয়ম।';

  @override
  String get apaQuickActionsLabel => 'এফএনএ-কে দ্রুত জিজ্ঞাসা';

  @override
  String get apaSourceServer => 'ফিননেস্টের যাচাই';

  @override
  String get apaSourcePhone => 'ফোনের নিরাপত্তা যাচাই';

  @override
  String get apaSourceSignal => 'আপনার ফোনের সংকেত';

  @override
  String get apaSourceScam => 'কল যাচাই';

  @override
  String get apaSourceRules => 'এফএনএ-র নিয়ম';

  @override
  String get apaSourceAi => 'এফএনএ-র উত্তর · এআই';

  @override
  String apaInsightMore(String count) {
    return 'আরও $countটি বিষয়';
  }

  @override
  String get homeWhatToDo => 'কী করতে চান';

  @override
  String get homeSeeAll => 'সব দেখুন';

  @override
  String greetingShort(String name) {
    return 'স্বাগতম, $name';
  }

  @override
  String get balanceTotal => 'মোট ব্যালেন্স';

  @override
  String get balanceShow => 'দেখুন';

  @override
  String get balanceHide => 'লুকান';

  @override
  String get balanceHidden => 'ব্যালেন্স লুকানো';

  @override
  String get featureSend => 'টাকা পাঠান';

  @override
  String get featureCashOut => 'ক্যাশ আউট';

  @override
  String get featureCashIn => 'ক্যাশ ইন';

  @override
  String get featureRecharge => 'মোবাইল রিচার্জ';

  @override
  String get featureBill => 'বিল দিন';

  @override
  String get featureHistory => 'লেনদেন';

  @override
  String get settings => 'সেটিংস';

  @override
  String get sendWho => 'কাকে পাঠাবেন';

  @override
  String get sendNewNumber => 'নতুন নম্বরে পাঠান';

  @override
  String get sendSaved => 'সেভ করা';

  @override
  String get sendHelper =>
      'চেনা মানুষকে পাঠান। কেউ ফোনে তাড়া দিলে আগে ফিননেস্ট সহকারীকে জিজ্ঞাসা করুন।';

  @override
  String numberDigitsLeft(String n) {
    return '$n/১১ সংখ্যা';
  }

  @override
  String get numberNeed11 => '১১ সংখ্যা লিখুন';

  @override
  String get numberInvalid => 'নম্বরটি ঠিক নয়';

  @override
  String numberIsSaved(String name) {
    return 'এটি $name-এর নম্বর';
  }

  @override
  String get numberConfirm => 'এই নম্বরে পাঠান';

  @override
  String get paste => 'পেস্ট';

  @override
  String get change => 'বদলান';

  @override
  String get amountHowMuch => 'কত টাকা পাঠাবেন';

  @override
  String get amountEnter => 'পরিমাণ লিখুন';

  @override
  String amountBalanceLine(String amount) {
    return 'ব্যালেন্স $amount';
  }

  @override
  String amountOverBalance(String amount) {
    return 'ব্যালেন্সের চেয়ে বেশি · ব্যালেন্স $amount';
  }

  @override
  String amountMin(String amount) {
    return 'কমপক্ষে $amount';
  }

  @override
  String amountRange(String min, String max) {
    return '$min থেকে $max';
  }

  @override
  String stepOf(String n, String total) {
    return 'ধাপ $n, মোট $total';
  }

  @override
  String get cashOutAgent => 'এজেন্ট নম্বর';

  @override
  String get cashOutNewAgent => 'নতুন এজেন্ট নম্বর';

  @override
  String get cashOutHelper =>
      'এজেন্টের দোকানে গিয়ে এজেন্টের নম্বর লিখুন। টাকা হাতে নিয়ে তারপর পিন দিন।';

  @override
  String get agentNeverPin => 'এজেন্ট কখনো আপনার পিন জানতে চাইবে না';

  @override
  String get cashInMakeCode => 'কোড তৈরি করুন';

  @override
  String get cashInShowAgent =>
      'এজেন্টকে এই কোড আর টাকা দিন। এজেন্ট জমা দিলে ব্যালেন্সে যোগ হবে।';

  @override
  String get cashInDemoCode => 'ডেমো কোড — আসল QR নয়';

  @override
  String cashInExpires(String time) {
    return '$time পর্যন্ত চালু';
  }

  @override
  String get rechargeWhich => 'কোন নম্বরে?';

  @override
  String get rechargeMine => 'আমার নম্বর';

  @override
  String get rechargeOther => 'অন্য নম্বর';

  @override
  String get rechargePrepaid => 'প্রিপেইড';

  @override
  String get rechargePostpaid => 'পোস্টপেইড';

  @override
  String get opA => 'অপারেটর ক';

  @override
  String get opB => 'অপারেটর খ';

  @override
  String get opC => 'অপারেটর গ';

  @override
  String get opD => 'অপারেটর ঘ';

  @override
  String get opE => 'অপারেটর ঙ';

  @override
  String get billAccount => 'গ্রাহক নম্বর';

  @override
  String get billSee => 'বিল দেখুন';

  @override
  String billDue(String date) {
    return 'শেষ তারিখ $date';
  }

  @override
  String get billPay => 'বিল দিন';

  @override
  String get demoNoteFeature => 'ডেমো: আসল টাকা বা আসল অপারেটরে কিছু যায় না';

  @override
  String pinSendingTo(String name) {
    return '$name-কে পাঠাচ্ছেন';
  }

  @override
  String get resultRechargeDone => 'রিচার্জ হয়েছে';

  @override
  String get resultBillDone => 'বিল দেওয়া হয়েছে';

  @override
  String get resultNewBalance => 'নতুন ব্যালেন্স';

  @override
  String get resultReference => 'রেফারেন্স';

  @override
  String get overlayHeldLabel => 'আটকে রাখা হয়েছে';

  @override
  String get statusRequested => 'অপেক্ষায়';

  @override
  String get historyTitle => 'লেনদেন';

  @override
  String get historyFilterAll => 'সব';

  @override
  String get historyFilterSent => 'পাঠানো';

  @override
  String get historyFilterCashOut => 'ক্যাশ আউট';

  @override
  String get historyFilterCashIn => 'ক্যাশ ইন';

  @override
  String get historyFilterRecharge => 'রিচার্জ';

  @override
  String get historyFilterBill => 'বিল';

  @override
  String get historyFilterReceived => 'এসেছে';

  @override
  String get historyEmptyFilter => 'এই ধরনের কোনো লেনদেন নেই';

  @override
  String get today => 'আজ';

  @override
  String get yesterday => 'গতকাল';

  @override
  String get settingsAppearance => 'চেহারা';

  @override
  String get settingsColour => 'রঙ';

  @override
  String get presetTeal => 'ফিননেস্ট টিল';

  @override
  String get presetPadma => 'পদ্মা সবুজ';

  @override
  String get presetJamdani => 'জামদানি নীল';

  @override
  String get presetShapla => 'শাপলা বেগুনি';

  @override
  String get presetSlate => 'বর্ষা স্লেট';

  @override
  String get settingsMode => 'আলো / অন্ধকার';

  @override
  String get modeLight => 'আলো';

  @override
  String get modeDark => 'অন্ধকার';

  @override
  String get modeSystem => 'ফোনের মতো';

  @override
  String get settingsTextSize => 'লেখার আকার';

  @override
  String get textNormal => 'সাধারণ';

  @override
  String get textLarge => 'বড়';

  @override
  String get settingsSample => 'মা-কে ৳ ৫,০০০ পাঠান';

  @override
  String get settingsAccount => 'অ্যাকাউন্ট';

  @override
  String get neverAsksPinOtp =>
      'ফিননেস্ট কখনো আপনার পিন বা ওটিপি (এসএমএসে আসা গোপন কোড) চায় না';

  @override
  String get apaSays => 'এফএনএ বলছে';

  @override
  String get apaAsk => 'এফএনএ-কে জিজ্ঞাসা করুন';

  @override
  String get apaRole => 'ফিননেস্ট সহকারী · নিরাপত্তা গাইড';

  @override
  String get callHelpline => 'হেল্পলাইনে কল করুন';

  @override
  String get demoConfirmCashIn => 'এজেন্ট ক্যাশ ইন নিশ্চিত করলেন';

  @override
  String get loginSubmit => 'লগইন করুন';

  @override
  String get loginDistrictRina => 'গাজীপুর';

  @override
  String get loginDistrictRahima => 'ভোলা';

  @override
  String settingsAbout(String version) {
    return 'ফিননেস্ট · ডেমো সংস্করণ $version';
  }

  @override
  String get balanceUnavailable => 'ব্যালেন্স দেখা যাচ্ছে না';

  @override
  String balanceSemantics(String amount) {
    return 'মোট ব্যালেন্স $amount';
  }

  @override
  String amountSemantics(String amount) {
    return 'পরিমাণ $amount';
  }

  @override
  String get numpadClearAll => 'সব মুছুন';

  @override
  String get numpadDoubleZero => 'দুই শূন্য';

  @override
  String get numpadPaste => 'পেস্ট করুন';

  @override
  String get close => 'বন্ধ';

  @override
  String get txnSent => 'পাঠানো হয়েছে';

  @override
  String get txnReceived => 'এসেছে';

  @override
  String get statusCancelled => 'বাতিল হয়েছে';

  @override
  String get statusReleased => 'ছাড়া হয়েছে';

  @override
  String get apaNewAlert => 'নতুন সতর্কতা আছে';

  @override
  String get agentLabel => 'এজেন্ট';

  @override
  String get txnTypeBill => 'বিল / পেমেন্ট';

  @override
  String txnSemDebit(String amount) {
    return '$amount টাকা পাঠানো হয়েছে';
  }

  @override
  String txnSemCredit(String amount) {
    return '$amount টাকা এসেছে';
  }

  @override
  String get historyEmptyBody =>
      'টাকা পাঠালে বা এলে এখানে দেখা যাবে। শুরু করতে হোমে ফিরুন।';

  @override
  String get historyEmptyFilterBody => 'উপরে ‘সব’ চাপুন, সব লেনদেন দেখা যাবে।';

  @override
  String get historyDetailType => 'ধরন';

  @override
  String get historyDetailStatus => 'অবস্থা';

  @override
  String get historyDetailTime => 'সময়';

  @override
  String get historyFiltersLabel => 'লেনদেনের ধরন বেছে নিন';

  @override
  String get pendingTrustedTitle => 'আপনজনের উত্তরের অপেক্ষায়';

  @override
  String get safetyNotCheckedShort => 'যাচাই হয়নি';

  @override
  String get safetyCheckFailedShort => 'যাচাই করা যায়নি';

  @override
  String get safetyErrorBody =>
      'ইন্টারনেট চালু আছে কি না দেখে আবার চেষ্টা করুন।';

  @override
  String get safetyDetails => 'বিস্তারিত';

  @override
  String get safetyUninstallApp => 'আনইনস্টল করুন';

  @override
  String get tapToOpen => 'খুলতে চাপুন';

  @override
  String get amountHowMuchCashOut => 'কত টাকা তুলবেন';

  @override
  String get amountHowMuchCashIn => 'কত টাকা জমা দেবেন';

  @override
  String get amountHowMuchRecharge => 'কত টাকা রিচার্জ করবেন';

  @override
  String amountFeeLine(String fee, String total) {
    return 'চার্জ $fee · মোট $total';
  }

  @override
  String nextWithTotal(String total) {
    return 'পরের ধাপ · মোট $total';
  }

  @override
  String pinCashOutTo(String number) {
    return 'এজেন্ট $number-কে ক্যাশ আউট';
  }

  @override
  String pinRechargeLine(String number, String operator) {
    return '$number · $operator রিচার্জ';
  }

  @override
  String pinTotalWithFee(String total) {
    return 'চার্জ সহ মোট $total';
  }

  @override
  String get numberUseThis => 'এই নম্বর নিন';

  @override
  String get cashInCodeTitle => 'ক্যাশ ইন কোড';

  @override
  String get cashInCodeExpired => 'কোডের সময় শেষ। নতুন কোড তৈরি করুন।';

  @override
  String get cashInConfirmed => 'এজেন্ট জমা দিয়েছেন · ব্যালেন্সে যোগ হয়েছে';

  @override
  String get billDemo => 'ডেমো বিল';

  @override
  String get billWhich => 'কোন বিল দেবেন';

  @override
  String billAccountNeed(String n) {
    return '$n সংখ্যার গ্রাহক নম্বর লিখুন';
  }

  @override
  String get rechargeOperator => 'অপারেটর';

  @override
  String rechargeOperatorGuess(String operator) {
    return '$operator নম্বর মনে হচ্ছে';
  }

  @override
  String get rechargeChooseNumber => 'নম্বর বেছে নিন';

  @override
  String get rechargeChooseOperator => 'অপারেটর বেছে নিন';

  @override
  String get resultCashOutTitle => 'ক্যাশ আউট হয়েছে';

  @override
  String get resultCashOutBody => 'এজেন্টের কাছ থেকে টাকা নিন';

  @override
  String get resultSeeSafety => 'ফোনের নিরাপত্তা দেখুন';

  @override
  String recipientLast(String date) {
    return 'শেষ $date';
  }

  @override
  String get sendNoSaved => 'এখনো কাউকে সেভ করেননি';

  @override
  String overlayHeldTo(String name, String number) {
    return '$name-কে · $number';
  }

  @override
  String get overlayMoreActions => 'আরও উপায়';

  @override
  String numberCount(String n, String total) {
    return '$n/$total সংখ্যা';
  }

  @override
  String get wordmarkFin => 'Fin';

  @override
  String get wordmarkNest => 'Nest';

  @override
  String get loadingList => 'লোড হচ্ছে…';

  @override
  String get fraudDeskStaffNote => 'এটি ব্যাংকের কর্মীদের জন্য';

  @override
  String approveAsks(String name) {
    return '$name আপনার মত চাইছেন';
  }

  @override
  String get approveAsksSomeone => 'আপনার মত চাওয়া হচ্ছে';

  @override
  String get approveHeldLabel => 'আটকে রাখা টাকা';

  @override
  String approveToPayee(String name) {
    return '$name-কে পাঠানো হচ্ছিল';
  }

  @override
  String get approveWhyHeld => 'কেন আটকানো হয়েছে';

  @override
  String approveTimeLeftTag(String time) {
    return '$time বাকি';
  }

  @override
  String get approveUnknownBody =>
      'এই অনুরোধের বিস্তারিত অন্য ফোনে আছে। আপনি তবুও অনুমোদন বা প্রত্যাখ্যান করতে পারেন।';

  @override
  String approveRefSuffix(String ref) {
    return 'রেফারেন্স $ref';
  }

  @override
  String get loanYouCanGet => 'আপনি পেতে পারেন';

  @override
  String loanRowSubtitle(String months, String monthly) {
    return '$months · মাসিক কিস্তি $monthly';
  }

  @override
  String dpsPlanTitle(String amount) {
    return 'মাসে $amount জমা';
  }

  @override
  String get dpsProjectionLabel => 'মেয়াদ শেষে প্রায় পাবেন';

  @override
  String get demoGroupScene => 'দৃশ্য';

  @override
  String get demoGroupSignals => 'সংকেত';

  @override
  String get demoGroupActions => 'কাজ';

  @override
  String demoServerMsShort(String ms) {
    return 'সার্ভার $ms মি.সে.';
  }

  @override
  String get demoCashInDone => 'ক্যাশ ইন নিশ্চিত হয়েছে, ব্যালেন্স বেড়েছে';

  @override
  String get demoCashInNone => 'এজেন্টের অপেক্ষায় কোনো ক্যাশ ইন নেই';

  @override
  String get txnTypeDps => 'ডিপিএস জমা';

  @override
  String get dpsEmptyBody => 'নিচের ‘নতুন ডিপিএস খুলুন’ চাপুন।';

  @override
  String get cashInWriteFailed => 'কোড তৈরি করা যায়নি। আবার চেষ্টা করুন।';

  @override
  String get approveNotYoursTitle => 'এই অনুরোধ আপনার আপনজনের জন্য';

  @override
  String get approveNotYoursBody =>
      'অনুমোদন বা প্রত্যাখ্যান শুধু তিনিই করতে পারেন, তাঁর নিজের ফোন থেকে। কেউ আপনাকে এখানে অনুমোদন চাপতে বললে সে প্রতারক হতে পারে।';

  @override
  String get apaRoleCaption => 'নিরাপত্তা গাইড';

  @override
  String get demoVideoPresetDetail => 'কল চলছে + প্রতারণার কল';

  @override
  String dpsPlanLine(String amount, String tenure) {
    return 'মাসে $amount · $tenure';
  }

  @override
  String apaHeaderSeverity(String severity) {
    return 'এফএনএ: $severity';
  }

  @override
  String get safetyCaptionPrefix => 'ফোনের নিরাপত্তা:';

  @override
  String get loginBiometric => 'আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন';

  @override
  String get biometricReason => 'ফিননেস্টে লগইন করতে আপনার পরিচয় যাচাই করুন';

  @override
  String get loginBiometricFailed => 'যাচাই হয়নি, আবার চেষ্টা করুন।';

  @override
  String get loginWithPassword => 'পাসওয়ার্ড দিয়ে লগইন করুন';

  @override
  String get loginFallbackNotEnrolled =>
      'এই ফোনে আঙুলের ছাপ বা মুখ সেট করা নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।';

  @override
  String get loginFallbackWeak =>
      'এই ফোনের বায়োমেট্রিক যথেষ্ট নিরাপদ নয়, তাই পাসওয়ার্ড দিয়ে লগইন করুন।';

  @override
  String get loginFallbackUnsupported =>
      'এই ফোনে বায়োমেট্রিক নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।';

  @override
  String get loginPasswordLabel => 'পাসওয়ার্ড';

  @override
  String get loginPasswordShow => 'পাসওয়ার্ড দেখান';

  @override
  String get loginPasswordHide => 'পাসওয়ার্ড লুকান';

  @override
  String get loginPasswordWrong => 'পাসওয়ার্ড মেলেনি। আবার চেষ্টা করুন।';

  @override
  String loginDemoPasswordHint(String password) {
    return 'এটি ডেমো লগইন। ডেমো পাসওয়ার্ড: $password';
  }

  @override
  String get loginNoOtp =>
      'আমরা ওটিপি চাই না: ওটিপি শেয়ার করা যায়, আপনার আঙুলের ছাপ বা মুখ যায় না।';

  @override
  String get safetySearchHint => 'অ্যাপ বা সমস্যা খুঁজুন';

  @override
  String get safetySearchClear => 'খোঁজা মুছুন';

  @override
  String get safetyNothingFound => 'কিছু পাওয়া যায়নি';

  @override
  String get safetyNothingFoundBody => 'অন্য শব্দে খুঁজুন বা ফিল্টার সরান।';

  @override
  String get safetyClearFilters => 'ফিল্টার সরান';

  @override
  String get safetyFiltersLabel => 'ফিল্টার';

  @override
  String get safetyFilterAll => 'সব';

  @override
  String get safetyFilterDanger => 'বিপজ্জনক';

  @override
  String get safetyFilterCaution => 'সতর্কতা';

  @override
  String get safetyFilterInfo => 'তথ্য';

  @override
  String get safetyCategoryPermissions => 'অনুমতি';

  @override
  String get safetyCategoryAccessibility => 'অ্যাক্সেসিবিলিটি';

  @override
  String get safetyCategoryScreen => 'স্ক্রিন শেয়ার ও ওভারলে';

  @override
  String get safetyCategoryUnknownApps => 'অচেনা অ্যাপ';

  @override
  String get safetyCategoryPhone => 'ফোনের সেটিংস';

  @override
  String get safetyCategoryOther => 'অন্যান্য';

  @override
  String get safetySortLabel => 'সাজানো';

  @override
  String get safetySortSeverity => 'বিপদ আগে';

  @override
  String get safetySortName => 'নাম (অ-হ)';

  @override
  String get safetyCtaRevokePermission => 'অনুমতি বন্ধ করুন';

  @override
  String get safetyCtaDisableService => 'সার্ভিস বন্ধ করুন';

  @override
  String get safetyCtaStopNow => 'এখনই বন্ধ করুন';

  @override
  String get safetyCtaFixSetting => 'সেটিংস ঠিক করুন';

  @override
  String get safetyCtaAcknowledge => 'বুঝেছি';

  @override
  String get safetyAcknowledged => 'দেখা হয়েছে';

  @override
  String get safetyCtaReturnHint => 'ফিরে এলে আবার যাচাই হবে।';

  @override
  String get unknownNumber => 'নতুন নম্বর';

  @override
  String get payeeRecent => 'সাম্প্রতিক';

  @override
  String get payeeSavedLine => 'সেভ করা প্রাপক';

  @override
  String get payeeUnfamiliarLine =>
      'নতুন বা অচেনা প্রাপক। পাঠানোর আগে একবার ভাবুন।';

  @override
  String get reviewMoneySafe => 'টাকা পাঠানো হয়নি, আপনার কাছেই আছে।';

  @override
  String get reviewInReview => 'যাচাই চলছে।';

  @override
  String get reviewFinished => 'যাচাই শেষ, টাকা আপনার কাছেই।';

  @override
  String get fraudDeskStaffTag => 'স্টাফ ভিউ · ডেমো';

  @override
  String get fraudDeskTabWatchList => 'নজরে থাকা অ্যাকাউন্ট';

  @override
  String get fraudDeskTabCases => 'তদন্ত';

  @override
  String get fraudDeskWatchListEmpty => 'এখন কোনো অ্যাকাউন্ট নজরে নেই';

  @override
  String get fraudDeskWatchListEmptyBody =>
      'কোনো তদন্তে সন্দেহভাজন পাওয়া গেলে এখানে দেখা যাবে।';

  @override
  String get fraudDeskWatchListError => 'নজরের তালিকা আনা যায়নি';

  @override
  String get fraudDeskRetry => 'আবার চেষ্টা করুন';

  @override
  String get fraudDeskCasesEmpty => 'এই ফোন থেকে কোনো তদন্ত খোলা হয়নি';

  @override
  String get fraudDeskCasesEmptyBody =>
      'নজরে থাকা একটি অ্যাকাউন্ট বেছে তদন্ত শুরু করুন।';

  @override
  String get fraudDeskStartCase => 'তদন্ত শুরু করুন';

  @override
  String get fraudDeskPickTitle => 'কোন অ্যাকাউন্টের তদন্ত?';

  @override
  String get fraudDeskPickEmpty => 'নজরে থাকা সব অ্যাকাউন্টের তদন্ত খোলা আছে';

  @override
  String get fraudDeskCooldown => '৩০ মিনিটে একবার। পরে আবার চেষ্টা করুন।';

  @override
  String get fraudDeskAnalystApproved => 'বিশ্লেষক অনুমোদিত';

  @override
  String get fraudDeskNoCase => 'তদন্ত খোলা হয়নি';

  @override
  String get fraudDeskRoleL1 => 'প্রথম স্তর';

  @override
  String get fraudDeskRoleL2 => 'দ্বিতীয় স্তর';

  @override
  String get fraudDeskRoleController => 'নিয়ন্ত্রক';

  @override
  String get fraudDeskRoleCashout => 'ক্যাশ-আউট এজেন্ট';

  @override
  String get fraudDeskRoleVictim => 'ভুক্তভোগী';

  @override
  String get fraudDeskRoleOther => 'অন্যান্য';

  @override
  String get fraudDeskStatusSuspected => 'সন্দেহভাজন';

  @override
  String get fraudDeskStatusConfirmed => 'নিশ্চিত';

  @override
  String get fraudDeskStatusCleared => 'সন্দেহমুক্ত';

  @override
  String get fraudDeskStatusUnknown => 'অজানা';

  @override
  String fraudDeskOpenedAt(String time) {
    return 'খোলা: $time';
  }

  @override
  String get fraudDeskStarted => 'তদন্ত শুরু হয়েছে';

  @override
  String get fraudDeskStartFailed => 'তদন্ত শুরু করা যায়নি।';

  @override
  String fraudDeskAccount(String id) {
    return 'অ্যাকাউন্ট $id';
  }

  @override
  String get czCaseTitle => 'তদন্ত';

  @override
  String get czStatusQueued => 'সারিতে';

  @override
  String get czStatusRunning => 'চলছে';

  @override
  String get czStatusDone => 'শেষ';

  @override
  String get czStatusFailed => 'ব্যর্থ';

  @override
  String get czStatusUnknown => 'অজানা';

  @override
  String czRecommendation(String action) {
    return 'সুপারিশ: $action';
  }

  @override
  String get czActionFreeze => 'অ্যাকাউন্ট আটকানো';

  @override
  String get czActionEdd => 'বাড়তি যাচাই';

  @override
  String get czActionMonitor => 'নজরে রাখা';

  @override
  String get czActionClose => 'ব্যবস্থা নেই';

  @override
  String get czActionPending => 'অপেক্ষায়';

  @override
  String get czActionReviewer => 'পর্যালোচকের কাছে';

  @override
  String get czPendingApproval => 'এজেন্টের সুপারিশ, বিশ্লেষকের অনুমোদন বাকি';

  @override
  String czModelScore(String percent) {
    return 'মডেল স্কোর $percent%';
  }

  @override
  String czCounts(String evidence, String ring) {
    return 'প্রমাণ $evidence · রিং $ring';
  }

  @override
  String get czSummary => 'সারাংশ';

  @override
  String get czShowOtherLanguage => 'English';

  @override
  String get czEvidence => 'প্রমাণ';

  @override
  String get czRing => 'রিং';

  @override
  String get czFailed => 'তদন্ত ব্যর্থ হয়েছে';

  @override
  String get czReviewerLine => 'একজন ঝুঁকি পর্যালোচক বিষয়টি হাতে দেখবেন।';

  @override
  String get czStubFallback => 'স্ক্রিপ্টেড উত্তর (তদন্তকারী ব্যস্ত)';

  @override
  String get czStale => 'তদন্তটি আর পাওয়া যাচ্ছে না';

  @override
  String get czRunningLine => 'তদন্ত চলছে। সাধারণত এক মিনিটের মতো লাগে।';

  @override
  String get czRefreshFailed => 'এখন হালনাগাদ করা যায়নি, আবার চেষ্টা হবে।';

  @override
  String czModelVersion(String version) {
    return 'মডেল: $version';
  }

  @override
  String get czShowAppLanguage => 'বাংলা';

  @override
  String get behaviourModeSection => 'আচরণ';

  @override
  String get behaviourModeLabel => 'আচরণ সংকেত';

  @override
  String get behaviourModeLive => 'লাইভ';

  @override
  String get behaviourModeOff => 'বন্ধ';

  @override
  String get behaviourModeStranger => 'অন্য কেউ';

  @override
  String get behaviourModeOffNote => 'আচরণ সংকেত বন্ধ।';

  @override
  String get behaviourModeStrangerNote => 'সিমুলেটেড: অন্য কারও হাতের ধরন।';

  @override
  String get enrolToggle => 'নথিভুক্ত করা হচ্ছে';

  @override
  String get enrolHint =>
      'ডেমো: চালু থাকলে প্রতিটি পিনের আচরণ এই ফোনে জমা হয়।';

  @override
  String enrolCount(String count) {
    return 'নথিভুক্ত সেশন: $count';
  }

  @override
  String get enrolExport => 'ফাইলে লিখুন';

  @override
  String enrolExported(String path) {
    return 'ফাইলে লেখা হয়েছে: $path';
  }

  @override
  String get enrolExportFailed => 'ফাইলে লেখা যায়নি। আবার চেষ্টা করুন।';

  @override
  String get enrolClear => 'মুছুন';

  @override
  String get enrolCleared => 'নথিভুক্ত সেশন মুছে ফেলা হয়েছে।';

  @override
  String get stepUpConfirmTitle => 'একবার নিশ্চিত করুন';

  @override
  String get stepUpIsThisYou => 'এটা আপনিই?';

  @override
  String get actionKeepMoney => 'টাকা আমার কাছেই থাকুক';

  @override
  String get stepUpBiometricButton => 'হ্যাঁ, আঙুলের ছাপ দিয়ে নিশ্চিত করুন';

  @override
  String get stepUpBiometricReason => 'টাকা পাঠাতে আপনার আঙুলের ছাপ দিন।';

  @override
  String get stepUpAskTrusted => 'আপনজনের মত নিন';

  @override
  String get stepUpCancel => 'বাতিল';

  @override
  String get stepUpFailed => 'যাচাই হয়নি। আপনজনের মত নিন।';

  @override
  String get stepUpExhausted => 'তিনবার যাচাই হয়নি। এখন আপনজনের মত নিন।';

  @override
  String get stepUpReleasedTitle => 'ফোনে যাচাই করে পাঠানো হয়েছে';

  @override
  String get stepUpReleasedDemoNote =>
      'ডেমো: সার্ভারে লেনদেনটি আটকে রাখা হিসেবে লেখা আছে।';

  @override
  String get stepUpHistorySubtitle => 'ফোনে যাচাই করে পাঠানো';

  @override
  String get storySection => 'গল্প';

  @override
  String get storySuspectPayee => 'প্রাপক সন্দেহভাজন';

  @override
  String get storySuspectPayeeNote =>
      'ডেমো: এই গল্পে সার্ভার যা দেখবে: পরিষ্কার ফোন, আচরণ সংকেত বন্ধ, আর সন্দেহভাজন প্রাপক।';

  @override
  String get storyStranger => 'অন্য কেউ ফোন চালাচ্ছে';

  @override
  String get storyStrangerNote =>
      'ডেমো: এই গল্পে সার্ভার যা দেখবে: মালিকের সাথে না মেলা হাতের ধরন, তাই লেনদেন আটকে থাকবে।';

  @override
  String get storyInvestigation => 'তদন্ত দেখুন';

  @override
  String get storyInvestigationNote =>
      'ডেমো: এই গল্পে সার্ভার যা দেখবে: নজরে থাকা অ্যাকাউন্টের তালিকা আর তদন্ত।';

  @override
  String get behaviourModeTapPattern => 'ট্যাপের ধরন বদলে গেছে';

  @override
  String get behaviourModeShaking => 'হাত কাঁপছে, ফোন অন্যভাবে ধরা';

  @override
  String get behaviourModeCoached => 'কেউ বলে দিচ্ছে: ধীরে, থেমে থেমে টাইপ';

  @override
  String get behaviourModeTapPatternNote => 'সিমুলেটেড: ট্যাপের ধরন বদলানো।';

  @override
  String get behaviourModeShakingNote =>
      'সিমুলেটেড: কাঁপা হাত, অন্যভাবে ধরা ফোন।';

  @override
  String get behaviourModeCoachedNote =>
      'সিমুলেটেড: কেউ বলে দিচ্ছে, ধীরে টাইপ।';

  @override
  String get storyTapPattern => 'ট্যাপের ধরন বদলে গেছে';

  @override
  String get storyTapPatternNote =>
      'ডেমো: এই গল্পে সার্ভার যা দেখবে: ট্যাপ যেখানে পড়ছে আর কতটা জোরে, তা মালিকের সাথে মেলে না; বাকি সব আগের মতো। সার্ভারের উত্তর: আচরণ মালিকের সাথে মেলেনি, তাই লেনদেন আটকে থাকবে। রেকর্ডে \"সিমুলেটেড\" লেখা থাকবে।';

  @override
  String get storyShaking => 'হাত কাঁপছে';

  @override
  String get storyShakingNote =>
      'ডেমো: এই গল্পে সার্ভার যা দেখবে: ফোন কতটা নড়ছে আর কীভাবে ধরা, তা মালিকের সাথে মেলে না; বাকি সব আগের মতো। সার্ভারের উত্তর: আচরণ মালিকের সাথে মেলেনি, তাই লেনদেন আটকে থাকবে। রেকর্ডে \"সিমুলেটেড\" লেখা থাকবে।';

  @override
  String get storyCoached => 'কেউ বলে দিচ্ছে';

  @override
  String get storyCoachedNote =>
      'ডেমো: এই গল্পে সার্ভার যা দেখবে: মালিকের নিজের হাত, কিন্তু পিন টাইপের গতি আর বিরতি বদলে গেছে: ধীরে, থেমে থেমে, ভুল মুছে আবার। কলও চালু করা হলো, কারণ কল চলার সময়েই সার্ভার এতে লেনদেন আটকায়। আজকের ডেমোতে সার্ভারের উত্তর: আচরণ মালিকের সাথে মেলেনি, আর কেউ বলে দিচ্ছে বলে সন্দেহ; মালিকের আচরণ এই ফোন থেকে এখনও শেখানো হয়নি, তাই দুটোই আসে। রেকর্ডে \"সিমুলেটেড\" লেখা থাকবে।';

  @override
  String get voiceSourceBundled => 'অ্যাপে রাখা অডিও';

  @override
  String get voiceSourceServerClip => 'সার্ভারে আগে তৈরি অডিও';

  @override
  String get voiceSourceServerLive => 'সার্ভারের লাইভ অডিও';

  @override
  String get voiceSourceGemini => 'জেমিনাই ভয়েস (ভার্টেক্স এআই)';

  @override
  String get voiceSourceOnDevice => 'ফোনের নিজের ভয়েস';

  @override
  String get voiceSourceNone => 'কোনো অডিও বাজেনি';

  @override
  String voiceSourceNote(String source) {
    return 'ডেমো: শেষ অডিও এসেছে: $source';
  }

  @override
  String get demoPreviewGeminiVoice => 'জেমিনি কণ্ঠে শুনুন';

  @override
  String get overlayBlockedLabel => 'আটকানো হয়েছে';

  @override
  String get simulatedTagOff => 'সিমুলেটেড: আচরণ সংকেত বন্ধ';

  @override
  String get simulatedTagStranger => 'সিমুলেটেড: অন্য কারও হাতের ধরন';

  @override
  String get simulatedTagTapPattern => 'সিমুলেটেড: ট্যাপের ধরন বদলানো';

  @override
  String get simulatedTagShaking => 'সিমুলেটেড: কাঁপা হাত';

  @override
  String get simulatedTagCoached => 'সিমুলেটেড: কেউ বলে দিচ্ছে';

  @override
  String pendingSummaryTitle(int count, String countText) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countTextটি লেনদেন আটকে আছে',
    );
    return '$_temp0';
  }

  @override
  String get pendingSummarySee => 'দেখুন ›';

  @override
  String get historyFilterHeld => 'আটকে আছে';

  @override
  String get fraudDeskFactPrefix => 'তথ্য:';

  @override
  String get czNoEvidence => 'প্রমাণ পাওয়া যায়নি';

  @override
  String czCountsNoEvidence(String ring) {
    return 'প্রমাণ পাওয়া যায়নি · রিং $ring';
  }

  @override
  String get czCitedTxns => 'সারাংশে উল্লেখিত লেনদেন';

  @override
  String get txnTypeReceived => 'টাকা এসেছে';

  @override
  String get behaviourModeLiveHelp => 'এই ফোনের আসল স্পর্শ যায়';

  @override
  String get behaviourModeOffHelp => 'আচরণ সংকেত বন্ধ: সার্ভার আচরণ দেখবে না';

  @override
  String get behaviourModeStrangerHelp =>
      'সিমুলেটেড: অন্য কারও হাতের ধরন; সার্ভার আটকে রাখবে';

  @override
  String get demoPreviewPlaying => 'চলছে…';

  @override
  String get demoPreviewStop => 'থামান';

  @override
  String get approveNotConfirmedLine => 'আপনজন নিশ্চিত করেননি';

  @override
  String get czStatusDegraded => 'শেষ, সূত্র যাচাই হয়নি';

  @override
  String get fnaTalk => 'কথা বলুন';

  @override
  String get fnaHearIt => 'শুনুন';

  @override
  String get fnaHearStop => 'থামান';

  @override
  String get fnaStateConnecting => 'সংযোগ হচ্ছে…';

  @override
  String get fnaStateListening => 'এফএনএ শুনছে';

  @override
  String get fnaStateThinking => 'এফএনএ ভাবছে…';

  @override
  String get fnaStateSpeaking => 'এফএনএ বলছে';

  @override
  String get fnaStatePaused => 'বিরতি চলছে · কথা বলতে চাপুন';

  @override
  String get fnaPinStrip => 'পিন বা কোড মুখে বলবেন না, এফএনএ-কেও না।';

  @override
  String get fnaNumberHidden =>
      'একটি নম্বর লুকিয়ে রাখা হয়েছে। কোড কাউকে বলবেন না।';

  @override
  String get fnaMicRationale =>
      'এফএনএ-র সাথে কথা বলতে মাইক্রোফোন লাগবে। এফএনএ শুধু এই স্ক্রিন খোলা থাকলে শোনে। আপনার ফোনকল কখনো শোনে না।';

  @override
  String get fnaMicTurnOn => 'মাইক্রোফোন চালু করুন';

  @override
  String get fnaOpenSettings => 'সেটিংস খুলুন';

  @override
  String get fnaTypeInstead => 'লিখে বলুন';

  @override
  String get fnaStop => 'থামান';

  @override
  String get fnaPause => 'বিরতি';

  @override
  String get fnaResume => 'আবার কথা বলুন';

  @override
  String get fnaEnd => 'শেষ করুন';

  @override
  String get fnaVoiceDown =>
      'এখন কথা বলা যাচ্ছে না। লিখে জিজ্ঞাসা করুন, এফএনএ উত্তর পড়ে শোনাবে।';

  @override
  String get fnaOffline =>
      'ইন্টারনেট নেই। নিচের প্রশ্ন বেছে নিন। উত্তর আপনার ফোনেই আছে।';

  @override
  String fnaCallCardTitle(String time) {
    return 'সন্দেহজনক কল · $time';
  }

  @override
  String get fnaCallAskedFor => 'ফোনে চেয়েছিল';

  @override
  String get fnaCallTheySaid => 'ফোনে বলেছিল';

  @override
  String get fnaCallDoNow => 'এখন কী করবেন';

  @override
  String get fnaCallNextTime => 'পরের বার যা করবেন';

  @override
  String get fnaCallHelpline => 'হেল্পলাইনে কল করুন';

  @override
  String get fnaCallDoHangUp =>
      'আবার ফোন করলে কেটে দিন। টাকা পাঠাবেন না, কোনো কোড বলবেন না।';

  @override
  String get fnaCallDoCareful => 'সাবধান থাকুন, তাড়াহুড়ো করবেন না।';

  @override
  String get fnaSecretCard => 'কার্ডের নম্বর';

  @override
  String get fnaNoCallYet =>
      'এখনো কোনো সন্দেহজনক কল ধরা পড়েনি। কেউ কোড চাইলে, কলার কী বলছে এফএনএ-কে বলুন।';

  @override
  String get fnaQuickSummary => 'সন্দেহজনক কলের কথা';

  @override
  String get fnaVoiceControls => 'ভয়েস নিয়ন্ত্রণ';

  @override
  String get fnaSecretSpoken =>
      'আপনার কথায় একটি কোডের মতো নম্বর ছিল, সেটা লুকিয়ে রাখা হয়েছে। কোড বা পিন কাউকে বলবেন না, এফএনএ-কেও না।';

  @override
  String fnaHearItLabel(String text) {
    return 'শুনুন: $text';
  }

  @override
  String fnaHearStopLabel(String text) {
    return 'পড়া থামান: $text';
  }

  @override
  String get fnaShowAll => 'পুরোটা দেখুন';

  @override
  String get fnaShowLess => 'কম দেখুন';
}
