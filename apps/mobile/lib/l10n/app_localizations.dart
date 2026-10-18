import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_bn.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('bn'),
    Locale('en'),
  ];

  /// App name shown on the login screen and app bar
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট'**
  String get appName;

  /// No description provided for @tagline.
  ///
  /// In bn, this message translates to:
  /// **'আপনার টাকার নিরাপদ ঘর'**
  String get tagline;

  /// No description provided for @login.
  ///
  /// In bn, this message translates to:
  /// **'লগইন'**
  String get login;

  /// No description provided for @demoLogin.
  ///
  /// In bn, this message translates to:
  /// **'ডেমো লগইন'**
  String get demoLogin;

  /// No description provided for @demoLoginHint.
  ///
  /// In bn, this message translates to:
  /// **'এটি ডেমো লগইন। আপনি একজন নমুনা গ্রাহক হিসেবে ঢুকবেন।'**
  String get demoLoginHint;

  /// No description provided for @home.
  ///
  /// In bn, this message translates to:
  /// **'হোম'**
  String get home;

  /// No description provided for @sendMoney.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠান'**
  String get sendMoney;

  /// Short name of the guide, FinNest Assistant, for buttons, chips and the bottom-bar square button
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ'**
  String get apa;

  /// No description provided for @askApa.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-কে জিজ্ঞাসা করুন'**
  String get askApa;

  /// No description provided for @fraudDesk.
  ///
  /// In bn, this message translates to:
  /// **'ফ্রড ডেস্ক'**
  String get fraudDesk;

  /// No description provided for @demoMode.
  ///
  /// In bn, this message translates to:
  /// **'ডেমো মোড'**
  String get demoMode;

  /// No description provided for @recordingMode.
  ///
  /// In bn, this message translates to:
  /// **'রেকর্ডিং'**
  String get recordingMode;

  /// No description provided for @retry.
  ///
  /// In bn, this message translates to:
  /// **'আবার চেষ্টা করুন'**
  String get retry;

  /// No description provided for @cancel.
  ///
  /// In bn, this message translates to:
  /// **'বাতিল করুন'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In bn, this message translates to:
  /// **'ঠিক আছে'**
  String get ok;

  /// No description provided for @next.
  ///
  /// In bn, this message translates to:
  /// **'পরের ধাপ'**
  String get next;

  /// No description provided for @balance.
  ///
  /// In bn, this message translates to:
  /// **'ব্যালেন্স'**
  String get balance;

  /// No description provided for @recentTransactions.
  ///
  /// In bn, this message translates to:
  /// **'সাম্প্রতিক লেনদেন'**
  String get recentTransactions;

  /// No description provided for @safety.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিরাপত্তা'**
  String get safety;

  /// No description provided for @demoPanel.
  ///
  /// In bn, this message translates to:
  /// **'ডেমো প্যানেল'**
  String get demoPanel;

  /// No description provided for @placeholderScreen.
  ///
  /// In bn, this message translates to:
  /// **'{name} স্ক্রিন শিগগিরই আসছে'**
  String placeholderScreen(String name);

  /// No description provided for @safetyChecking.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই হচ্ছে…'**
  String get safetyChecking;

  /// No description provided for @safetyCheckFailed.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই করা যায়নি। আবার চেষ্টা করতে চাপুন।'**
  String get safetyCheckFailed;

  /// No description provided for @safetySimulatedTag.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড'**
  String get safetySimulatedTag;

  /// No description provided for @safetyUninstall.
  ///
  /// In bn, this message translates to:
  /// **'আনইনস্টল'**
  String get safetyUninstall;

  /// No description provided for @safetyNoFindings.
  ///
  /// In bn, this message translates to:
  /// **'কোনো ঝুঁকিপূর্ণ অ্যাপ পাওয়া যায়নি'**
  String get safetyNoFindings;

  /// No description provided for @safetyBlockedTitle.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন বাতিল করা হয়েছে'**
  String get safetyBlockedTitle;

  /// No description provided for @safetyFindingsTitle.
  ///
  /// In bn, this message translates to:
  /// **'যা পাওয়া গেছে'**
  String get safetyFindingsTitle;

  /// No description provided for @safetyVerdictSafe.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপদ'**
  String get safetyVerdictSafe;

  /// No description provided for @safetyVerdictCaution.
  ///
  /// In bn, this message translates to:
  /// **'সাবধান'**
  String get safetyVerdictCaution;

  /// No description provided for @safetyVerdictBlock.
  ///
  /// In bn, this message translates to:
  /// **'ঝুঁকিপূর্ণ'**
  String get safetyVerdictBlock;

  /// No description provided for @safetySeverityLow.
  ///
  /// In bn, this message translates to:
  /// **'কম'**
  String get safetySeverityLow;

  /// No description provided for @safetySeverityMedium.
  ///
  /// In bn, this message translates to:
  /// **'মাঝারি'**
  String get safetySeverityMedium;

  /// No description provided for @safetySeverityHigh.
  ///
  /// In bn, this message translates to:
  /// **'বেশি'**
  String get safetySeverityHigh;

  /// No description provided for @safetySeverityCritical.
  ///
  /// In bn, this message translates to:
  /// **'গুরুতর'**
  String get safetySeverityCritical;

  /// No description provided for @safetyOpenDetails.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিরাপত্তা দেখুন'**
  String get safetyOpenDetails;

  /// No description provided for @approveTitle.
  ///
  /// In bn, this message translates to:
  /// **'অনুমোদনের অনুরোধ'**
  String get approveTitle;

  /// No description provided for @approveButton.
  ///
  /// In bn, this message translates to:
  /// **'অনুমোদন করুন'**
  String get approveButton;

  /// No description provided for @declineButton.
  ///
  /// In bn, this message translates to:
  /// **'প্রত্যাখ্যান করুন'**
  String get declineButton;

  /// No description provided for @approvedLine.
  ///
  /// In bn, this message translates to:
  /// **'অনুমোদিত। টাকা পাঠানো হয়েছে।'**
  String get approvedLine;

  /// No description provided for @declinedLine.
  ///
  /// In bn, this message translates to:
  /// **'প্রত্যাখ্যাত। লেনদেন আটকে থাকবে।'**
  String get declinedLine;

  /// No description provided for @expiredLine.
  ///
  /// In bn, this message translates to:
  /// **'সময় শেষ'**
  String get expiredLine;

  /// Countdown on the approve screen; time is mm:ss in Bangla digits
  ///
  /// In bn, this message translates to:
  /// **'সময় বাকি {time}'**
  String timeLeft(String time);

  /// No description provided for @approveRetry.
  ///
  /// In bn, this message translates to:
  /// **'আবার চেষ্টা করুন'**
  String get approveRetry;

  /// No description provided for @approveFailed.
  ///
  /// In bn, this message translates to:
  /// **'এখন পাঠানো যাচ্ছে না'**
  String get approveFailed;

  /// No description provided for @approveSending.
  ///
  /// In bn, this message translates to:
  /// **'পাঠানো হচ্ছে…'**
  String get approveSending;

  /// No description provided for @approveLoading.
  ///
  /// In bn, this message translates to:
  /// **'অনুরোধ খোঁজা হচ্ছে…'**
  String get approveLoading;

  /// No description provided for @incomingRequestTitle.
  ///
  /// In bn, this message translates to:
  /// **'নতুন অনুমোদনের অনুরোধ'**
  String get incomingRequestTitle;

  /// No description provided for @openRequest.
  ///
  /// In bn, this message translates to:
  /// **'অনুরোধ দেখুন'**
  String get openRequest;

  /// Top-left chrome button that closes the intervention overlay; never clears the hold
  ///
  /// In bn, this message translates to:
  /// **'পরে দেখব'**
  String get interventionDismiss;

  /// Toggle that reveals the English version of Apa's line; the Bangla label stays in English so an English reader finds it
  ///
  /// In bn, this message translates to:
  /// **'English'**
  String get interventionEnglish;

  /// Shown while /v1/intervene has not answered yet
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ বলছে…'**
  String get interventionWaiting;

  /// Overlay title keyed by decision=hold
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন আটকে রাখা হয়েছে'**
  String get interventionHeldTitle;

  /// Banner/overlay title keyed by decision=delay
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন দেরি হবে'**
  String get interventionDelayTitle;

  /// Overlay title keyed by decision=block
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন বাতিল করা হয়েছে'**
  String get interventionBlockedTitle;

  /// Banner/overlay title keyed by decision=step_up
  ///
  /// In bn, this message translates to:
  /// **'আবার যাচাই দরকার'**
  String get interventionStepUpTitle;

  /// Monogram on the FinNest Assistant avatar tile (Latin in both languages, like the logo)
  ///
  /// In bn, this message translates to:
  /// **'FNA'**
  String get apaInitial;

  /// Button label for actions[].type=hold_transaction
  ///
  /// In bn, this message translates to:
  /// **'{minutes} মিনিট আটকে রাখুন'**
  String actionHoldTransaction(String minutes);

  /// Button label for actions[].type=freeze_pin_reset
  ///
  /// In bn, this message translates to:
  /// **'পিন বদল {minutes} মিনিট বন্ধ রাখুন'**
  String actionFreezePinReset(String minutes);

  /// Button label for actions[].type=delay_new_payee
  ///
  /// In bn, this message translates to:
  /// **'{minutes} মিনিট পরে পাঠান'**
  String actionDelayNewPayee(String minutes);

  /// Button label for actions[].type=trusted_contact_check
  ///
  /// In bn, this message translates to:
  /// **'আপনজনের মত নিন ({expiresInMinutes} মিনিট)'**
  String actionTrustedContact(String expiresInMinutes);

  /// Button label for actions[].type=step_up_verification
  ///
  /// In bn, this message translates to:
  /// **'আবার যাচাই করুন'**
  String get actionStepUp;

  /// Button label for actions[].type=block_transaction
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন বাতিল করুন'**
  String get actionBlock;

  /// Generic label for an actions[].type the client has never seen; the raw type stays in the log, never on screen
  ///
  /// In bn, this message translates to:
  /// **'অন্য পদক্ষেপ'**
  String get actionUnknown;

  /// No description provided for @apaSheetTitle.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট সহকারী'**
  String get apaSheetTitle;

  /// No description provided for @apaHoldToTalk.
  ///
  /// In bn, this message translates to:
  /// **'চেপে ধরে বলুন'**
  String get apaHoldToTalk;

  /// No description provided for @apaListening.
  ///
  /// In bn, this message translates to:
  /// **'শুনছি…'**
  String get apaListening;

  /// No description provided for @apaPathLive.
  ///
  /// In bn, this message translates to:
  /// **'লাইভ'**
  String get apaPathLive;

  /// No description provided for @apaTypeHint.
  ///
  /// In bn, this message translates to:
  /// **'এখানে লিখুন…'**
  String get apaTypeHint;

  /// No description provided for @apaSend.
  ///
  /// In bn, this message translates to:
  /// **'পাঠান'**
  String get apaSend;

  /// No description provided for @apaLiveUnavailable.
  ///
  /// In bn, this message translates to:
  /// **'লাইভ কথা এখন চালু নেই। লিখে জিজ্ঞাসা করুন।'**
  String get apaLiveUnavailable;

  /// No description provided for @apaMicDenied.
  ///
  /// In bn, this message translates to:
  /// **'মাইক্রোফোনের অনুমতি নেই। লিখে জিজ্ঞাসা করুন।'**
  String get apaMicDenied;

  /// No description provided for @apaTextFailed.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট সহকারীর সাথে এখন যোগাযোগ করা যাচ্ছে না। আবার চেষ্টা করুন।'**
  String get apaTextFailed;

  /// No description provided for @apaLiveFailed.
  ///
  /// In bn, this message translates to:
  /// **'লাইভ কথা বন্ধ হয়ে গেছে। লিখে জিজ্ঞাসা করুন।'**
  String get apaLiveFailed;

  /// Toggle that shows the English line under each Apa answer; the Bangla label stays in English so an English reader finds it
  ///
  /// In bn, this message translates to:
  /// **'English'**
  String get apaEnglishToggle;

  /// No description provided for @apaThinking.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ ভাবছে…'**
  String get apaThinking;

  /// No description provided for @apaEmptyTranscript.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট সহকারীকে যা খুশি জিজ্ঞাসা করুন'**
  String get apaEmptyTranscript;

  /// No description provided for @apaYou.
  ///
  /// In bn, this message translates to:
  /// **'আপনি'**
  String get apaYou;

  /// No description provided for @demoVideoPreset.
  ///
  /// In bn, this message translates to:
  /// **'ভিডিওর জন্য সাজান'**
  String get demoVideoPreset;

  /// No description provided for @demoReplayScam.
  ///
  /// In bn, this message translates to:
  /// **'প্রতারণার কলটি চালান'**
  String get demoReplayScam;

  /// No description provided for @demoResetCooldown.
  ///
  /// In bn, this message translates to:
  /// **'অপেক্ষার সময় মুছে দিন'**
  String get demoResetCooldown;

  /// No description provided for @demoResetAll.
  ///
  /// In bn, this message translates to:
  /// **'সব শুরুর মতো করুন'**
  String get demoResetAll;

  /// No description provided for @demoPreviewAudio.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-র অডিও শুনুন'**
  String get demoPreviewAudio;

  /// No description provided for @demoForcedVerdict.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপত্তার ফল ঠিক করে দিন'**
  String get demoForcedVerdict;

  /// No description provided for @demoPersona.
  ///
  /// In bn, this message translates to:
  /// **'গ্রাহক'**
  String get demoPersona;

  /// No description provided for @demoFlagSimSwap.
  ///
  /// In bn, this message translates to:
  /// **'সিম বদল'**
  String get demoFlagSimSwap;

  /// No description provided for @demoFlagCallActive.
  ///
  /// In bn, this message translates to:
  /// **'কল চলছে'**
  String get demoFlagCallActive;

  /// No description provided for @demoFlagScreenShare.
  ///
  /// In bn, this message translates to:
  /// **'স্ক্রিন শেয়ার'**
  String get demoFlagScreenShare;

  /// No description provided for @demoFlagCallerInContacts.
  ///
  /// In bn, this message translates to:
  /// **'কলার কন্ট্যাক্টে আছে'**
  String get demoFlagCallerInContacts;

  /// No description provided for @demoHealth.
  ///
  /// In bn, this message translates to:
  /// **'সার্ভার চালু আছে কি না দেখুন'**
  String get demoHealth;

  /// No description provided for @loginChoosePersona.
  ///
  /// In bn, this message translates to:
  /// **'কে লগইন করবেন?'**
  String get loginChoosePersona;

  /// No description provided for @passkeyUnavailable.
  ///
  /// In bn, this message translates to:
  /// **'পাসকি লগইন এখন চালু নেই'**
  String get passkeyUnavailable;

  /// No description provided for @passkeyPendingLine.
  ///
  /// In bn, this message translates to:
  /// **'পাসকি কাজ করেছে। এই ডেমোতে ডেমো লগইন ব্যবহার করুন।'**
  String get passkeyPendingLine;

  /// No description provided for @logout.
  ///
  /// In bn, this message translates to:
  /// **'লগ আউট'**
  String get logout;

  /// No description provided for @savedPayees.
  ///
  /// In bn, this message translates to:
  /// **'সেভ করা প্রাপক'**
  String get savedPayees;

  /// No description provided for @newNumber.
  ///
  /// In bn, this message translates to:
  /// **'নতুন নম্বর'**
  String get newNumber;

  /// No description provided for @amount.
  ///
  /// In bn, this message translates to:
  /// **'পরিমাণ'**
  String get amount;

  /// No description provided for @quickAmounts.
  ///
  /// In bn, this message translates to:
  /// **'দ্রুত পরিমাণ'**
  String get quickAmounts;

  /// No description provided for @backspace.
  ///
  /// In bn, this message translates to:
  /// **'মুছুন'**
  String get backspace;

  /// No description provided for @pinTitle.
  ///
  /// In bn, this message translates to:
  /// **'পিন দিন'**
  String get pinTitle;

  /// No description provided for @pinVerifying.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই হচ্ছে…'**
  String get pinVerifying;

  /// No description provided for @pinWrong.
  ///
  /// In bn, this message translates to:
  /// **'পিন ভুল হয়েছে। আবার দিন।'**
  String get pinWrong;

  /// 30 s pause after three wrong PINs; seconds in Bangla digits
  ///
  /// In bn, this message translates to:
  /// **'{seconds} সেকেন্ড পরে আবার চেষ্টা করুন'**
  String pinLocked(String seconds);

  /// No description provided for @pinObscured.
  ///
  /// In bn, this message translates to:
  /// **'অন্য একটি অ্যাপ স্ক্রিন ঢেকে রেখেছে। এক মুহূর্ত অপেক্ষা করুন।'**
  String get pinObscured;

  /// TalkBack label of the PIN dots
  ///
  /// In bn, this message translates to:
  /// **'{count} সংখ্যা দেওয়া হয়েছে'**
  String pinDigitsEntered(String count);

  /// No description provided for @stepUpTitle.
  ///
  /// In bn, this message translates to:
  /// **'স্ক্রিন শেয়ার বন্ধ করুন'**
  String get stepUpTitle;

  /// No description provided for @stepUpBody.
  ///
  /// In bn, this message translates to:
  /// **'স্ক্রিন শেয়ার চলা অবস্থায় টাকা পাঠানো নিরাপদ নয়। শেয়ার বন্ধ করে আবার পিন দিন।'**
  String get stepUpBody;

  /// No description provided for @stepUpRetry.
  ///
  /// In bn, this message translates to:
  /// **'আবার চেষ্টা করুন'**
  String get stepUpRetry;

  /// No description provided for @resultDone.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠানো হয়েছে'**
  String get resultDone;

  /// No description provided for @resultHeld.
  ///
  /// In bn, this message translates to:
  /// **'আপনার টাকা নিরাপদে আটকে আছে'**
  String get resultHeld;

  /// No description provided for @resultBlocked.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন বাতিল করা হয়েছে'**
  String get resultBlocked;

  /// No description provided for @resultUnavailable.
  ///
  /// In bn, this message translates to:
  /// **'এখন যাচাই করা যাচ্ছে না'**
  String get resultUnavailable;

  /// No description provided for @resultUnavailableBody.
  ///
  /// In bn, this message translates to:
  /// **'আপনার টাকা কোথাও যায়নি, অ্যাকাউন্টেই আছে। একটু পরে আবার চেষ্টা করুন।'**
  String get resultUnavailableBody;

  /// No description provided for @goHome.
  ///
  /// In bn, this message translates to:
  /// **'হোমে ফিরুন'**
  String get goHome;

  /// No description provided for @fraudDeskBody.
  ///
  /// In bn, this message translates to:
  /// **'ফ্রড ডেস্ক হলো ব্যাংকের তদন্ত দলের কনসোল। আটকে রাখা লেনদেন, কারণ ও সময়রেখা এখানে দেখা যায়। এটি ব্রাউজারে খুলবে।'**
  String get fraudDeskBody;

  /// No description provided for @openConsole.
  ///
  /// In bn, this message translates to:
  /// **'কনসোল খুলুন'**
  String get openConsole;

  /// No description provided for @openConsoleFailed.
  ///
  /// In bn, this message translates to:
  /// **'কনসোল খোলা যায়নি'**
  String get openConsoleFailed;

  /// No description provided for @txnTypeSendMoney.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠানো'**
  String get txnTypeSendMoney;

  /// No description provided for @txnTypeCashIn.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ ইন'**
  String get txnTypeCashIn;

  /// No description provided for @txnTypeCashOut.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ আউট'**
  String get txnTypeCashOut;

  /// No description provided for @txnTypeSalary.
  ///
  /// In bn, this message translates to:
  /// **'বেতন'**
  String get txnTypeSalary;

  /// No description provided for @txnTypeRecharge.
  ///
  /// In bn, this message translates to:
  /// **'রিচার্জ'**
  String get txnTypeRecharge;

  /// No description provided for @txnTypeOther.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন'**
  String get txnTypeOther;

  /// No description provided for @statusHeld.
  ///
  /// In bn, this message translates to:
  /// **'আটকে আছে'**
  String get statusHeld;

  /// No description provided for @statusBlocked.
  ///
  /// In bn, this message translates to:
  /// **'ঝুঁকিতে বাতিল'**
  String get statusBlocked;

  /// No description provided for @statusDone.
  ///
  /// In bn, this message translates to:
  /// **'সম্পন্ন'**
  String get statusDone;

  /// No description provided for @trustedRequestSent.
  ///
  /// In bn, this message translates to:
  /// **'আপনজনকে অনুরোধ পাঠানো হয়েছে। উত্তর এলে জানাব।'**
  String get trustedRequestSent;

  /// No description provided for @trustedRequestFailed.
  ///
  /// In bn, this message translates to:
  /// **'অনুরোধ পাঠানো যায়নি'**
  String get trustedRequestFailed;

  /// No description provided for @noRecentTransactions.
  ///
  /// In bn, this message translates to:
  /// **'এখনো কোনো লেনদেন নেই'**
  String get noRecentTransactions;

  /// No description provided for @safetyFromLastCheck.
  ///
  /// In bn, this message translates to:
  /// **'নতুন যাচাই করা যায়নি। আগের ফলাফল দেখানো হচ্ছে।'**
  String get safetyFromLastCheck;

  /// No description provided for @safetyDeviceSection.
  ///
  /// In bn, this message translates to:
  /// **'আপনার ফোন'**
  String get safetyDeviceSection;

  /// No description provided for @safetyUninstallLine.
  ///
  /// In bn, this message translates to:
  /// **'ঝুঁকিপূর্ণ অ্যাপ সরিয়ে আবার যাচাই করুন'**
  String get safetyUninstallLine;

  /// No description provided for @safetyFixPhoneLine.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের সেটিংস ঠিক করে আবার যাচাই করুন'**
  String get safetyFixPhoneLine;

  /// No description provided for @safetyReinstallLine.
  ///
  /// In bn, this message translates to:
  /// **'প্লে স্টোর থেকে ফিননেস্ট আবার ইনস্টল করুন'**
  String get safetyReinstallLine;

  /// No description provided for @safetyOpenPlay.
  ///
  /// In bn, this message translates to:
  /// **'প্লে স্টোরে যান'**
  String get safetyOpenPlay;

  /// No description provided for @safetyCallBankLine.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্টের হেল্পলাইনে কথা বলুন'**
  String get safetyCallBankLine;

  /// No description provided for @safetyCallBank.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্টে কল করুন'**
  String get safetyCallBank;

  /// No description provided for @safetyRecheck.
  ///
  /// In bn, this message translates to:
  /// **'আবার যাচাই করুন'**
  String get safetyRecheck;

  /// No description provided for @demoIntegrity.
  ///
  /// In bn, this message translates to:
  /// **'ফোন যাচাইয়ের ফল · ডেমো'**
  String get demoIntegrity;

  /// No description provided for @demoIntegrityClean.
  ///
  /// In bn, this message translates to:
  /// **'স্বাভাবিক'**
  String get demoIntegrityClean;

  /// No description provided for @demoIntegrityScreenControlled.
  ///
  /// In bn, this message translates to:
  /// **'স্ক্রিন অন্যের হাতে'**
  String get demoIntegrityScreenControlled;

  /// No description provided for @demoIntegrityModded.
  ///
  /// In bn, this message translates to:
  /// **'বদলানো অ্যাপ'**
  String get demoIntegrityModded;

  /// No description provided for @demoIntegrityEmulator.
  ///
  /// In bn, this message translates to:
  /// **'নকল ফোন (এমুলেটর)'**
  String get demoIntegrityEmulator;

  /// No description provided for @demoIntegrityUnbound.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই মেলেনি'**
  String get demoIntegrityUnbound;

  /// No description provided for @demoRerunSafety.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপত্তা যাচাই আবার চালান'**
  String get demoRerunSafety;

  /// Savings screen app bar
  ///
  /// In bn, this message translates to:
  /// **'সঞ্চয়'**
  String get financeSavingsTitle;

  /// Loans screen app bar
  ///
  /// In bn, this message translates to:
  /// **'ঋণ'**
  String get financeLoansTitle;

  /// Home tile that opens /loans
  ///
  /// In bn, this message translates to:
  /// **'ঋণ'**
  String get financeTileLoans;

  /// Home tile that opens /savings
  ///
  /// In bn, this message translates to:
  /// **'সঞ্চয়'**
  String get financeTileSavings;

  /// Savings empty state
  ///
  /// In bn, this message translates to:
  /// **'এখনো কোনো ডিপিএস নেই'**
  String get financeEmpty;

  /// Finance stream error line
  ///
  /// In bn, this message translates to:
  /// **'তথ্য আনা যায়নি'**
  String get financeLoadFailed;

  /// Snackbar when opening a DPS or applying for a loan fails
  ///
  /// In bn, this message translates to:
  /// **'হয়নি। আবার চেষ্টা করুন।'**
  String get financeActionFailed;

  /// Savings primary button and sheet title
  ///
  /// In bn, this message translates to:
  /// **'নতুন ডিপিএস খুলুন'**
  String get dpsOpenNew;

  /// No description provided for @dpsMonthly.
  ///
  /// In bn, this message translates to:
  /// **'মাসিক জমা'**
  String get dpsMonthly;

  /// No description provided for @dpsPaidSoFar.
  ///
  /// In bn, this message translates to:
  /// **'এ পর্যন্ত জমা'**
  String get dpsPaidSoFar;

  /// No description provided for @dpsMaturity.
  ///
  /// In bn, this message translates to:
  /// **'মেয়াদ শেষে পাবেন'**
  String get dpsMaturity;

  /// Tag on every DPS card; rate is in Bangla digits
  ///
  /// In bn, this message translates to:
  /// **'ডেমো হার {rate}%'**
  String dpsDemoRate(String rate);

  /// No description provided for @dpsTenureYears.
  ///
  /// In bn, this message translates to:
  /// **'{years} বছর'**
  String dpsTenureYears(int years);

  /// Progress caption under the bar; Bangla digits
  ///
  /// In bn, this message translates to:
  /// **'{paid}/{total} কিস্তি'**
  String dpsInstalments(String paid, String total);

  /// No description provided for @dpsChooseAmount.
  ///
  /// In bn, this message translates to:
  /// **'মাসে কত জমাবেন?'**
  String get dpsChooseAmount;

  /// No description provided for @dpsChooseTenure.
  ///
  /// In bn, this message translates to:
  /// **'কত বছরের জন্য?'**
  String get dpsChooseTenure;

  /// No description provided for @dpsFirstInstalment.
  ///
  /// In bn, this message translates to:
  /// **'আজই প্রথম কিস্তি {amount} কেটে নেওয়া হবে'**
  String dpsFirstInstalment(String amount);

  /// Confirm button in the open-DPS sheet
  ///
  /// In bn, this message translates to:
  /// **'ডিপিএস খুলুন'**
  String get dpsConfirm;

  /// Snackbar after a plan is opened
  ///
  /// In bn, this message translates to:
  /// **'ডিপিএস খোলা হয়েছে'**
  String get dpsOpened;

  /// Shown under the limit when the seeded income is above zero
  ///
  /// In bn, this message translates to:
  /// **'মাসিক আয় {amount} অনুসারে'**
  String loanIncomeLine(String amount);

  /// No description provided for @loanProducts.
  ///
  /// In bn, this message translates to:
  /// **'ঋণের ধরন'**
  String get loanProducts;

  /// No description provided for @loanApply.
  ///
  /// In bn, this message translates to:
  /// **'আবেদন করুন'**
  String get loanApply;

  /// Reason line under a disabled apply button
  ///
  /// In bn, this message translates to:
  /// **'আপনার সীমার বেশি'**
  String get loanOverLimit;

  /// Fixed product line on the loans screen (product copy, not intervention copy)
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট কখনো ঋণের জন্য ওটিপি (এসএমএসে আসা গোপন কোড) বা পিন চায় না'**
  String get loanNeverAsksOtp;

  /// No description provided for @loanStatusPending.
  ///
  /// In bn, this message translates to:
  /// **'অনুমোদনের অপেক্ষায়'**
  String get loanStatusPending;

  /// No description provided for @loanStatusApproved.
  ///
  /// In bn, this message translates to:
  /// **'অনুমোদিত'**
  String get loanStatusApproved;

  /// No description provided for @loanStatusRejected.
  ///
  /// In bn, this message translates to:
  /// **'প্রত্যাখ্যাত'**
  String get loanStatusRejected;

  /// No description provided for @loanTotalRepayable.
  ///
  /// In bn, this message translates to:
  /// **'মোট ফেরত'**
  String get loanTotalRepayable;

  /// No description provided for @loanTenureMonths.
  ///
  /// In bn, this message translates to:
  /// **'{months} মাস'**
  String loanTenureMonths(int months);

  /// Flat fee tag on a product card; pct in Bangla digits
  ///
  /// In bn, this message translates to:
  /// **'ডেমো ফি {pct}%'**
  String loanDemoFee(String pct);

  /// Snackbar after applying
  ///
  /// In bn, this message translates to:
  /// **'আবেদন জমা হয়েছে'**
  String get loanApplied;

  /// No description provided for @loanApplications.
  ///
  /// In bn, this message translates to:
  /// **'আপনার আবেদন'**
  String get loanApplications;

  /// No description provided for @trustedRequestSentLine.
  ///
  /// In bn, this message translates to:
  /// **'আপনজনকে অনুরোধ পাঠানো হয়েছে'**
  String get trustedRequestSentLine;

  /// No description provided for @loginFailed.
  ///
  /// In bn, this message translates to:
  /// **'লগইন হয়নি। আবার চেষ্টা করুন।'**
  String get loginFailed;

  /// No description provided for @pinCheckUnavailable.
  ///
  /// In bn, this message translates to:
  /// **'পিন এখন যাচাই করা যায়নি। আবার পিন দিন।'**
  String get pinCheckUnavailable;

  /// No description provided for @recentLoadFailed.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন আনা যায়নি'**
  String get recentLoadFailed;

  /// No description provided for @resultHeldBody.
  ///
  /// In bn, this message translates to:
  /// **'টাকা আপনার অ্যাকাউন্টেই আছে, কোথাও যায়নি। কী করবেন জানতে ফিননেস্ট সহকারীকে জিজ্ঞাসা করুন।'**
  String get resultHeldBody;

  /// No description provided for @demoDataOnline.
  ///
  /// In bn, this message translates to:
  /// **'অনলাইন ডেটা'**
  String get demoDataOnline;

  /// No description provided for @demoDataOffline.
  ///
  /// In bn, this message translates to:
  /// **'অফলাইন ডেটা'**
  String get demoDataOffline;

  /// Endonym on the language toggle; the same in every locale so a reader finds their own language
  ///
  /// In bn, this message translates to:
  /// **'বাংলা'**
  String get languageBangla;

  /// Endonym on the language toggle; the same in every locale so a reader finds their own language
  ///
  /// In bn, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// TalkBack label of the two-segment language toggle
  ///
  /// In bn, this message translates to:
  /// **'ভাষা বেছে নিন'**
  String get languageToggleLabel;

  /// Demo persona name on the login picker
  ///
  /// In bn, this message translates to:
  /// **'রিনা আক্তার'**
  String get loginPersonaRina;

  /// Demo persona name on the login picker
  ///
  /// In bn, this message translates to:
  /// **'রহিমা বেগম'**
  String get loginPersonaRahima;

  /// No description provided for @demoPersonaRina.
  ///
  /// In bn, this message translates to:
  /// **'রিনা'**
  String get demoPersonaRina;

  /// No description provided for @demoPersonaRahima.
  ///
  /// In bn, this message translates to:
  /// **'রহিমা'**
  String get demoPersonaRahima;

  /// Approve screen header when the payee has no name
  ///
  /// In bn, this message translates to:
  /// **'অনুরোধ · {amount}'**
  String approveHeaderAmount(String amount);

  /// Approve screen header when the request was made on another phone
  ///
  /// In bn, this message translates to:
  /// **'আপনজনের অনুরোধ'**
  String get approveHeaderUnknown;

  /// Finding or uninstall label when the app has no readable name
  ///
  /// In bn, this message translates to:
  /// **'নাম না জানা অ্যাপ'**
  String get safetyUnknownApp;

  /// Severity tag for a severity value the app does not know
  ///
  /// In bn, this message translates to:
  /// **'ঝুঁকি'**
  String get safetySeverityOther;

  /// Loan application row title when the product is unknown
  ///
  /// In bn, this message translates to:
  /// **'ঋণ'**
  String get loanGeneric;

  /// Demo panel: no forced safety verdict; the server decides
  ///
  /// In bn, this message translates to:
  /// **'স্বয়ংক্রিয়'**
  String get demoVerdictAuto;

  /// No description provided for @demoCloudStatus.
  ///
  /// In bn, this message translates to:
  /// **'ক্লাউড: {status}'**
  String demoCloudStatus(String status);

  /// No description provided for @demoCloudConfigured.
  ///
  /// In bn, this message translates to:
  /// **'সংযুক্ত'**
  String get demoCloudConfigured;

  /// No description provided for @demoCloudAbsent.
  ///
  /// In bn, this message translates to:
  /// **'চালু করা নেই'**
  String get demoCloudAbsent;

  /// No description provided for @demoCloudFailed.
  ///
  /// In bn, this message translates to:
  /// **'চালু হয়নি'**
  String get demoCloudFailed;

  /// No description provided for @demoScamScore.
  ///
  /// In bn, this message translates to:
  /// **'প্রতারণার স্কোর {score}'**
  String demoScamScore(String score);

  /// One line of the scam replay log; the scam type follows as a muted wire suffix
  ///
  /// In bn, this message translates to:
  /// **'{n}. স্কোর {score} · তাড়া: {urgency}'**
  String demoReplayTurn(String n, String score, String urgency);

  /// No description provided for @demoUrgencyNone.
  ///
  /// In bn, this message translates to:
  /// **'নেই'**
  String get demoUrgencyNone;

  /// No description provided for @demoActionFailed.
  ///
  /// In bn, this message translates to:
  /// **'হয়নি। আবার চেষ্টা করুন।'**
  String get demoActionFailed;

  /// Overlay toggle shown when the app is in English: reveals the server's Bangla line (script_bn) under the English one
  ///
  /// In bn, this message translates to:
  /// **'বাংলা দেখুন'**
  String get interventionShowBangla;

  /// No description provided for @apaPathGemini.
  ///
  /// In bn, this message translates to:
  /// **'এআই'**
  String get apaPathGemini;

  /// No description provided for @apaPathGuide.
  ///
  /// In bn, this message translates to:
  /// **'অফলাইন গাইড'**
  String get apaPathGuide;

  /// No description provided for @apaQuickPhoneSafe.
  ///
  /// In bn, this message translates to:
  /// **'আমার ফোন কি নিরাপদ?'**
  String get apaQuickPhoneSafe;

  /// No description provided for @apaQuickWhyHeld.
  ///
  /// In bn, this message translates to:
  /// **'টাকা কেন আটকাল?'**
  String get apaQuickWhyHeld;

  /// No description provided for @apaQuickCodeAsked.
  ///
  /// In bn, this message translates to:
  /// **'কেউ ফোনে কোড চাইছে'**
  String get apaQuickCodeAsked;

  /// No description provided for @apaQuickRules.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপদ থাকার ৫ নিয়ম'**
  String get apaQuickRules;

  /// No description provided for @apaInsightBlockTitle.
  ///
  /// In bn, this message translates to:
  /// **'আপনার ফোনে ঝুঁকিপূর্ণ অ্যাপ আছে'**
  String get apaInsightBlockTitle;

  /// No description provided for @apaInsightUninstallApps.
  ///
  /// In bn, this message translates to:
  /// **'এগুলো আনইনস্টল করুন: {apps}'**
  String apaInsightUninstallApps(String apps);

  /// No description provided for @apaInsightCautionTitle.
  ///
  /// In bn, this message translates to:
  /// **'ফোনে সাবধান হওয়ার মতো কিছু আছে'**
  String get apaInsightCautionTitle;

  /// No description provided for @apaInsightScamTitle.
  ///
  /// In bn, this message translates to:
  /// **'কলে প্রতারণার লক্ষণ'**
  String get apaInsightScamTitle;

  /// No description provided for @apaInsightCallTransferTitle.
  ///
  /// In bn, this message translates to:
  /// **'কলে থাকা অবস্থায় টাকা পাঠাবেন না'**
  String get apaInsightCallTransferTitle;

  /// No description provided for @apaInsightCallTransferBody.
  ///
  /// In bn, this message translates to:
  /// **'আপনি এখন কলে আছেন আর একটি লেনদেন অপেক্ষায় আছে। আগে কল কেটে দিন।'**
  String get apaInsightCallTransferBody;

  /// No description provided for @apaInsightHeldTitle.
  ///
  /// In bn, this message translates to:
  /// **'আপনার একটি লেনদেন আটকে আছে'**
  String get apaInsightHeldTitle;

  /// No description provided for @apaInsightHeldNoReasons.
  ///
  /// In bn, this message translates to:
  /// **'বিস্তারিত জানতে এফএনএ-কে জিজ্ঞাসা করুন।'**
  String get apaInsightHeldNoReasons;

  /// No description provided for @apaInsightSimSwapTitle.
  ///
  /// In bn, this message translates to:
  /// **'আপনার সিম সম্প্রতি বদলেছে'**
  String get apaInsightSimSwapTitle;

  /// No description provided for @apaInsightSimSwapBody.
  ///
  /// In bn, this message translates to:
  /// **'২৪ ঘণ্টা টাকা পাঠানো আটকে থাকতে পারে। আপনি না বদলালে এখনই {helpline} নম্বরে কল করুন।'**
  String apaInsightSimSwapBody(String helpline);

  /// No description provided for @apaInsightScreenShareTitle.
  ///
  /// In bn, this message translates to:
  /// **'আপনার স্ক্রিন শেয়ার হচ্ছে'**
  String get apaInsightScreenShareTitle;

  /// No description provided for @apaInsightScreenShareBody.
  ///
  /// In bn, this message translates to:
  /// **'শেয়ার বন্ধ না করে টাকা পাঠাবেন না বা পিন দেবেন না।'**
  String get apaInsightScreenShareBody;

  /// No description provided for @apaInsightAllClearTitle.
  ///
  /// In bn, this message translates to:
  /// **'ফোন ও লেনদেন নিরাপদ দেখাচ্ছে'**
  String get apaInsightAllClearTitle;

  /// No description provided for @apaInsightAllClearBody.
  ///
  /// In bn, this message translates to:
  /// **'কেউ কোড চাইলে এফএনএ-কে জানান।'**
  String get apaInsightAllClearBody;

  /// No description provided for @apaInsightUncheckedTitle.
  ///
  /// In bn, this message translates to:
  /// **'ফোন এখনো যাচাই হয়নি'**
  String get apaInsightUncheckedTitle;

  /// No description provided for @apaInsightUncheckedBody.
  ///
  /// In bn, this message translates to:
  /// **'একবার ফোনের নিরাপত্তা দেখে নিন।'**
  String get apaInsightUncheckedBody;

  /// No description provided for @apaInsightLoading.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ দেখছে…'**
  String get apaInsightLoading;

  /// No description provided for @apaSeverityDanger.
  ///
  /// In bn, this message translates to:
  /// **'বিপদ'**
  String get apaSeverityDanger;

  /// No description provided for @apaSeverityCaution.
  ///
  /// In bn, this message translates to:
  /// **'সাবধান'**
  String get apaSeverityCaution;

  /// No description provided for @apaSeverityOk.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপদ'**
  String get apaSeverityOk;

  /// No description provided for @apaSeverityInfo.
  ///
  /// In bn, this message translates to:
  /// **'জেনে রাখুন'**
  String get apaSeverityInfo;

  /// No description provided for @apaActionOpenSafety.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিরাপত্তা দেখুন'**
  String get apaActionOpenSafety;

  /// No description provided for @apaActionScamCheck.
  ///
  /// In bn, this message translates to:
  /// **'কলারের কথা যাচাই করুন'**
  String get apaActionScamCheck;

  /// No description provided for @apaActionHeld.
  ///
  /// In bn, this message translates to:
  /// **'আটকে থাকা টাকা দেখুন'**
  String get apaActionHeld;

  /// No description provided for @apaActionRules.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপদ থাকার নিয়ম'**
  String get apaActionRules;

  /// No description provided for @apaActionAskApa.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-কে জিজ্ঞাসা করুন'**
  String get apaActionAskApa;

  /// No description provided for @apaActionCallHelpline.
  ///
  /// In bn, this message translates to:
  /// **'{helpline} নম্বরে কল করুন'**
  String apaActionCallHelpline(String helpline);

  /// No description provided for @apaAnswerPhoneUnchecked.
  ///
  /// In bn, this message translates to:
  /// **'ফোন এখনো যাচাই হয়নি। নিচের বোতাম চেপে যাচাই করুন।'**
  String get apaAnswerPhoneUnchecked;

  /// No description provided for @apaAnswerVerdictLine.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের অবস্থা: {verdict}'**
  String apaAnswerVerdictLine(String verdict);

  /// No description provided for @apaAnswerFindingsIntro.
  ///
  /// In bn, this message translates to:
  /// **'যা পাওয়া গেছে:'**
  String get apaAnswerFindingsIntro;

  /// No description provided for @apaAnswerNothingHeld.
  ///
  /// In bn, this message translates to:
  /// **'এখন আপনার কোনো টাকা আটকে নেই।'**
  String get apaAnswerNothingHeld;

  /// No description provided for @apaAnswerHoldsIntro.
  ///
  /// In bn, this message translates to:
  /// **'এসব কারণে টাকা আটকাতে পারে:'**
  String get apaAnswerHoldsIntro;

  /// No description provided for @apaAnswerHeldNext.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠানো হয়নি। আপনজনের অনুমোদন চাইতে পারেন, অথবা কারণটা মিটলে আবার চেষ্টা করুন।'**
  String get apaAnswerHeldNext;

  /// No description provided for @apaScamPrompt.
  ///
  /// In bn, this message translates to:
  /// **'কলার কী বলেছে, যতটা পারেন হুবহু লিখুন। আপনার কোড বা পিন এখানে লিখবেন না।'**
  String get apaScamPrompt;

  /// No description provided for @apaScamInputHint.
  ///
  /// In bn, this message translates to:
  /// **'কলার যা বলেছে…'**
  String get apaScamInputHint;

  /// No description provided for @apaScamCancel.
  ///
  /// In bn, this message translates to:
  /// **'বাতিল'**
  String get apaScamCancel;

  /// No description provided for @apaScamTypeFakeCare.
  ///
  /// In bn, this message translates to:
  /// **'ভুয়া কাস্টমার কেয়ার কল'**
  String get apaScamTypeFakeCare;

  /// No description provided for @apaScamTypePressure.
  ///
  /// In bn, this message translates to:
  /// **'চাপ দিয়ে তাড়াহুড়ো করানো'**
  String get apaScamTypePressure;

  /// No description provided for @apaScamTypeLottery.
  ///
  /// In bn, this message translates to:
  /// **'লটারি বা পুরস্কারের ফাঁদ'**
  String get apaScamTypeLottery;

  /// No description provided for @apaScamTypeOther.
  ///
  /// In bn, this message translates to:
  /// **'সন্দেহজনক কল'**
  String get apaScamTypeOther;

  /// No description provided for @apaScamTypeBenign.
  ///
  /// In bn, this message translates to:
  /// **'প্রতারণার স্পষ্ট লক্ষণ পাওয়া যায়নি'**
  String get apaScamTypeBenign;

  /// No description provided for @apaScamLineType.
  ///
  /// In bn, this message translates to:
  /// **'ধরন: {type}'**
  String apaScamLineType(String type);

  /// No description provided for @apaScamLineQuote.
  ///
  /// In bn, this message translates to:
  /// **'কলার বলেছে: “{quote}”'**
  String apaScamLineQuote(String quote);

  /// No description provided for @apaScamLineSecret.
  ///
  /// In bn, this message translates to:
  /// **'চাওয়া হয়েছে: {secret}'**
  String apaScamLineSecret(String secret);

  /// No description provided for @apaScamLineUrgency.
  ///
  /// In bn, this message translates to:
  /// **'চাপ: {level}'**
  String apaScamLineUrgency(String level);

  /// No description provided for @apaSecretOtp.
  ///
  /// In bn, this message translates to:
  /// **'ওটিপি বা কোড'**
  String get apaSecretOtp;

  /// No description provided for @apaSecretPin.
  ///
  /// In bn, this message translates to:
  /// **'পিন'**
  String get apaSecretPin;

  /// No description provided for @apaSecretPassword.
  ///
  /// In bn, this message translates to:
  /// **'পাসওয়ার্ড'**
  String get apaSecretPassword;

  /// No description provided for @apaSecretOther.
  ///
  /// In bn, this message translates to:
  /// **'গোপন তথ্য'**
  String get apaSecretOther;

  /// No description provided for @apaUrgencyHigh.
  ///
  /// In bn, this message translates to:
  /// **'অনেক বেশি'**
  String get apaUrgencyHigh;

  /// No description provided for @apaUrgencyMedium.
  ///
  /// In bn, this message translates to:
  /// **'মাঝারি'**
  String get apaUrgencyMedium;

  /// No description provided for @apaScamDoHangUp.
  ///
  /// In bn, this message translates to:
  /// **'কী করবেন: কল কেটে দিন, টাকা পাঠাবেন না, কোনো কোড বলবেন না।'**
  String get apaScamDoHangUp;

  /// No description provided for @apaScamDoCareful.
  ///
  /// In bn, this message translates to:
  /// **'কী করবেন: সাবধান থাকুন, তাড়াহুড়ো করবেন না।'**
  String get apaScamDoCareful;

  /// No description provided for @apaScamDoNothing.
  ///
  /// In bn, this message translates to:
  /// **'কী করবেন: এখন বিশেষ কিছু করার নেই। তবে কেউ কোড চাইলে কল কেটে দিন।'**
  String get apaScamDoNothing;

  /// No description provided for @apaScamHotline.
  ///
  /// In bn, this message translates to:
  /// **'কল কেটে দিন, তারপর নিজে {helpline} নম্বরে কল করুন।'**
  String apaScamHotline(String helpline);

  /// No description provided for @apaScamSaved.
  ///
  /// In bn, this message translates to:
  /// **'এই কথাটা আপনার পরের লেনদেনের নিরাপত্তা যাচাইয়ে যোগ হবে।'**
  String get apaScamSaved;

  /// No description provided for @apaScamFailed.
  ///
  /// In bn, this message translates to:
  /// **'এখন যাচাই করা গেল না। মনে রাখবেন: কেউ কোড বা পিন চাইলে সে প্রতারক।'**
  String get apaScamFailed;

  /// No description provided for @apaSecretRedacted.
  ///
  /// In bn, this message translates to:
  /// **'আপনার লেখায় একটি কোডের মতো নম্বর ছিল, সেটা লুকিয়ে রাখা হয়েছে। কোড বা পিন কাউকে বলবেন না, এফএনএ-কেও না।'**
  String get apaSecretRedacted;

  /// No description provided for @apaCoachCode.
  ///
  /// In bn, this message translates to:
  /// **'কেউ কোড, ওটিপি বা পিন চাইলে সে প্রতারক। ফিননেস্ট কখনো এগুলো চায় না। কল কেটে দিন, তারপর {helpline} নম্বরে কল করুন।'**
  String apaCoachCode(String helpline);

  /// No description provided for @apaCoachApp.
  ///
  /// In bn, this message translates to:
  /// **'কারো কথায় বা অচেনা লিংক থেকে অ্যাপ নামাবেন না। এমন অ্যাপ আপনার স্ক্রিন দেখতে বা ফোন চালাতে পারে।'**
  String get apaCoachApp;

  /// No description provided for @apaCoachLoan.
  ///
  /// In bn, this message translates to:
  /// **'ঋণ দেবে বলে আগে টাকা, কোড বা অ্যাপ নামাতে বললে সেটা প্রতারণা। ফিননেস্টের ঋণ শুধু এই অ্যাপের ‘ঋণ’ পাতায়।'**
  String get apaCoachLoan;

  /// No description provided for @apaCoachTrusted.
  ///
  /// In bn, this message translates to:
  /// **'আপনজন হলেন আপনার বিশ্বস্ত একজন মানুষ। সন্দেহজনক লেনদেন আটকালে তাঁর অনুমোদন চাওয়া যায়। তিনি রাজি হলেই টাকা যায়।'**
  String get apaCoachTrusted;

  /// No description provided for @apaCoachLottery.
  ///
  /// In bn, this message translates to:
  /// **'লটারি বা পুরস্কার জিতেছেন বলে আগে টাকা বা কোড চাইলে সেটা প্রতারণা।'**
  String get apaCoachLottery;

  /// No description provided for @apaCoachGeneric.
  ///
  /// In bn, this message translates to:
  /// **'আমি ফিননেস্ট সহকারী বলছি। সংক্ষেপে আমাকে এফএনএ বলতে পারেন। নিচের চারটি বোতামের যেকোনোটা চাপুন: ফোন নিরাপদ কি না, টাকা কেন আটকাল, কেউ কোড চাইলে কী করবেন, আর নিরাপদ থাকার নিয়ম।'**
  String get apaCoachGeneric;

  /// No description provided for @apaQuickActionsLabel.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-কে দ্রুত জিজ্ঞাসা'**
  String get apaQuickActionsLabel;

  /// No description provided for @apaSourceServer.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্টের যাচাই'**
  String get apaSourceServer;

  /// No description provided for @apaSourcePhone.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিরাপত্তা যাচাই'**
  String get apaSourcePhone;

  /// No description provided for @apaSourceSignal.
  ///
  /// In bn, this message translates to:
  /// **'আপনার ফোনের সংকেত'**
  String get apaSourceSignal;

  /// No description provided for @apaSourceScam.
  ///
  /// In bn, this message translates to:
  /// **'কল যাচাই'**
  String get apaSourceScam;

  /// No description provided for @apaSourceRules.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-র নিয়ম'**
  String get apaSourceRules;

  /// No description provided for @apaSourceAi.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-র উত্তর · এআই'**
  String get apaSourceAi;

  /// No description provided for @apaInsightMore.
  ///
  /// In bn, this message translates to:
  /// **'আরও {count}টি বিষয়'**
  String apaInsightMore(String count);

  /// No description provided for @homeWhatToDo.
  ///
  /// In bn, this message translates to:
  /// **'কী করতে চান'**
  String get homeWhatToDo;

  /// No description provided for @homeSeeAll.
  ///
  /// In bn, this message translates to:
  /// **'সব দেখুন'**
  String get homeSeeAll;

  /// No description provided for @greetingShort.
  ///
  /// In bn, this message translates to:
  /// **'স্বাগতম, {name}'**
  String greetingShort(String name);

  /// No description provided for @balanceTotal.
  ///
  /// In bn, this message translates to:
  /// **'মোট ব্যালেন্স'**
  String get balanceTotal;

  /// No description provided for @balanceShow.
  ///
  /// In bn, this message translates to:
  /// **'দেখুন'**
  String get balanceShow;

  /// No description provided for @balanceHide.
  ///
  /// In bn, this message translates to:
  /// **'লুকান'**
  String get balanceHide;

  /// No description provided for @balanceHidden.
  ///
  /// In bn, this message translates to:
  /// **'ব্যালেন্স লুকানো'**
  String get balanceHidden;

  /// No description provided for @featureSend.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠান'**
  String get featureSend;

  /// No description provided for @featureCashOut.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ আউট'**
  String get featureCashOut;

  /// No description provided for @featureCashIn.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ ইন'**
  String get featureCashIn;

  /// No description provided for @featureRecharge.
  ///
  /// In bn, this message translates to:
  /// **'মোবাইল রিচার্জ'**
  String get featureRecharge;

  /// No description provided for @featureBill.
  ///
  /// In bn, this message translates to:
  /// **'বিল দিন'**
  String get featureBill;

  /// No description provided for @featureHistory.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন'**
  String get featureHistory;

  /// No description provided for @settings.
  ///
  /// In bn, this message translates to:
  /// **'সেটিংস'**
  String get settings;

  /// No description provided for @sendWho.
  ///
  /// In bn, this message translates to:
  /// **'কাকে পাঠাবেন'**
  String get sendWho;

  /// No description provided for @sendNewNumber.
  ///
  /// In bn, this message translates to:
  /// **'নতুন নম্বরে পাঠান'**
  String get sendNewNumber;

  /// No description provided for @sendSaved.
  ///
  /// In bn, this message translates to:
  /// **'সেভ করা'**
  String get sendSaved;

  /// No description provided for @sendHelper.
  ///
  /// In bn, this message translates to:
  /// **'চেনা মানুষকে পাঠান। কেউ ফোনে তাড়া দিলে আগে ফিননেস্ট সহকারীকে জিজ্ঞাসা করুন।'**
  String get sendHelper;

  /// No description provided for @numberDigitsLeft.
  ///
  /// In bn, this message translates to:
  /// **'{n}/১১ সংখ্যা'**
  String numberDigitsLeft(String n);

  /// No description provided for @numberNeed11.
  ///
  /// In bn, this message translates to:
  /// **'১১ সংখ্যা লিখুন'**
  String get numberNeed11;

  /// No description provided for @numberInvalid.
  ///
  /// In bn, this message translates to:
  /// **'নম্বরটি ঠিক নয়'**
  String get numberInvalid;

  /// No description provided for @numberIsSaved.
  ///
  /// In bn, this message translates to:
  /// **'এটি {name}-এর নম্বর'**
  String numberIsSaved(String name);

  /// No description provided for @numberConfirm.
  ///
  /// In bn, this message translates to:
  /// **'এই নম্বরে পাঠান'**
  String get numberConfirm;

  /// No description provided for @paste.
  ///
  /// In bn, this message translates to:
  /// **'পেস্ট'**
  String get paste;

  /// No description provided for @change.
  ///
  /// In bn, this message translates to:
  /// **'বদলান'**
  String get change;

  /// No description provided for @amountHowMuch.
  ///
  /// In bn, this message translates to:
  /// **'কত টাকা পাঠাবেন'**
  String get amountHowMuch;

  /// No description provided for @amountEnter.
  ///
  /// In bn, this message translates to:
  /// **'পরিমাণ লিখুন'**
  String get amountEnter;

  /// No description provided for @amountBalanceLine.
  ///
  /// In bn, this message translates to:
  /// **'ব্যালেন্স {amount}'**
  String amountBalanceLine(String amount);

  /// No description provided for @amountOverBalance.
  ///
  /// In bn, this message translates to:
  /// **'ব্যালেন্সের চেয়ে বেশি · ব্যালেন্স {amount}'**
  String amountOverBalance(String amount);

  /// No description provided for @amountMin.
  ///
  /// In bn, this message translates to:
  /// **'কমপক্ষে {amount}'**
  String amountMin(String amount);

  /// No description provided for @amountRange.
  ///
  /// In bn, this message translates to:
  /// **'{min} থেকে {max}'**
  String amountRange(String min, String max);

  /// No description provided for @stepOf.
  ///
  /// In bn, this message translates to:
  /// **'ধাপ {n}, মোট {total}'**
  String stepOf(String n, String total);

  /// No description provided for @cashOutAgent.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্ট নম্বর'**
  String get cashOutAgent;

  /// No description provided for @cashOutNewAgent.
  ///
  /// In bn, this message translates to:
  /// **'নতুন এজেন্ট নম্বর'**
  String get cashOutNewAgent;

  /// No description provided for @cashOutHelper.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্টের দোকানে গিয়ে এজেন্টের নম্বর লিখুন। টাকা হাতে নিয়ে তারপর পিন দিন।'**
  String get cashOutHelper;

  /// No description provided for @agentNeverPin.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্ট কখনো আপনার পিন জানতে চাইবে না'**
  String get agentNeverPin;

  /// No description provided for @cashInMakeCode.
  ///
  /// In bn, this message translates to:
  /// **'কোড তৈরি করুন'**
  String get cashInMakeCode;

  /// No description provided for @cashInShowAgent.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্টকে এই কোড আর টাকা দিন। এজেন্ট জমা দিলে ব্যালেন্সে যোগ হবে।'**
  String get cashInShowAgent;

  /// No description provided for @cashInDemoCode.
  ///
  /// In bn, this message translates to:
  /// **'ডেমো কোড — আসল QR নয়'**
  String get cashInDemoCode;

  /// No description provided for @cashInExpires.
  ///
  /// In bn, this message translates to:
  /// **'{time} পর্যন্ত চালু'**
  String cashInExpires(String time);

  /// No description provided for @rechargeWhich.
  ///
  /// In bn, this message translates to:
  /// **'কোন নম্বরে?'**
  String get rechargeWhich;

  /// No description provided for @rechargeMine.
  ///
  /// In bn, this message translates to:
  /// **'আমার নম্বর'**
  String get rechargeMine;

  /// No description provided for @rechargeOther.
  ///
  /// In bn, this message translates to:
  /// **'অন্য নম্বর'**
  String get rechargeOther;

  /// No description provided for @rechargePrepaid.
  ///
  /// In bn, this message translates to:
  /// **'প্রিপেইড'**
  String get rechargePrepaid;

  /// No description provided for @rechargePostpaid.
  ///
  /// In bn, this message translates to:
  /// **'পোস্টপেইড'**
  String get rechargePostpaid;

  /// No description provided for @opA.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর ক'**
  String get opA;

  /// No description provided for @opB.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর খ'**
  String get opB;

  /// No description provided for @opC.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর গ'**
  String get opC;

  /// No description provided for @opD.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর ঘ'**
  String get opD;

  /// No description provided for @opE.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর ঙ'**
  String get opE;

  /// No description provided for @billAccount.
  ///
  /// In bn, this message translates to:
  /// **'গ্রাহক নম্বর'**
  String get billAccount;

  /// No description provided for @billSee.
  ///
  /// In bn, this message translates to:
  /// **'বিল দেখুন'**
  String get billSee;

  /// No description provided for @billDue.
  ///
  /// In bn, this message translates to:
  /// **'শেষ তারিখ {date}'**
  String billDue(String date);

  /// No description provided for @billPay.
  ///
  /// In bn, this message translates to:
  /// **'বিল দিন'**
  String get billPay;

  /// No description provided for @demoNoteFeature.
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: আসল টাকা বা আসল অপারেটরে কিছু যায় না'**
  String get demoNoteFeature;

  /// No description provided for @pinSendingTo.
  ///
  /// In bn, this message translates to:
  /// **'{name}-কে পাঠাচ্ছেন'**
  String pinSendingTo(String name);

  /// No description provided for @resultRechargeDone.
  ///
  /// In bn, this message translates to:
  /// **'রিচার্জ হয়েছে'**
  String get resultRechargeDone;

  /// No description provided for @resultBillDone.
  ///
  /// In bn, this message translates to:
  /// **'বিল দেওয়া হয়েছে'**
  String get resultBillDone;

  /// No description provided for @resultNewBalance.
  ///
  /// In bn, this message translates to:
  /// **'নতুন ব্যালেন্স'**
  String get resultNewBalance;

  /// No description provided for @resultReference.
  ///
  /// In bn, this message translates to:
  /// **'রেফারেন্স'**
  String get resultReference;

  /// No description provided for @overlayHeldLabel.
  ///
  /// In bn, this message translates to:
  /// **'আটকে রাখা হয়েছে'**
  String get overlayHeldLabel;

  /// No description provided for @statusRequested.
  ///
  /// In bn, this message translates to:
  /// **'অপেক্ষায়'**
  String get statusRequested;

  /// No description provided for @historyTitle.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেন'**
  String get historyTitle;

  /// No description provided for @historyFilterAll.
  ///
  /// In bn, this message translates to:
  /// **'সব'**
  String get historyFilterAll;

  /// No description provided for @historyFilterSent.
  ///
  /// In bn, this message translates to:
  /// **'পাঠানো'**
  String get historyFilterSent;

  /// No description provided for @historyFilterCashOut.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ আউট'**
  String get historyFilterCashOut;

  /// No description provided for @historyFilterCashIn.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ ইন'**
  String get historyFilterCashIn;

  /// No description provided for @historyFilterRecharge.
  ///
  /// In bn, this message translates to:
  /// **'রিচার্জ'**
  String get historyFilterRecharge;

  /// No description provided for @historyFilterBill.
  ///
  /// In bn, this message translates to:
  /// **'বিল'**
  String get historyFilterBill;

  /// No description provided for @historyFilterReceived.
  ///
  /// In bn, this message translates to:
  /// **'এসেছে'**
  String get historyFilterReceived;

  /// No description provided for @historyEmptyFilter.
  ///
  /// In bn, this message translates to:
  /// **'এই ধরনের কোনো লেনদেন নেই'**
  String get historyEmptyFilter;

  /// No description provided for @today.
  ///
  /// In bn, this message translates to:
  /// **'আজ'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In bn, this message translates to:
  /// **'গতকাল'**
  String get yesterday;

  /// No description provided for @settingsAppearance.
  ///
  /// In bn, this message translates to:
  /// **'চেহারা'**
  String get settingsAppearance;

  /// No description provided for @settingsColour.
  ///
  /// In bn, this message translates to:
  /// **'রঙ'**
  String get settingsColour;

  /// No description provided for @presetTeal.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট টিল'**
  String get presetTeal;

  /// No description provided for @presetPadma.
  ///
  /// In bn, this message translates to:
  /// **'পদ্মা সবুজ'**
  String get presetPadma;

  /// No description provided for @presetJamdani.
  ///
  /// In bn, this message translates to:
  /// **'জামদানি নীল'**
  String get presetJamdani;

  /// No description provided for @presetShapla.
  ///
  /// In bn, this message translates to:
  /// **'শাপলা বেগুনি'**
  String get presetShapla;

  /// No description provided for @presetSlate.
  ///
  /// In bn, this message translates to:
  /// **'বর্ষা স্লেট'**
  String get presetSlate;

  /// No description provided for @settingsMode.
  ///
  /// In bn, this message translates to:
  /// **'আলো / অন্ধকার'**
  String get settingsMode;

  /// No description provided for @modeLight.
  ///
  /// In bn, this message translates to:
  /// **'আলো'**
  String get modeLight;

  /// No description provided for @modeDark.
  ///
  /// In bn, this message translates to:
  /// **'অন্ধকার'**
  String get modeDark;

  /// No description provided for @modeSystem.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের মতো'**
  String get modeSystem;

  /// No description provided for @settingsTextSize.
  ///
  /// In bn, this message translates to:
  /// **'লেখার আকার'**
  String get settingsTextSize;

  /// No description provided for @textNormal.
  ///
  /// In bn, this message translates to:
  /// **'সাধারণ'**
  String get textNormal;

  /// No description provided for @textLarge.
  ///
  /// In bn, this message translates to:
  /// **'বড়'**
  String get textLarge;

  /// No description provided for @settingsSample.
  ///
  /// In bn, this message translates to:
  /// **'মা-কে ৳ ৫,০০০ পাঠান'**
  String get settingsSample;

  /// No description provided for @settingsAccount.
  ///
  /// In bn, this message translates to:
  /// **'অ্যাকাউন্ট'**
  String get settingsAccount;

  /// No description provided for @neverAsksPinOtp.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট কখনো আপনার পিন বা ওটিপি (এসএমএসে আসা গোপন কোড) চায় না'**
  String get neverAsksPinOtp;

  /// No description provided for @apaSays.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ বলছে'**
  String get apaSays;

  /// No description provided for @apaAsk.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-কে জিজ্ঞাসা করুন'**
  String get apaAsk;

  /// No description provided for @apaRole.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট সহকারী · নিরাপত্তা গাইড'**
  String get apaRole;

  /// No description provided for @callHelpline.
  ///
  /// In bn, this message translates to:
  /// **'হেল্পলাইনে কল করুন'**
  String get callHelpline;

  /// No description provided for @demoConfirmCashIn.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্ট ক্যাশ ইন নিশ্চিত করলেন'**
  String get demoConfirmCashIn;

  /// No description provided for @loginSubmit.
  ///
  /// In bn, this message translates to:
  /// **'লগইন করুন'**
  String get loginSubmit;

  /// No description provided for @loginDistrictRina.
  ///
  /// In bn, this message translates to:
  /// **'গাজীপুর'**
  String get loginDistrictRina;

  /// No description provided for @loginDistrictRahima.
  ///
  /// In bn, this message translates to:
  /// **'ভোলা'**
  String get loginDistrictRahima;

  /// No description provided for @settingsAbout.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্ট · ডেমো সংস্করণ {version}'**
  String settingsAbout(String version);

  /// No description provided for @balanceUnavailable.
  ///
  /// In bn, this message translates to:
  /// **'ব্যালেন্স দেখা যাচ্ছে না'**
  String get balanceUnavailable;

  /// No description provided for @balanceSemantics.
  ///
  /// In bn, this message translates to:
  /// **'মোট ব্যালেন্স {amount}'**
  String balanceSemantics(String amount);

  /// No description provided for @amountSemantics.
  ///
  /// In bn, this message translates to:
  /// **'পরিমাণ {amount}'**
  String amountSemantics(String amount);

  /// No description provided for @numpadClearAll.
  ///
  /// In bn, this message translates to:
  /// **'সব মুছুন'**
  String get numpadClearAll;

  /// No description provided for @numpadDoubleZero.
  ///
  /// In bn, this message translates to:
  /// **'দুই শূন্য'**
  String get numpadDoubleZero;

  /// No description provided for @numpadPaste.
  ///
  /// In bn, this message translates to:
  /// **'পেস্ট করুন'**
  String get numpadPaste;

  /// No description provided for @close.
  ///
  /// In bn, this message translates to:
  /// **'বন্ধ'**
  String get close;

  /// No description provided for @txnSent.
  ///
  /// In bn, this message translates to:
  /// **'পাঠানো হয়েছে'**
  String get txnSent;

  /// No description provided for @txnReceived.
  ///
  /// In bn, this message translates to:
  /// **'এসেছে'**
  String get txnReceived;

  /// No description provided for @statusCancelled.
  ///
  /// In bn, this message translates to:
  /// **'বাতিল হয়েছে'**
  String get statusCancelled;

  /// No description provided for @statusReleased.
  ///
  /// In bn, this message translates to:
  /// **'ছাড়া হয়েছে'**
  String get statusReleased;

  /// No description provided for @apaNewAlert.
  ///
  /// In bn, this message translates to:
  /// **'নতুন সতর্কতা আছে'**
  String get apaNewAlert;

  /// No description provided for @agentLabel.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্ট'**
  String get agentLabel;

  /// No description provided for @txnTypeBill.
  ///
  /// In bn, this message translates to:
  /// **'বিল / পেমেন্ট'**
  String get txnTypeBill;

  /// No description provided for @txnSemDebit.
  ///
  /// In bn, this message translates to:
  /// **'{amount} টাকা পাঠানো হয়েছে'**
  String txnSemDebit(String amount);

  /// No description provided for @txnSemCredit.
  ///
  /// In bn, this message translates to:
  /// **'{amount} টাকা এসেছে'**
  String txnSemCredit(String amount);

  /// No description provided for @historyEmptyBody.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠালে বা এলে এখানে দেখা যাবে। শুরু করতে হোমে ফিরুন।'**
  String get historyEmptyBody;

  /// No description provided for @historyEmptyFilterBody.
  ///
  /// In bn, this message translates to:
  /// **'উপরে ‘সব’ চাপুন, সব লেনদেন দেখা যাবে।'**
  String get historyEmptyFilterBody;

  /// No description provided for @historyDetailType.
  ///
  /// In bn, this message translates to:
  /// **'ধরন'**
  String get historyDetailType;

  /// No description provided for @historyDetailStatus.
  ///
  /// In bn, this message translates to:
  /// **'অবস্থা'**
  String get historyDetailStatus;

  /// No description provided for @historyDetailTime.
  ///
  /// In bn, this message translates to:
  /// **'সময়'**
  String get historyDetailTime;

  /// No description provided for @historyFiltersLabel.
  ///
  /// In bn, this message translates to:
  /// **'লেনদেনের ধরন বেছে নিন'**
  String get historyFiltersLabel;

  /// No description provided for @pendingTrustedTitle.
  ///
  /// In bn, this message translates to:
  /// **'আপনজনের উত্তরের অপেক্ষায়'**
  String get pendingTrustedTitle;

  /// No description provided for @safetyNotCheckedShort.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই হয়নি'**
  String get safetyNotCheckedShort;

  /// No description provided for @safetyCheckFailedShort.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই করা যায়নি'**
  String get safetyCheckFailedShort;

  /// No description provided for @safetyErrorBody.
  ///
  /// In bn, this message translates to:
  /// **'ইন্টারনেট চালু আছে কি না দেখে আবার চেষ্টা করুন।'**
  String get safetyErrorBody;

  /// No description provided for @safetyDetails.
  ///
  /// In bn, this message translates to:
  /// **'বিস্তারিত'**
  String get safetyDetails;

  /// No description provided for @safetyUninstallApp.
  ///
  /// In bn, this message translates to:
  /// **'আনইনস্টল করুন'**
  String get safetyUninstallApp;

  /// No description provided for @tapToOpen.
  ///
  /// In bn, this message translates to:
  /// **'খুলতে চাপুন'**
  String get tapToOpen;

  /// No description provided for @amountHowMuchCashOut.
  ///
  /// In bn, this message translates to:
  /// **'কত টাকা তুলবেন'**
  String get amountHowMuchCashOut;

  /// No description provided for @amountHowMuchCashIn.
  ///
  /// In bn, this message translates to:
  /// **'কত টাকা জমা দেবেন'**
  String get amountHowMuchCashIn;

  /// No description provided for @amountHowMuchRecharge.
  ///
  /// In bn, this message translates to:
  /// **'কত টাকা রিচার্জ করবেন'**
  String get amountHowMuchRecharge;

  /// No description provided for @amountFeeLine.
  ///
  /// In bn, this message translates to:
  /// **'চার্জ {fee} · মোট {total}'**
  String amountFeeLine(String fee, String total);

  /// No description provided for @nextWithTotal.
  ///
  /// In bn, this message translates to:
  /// **'পরের ধাপ · মোট {total}'**
  String nextWithTotal(String total);

  /// No description provided for @pinCashOutTo.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্ট {number}-কে ক্যাশ আউট'**
  String pinCashOutTo(String number);

  /// No description provided for @pinRechargeLine.
  ///
  /// In bn, this message translates to:
  /// **'{number} · {operator} রিচার্জ'**
  String pinRechargeLine(String number, String operator);

  /// No description provided for @pinTotalWithFee.
  ///
  /// In bn, this message translates to:
  /// **'চার্জ সহ মোট {total}'**
  String pinTotalWithFee(String total);

  /// No description provided for @numberUseThis.
  ///
  /// In bn, this message translates to:
  /// **'এই নম্বর নিন'**
  String get numberUseThis;

  /// No description provided for @cashInCodeTitle.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ ইন কোড'**
  String get cashInCodeTitle;

  /// No description provided for @cashInCodeExpired.
  ///
  /// In bn, this message translates to:
  /// **'কোডের সময় শেষ। নতুন কোড তৈরি করুন।'**
  String get cashInCodeExpired;

  /// No description provided for @cashInConfirmed.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্ট জমা দিয়েছেন · ব্যালেন্সে যোগ হয়েছে'**
  String get cashInConfirmed;

  /// No description provided for @billDemo.
  ///
  /// In bn, this message translates to:
  /// **'ডেমো বিল'**
  String get billDemo;

  /// No description provided for @billWhich.
  ///
  /// In bn, this message translates to:
  /// **'কোন বিল দেবেন'**
  String get billWhich;

  /// No description provided for @billAccountNeed.
  ///
  /// In bn, this message translates to:
  /// **'{n} সংখ্যার গ্রাহক নম্বর লিখুন'**
  String billAccountNeed(String n);

  /// No description provided for @rechargeOperator.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর'**
  String get rechargeOperator;

  /// No description provided for @rechargeOperatorGuess.
  ///
  /// In bn, this message translates to:
  /// **'{operator} নম্বর মনে হচ্ছে'**
  String rechargeOperatorGuess(String operator);

  /// No description provided for @rechargeChooseNumber.
  ///
  /// In bn, this message translates to:
  /// **'নম্বর বেছে নিন'**
  String get rechargeChooseNumber;

  /// No description provided for @rechargeChooseOperator.
  ///
  /// In bn, this message translates to:
  /// **'অপারেটর বেছে নিন'**
  String get rechargeChooseOperator;

  /// No description provided for @resultCashOutTitle.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ আউট হয়েছে'**
  String get resultCashOutTitle;

  /// No description provided for @resultCashOutBody.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্টের কাছ থেকে টাকা নিন'**
  String get resultCashOutBody;

  /// No description provided for @resultSeeSafety.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিরাপত্তা দেখুন'**
  String get resultSeeSafety;

  /// No description provided for @recipientLast.
  ///
  /// In bn, this message translates to:
  /// **'শেষ {date}'**
  String recipientLast(String date);

  /// No description provided for @sendNoSaved.
  ///
  /// In bn, this message translates to:
  /// **'এখনো কাউকে সেভ করেননি'**
  String get sendNoSaved;

  /// No description provided for @overlayHeldTo.
  ///
  /// In bn, this message translates to:
  /// **'{name}-কে · {number}'**
  String overlayHeldTo(String name, String number);

  /// No description provided for @overlayMoreActions.
  ///
  /// In bn, this message translates to:
  /// **'আরও উপায়'**
  String get overlayMoreActions;

  /// No description provided for @numberCount.
  ///
  /// In bn, this message translates to:
  /// **'{n}/{total} সংখ্যা'**
  String numberCount(String n, String total);

  /// First half of the two-tone FinNest wordmark (leaf green); the logo is not translated
  ///
  /// In bn, this message translates to:
  /// **'Fin'**
  String get wordmarkFin;

  /// Second half of the two-tone FinNest wordmark (navy); the logo is not translated
  ///
  /// In bn, this message translates to:
  /// **'Nest'**
  String get wordmarkNest;

  /// No description provided for @loadingList.
  ///
  /// In bn, this message translates to:
  /// **'লোড হচ্ছে…'**
  String get loadingList;

  /// No description provided for @fraudDeskStaffNote.
  ///
  /// In bn, this message translates to:
  /// **'এটি ব্যাংকের কর্মীদের জন্য'**
  String get fraudDeskStaffNote;

  /// Approve screen header: who asks the trusted contact
  ///
  /// In bn, this message translates to:
  /// **'{name} আপনার মত চাইছেন'**
  String approveAsks(String name);

  /// Approve screen header when the requester is not known
  ///
  /// In bn, this message translates to:
  /// **'আপনার মত চাওয়া হচ্ছে'**
  String get approveAsksSomeone;

  /// Caption above the held amount on the approve screen
  ///
  /// In bn, this message translates to:
  /// **'আটকে রাখা টাকা'**
  String get approveHeldLabel;

  /// Kind line under the approve header; name is the payee
  ///
  /// In bn, this message translates to:
  /// **'{name}-কে পাঠানো হচ্ছিল'**
  String approveToPayee(String name);

  /// Section header above the server reasons on the approve screen
  ///
  /// In bn, this message translates to:
  /// **'কেন আটকানো হয়েছে'**
  String get approveWhyHeld;

  /// Countdown tag; time is m:ss in the active digits
  ///
  /// In bn, this message translates to:
  /// **'{time} বাকি'**
  String approveTimeLeftTag(String time);

  /// Empty-state body for a request created on another phone
  ///
  /// In bn, this message translates to:
  /// **'এই অনুরোধের বিস্তারিত অন্য ফোনে আছে। আপনি তবুও অনুমোদন বা প্রত্যাখ্যান করতে পারেন।'**
  String get approveUnknownBody;

  /// Muted short reference under the unknown-request body: the last six letters and digits of the id, uppercased ASCII (a code, not localised)
  ///
  /// In bn, this message translates to:
  /// **'রেফারেন্স {ref}'**
  String approveRefSuffix(String ref);

  /// Caption above the loan limit hero amount
  ///
  /// In bn, this message translates to:
  /// **'আপনি পেতে পারেন'**
  String get loanYouCanGet;

  /// Loan product row subtitle; months like '৩ মাস', monthly is formatted taka
  ///
  /// In bn, this message translates to:
  /// **'{months} · মাসিক কিস্তি {monthly}'**
  String loanRowSubtitle(String months, String monthly);

  /// Spoken title of a savings plan card
  ///
  /// In bn, this message translates to:
  /// **'মাসে {amount} জমা'**
  String dpsPlanTitle(String amount);

  /// Kind line above the projected maturity amount in the open-DPS sheet
  ///
  /// In bn, this message translates to:
  /// **'মেয়াদ শেষে প্রায় পাবেন'**
  String get dpsProjectionLabel;

  /// Demo panel group: video preset, persona, forced verdict, phone check
  ///
  /// In bn, this message translates to:
  /// **'দৃশ্য'**
  String get demoGroupScene;

  /// Demo panel group: the four simulated phone signals
  ///
  /// In bn, this message translates to:
  /// **'সংকেত'**
  String get demoGroupSignals;

  /// Demo panel group: re-run, replay, audio, cash in, resets
  ///
  /// In bn, this message translates to:
  /// **'কাজ'**
  String get demoGroupActions;

  /// Demo panel status line: last server time; ms in the active digits
  ///
  /// In bn, this message translates to:
  /// **'সার্ভার {ms} মি.সে.'**
  String demoServerMsShort(String ms);

  /// Snackbar after the demo panel confirms a waiting cash in
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ ইন নিশ্চিত হয়েছে, ব্যালেন্স বেড়েছে'**
  String get demoCashInDone;

  /// Snackbar when the demo panel finds no cash in to confirm
  ///
  /// In bn, this message translates to:
  /// **'এজেন্টের অপেক্ষায় কোনো ক্যাশ ইন নেই'**
  String get demoCashInNone;

  /// No description provided for @txnTypeDps.
  ///
  /// In bn, this message translates to:
  /// **'ডিপিএস জমা'**
  String get txnTypeDps;

  /// No description provided for @dpsEmptyBody.
  ///
  /// In bn, this message translates to:
  /// **'নিচের ‘নতুন ডিপিএস খুলুন’ চাপুন।'**
  String get dpsEmptyBody;

  /// No description provided for @cashInWriteFailed.
  ///
  /// In bn, this message translates to:
  /// **'কোড তৈরি করা যায়নি। আবার চেষ্টা করুন।'**
  String get cashInWriteFailed;

  /// No description provided for @approveNotYoursTitle.
  ///
  /// In bn, this message translates to:
  /// **'এই অনুরোধ আপনার আপনজনের জন্য'**
  String get approveNotYoursTitle;

  /// No description provided for @approveNotYoursBody.
  ///
  /// In bn, this message translates to:
  /// **'অনুমোদন বা প্রত্যাখ্যান শুধু তিনিই করতে পারেন, তাঁর নিজের ফোন থেকে। কেউ আপনাকে এখানে অনুমোদন চাপতে বললে সে প্রতারক হতে পারে।'**
  String get approveNotYoursBody;

  /// No description provided for @apaRoleCaption.
  ///
  /// In bn, this message translates to:
  /// **'নিরাপত্তা গাইড'**
  String get apaRoleCaption;

  /// No description provided for @demoVideoPresetDetail.
  ///
  /// In bn, this message translates to:
  /// **'কল চলছে + প্রতারণার কল'**
  String get demoVideoPresetDetail;

  /// The DPS plan under the result title and on the PIN pad: monthly instalment and tenure
  ///
  /// In bn, this message translates to:
  /// **'মাসে {amount} · {tenure}'**
  String dpsPlanLine(String amount, String tenure);

  /// Home security card header in a danger or caution state: the assistant's short name and the severity word.
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ: {severity}'**
  String apaHeaderSeverity(String severity);

  /// Lead-in of the one-line phone-safety caption under a danger or caution card; the verdict word follows.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিরাপত্তা:'**
  String get safetyCaptionPrefix;

  /// No description provided for @loginBiometric.
  ///
  /// In bn, this message translates to:
  /// **'আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন'**
  String get loginBiometric;

  /// No description provided for @biometricReason.
  ///
  /// In bn, this message translates to:
  /// **'ফিননেস্টে লগইন করতে আপনার পরিচয় যাচাই করুন'**
  String get biometricReason;

  /// No description provided for @loginBiometricFailed.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই হয়নি, আবার চেষ্টা করুন।'**
  String get loginBiometricFailed;

  /// No description provided for @loginWithPassword.
  ///
  /// In bn, this message translates to:
  /// **'পাসওয়ার্ড দিয়ে লগইন করুন'**
  String get loginWithPassword;

  /// No description provided for @loginFallbackNotEnrolled.
  ///
  /// In bn, this message translates to:
  /// **'এই ফোনে আঙুলের ছাপ বা মুখ সেট করা নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।'**
  String get loginFallbackNotEnrolled;

  /// No description provided for @loginFallbackWeak.
  ///
  /// In bn, this message translates to:
  /// **'এই ফোনের বায়োমেট্রিক যথেষ্ট নিরাপদ নয়, তাই পাসওয়ার্ড দিয়ে লগইন করুন।'**
  String get loginFallbackWeak;

  /// No description provided for @loginFallbackUnsupported.
  ///
  /// In bn, this message translates to:
  /// **'এই ফোনে বায়োমেট্রিক নেই, তাই পাসওয়ার্ড দিয়ে লগইন করুন।'**
  String get loginFallbackUnsupported;

  /// No description provided for @loginPasswordLabel.
  ///
  /// In bn, this message translates to:
  /// **'পাসওয়ার্ড'**
  String get loginPasswordLabel;

  /// No description provided for @loginPasswordShow.
  ///
  /// In bn, this message translates to:
  /// **'পাসওয়ার্ড দেখান'**
  String get loginPasswordShow;

  /// No description provided for @loginPasswordHide.
  ///
  /// In bn, this message translates to:
  /// **'পাসওয়ার্ড লুকান'**
  String get loginPasswordHide;

  /// No description provided for @loginPasswordWrong.
  ///
  /// In bn, this message translates to:
  /// **'পাসওয়ার্ড মেলেনি। আবার চেষ্টা করুন।'**
  String get loginPasswordWrong;

  /// Demo note on the password login path
  ///
  /// In bn, this message translates to:
  /// **'এটি ডেমো লগইন। ডেমো পাসওয়ার্ড: {password}'**
  String loginDemoPasswordHint(String password);

  /// No description provided for @loginNoOtp.
  ///
  /// In bn, this message translates to:
  /// **'আমরা ওটিপি চাই না: ওটিপি শেয়ার করা যায়, আপনার আঙুলের ছাপ বা মুখ যায় না।'**
  String get loginNoOtp;

  /// No description provided for @safetySearchHint.
  ///
  /// In bn, this message translates to:
  /// **'অ্যাপ বা সমস্যা খুঁজুন'**
  String get safetySearchHint;

  /// No description provided for @safetySearchClear.
  ///
  /// In bn, this message translates to:
  /// **'খোঁজা মুছুন'**
  String get safetySearchClear;

  /// No description provided for @safetyNothingFound.
  ///
  /// In bn, this message translates to:
  /// **'কিছু পাওয়া যায়নি'**
  String get safetyNothingFound;

  /// No description provided for @safetyNothingFoundBody.
  ///
  /// In bn, this message translates to:
  /// **'অন্য শব্দে খুঁজুন বা ফিল্টার সরান।'**
  String get safetyNothingFoundBody;

  /// No description provided for @safetyClearFilters.
  ///
  /// In bn, this message translates to:
  /// **'ফিল্টার সরান'**
  String get safetyClearFilters;

  /// No description provided for @safetyFiltersLabel.
  ///
  /// In bn, this message translates to:
  /// **'ফিল্টার'**
  String get safetyFiltersLabel;

  /// No description provided for @safetyFilterAll.
  ///
  /// In bn, this message translates to:
  /// **'সব'**
  String get safetyFilterAll;

  /// No description provided for @safetyFilterDanger.
  ///
  /// In bn, this message translates to:
  /// **'বিপজ্জনক'**
  String get safetyFilterDanger;

  /// No description provided for @safetyFilterCaution.
  ///
  /// In bn, this message translates to:
  /// **'সতর্কতা'**
  String get safetyFilterCaution;

  /// No description provided for @safetyFilterInfo.
  ///
  /// In bn, this message translates to:
  /// **'তথ্য'**
  String get safetyFilterInfo;

  /// No description provided for @safetyCategoryPermissions.
  ///
  /// In bn, this message translates to:
  /// **'অনুমতি'**
  String get safetyCategoryPermissions;

  /// No description provided for @safetyCategoryAccessibility.
  ///
  /// In bn, this message translates to:
  /// **'অ্যাক্সেসিবিলিটি'**
  String get safetyCategoryAccessibility;

  /// No description provided for @safetyCategoryScreen.
  ///
  /// In bn, this message translates to:
  /// **'স্ক্রিন শেয়ার ও ওভারলে'**
  String get safetyCategoryScreen;

  /// No description provided for @safetyCategoryUnknownApps.
  ///
  /// In bn, this message translates to:
  /// **'অচেনা অ্যাপ'**
  String get safetyCategoryUnknownApps;

  /// No description provided for @safetyCategoryPhone.
  ///
  /// In bn, this message translates to:
  /// **'ফোনের সেটিংস'**
  String get safetyCategoryPhone;

  /// No description provided for @safetyCategoryOther.
  ///
  /// In bn, this message translates to:
  /// **'অন্যান্য'**
  String get safetyCategoryOther;

  /// No description provided for @safetySortLabel.
  ///
  /// In bn, this message translates to:
  /// **'সাজানো'**
  String get safetySortLabel;

  /// No description provided for @safetySortSeverity.
  ///
  /// In bn, this message translates to:
  /// **'বিপদ আগে'**
  String get safetySortSeverity;

  /// No description provided for @safetySortName.
  ///
  /// In bn, this message translates to:
  /// **'নাম (অ-হ)'**
  String get safetySortName;

  /// No description provided for @safetyCtaRevokePermission.
  ///
  /// In bn, this message translates to:
  /// **'অনুমতি বন্ধ করুন'**
  String get safetyCtaRevokePermission;

  /// No description provided for @safetyCtaDisableService.
  ///
  /// In bn, this message translates to:
  /// **'সার্ভিস বন্ধ করুন'**
  String get safetyCtaDisableService;

  /// No description provided for @safetyCtaStopNow.
  ///
  /// In bn, this message translates to:
  /// **'এখনই বন্ধ করুন'**
  String get safetyCtaStopNow;

  /// No description provided for @safetyCtaFixSetting.
  ///
  /// In bn, this message translates to:
  /// **'সেটিংস ঠিক করুন'**
  String get safetyCtaFixSetting;

  /// No description provided for @safetyCtaAcknowledge.
  ///
  /// In bn, this message translates to:
  /// **'বুঝেছি'**
  String get safetyCtaAcknowledge;

  /// No description provided for @safetyAcknowledged.
  ///
  /// In bn, this message translates to:
  /// **'দেখা হয়েছে'**
  String get safetyAcknowledged;

  /// No description provided for @safetyCtaReturnHint.
  ///
  /// In bn, this message translates to:
  /// **'ফিরে এলে আবার যাচাই হবে।'**
  String get safetyCtaReturnHint;

  /// No description provided for @unknownNumber.
  ///
  /// In bn, this message translates to:
  /// **'নতুন নম্বর'**
  String get unknownNumber;

  /// No description provided for @payeeRecent.
  ///
  /// In bn, this message translates to:
  /// **'সাম্প্রতিক'**
  String get payeeRecent;

  /// No description provided for @payeeSavedLine.
  ///
  /// In bn, this message translates to:
  /// **'সেভ করা প্রাপক'**
  String get payeeSavedLine;

  /// No description provided for @payeeUnfamiliarLine.
  ///
  /// In bn, this message translates to:
  /// **'নতুন বা অচেনা প্রাপক। পাঠানোর আগে একবার ভাবুন।'**
  String get payeeUnfamiliarLine;

  /// No description provided for @reviewMoneySafe.
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠানো হয়নি, আপনার কাছেই আছে।'**
  String get reviewMoneySafe;

  /// No description provided for @reviewInReview.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই চলছে।'**
  String get reviewInReview;

  /// No description provided for @reviewFinished.
  ///
  /// In bn, this message translates to:
  /// **'যাচাই শেষ, টাকা আপনার কাছেই।'**
  String get reviewFinished;

  /// No description provided for @fraudDeskStaffTag.
  ///
  /// In bn, this message translates to:
  /// **'স্টাফ ভিউ · ডেমো'**
  String get fraudDeskStaffTag;

  /// No description provided for @fraudDeskTabWatchList.
  ///
  /// In bn, this message translates to:
  /// **'নজরে থাকা অ্যাকাউন্ট'**
  String get fraudDeskTabWatchList;

  /// No description provided for @fraudDeskTabCases.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত'**
  String get fraudDeskTabCases;

  /// No description provided for @fraudDeskWatchListEmpty.
  ///
  /// In bn, this message translates to:
  /// **'এখন কোনো অ্যাকাউন্ট নজরে নেই'**
  String get fraudDeskWatchListEmpty;

  /// No description provided for @fraudDeskWatchListEmptyBody.
  ///
  /// In bn, this message translates to:
  /// **'কোনো তদন্তে সন্দেহভাজন পাওয়া গেলে এখানে দেখা যাবে।'**
  String get fraudDeskWatchListEmptyBody;

  /// No description provided for @fraudDeskWatchListError.
  ///
  /// In bn, this message translates to:
  /// **'নজরের তালিকা আনা যায়নি'**
  String get fraudDeskWatchListError;

  /// No description provided for @fraudDeskRetry.
  ///
  /// In bn, this message translates to:
  /// **'আবার চেষ্টা করুন'**
  String get fraudDeskRetry;

  /// No description provided for @fraudDeskCasesEmpty.
  ///
  /// In bn, this message translates to:
  /// **'এই ফোন থেকে কোনো তদন্ত খোলা হয়নি'**
  String get fraudDeskCasesEmpty;

  /// No description provided for @fraudDeskCasesEmptyBody.
  ///
  /// In bn, this message translates to:
  /// **'নজরে থাকা একটি অ্যাকাউন্ট বেছে তদন্ত শুরু করুন।'**
  String get fraudDeskCasesEmptyBody;

  /// No description provided for @fraudDeskStartCase.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত শুরু করুন'**
  String get fraudDeskStartCase;

  /// No description provided for @fraudDeskPickTitle.
  ///
  /// In bn, this message translates to:
  /// **'কোন অ্যাকাউন্টের তদন্ত?'**
  String get fraudDeskPickTitle;

  /// No description provided for @fraudDeskPickEmpty.
  ///
  /// In bn, this message translates to:
  /// **'নজরে থাকা সব অ্যাকাউন্টের তদন্ত খোলা আছে'**
  String get fraudDeskPickEmpty;

  /// No description provided for @fraudDeskCooldown.
  ///
  /// In bn, this message translates to:
  /// **'৩০ মিনিটে একবার। পরে আবার চেষ্টা করুন।'**
  String get fraudDeskCooldown;

  /// No description provided for @fraudDeskAnalystApproved.
  ///
  /// In bn, this message translates to:
  /// **'বিশ্লেষক অনুমোদিত'**
  String get fraudDeskAnalystApproved;

  /// No description provided for @fraudDeskNoCase.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত খোলা হয়নি'**
  String get fraudDeskNoCase;

  /// No description provided for @fraudDeskRoleL1.
  ///
  /// In bn, this message translates to:
  /// **'প্রথম স্তর'**
  String get fraudDeskRoleL1;

  /// No description provided for @fraudDeskRoleL2.
  ///
  /// In bn, this message translates to:
  /// **'দ্বিতীয় স্তর'**
  String get fraudDeskRoleL2;

  /// No description provided for @fraudDeskRoleController.
  ///
  /// In bn, this message translates to:
  /// **'নিয়ন্ত্রক'**
  String get fraudDeskRoleController;

  /// No description provided for @fraudDeskRoleCashout.
  ///
  /// In bn, this message translates to:
  /// **'ক্যাশ-আউট এজেন্ট'**
  String get fraudDeskRoleCashout;

  /// No description provided for @fraudDeskRoleVictim.
  ///
  /// In bn, this message translates to:
  /// **'ভুক্তভোগী'**
  String get fraudDeskRoleVictim;

  /// No description provided for @fraudDeskRoleOther.
  ///
  /// In bn, this message translates to:
  /// **'অন্যান্য'**
  String get fraudDeskRoleOther;

  /// No description provided for @fraudDeskStatusSuspected.
  ///
  /// In bn, this message translates to:
  /// **'সন্দেহভাজন'**
  String get fraudDeskStatusSuspected;

  /// No description provided for @fraudDeskStatusConfirmed.
  ///
  /// In bn, this message translates to:
  /// **'নিশ্চিত'**
  String get fraudDeskStatusConfirmed;

  /// No description provided for @fraudDeskStatusCleared.
  ///
  /// In bn, this message translates to:
  /// **'সন্দেহমুক্ত'**
  String get fraudDeskStatusCleared;

  /// No description provided for @fraudDeskStatusUnknown.
  ///
  /// In bn, this message translates to:
  /// **'অজানা'**
  String get fraudDeskStatusUnknown;

  /// No description provided for @fraudDeskOpenedAt.
  ///
  /// In bn, this message translates to:
  /// **'খোলা: {time}'**
  String fraudDeskOpenedAt(String time);

  /// No description provided for @fraudDeskStarted.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত শুরু হয়েছে'**
  String get fraudDeskStarted;

  /// No description provided for @fraudDeskStartFailed.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত শুরু করা যায়নি।'**
  String get fraudDeskStartFailed;

  /// No description provided for @fraudDeskAccount.
  ///
  /// In bn, this message translates to:
  /// **'অ্যাকাউন্ট {id}'**
  String fraudDeskAccount(String id);

  /// No description provided for @czCaseTitle.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত'**
  String get czCaseTitle;

  /// No description provided for @czStatusQueued.
  ///
  /// In bn, this message translates to:
  /// **'সারিতে'**
  String get czStatusQueued;

  /// No description provided for @czStatusRunning.
  ///
  /// In bn, this message translates to:
  /// **'চলছে'**
  String get czStatusRunning;

  /// No description provided for @czStatusDone.
  ///
  /// In bn, this message translates to:
  /// **'শেষ'**
  String get czStatusDone;

  /// No description provided for @czStatusFailed.
  ///
  /// In bn, this message translates to:
  /// **'ব্যর্থ'**
  String get czStatusFailed;

  /// No description provided for @czStatusUnknown.
  ///
  /// In bn, this message translates to:
  /// **'অজানা'**
  String get czStatusUnknown;

  /// No description provided for @czRecommendation.
  ///
  /// In bn, this message translates to:
  /// **'সুপারিশ: {action}'**
  String czRecommendation(String action);

  /// No description provided for @czActionFreeze.
  ///
  /// In bn, this message translates to:
  /// **'অ্যাকাউন্ট আটকানো'**
  String get czActionFreeze;

  /// No description provided for @czActionEdd.
  ///
  /// In bn, this message translates to:
  /// **'বাড়তি যাচাই'**
  String get czActionEdd;

  /// No description provided for @czActionMonitor.
  ///
  /// In bn, this message translates to:
  /// **'নজরে রাখা'**
  String get czActionMonitor;

  /// No description provided for @czActionClose.
  ///
  /// In bn, this message translates to:
  /// **'ব্যবস্থা নেই'**
  String get czActionClose;

  /// No description provided for @czActionPending.
  ///
  /// In bn, this message translates to:
  /// **'অপেক্ষায়'**
  String get czActionPending;

  /// No description provided for @czActionReviewer.
  ///
  /// In bn, this message translates to:
  /// **'পর্যালোচকের কাছে'**
  String get czActionReviewer;

  /// No description provided for @czPendingApproval.
  ///
  /// In bn, this message translates to:
  /// **'এজেন্টের সুপারিশ, বিশ্লেষকের অনুমোদন বাকি'**
  String get czPendingApproval;

  /// No description provided for @czModelScore.
  ///
  /// In bn, this message translates to:
  /// **'মডেল স্কোর {percent}%'**
  String czModelScore(String percent);

  /// No description provided for @czCounts.
  ///
  /// In bn, this message translates to:
  /// **'প্রমাণ {evidence} · রিং {ring}'**
  String czCounts(String evidence, String ring);

  /// No description provided for @czSummary.
  ///
  /// In bn, this message translates to:
  /// **'সারাংশ'**
  String get czSummary;

  /// No description provided for @czShowOtherLanguage.
  ///
  /// In bn, this message translates to:
  /// **'English'**
  String get czShowOtherLanguage;

  /// No description provided for @czEvidence.
  ///
  /// In bn, this message translates to:
  /// **'প্রমাণ'**
  String get czEvidence;

  /// No description provided for @czRing.
  ///
  /// In bn, this message translates to:
  /// **'রিং'**
  String get czRing;

  /// No description provided for @czFailed.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত ব্যর্থ হয়েছে'**
  String get czFailed;

  /// No description provided for @czReviewerLine.
  ///
  /// In bn, this message translates to:
  /// **'একজন ঝুঁকি পর্যালোচক বিষয়টি হাতে দেখবেন।'**
  String get czReviewerLine;

  /// No description provided for @czStubFallback.
  ///
  /// In bn, this message translates to:
  /// **'স্ক্রিপ্টেড উত্তর (তদন্তকারী ব্যস্ত)'**
  String get czStubFallback;

  /// No description provided for @czStale.
  ///
  /// In bn, this message translates to:
  /// **'তদন্তটি আর পাওয়া যাচ্ছে না'**
  String get czStale;

  /// No description provided for @czRunningLine.
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত চলছে। সাধারণত এক মিনিটের মতো লাগে।'**
  String get czRunningLine;

  /// No description provided for @czRefreshFailed.
  ///
  /// In bn, this message translates to:
  /// **'এখন হালনাগাদ করা যায়নি, আবার চেষ্টা হবে।'**
  String get czRefreshFailed;

  /// No description provided for @czModelVersion.
  ///
  /// In bn, this message translates to:
  /// **'মডেল: {version}'**
  String czModelVersion(String version);

  /// No description provided for @czShowAppLanguage.
  ///
  /// In bn, this message translates to:
  /// **'বাংলা'**
  String get czShowAppLanguage;

  /// Demo panel group: what the app posts as the behaviour signal
  ///
  /// In bn, this message translates to:
  /// **'আচরণ'**
  String get behaviourModeSection;

  /// Demo panel: label over the behaviour mode segments
  ///
  /// In bn, this message translates to:
  /// **'আচরণ সংকেত'**
  String get behaviourModeLabel;

  /// Behaviour mode: the measured touch is sent
  ///
  /// In bn, this message translates to:
  /// **'লাইভ'**
  String get behaviourModeLive;

  /// Behaviour mode: no behaviour is sent
  ///
  /// In bn, this message translates to:
  /// **'বন্ধ'**
  String get behaviourModeOff;

  /// Behaviour mode: a stranger's touch is replayed
  ///
  /// In bn, this message translates to:
  /// **'অন্য কেউ'**
  String get behaviourModeStranger;

  /// Demo note on the overlay when the behaviour mode is off
  ///
  /// In bn, this message translates to:
  /// **'আচরণ সংকেত বন্ধ।'**
  String get behaviourModeOffNote;

  /// Demo note on the overlay when a stranger's touch was replayed
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: অন্য কারও হাতের ধরন।'**
  String get behaviourModeStrangerNote;

  /// Demo panel switch: save each PIN entry's behaviour on this phone
  ///
  /// In bn, this message translates to:
  /// **'নথিভুক্ত করা হচ্ছে'**
  String get enrolToggle;

  /// Demo note under the enrolment switch
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: চালু থাকলে প্রতিটি পিনের আচরণ এই ফোনে জমা হয়।'**
  String get enrolHint;

  /// Demo panel: how many enrolment rows this persona has
  ///
  /// In bn, this message translates to:
  /// **'নথিভুক্ত সেশন: {count}'**
  String enrolCount(String count);

  /// Demo panel: export the enrolment rows as a JSONL file
  ///
  /// In bn, this message translates to:
  /// **'ফাইলে লিখুন'**
  String get enrolExport;

  /// Snackbar after the export, with the file path
  ///
  /// In bn, this message translates to:
  /// **'ফাইলে লেখা হয়েছে: {path}'**
  String enrolExported(String path);

  /// Snackbar when the export failed
  ///
  /// In bn, this message translates to:
  /// **'ফাইলে লেখা যায়নি। আবার চেষ্টা করুন।'**
  String get enrolExportFailed;

  /// Demo panel: delete the enrolment rows of this persona
  ///
  /// In bn, this message translates to:
  /// **'মুছুন'**
  String get enrolClear;

  /// Snackbar after clearing the enrolment rows
  ///
  /// In bn, this message translates to:
  /// **'নথিভুক্ত সেশন মুছে ফেলা হয়েছে।'**
  String get enrolCleared;

  /// Step-up sheet title (identity and generic)
  ///
  /// In bn, this message translates to:
  /// **'একবার নিশ্চিত করুন'**
  String get stepUpConfirmTitle;

  /// Question above the fingerprint step-up button: the hold is about identity, and the owner's own fingerprint answers it
  ///
  /// In bn, this message translates to:
  /// **'এটা আপনিই?'**
  String get stepUpIsThisYou;

  /// Primary button on a hold overlay (hold_transaction): the customer keeps the money, the hold stays
  ///
  /// In bn, this message translates to:
  /// **'টাকা আমার কাছেই থাকুক'**
  String get actionKeepMoney;

  /// Outlined step-up button on the sheet and the overlay
  ///
  /// In bn, this message translates to:
  /// **'হ্যাঁ, আঙুলের ছাপ দিয়ে নিশ্চিত করুন'**
  String get stepUpBiometricButton;

  /// Text of the system fingerprint prompt
  ///
  /// In bn, this message translates to:
  /// **'টাকা পাঠাতে আপনার আঙুলের ছাপ দিন।'**
  String get stepUpBiometricReason;

  /// Step-up sheet secondary: ask the trusted contact instead
  ///
  /// In bn, this message translates to:
  /// **'আপনজনের মত নিন'**
  String get stepUpAskTrusted;

  /// Step-up sheet dismiss
  ///
  /// In bn, this message translates to:
  /// **'বাতিল'**
  String get stepUpCancel;

  /// Line after a failed or unavailable fingerprint step-up
  ///
  /// In bn, this message translates to:
  /// **'যাচাই হয়নি। আপনজনের মত নিন।'**
  String get stepUpFailed;

  /// Line in place of the fingerprint step-up once three prompts in this session did not pass (cancels count)
  ///
  /// In bn, this message translates to:
  /// **'তিনবার যাচাই হয়নি। এখন আপনজনের মত নিন।'**
  String get stepUpExhausted;

  /// Result title after a held transfer was released by the fingerprint step-up
  ///
  /// In bn, this message translates to:
  /// **'ফোনে যাচাই করে পাঠানো হয়েছে'**
  String get stepUpReleasedTitle;

  /// Demo note on the result after a step-up release
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: সার্ভারে লেনদেনটি আটকে রাখা হিসেবে লেখা আছে।'**
  String get stepUpReleasedDemoNote;

  /// History row subtitle of a transfer released by the step-up
  ///
  /// In bn, this message translates to:
  /// **'ফোনে যাচাই করে পাঠানো'**
  String get stepUpHistorySubtitle;

  /// Demo panel group: one-tap demo stories
  ///
  /// In bn, this message translates to:
  /// **'গল্প'**
  String get storySection;

  /// Demo story: send to the ring's first-level account
  ///
  /// In bn, this message translates to:
  /// **'প্রাপক সন্দেহভাজন'**
  String get storySuspectPayee;

  /// Demo note under the suspicious-recipient story
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: এই গল্পে সার্ভার যা দেখবে: পরিষ্কার ফোন, আচরণ সংকেত বন্ধ, আর সন্দেহভাজন প্রাপক।'**
  String get storySuspectPayeeNote;

  /// Demo story: a stranger's touch is replayed
  ///
  /// In bn, this message translates to:
  /// **'অন্য কেউ ফোন চালাচ্ছে'**
  String get storyStranger;

  /// Demo note under the stranger story
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: এই গল্পে সার্ভার যা দেখবে: মালিকের সাথে না মেলা হাতের ধরন, তাই লেনদেন আটকে থাকবে।'**
  String get storyStrangerNote;

  /// Demo story: open the staff fraud desk
  ///
  /// In bn, this message translates to:
  /// **'তদন্ত দেখুন'**
  String get storyInvestigation;

  /// Demo note under the investigation story
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: এই গল্পে সার্ভার যা দেখবে: নজরে থাকা অ্যাকাউন্টের তালিকা আর তদন্ত।'**
  String get storyInvestigationNote;

  /// Behaviour mode: only where and how hard the taps land changes
  ///
  /// In bn, this message translates to:
  /// **'ট্যাপের ধরন বদলে গেছে'**
  String get behaviourModeTapPattern;

  /// Behaviour mode: only how the phone moves and is held changes
  ///
  /// In bn, this message translates to:
  /// **'হাত কাঁপছে, ফোন অন্যভাবে ধরা'**
  String get behaviourModeShaking;

  /// Behaviour mode: only the typing speed and pauses change (a coached victim)
  ///
  /// In bn, this message translates to:
  /// **'কেউ বলে দিচ্ছে: ধীরে, থেমে থেমে টাইপ'**
  String get behaviourModeCoached;

  /// Demo note on the overlay when a changed tap pattern was replayed
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: ট্যাপের ধরন বদলানো।'**
  String get behaviourModeTapPatternNote;

  /// Demo note on the overlay when a shaking hand was replayed
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: কাঁপা হাত, অন্যভাবে ধরা ফোন।'**
  String get behaviourModeShakingNote;

  /// Demo note on the overlay when a coached, slow PIN entry was replayed
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: কেউ বলে দিচ্ছে, ধীরে টাইপ।'**
  String get behaviourModeCoachedNote;

  /// Demo story: only the tap pattern differs from the owner's
  ///
  /// In bn, this message translates to:
  /// **'ট্যাপের ধরন বদলে গেছে'**
  String get storyTapPattern;

  /// Demo note under the tap pattern story
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: এই গল্পে সার্ভার যা দেখবে: ট্যাপ যেখানে পড়ছে আর কতটা জোরে, তা মালিকের সাথে মেলে না; বাকি সব আগের মতো। সার্ভারের উত্তর: আচরণ মালিকের সাথে মেলেনি, তাই লেনদেন আটকে থাকবে। রেকর্ডে \"সিমুলেটেড\" লেখা থাকবে।'**
  String get storyTapPatternNote;

  /// Demo story: the hand shakes and the phone is held differently
  ///
  /// In bn, this message translates to:
  /// **'হাত কাঁপছে'**
  String get storyShaking;

  /// Demo note under the shaking hand story
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: এই গল্পে সার্ভার যা দেখবে: ফোন কতটা নড়ছে আর কীভাবে ধরা, তা মালিকের সাথে মেলে না; বাকি সব আগের মতো। সার্ভারের উত্তর: আচরণ মালিকের সাথে মেলেনি, তাই লেনদেন আটকে থাকবে। রেকর্ডে \"সিমুলেটেড\" লেখা থাকবে।'**
  String get storyShakingNote;

  /// Demo story: a coached victim types slowly, with pauses
  ///
  /// In bn, this message translates to:
  /// **'কেউ বলে দিচ্ছে'**
  String get storyCoached;

  /// Demo note under the coached story; the story also switches the call on
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: এই গল্পে সার্ভার যা দেখবে: মালিকের নিজের হাত, কিন্তু পিন টাইপের গতি আর বিরতি বদলে গেছে: ধীরে, থেমে থেমে, ভুল মুছে আবার। কলও চালু করা হলো, কারণ কল চলার সময়েই সার্ভার এতে লেনদেন আটকায়। আজকের ডেমোতে সার্ভারের উত্তর: আচরণ মালিকের সাথে মেলেনি, আর কেউ বলে দিচ্ছে বলে সন্দেহ; মালিকের আচরণ এই ফোন থেকে এখনও শেখানো হয়নি, তাই দুটোই আসে। রেকর্ডে \"সিমুলেটেড\" লেখা থাকবে।'**
  String get storyCoachedNote;

  /// Demo panel: FNA's last line played from a clip shipped in the app
  ///
  /// In bn, this message translates to:
  /// **'অ্যাপে রাখা অডিও'**
  String get voiceSourceBundled;

  /// Demo panel: FNA's last line played from the server's pre-rendered clip
  ///
  /// In bn, this message translates to:
  /// **'সার্ভারে আগে তৈরি অডিও'**
  String get voiceSourceServerClip;

  /// Demo panel: FNA's last line played from /v1/apa/why-audio
  ///
  /// In bn, this message translates to:
  /// **'সার্ভারের লাইভ অডিও'**
  String get voiceSourceServerLive;

  /// Demo panel: FNA's last line spoken by Gemini TTS on Vertex AI
  ///
  /// In bn, this message translates to:
  /// **'জেমিনাই ভয়েস (ভার্টেক্স এআই)'**
  String get voiceSourceGemini;

  /// Demo panel: FNA's last line spoken by the phone's TTS (fallback)
  ///
  /// In bn, this message translates to:
  /// **'ফোনের নিজের ভয়েস'**
  String get voiceSourceOnDevice;

  /// Demo panel: FNA said nothing
  ///
  /// In bn, this message translates to:
  /// **'কোনো অডিও বাজেনি'**
  String get voiceSourceNone;

  /// Demo panel note under the audio preview; source is one of the voiceSource* labels
  ///
  /// In bn, this message translates to:
  /// **'ডেমো: শেষ অডিও এসেছে: {source}'**
  String voiceSourceNote(String source);

  /// No description provided for @demoPreviewGeminiVoice.
  ///
  /// In bn, this message translates to:
  /// **'জেমিনি কণ্ঠে শুনুন'**
  String get demoPreviewGeminiVoice;

  /// No description provided for @overlayBlockedLabel.
  ///
  /// In bn, this message translates to:
  /// **'আটকানো হয়েছে'**
  String get overlayBlockedLabel;

  /// No description provided for @simulatedTagOff.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: আচরণ সংকেত বন্ধ'**
  String get simulatedTagOff;

  /// No description provided for @simulatedTagStranger.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: অন্য কারও হাতের ধরন'**
  String get simulatedTagStranger;

  /// No description provided for @simulatedTagTapPattern.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: ট্যাপের ধরন বদলানো'**
  String get simulatedTagTapPattern;

  /// No description provided for @simulatedTagShaking.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: কাঁপা হাত'**
  String get simulatedTagShaking;

  /// No description provided for @simulatedTagCoached.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: কেউ বলে দিচ্ছে'**
  String get simulatedTagCoached;

  /// No description provided for @pendingSummaryTitle.
  ///
  /// In bn, this message translates to:
  /// **'{count, plural, other{{countText}টি লেনদেন আটকে আছে}}'**
  String pendingSummaryTitle(int count, String countText);

  /// No description provided for @pendingSummarySee.
  ///
  /// In bn, this message translates to:
  /// **'দেখুন ›'**
  String get pendingSummarySee;

  /// No description provided for @historyFilterHeld.
  ///
  /// In bn, this message translates to:
  /// **'আটকে আছে'**
  String get historyFilterHeld;

  /// No description provided for @fraudDeskFactPrefix.
  ///
  /// In bn, this message translates to:
  /// **'তথ্য:'**
  String get fraudDeskFactPrefix;

  /// No description provided for @czNoEvidence.
  ///
  /// In bn, this message translates to:
  /// **'প্রমাণ পাওয়া যায়নি'**
  String get czNoEvidence;

  /// No description provided for @czCountsNoEvidence.
  ///
  /// In bn, this message translates to:
  /// **'প্রমাণ পাওয়া যায়নি · রিং {ring}'**
  String czCountsNoEvidence(String ring);

  /// No description provided for @czCitedTxns.
  ///
  /// In bn, this message translates to:
  /// **'সারাংশে উল্লেখিত লেনদেন'**
  String get czCitedTxns;

  /// No description provided for @txnTypeReceived.
  ///
  /// In bn, this message translates to:
  /// **'টাকা এসেছে'**
  String get txnTypeReceived;

  /// No description provided for @behaviourModeLiveHelp.
  ///
  /// In bn, this message translates to:
  /// **'এই ফোনের আসল স্পর্শ যায়'**
  String get behaviourModeLiveHelp;

  /// No description provided for @behaviourModeOffHelp.
  ///
  /// In bn, this message translates to:
  /// **'আচরণ সংকেত বন্ধ: সার্ভার আচরণ দেখবে না'**
  String get behaviourModeOffHelp;

  /// No description provided for @behaviourModeStrangerHelp.
  ///
  /// In bn, this message translates to:
  /// **'সিমুলেটেড: অন্য কারও হাতের ধরন; সার্ভার আটকে রাখবে'**
  String get behaviourModeStrangerHelp;

  /// No description provided for @demoPreviewPlaying.
  ///
  /// In bn, this message translates to:
  /// **'চলছে…'**
  String get demoPreviewPlaying;

  /// No description provided for @demoPreviewStop.
  ///
  /// In bn, this message translates to:
  /// **'থামান'**
  String get demoPreviewStop;

  /// Approve screen: the server says the decision did not come from the named trusted contact (contact_verified false); the hold stays
  ///
  /// In bn, this message translates to:
  /// **'আপনজন নিশ্চিত করেননি'**
  String get approveNotConfirmedLine;

  /// Staff Fraud desk: a Case Zero report delivered but failing the citation check (status degraded)
  ///
  /// In bn, this message translates to:
  /// **'শেষ, সূত্র যাচাই হয়নি'**
  String get czStatusDegraded;

  /// FNA chat: the large microphone button that opens voice mode
  ///
  /// In bn, this message translates to:
  /// **'কথা বলুন'**
  String get fnaTalk;

  /// FNA chat: speaker button under an FNA answer and on the call summary card
  ///
  /// In bn, this message translates to:
  /// **'শুনুন'**
  String get fnaHearIt;

  /// FNA chat: the Hear it button while that answer is playing
  ///
  /// In bn, this message translates to:
  /// **'থামান'**
  String get fnaHearStop;

  /// FNA voice mode state label (live region)
  ///
  /// In bn, this message translates to:
  /// **'সংযোগ হচ্ছে…'**
  String get fnaStateConnecting;

  /// FNA voice mode state label (live region)
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ শুনছে'**
  String get fnaStateListening;

  /// FNA voice mode state label (live region)
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ ভাবছে…'**
  String get fnaStateThinking;

  /// FNA voice mode state label (live region)
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ বলছে'**
  String get fnaStateSpeaking;

  /// FNA voice mode state label (live region)
  ///
  /// In bn, this message translates to:
  /// **'বিরতি চলছে · কথা বলতে চাপুন'**
  String get fnaStatePaused;

  /// FNA voice mode: permanent strip at the top
  ///
  /// In bn, this message translates to:
  /// **'পিন বা কোড মুখে বলবেন না, এফএনএ-কেও না।'**
  String get fnaPinStrip;

  /// FNA voice mode: a code-like number was heard and masked
  ///
  /// In bn, this message translates to:
  /// **'একটি নম্বর লুকিয়ে রাখা হয়েছে। কোড কাউকে বলবেন না।'**
  String get fnaNumberHidden;

  /// FNA: explanation shown before the Android microphone dialog
  ///
  /// In bn, this message translates to:
  /// **'এফএনএ-র সাথে কথা বলতে মাইক্রোফোন লাগবে। এফএনএ শুধু এই স্ক্রিন খোলা থাকলে শোনে। আপনার ফোনকল কখনো শোনে না।'**
  String get fnaMicRationale;

  /// FNA: button on the microphone explanation
  ///
  /// In bn, this message translates to:
  /// **'মাইক্রোফোন চালু করুন'**
  String get fnaMicTurnOn;

  /// FNA: the microphone was denied for good; opens the app settings
  ///
  /// In bn, this message translates to:
  /// **'সেটিংস খুলুন'**
  String get fnaOpenSettings;

  /// FNA: leave voice mode and type
  ///
  /// In bn, this message translates to:
  /// **'লিখে বলুন'**
  String get fnaTypeInstead;

  /// FNA voice mode control: stop FNA speaking
  ///
  /// In bn, this message translates to:
  /// **'থামান'**
  String get fnaStop;

  /// FNA voice mode control
  ///
  /// In bn, this message translates to:
  /// **'বিরতি'**
  String get fnaPause;

  /// FNA voice mode control
  ///
  /// In bn, this message translates to:
  /// **'আবার কথা বলুন'**
  String get fnaResume;

  /// FNA voice mode control: close voice mode
  ///
  /// In bn, this message translates to:
  /// **'শেষ করুন'**
  String get fnaEnd;

  /// FNA: voice mode could not connect or failed
  ///
  /// In bn, this message translates to:
  /// **'এখন কথা বলা যাচ্ছে না। লিখে জিজ্ঞাসা করুন, এফএনএ উত্তর পড়ে শোনাবে।'**
  String get fnaVoiceDown;

  /// FNA: voice mode fell back because there is no network
  ///
  /// In bn, this message translates to:
  /// **'ইন্টারনেট নেই। নিচের প্রশ্ন বেছে নিন। উত্তর আপনার ফোনেই আছে।'**
  String get fnaOffline;

  /// FNA call summary card heading
  ///
  /// In bn, this message translates to:
  /// **'সন্দেহজনক কল · {time}'**
  String fnaCallCardTitle(String time);

  /// FNA call summary card row label
  ///
  /// In bn, this message translates to:
  /// **'ফোনে চেয়েছিল'**
  String get fnaCallAskedFor;

  /// FNA call summary card row label
  ///
  /// In bn, this message translates to:
  /// **'ফোনে বলেছিল'**
  String get fnaCallTheySaid;

  /// FNA call summary card row label
  ///
  /// In bn, this message translates to:
  /// **'এখন কী করবেন'**
  String get fnaCallDoNow;

  /// FNA call summary card row label
  ///
  /// In bn, this message translates to:
  /// **'পরের বার যা করবেন'**
  String get fnaCallNextTime;

  /// FNA call summary card button: opens the dialer, never dials
  ///
  /// In bn, this message translates to:
  /// **'হেল্পলাইনে কল করুন'**
  String get fnaCallHelpline;

  /// FNA call summary card: what to do now
  ///
  /// In bn, this message translates to:
  /// **'আবার ফোন করলে কেটে দিন। টাকা পাঠাবেন না, কোনো কোড বলবেন না।'**
  String get fnaCallDoHangUp;

  /// FNA call summary card: what to do now
  ///
  /// In bn, this message translates to:
  /// **'সাবধান থাকুন, তাড়াহুড়ো করবেন না।'**
  String get fnaCallDoCareful;

  /// FNA call summary card: the caller asked for a card number
  ///
  /// In bn, this message translates to:
  /// **'কার্ডের নম্বর'**
  String get fnaSecretCard;

  /// FNA: Summarise the call when no call was flagged
  ///
  /// In bn, this message translates to:
  /// **'এখনো কোনো সন্দেহজনক কল ধরা পড়েনি। কেউ কোড চাইলে, কলার কী বলছে এফএনএ-কে বলুন।'**
  String get fnaNoCallYet;

  /// FNA chat topic chip: the last flagged call
  ///
  /// In bn, this message translates to:
  /// **'সন্দেহজনক কলের কথা'**
  String get fnaQuickSummary;

  /// FNA voice mode: TalkBack label of the controls row
  ///
  /// In bn, this message translates to:
  /// **'ভয়েস নিয়ন্ত্রণ'**
  String get fnaVoiceControls;

  /// No description provided for @fnaSecretSpoken.
  ///
  /// In bn, this message translates to:
  /// **'আপনার কথায় একটি কোডের মতো নম্বর ছিল, সেটা লুকিয়ে রাখা হয়েছে। কোড বা পিন কাউকে বলবেন না, এফএনএ-কেও না।'**
  String get fnaSecretSpoken;

  /// No description provided for @fnaHearItLabel.
  ///
  /// In bn, this message translates to:
  /// **'শুনুন: {text}'**
  String fnaHearItLabel(String text);

  /// No description provided for @fnaHearStopLabel.
  ///
  /// In bn, this message translates to:
  /// **'পড়া থামান: {text}'**
  String fnaHearStopLabel(String text);

  /// No description provided for @fnaShowAll.
  ///
  /// In bn, this message translates to:
  /// **'পুরোটা দেখুন'**
  String get fnaShowAll;

  /// No description provided for @fnaShowLess.
  ///
  /// In bn, this message translates to:
  /// **'কম দেখুন'**
  String get fnaShowLess;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['bn', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'bn':
      return AppLocalizationsBn();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
