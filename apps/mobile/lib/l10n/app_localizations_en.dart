// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'FinNest';

  @override
  String get tagline => 'A safe nest for your money';

  @override
  String get login => 'Log in';

  @override
  String get demoLogin => 'Demo login';

  @override
  String get demoLoginHint =>
      'This is a demo login. You will enter as a sample customer.';

  @override
  String get home => 'Home';

  @override
  String get sendMoney => 'Send money';

  @override
  String get apa => 'FNA';

  @override
  String get askApa => 'Ask FNA';

  @override
  String get fraudDesk => 'Fraud desk';

  @override
  String get demoMode => 'Demo mode';

  @override
  String get recordingMode => 'Recording';

  @override
  String get retry => 'Try again';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get next => 'Next';

  @override
  String get balance => 'Balance';

  @override
  String get recentTransactions => 'Recent transactions';

  @override
  String get safety => 'Phone safety';

  @override
  String get demoPanel => 'Demo panel';

  @override
  String placeholderScreen(String name) {
    return '$name screen coming soon';
  }

  @override
  String get safetyChecking => 'Checking…';

  @override
  String get safetyCheckFailed => 'Could not check. Tap to try again.';

  @override
  String get safetySimulatedTag => 'Simulated';

  @override
  String get safetyUninstall => 'Uninstall';

  @override
  String get safetyNoFindings => 'No risky apps found';

  @override
  String get safetyBlockedTitle => 'Transaction cancelled';

  @override
  String get safetyFindingsTitle => 'What we found';

  @override
  String get safetyVerdictSafe => 'Safe';

  @override
  String get safetyVerdictCaution => 'Caution';

  @override
  String get safetyVerdictBlock => 'Unsafe';

  @override
  String get safetySeverityLow => 'Low';

  @override
  String get safetySeverityMedium => 'Medium';

  @override
  String get safetySeverityHigh => 'High';

  @override
  String get safetySeverityCritical => 'Critical';

  @override
  String get safetyOpenDetails => 'See phone safety';

  @override
  String get approveTitle => 'Approval request';

  @override
  String get approveButton => 'Approve';

  @override
  String get declineButton => 'Decline';

  @override
  String get approvedLine => 'Approved. The money has been sent.';

  @override
  String get declinedLine => 'Declined. The transaction stays on hold.';

  @override
  String get expiredLine => 'Time is up';

  @override
  String timeLeft(String time) {
    return 'Time left $time';
  }

  @override
  String get approveRetry => 'Try again';

  @override
  String get approveFailed => 'Could not send right now';

  @override
  String get approveSending => 'Sending…';

  @override
  String get approveLoading => 'Looking up the request…';

  @override
  String get incomingRequestTitle => 'New approval request';

  @override
  String get openRequest => 'Open request';

  @override
  String get interventionDismiss => 'Later';

  @override
  String get interventionEnglish => 'Show English';

  @override
  String get interventionWaiting => 'FNA is speaking…';

  @override
  String get interventionHeldTitle => 'Transaction held';

  @override
  String get interventionDelayTitle => 'Transaction delayed';

  @override
  String get interventionBlockedTitle => 'Transaction cancelled';

  @override
  String get interventionStepUpTitle => 'Extra check needed';

  @override
  String get apaInitial => 'FNA';

  @override
  String actionHoldTransaction(String minutes) {
    return 'Hold for $minutes minutes';
  }

  @override
  String actionFreezePinReset(String minutes) {
    return 'Freeze PIN changes for $minutes minutes';
  }

  @override
  String actionDelayNewPayee(String minutes) {
    return 'Send after $minutes minutes';
  }

  @override
  String actionTrustedContact(String expiresInMinutes) {
    return 'Ask your trusted person ($expiresInMinutes minutes)';
  }

  @override
  String get actionStepUp => 'Verify again';

  @override
  String get actionBlock => 'Cancel the transaction';

  @override
  String get actionUnknown => 'Other action';

  @override
  String get apaSheetTitle => 'FinNest Assistant';

  @override
  String get apaHoldToTalk => 'Hold to talk';

  @override
  String get apaListening => 'Listening…';

  @override
  String get apaPathLive => 'Live';

  @override
  String get apaTypeHint => 'Type here…';

  @override
  String get apaSend => 'Send';

  @override
  String get apaLiveUnavailable =>
      'Live voice is off now. Type your question instead.';

  @override
  String get apaMicDenied =>
      'The microphone is not allowed. Type your question instead.';

  @override
  String get apaTextFailed =>
      'Cannot reach FinNest Assistant right now. Try again.';

  @override
  String get apaLiveFailed => 'Live voice stopped. Type your question instead.';

  @override
  String get apaEnglishToggle => 'Show English';

  @override
  String get apaThinking => 'FNA is thinking…';

  @override
  String get apaEmptyTranscript => 'Ask FinNest Assistant anything';

  @override
  String get apaYou => 'You';

  @override
  String get demoVideoPreset => 'Set up for the video';

  @override
  String get demoReplayScam => 'Play the scam call';

  @override
  String get demoResetCooldown => 'Clear the waiting time';

  @override
  String get demoResetAll => 'Reset everything';

  @override
  String get demoPreviewAudio => 'Play FNA\'s voice';

  @override
  String get demoForcedVerdict => 'Force the safety result';

  @override
  String get demoPersona => 'Customer';

  @override
  String get demoFlagSimSwap => 'SIM swap';

  @override
  String get demoFlagCallActive => 'Call in progress';

  @override
  String get demoFlagScreenShare => 'Screen sharing';

  @override
  String get demoFlagCallerInContacts => 'Caller is in contacts';

  @override
  String get demoHealth => 'Check the server';

  @override
  String get loginChoosePersona => 'Who is logging in?';

  @override
  String get passkeyUnavailable => 'Passkey login is not available yet';

  @override
  String get passkeyPendingLine =>
      'The passkey worked. In this demo, use the demo login.';

  @override
  String get logout => 'Log out';

  @override
  String get savedPayees => 'Saved payees';

  @override
  String get newNumber => 'New number';

  @override
  String get amount => 'Amount';

  @override
  String get quickAmounts => 'Quick amounts';

  @override
  String get backspace => 'Delete';

  @override
  String get pinTitle => 'Enter PIN';

  @override
  String get pinVerifying => 'Verifying…';

  @override
  String get pinWrong => 'Wrong PIN. Enter it again.';

  @override
  String pinLocked(String seconds) {
    return 'Wait $seconds s, then try again';
  }

  @override
  String get pinObscured =>
      'Another app is covering the screen. Wait a moment.';

  @override
  String pinDigitsEntered(String count) {
    return 'Digits entered: $count';
  }

  @override
  String get stepUpTitle => 'Stop screen sharing';

  @override
  String get stepUpBody =>
      'Sending money while the screen is shared is not safe. Stop sharing and enter your PIN again.';

  @override
  String get stepUpRetry => 'Try again';

  @override
  String get resultDone => 'Money sent';

  @override
  String get resultHeld => 'Your money is safely on hold';

  @override
  String get resultBlocked => 'Transaction cancelled';

  @override
  String get resultUnavailable => 'Cannot verify right now';

  @override
  String get resultUnavailableBody =>
      'Your money has not gone anywhere; it is still in your account. Try again in a moment.';

  @override
  String get goHome => 'Back to home';

  @override
  String get fraudDeskBody =>
      'The fraud desk is the bank investigators\' console. Held transactions, reasons and timelines are reviewed there. It opens in the browser.';

  @override
  String get openConsole => 'Open console';

  @override
  String get openConsoleFailed => 'Could not open the console';

  @override
  String get txnTypeSendMoney => 'Send money';

  @override
  String get txnTypeCashIn => 'Cash in';

  @override
  String get txnTypeCashOut => 'Cash out';

  @override
  String get txnTypeSalary => 'Salary';

  @override
  String get txnTypeRecharge => 'Recharge';

  @override
  String get txnTypeOther => 'Transaction';

  @override
  String get statusHeld => 'Held';

  @override
  String get statusBlocked => 'Blocked';

  @override
  String get statusDone => 'Done';

  @override
  String get trustedRequestSent =>
      'Request sent to your trusted person. We will tell you when they answer.';

  @override
  String get trustedRequestFailed => 'Could not send the request';

  @override
  String get noRecentTransactions => 'No transactions yet';

  @override
  String get safetyFromLastCheck =>
      'Could not check again. Showing the last result.';

  @override
  String get safetyDeviceSection => 'Your phone';

  @override
  String get safetyUninstallLine => 'Remove the risky app, then check again';

  @override
  String get safetyFixPhoneLine => 'Fix the phone settings, then check again';

  @override
  String get safetyReinstallLine => 'Reinstall FinNest from the Play Store';

  @override
  String get safetyOpenPlay => 'Open Play Store';

  @override
  String get safetyCallBankLine => 'Talk to the FinNest helpline';

  @override
  String get safetyCallBank => 'Call FinNest';

  @override
  String get safetyRecheck => 'Check again';

  @override
  String get demoIntegrity => 'Phone check result · demo';

  @override
  String get demoIntegrityClean => 'Normal';

  @override
  String get demoIntegrityScreenControlled => 'Screen controlled';

  @override
  String get demoIntegrityModded => 'Modified app';

  @override
  String get demoIntegrityEmulator => 'Emulator';

  @override
  String get demoIntegrityUnbound => 'Check did not match';

  @override
  String get demoRerunSafety => 'Run the safety check again';

  @override
  String get financeSavingsTitle => 'Savings';

  @override
  String get financeLoansTitle => 'Loans';

  @override
  String get financeTileLoans => 'Loans';

  @override
  String get financeTileSavings => 'Savings';

  @override
  String get financeEmpty => 'No savings plan (DPS) yet';

  @override
  String get financeLoadFailed => 'Could not load the details';

  @override
  String get financeActionFailed => 'That did not work. Try again.';

  @override
  String get dpsOpenNew => 'Open a new DPS';

  @override
  String get dpsMonthly => 'Monthly deposit';

  @override
  String get dpsPaidSoFar => 'Paid so far';

  @override
  String get dpsMaturity => 'At maturity';

  @override
  String dpsDemoRate(String rate) {
    return 'Demo rate $rate%';
  }

  @override
  String dpsTenureYears(int years) {
    final intl.NumberFormat yearsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String yearsString = yearsNumberFormat.format(years);

    String _temp0 = intl.Intl.pluralLogic(
      years,
      locale: localeName,
      other: '$yearsString years',
      one: '1 year',
    );
    return '$_temp0';
  }

  @override
  String dpsInstalments(String paid, String total) {
    return '$paid/$total instalments';
  }

  @override
  String get dpsChooseAmount => 'How much per month?';

  @override
  String get dpsChooseTenure => 'For how many years?';

  @override
  String dpsFirstInstalment(String amount) {
    return 'The first instalment of $amount is taken today';
  }

  @override
  String get dpsConfirm => 'Open DPS';

  @override
  String get dpsOpened => 'DPS opened';

  @override
  String loanIncomeLine(String amount) {
    return 'Based on a monthly income of $amount';
  }

  @override
  String get loanProducts => 'Loan products';

  @override
  String get loanApply => 'Apply';

  @override
  String get loanOverLimit => 'Above your limit';

  @override
  String get loanNeverAsksOtp =>
      'FinNest never asks for an OTP (the secret code sent by SMS) or PIN for a loan';

  @override
  String get loanStatusPending => 'Awaiting approval';

  @override
  String get loanStatusApproved => 'Approved';

  @override
  String get loanStatusRejected => 'Rejected';

  @override
  String get loanTotalRepayable => 'Total repayable';

  @override
  String loanTenureMonths(int months) {
    final intl.NumberFormat monthsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String monthsString = monthsNumberFormat.format(months);

    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$monthsString months',
      one: '1 month',
    );
    return '$_temp0';
  }

  @override
  String loanDemoFee(String pct) {
    return 'Demo fee $pct%';
  }

  @override
  String get loanApplied => 'Application submitted';

  @override
  String get loanApplications => 'Your applications';

  @override
  String get trustedRequestSentLine => 'Request sent to your trusted person';

  @override
  String get loginFailed => 'Could not log in. Try again.';

  @override
  String get pinCheckUnavailable =>
      'Could not check the PIN right now. Enter it again.';

  @override
  String get recentLoadFailed => 'Could not load transactions';

  @override
  String get resultHeldBody =>
      'The money is still in your account; it has not gone anywhere. Ask FinNest Assistant what to do next.';

  @override
  String get demoDataOnline => 'Online data';

  @override
  String get demoDataOffline => 'Offline data';

  @override
  String get languageBangla => 'বাংলা';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageToggleLabel => 'Choose language';

  @override
  String get loginPersonaRina => 'Rina Akter';

  @override
  String get loginPersonaRahima => 'Rahima Begum';

  @override
  String get demoPersonaRina => 'Rina';

  @override
  String get demoPersonaRahima => 'Rahima';

  @override
  String approveHeaderAmount(String amount) {
    return 'Request · $amount';
  }

  @override
  String get approveHeaderUnknown => 'A request from someone who trusts you';

  @override
  String get safetyUnknownApp => 'Unnamed app';

  @override
  String get safetySeverityOther => 'Risk';

  @override
  String get loanGeneric => 'Loan';

  @override
  String get demoVerdictAuto => 'Automatic';

  @override
  String demoCloudStatus(String status) {
    return 'Cloud: $status';
  }

  @override
  String get demoCloudConfigured => 'Connected';

  @override
  String get demoCloudAbsent => 'Not set up';

  @override
  String get demoCloudFailed => 'Did not start';

  @override
  String demoScamScore(String score) {
    return 'Scam score $score';
  }

  @override
  String demoReplayTurn(String n, String score, String urgency) {
    return '$n. Score $score · urgency: $urgency';
  }

  @override
  String get demoUrgencyNone => 'None';

  @override
  String get demoActionFailed => 'Did not work. Try again.';

  @override
  String get interventionShowBangla => 'Show Bangla';

  @override
  String get apaPathGemini => 'AI';

  @override
  String get apaPathGuide => 'Offline guide';

  @override
  String get apaQuickPhoneSafe => 'Is my phone safe?';

  @override
  String get apaQuickWhyHeld => 'Why was my money held?';

  @override
  String get apaQuickCodeAsked => 'Someone on the phone wants a code';

  @override
  String get apaQuickRules => '5 rules to stay safe';

  @override
  String get apaInsightBlockTitle => 'A risky app is on your phone';

  @override
  String apaInsightUninstallApps(String apps) {
    return 'Uninstall: $apps';
  }

  @override
  String get apaInsightCautionTitle => 'Something on your phone needs care';

  @override
  String get apaInsightScamTitle => 'Signs of a scam on the call';

  @override
  String get apaInsightCallTransferTitle => 'Do not send money during a call';

  @override
  String get apaInsightCallTransferBody =>
      'You are on a call and a transaction is waiting. Hang up first.';

  @override
  String get apaInsightHeldTitle => 'One of your transactions is on hold';

  @override
  String get apaInsightHeldNoReasons => 'Ask FNA for the details.';

  @override
  String get apaInsightSimSwapTitle => 'Your SIM changed recently';

  @override
  String apaInsightSimSwapBody(String helpline) {
    return 'Sending money may be held for 24 hours. If you did not change it, call $helpline now.';
  }

  @override
  String get apaInsightScreenShareTitle => 'Your screen is being shared';

  @override
  String get apaInsightScreenShareBody =>
      'Stop sharing before you send money or enter your PIN.';

  @override
  String get apaInsightAllClearTitle => 'Phone and payments look safe';

  @override
  String get apaInsightAllClearBody => 'If anyone asks for a code, tell FNA.';

  @override
  String get apaInsightUncheckedTitle => 'Your phone has not been checked yet';

  @override
  String get apaInsightUncheckedBody =>
      'Take a moment to check your phone\'s safety.';

  @override
  String get apaInsightLoading => 'FNA is checking…';

  @override
  String get apaSeverityDanger => 'Danger';

  @override
  String get apaSeverityCaution => 'Caution';

  @override
  String get apaSeverityOk => 'Safe';

  @override
  String get apaSeverityInfo => 'Good to know';

  @override
  String get apaActionOpenSafety => 'Check phone safety';

  @override
  String get apaActionScamCheck => 'Check what the caller said';

  @override
  String get apaActionHeld => 'See the held payment';

  @override
  String get apaActionRules => 'Rules to stay safe';

  @override
  String get apaActionAskApa => 'Ask FNA';

  @override
  String apaActionCallHelpline(String helpline) {
    return 'Call $helpline';
  }

  @override
  String get apaAnswerPhoneUnchecked =>
      'Your phone has not been checked yet. Tap the button below to check it.';

  @override
  String apaAnswerVerdictLine(String verdict) {
    return 'Phone status: $verdict';
  }

  @override
  String get apaAnswerFindingsIntro => 'What was found:';

  @override
  String get apaAnswerNothingHeld => 'None of your money is on hold right now.';

  @override
  String get apaAnswerHoldsIntro => 'Money can be held for these reasons:';

  @override
  String get apaAnswerHeldNext =>
      'The money was not sent. You can ask your trusted person to approve it, or try again once the reason is gone.';

  @override
  String get apaScamPrompt =>
      'Type what the caller said, as close to their words as you can. Do not type your code or PIN here.';

  @override
  String get apaScamInputHint => 'What the caller said…';

  @override
  String get apaScamCancel => 'Cancel';

  @override
  String get apaScamTypeFakeCare => 'Fake customer-care call';

  @override
  String get apaScamTypePressure => 'Pressure to hurry';

  @override
  String get apaScamTypeLottery => 'Lottery or prize trap';

  @override
  String get apaScamTypeOther => 'Suspicious call';

  @override
  String get apaScamTypeBenign => 'No clear sign of a scam';

  @override
  String apaScamLineType(String type) {
    return 'Type: $type';
  }

  @override
  String apaScamLineQuote(String quote) {
    return 'The caller said: “$quote”';
  }

  @override
  String apaScamLineSecret(String secret) {
    return 'They asked for: $secret';
  }

  @override
  String apaScamLineUrgency(String level) {
    return 'Pressure: $level';
  }

  @override
  String get apaSecretOtp => 'OTP or code';

  @override
  String get apaSecretPin => 'PIN';

  @override
  String get apaSecretPassword => 'Password';

  @override
  String get apaSecretOther => 'Private information';

  @override
  String get apaUrgencyHigh => 'Very high';

  @override
  String get apaUrgencyMedium => 'Medium';

  @override
  String get apaScamDoHangUp =>
      'What to do: hang up, do not send money, do not share any code.';

  @override
  String get apaScamDoCareful => 'What to do: be careful and do not hurry.';

  @override
  String get apaScamDoNothing =>
      'What to do: nothing special now. But if anyone asks for a code, hang up.';

  @override
  String apaScamHotline(String helpline) {
    return 'Hang up, then call $helpline yourself.';
  }

  @override
  String get apaScamSaved =>
      'What they said will be added to the safety check of your next transaction.';

  @override
  String get apaScamFailed =>
      'Could not check right now. Remember: anyone who asks for a code or PIN is a scammer.';

  @override
  String get apaSecretRedacted =>
      'Your message had a number that looks like a code, so it was hidden. Never tell anyone a code or PIN, not even FNA.';

  @override
  String apaCoachCode(String helpline) {
    return 'Anyone who asks for a code, OTP or PIN is a scammer. FinNest never asks for them. Hang up, then call $helpline.';
  }

  @override
  String get apaCoachApp =>
      'Do not install an app because someone told you to, or from an unknown link. Such an app can see your screen or control your phone.';

  @override
  String get apaCoachLoan =>
      'If someone offers a loan but first wants money, a code or an app installed, it is a scam. FinNest loans are only on the Loans page of this app.';

  @override
  String get apaCoachTrusted =>
      'Your trusted person is someone you rely on. When a doubtful transaction is held, you can ask them to approve it. The money goes only if they agree.';

  @override
  String get apaCoachLottery =>
      'If someone says you won a lottery or prize but first wants money or a code, it is a scam.';

  @override
  String get apaCoachGeneric =>
      'This is FinNest Assistant, FNA for short. Tap any of the four buttons below: is your phone safe, why money was held, what to do if someone wants a code, and the rules to stay safe.';

  @override
  String get apaQuickActionsLabel => 'Quick questions for FNA';

  @override
  String get apaSourceServer => 'FinNest check';

  @override
  String get apaSourcePhone => 'Phone safety check';

  @override
  String get apaSourceSignal => 'Your phone\'s signals';

  @override
  String get apaSourceScam => 'Call check';

  @override
  String get apaSourceRules => 'FNA\'s rules';

  @override
  String get apaSourceAi => 'FNA\'s answer · AI';

  @override
  String apaInsightMore(String count) {
    return '$count more';
  }

  @override
  String get homeWhatToDo => 'What would you like to do';

  @override
  String get homeSeeAll => 'See all';

  @override
  String greetingShort(String name) {
    return 'Welcome, $name';
  }

  @override
  String get balanceTotal => 'Total balance';

  @override
  String get balanceShow => 'Show';

  @override
  String get balanceHide => 'Hide';

  @override
  String get balanceHidden => 'Balance hidden';

  @override
  String get featureSend => 'Send money';

  @override
  String get featureCashOut => 'Cash out';

  @override
  String get featureCashIn => 'Cash in';

  @override
  String get featureRecharge => 'Mobile recharge';

  @override
  String get featureBill => 'Pay bill';

  @override
  String get featureHistory => 'History';

  @override
  String get settings => 'Settings';

  @override
  String get sendWho => 'Who are you sending to';

  @override
  String get sendNewNumber => 'Send to a new number';

  @override
  String get sendSaved => 'Saved';

  @override
  String get sendHelper =>
      'Send to people you know. If someone on a call is rushing you, ask FinNest Assistant first.';

  @override
  String numberDigitsLeft(String n) {
    return '$n/11 digits';
  }

  @override
  String get numberNeed11 => 'Enter 11 digits';

  @override
  String get numberInvalid => 'This number is not valid';

  @override
  String numberIsSaved(String name) {
    return 'This is $name\'s number';
  }

  @override
  String get numberConfirm => 'Send to this number';

  @override
  String get paste => 'Paste';

  @override
  String get change => 'Change';

  @override
  String get amountHowMuch => 'How much to send';

  @override
  String get amountEnter => 'Enter an amount';

  @override
  String amountBalanceLine(String amount) {
    return 'Balance $amount';
  }

  @override
  String amountOverBalance(String amount) {
    return 'More than your balance · Balance $amount';
  }

  @override
  String amountMin(String amount) {
    return 'At least $amount';
  }

  @override
  String amountRange(String min, String max) {
    return '$min to $max';
  }

  @override
  String stepOf(String n, String total) {
    return 'Step $n of $total';
  }

  @override
  String get cashOutAgent => 'Agent number';

  @override
  String get cashOutNewAgent => 'New agent number';

  @override
  String get cashOutHelper =>
      'At the agent\'s shop, enter the agent\'s number. Take the cash, then enter your PIN.';

  @override
  String get agentNeverPin => 'An agent will never ask for your PIN';

  @override
  String get cashInMakeCode => 'Create code';

  @override
  String get cashInShowAgent =>
      'Give this code and the cash to the agent. It is added once the agent confirms.';

  @override
  String get cashInDemoCode => 'Demo code — not a real QR';

  @override
  String cashInExpires(String time) {
    return 'Valid until $time';
  }

  @override
  String get rechargeWhich => 'Which number?';

  @override
  String get rechargeMine => 'My number';

  @override
  String get rechargeOther => 'Another number';

  @override
  String get rechargePrepaid => 'Prepaid';

  @override
  String get rechargePostpaid => 'Postpaid';

  @override
  String get opA => 'Operator A';

  @override
  String get opB => 'Operator B';

  @override
  String get opC => 'Operator C';

  @override
  String get opD => 'Operator D';

  @override
  String get opE => 'Operator E';

  @override
  String get billAccount => 'Customer number';

  @override
  String get billSee => 'See bill';

  @override
  String billDue(String date) {
    return 'Due $date';
  }

  @override
  String get billPay => 'Pay bill';

  @override
  String get demoNoteFeature => 'Demo: no real money or operator is involved';

  @override
  String pinSendingTo(String name) {
    return 'Sending to $name';
  }

  @override
  String get resultRechargeDone => 'Recharge done';

  @override
  String get resultBillDone => 'Bill paid';

  @override
  String get resultNewBalance => 'New balance';

  @override
  String get resultReference => 'Reference';

  @override
  String get overlayHeldLabel => 'Held';

  @override
  String get statusRequested => 'Waiting';

  @override
  String get historyTitle => 'History';

  @override
  String get historyFilterAll => 'All';

  @override
  String get historyFilterSent => 'Sent';

  @override
  String get historyFilterCashOut => 'Cash out';

  @override
  String get historyFilterCashIn => 'Cash in';

  @override
  String get historyFilterRecharge => 'Recharge';

  @override
  String get historyFilterBill => 'Bills';

  @override
  String get historyFilterReceived => 'Received';

  @override
  String get historyEmptyFilter => 'No transactions of this kind';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsColour => 'Colour';

  @override
  String get presetTeal => 'FinNest teal';

  @override
  String get presetPadma => 'Padma green';

  @override
  String get presetJamdani => 'Jamdani indigo';

  @override
  String get presetShapla => 'Shapla plum';

  @override
  String get presetSlate => 'Monsoon slate';

  @override
  String get settingsMode => 'Light / dark';

  @override
  String get modeLight => 'Light';

  @override
  String get modeDark => 'Dark';

  @override
  String get modeSystem => 'Auto';

  @override
  String get settingsTextSize => 'Text size';

  @override
  String get textNormal => 'Normal';

  @override
  String get textLarge => 'Large';

  @override
  String get settingsSample => 'Send ৳ 5,000 to Ma';

  @override
  String get settingsAccount => 'Account';

  @override
  String get neverAsksPinOtp =>
      'FinNest never asks for your PIN or OTP (the secret code sent by SMS)';

  @override
  String get apaSays => 'FNA says';

  @override
  String get apaAsk => 'Ask FNA';

  @override
  String get apaRole => 'FinNest Assistant · safety guide';

  @override
  String get callHelpline => 'Call the helpline';

  @override
  String get demoConfirmCashIn => 'Agent confirmed cash in';

  @override
  String get loginSubmit => 'Log in';

  @override
  String get loginDistrictRina => 'Gazipur';

  @override
  String get loginDistrictRahima => 'Bhola';

  @override
  String settingsAbout(String version) {
    return 'FinNest · demo version $version';
  }

  @override
  String get balanceUnavailable => 'Balance cannot be shown';

  @override
  String balanceSemantics(String amount) {
    return 'Total balance $amount';
  }

  @override
  String amountSemantics(String amount) {
    return 'Amount $amount';
  }

  @override
  String get numpadClearAll => 'Clear all';

  @override
  String get numpadDoubleZero => 'Double zero';

  @override
  String get numpadPaste => 'Paste';

  @override
  String get close => 'Close';

  @override
  String get txnSent => 'sent';

  @override
  String get txnReceived => 'received';

  @override
  String get statusCancelled => 'Cancelled';

  @override
  String get statusReleased => 'Released';

  @override
  String get apaNewAlert => 'New alert';

  @override
  String get agentLabel => 'Agent';

  @override
  String get txnTypeBill => 'Bill / payment';

  @override
  String txnSemDebit(String amount) {
    return '$amount taka sent';
  }

  @override
  String txnSemCredit(String amount) {
    return '$amount taka received';
  }

  @override
  String get historyEmptyBody =>
      'Money you send or receive shows up here. Go back home to start.';

  @override
  String get historyEmptyFilterBody =>
      'Tap ‘All’ above to see every transaction.';

  @override
  String get historyDetailType => 'Type';

  @override
  String get historyDetailStatus => 'Status';

  @override
  String get historyDetailTime => 'Time';

  @override
  String get historyFiltersLabel => 'Choose a transaction type';

  @override
  String get pendingTrustedTitle => 'Waiting for your trusted person';

  @override
  String get safetyNotCheckedShort => 'Not checked';

  @override
  String get safetyCheckFailedShort => 'Could not check';

  @override
  String get safetyErrorBody =>
      'Check that the internet is on, then try again.';

  @override
  String get safetyDetails => 'Details';

  @override
  String get safetyUninstallApp => 'Uninstall';

  @override
  String get tapToOpen => 'Tap to open';

  @override
  String get amountHowMuchCashOut => 'How much to cash out';

  @override
  String get amountHowMuchCashIn => 'How much to cash in';

  @override
  String get amountHowMuchRecharge => 'How much to recharge';

  @override
  String amountFeeLine(String fee, String total) {
    return 'Fee $fee · Total $total';
  }

  @override
  String nextWithTotal(String total) {
    return 'Next · Total $total';
  }

  @override
  String pinCashOutTo(String number) {
    return 'Cash out to agent $number';
  }

  @override
  String pinRechargeLine(String number, String operator) {
    return '$number · $operator recharge';
  }

  @override
  String pinTotalWithFee(String total) {
    return 'Total with fee $total';
  }

  @override
  String get numberUseThis => 'Use this number';

  @override
  String get cashInCodeTitle => 'Cash-in code';

  @override
  String get cashInCodeExpired => 'This code has expired. Create a new one.';

  @override
  String get cashInConfirmed => 'The agent confirmed · added to your balance';

  @override
  String get billDemo => 'Demo bill';

  @override
  String get billWhich => 'Which bill';

  @override
  String billAccountNeed(String n) {
    return 'Enter the $n-digit customer number';
  }

  @override
  String get rechargeOperator => 'Operator';

  @override
  String rechargeOperatorGuess(String operator) {
    return 'Looks like a $operator number';
  }

  @override
  String get rechargeChooseNumber => 'Choose a number';

  @override
  String get rechargeChooseOperator => 'Choose the operator';

  @override
  String get resultCashOutTitle => 'Cash out done';

  @override
  String get resultCashOutBody => 'Collect the cash from the agent';

  @override
  String get resultSeeSafety => 'See phone safety';

  @override
  String recipientLast(String date) {
    return 'Last $date';
  }

  @override
  String get sendNoSaved => 'You have not saved anyone yet';

  @override
  String overlayHeldTo(String name, String number) {
    return 'To $name · $number';
  }

  @override
  String get overlayMoreActions => 'More options';

  @override
  String numberCount(String n, String total) {
    return '$n/$total digits';
  }

  @override
  String get wordmarkFin => 'Fin';

  @override
  String get wordmarkNest => 'Nest';

  @override
  String get loadingList => 'Loading…';

  @override
  String get fraudDeskStaffNote => 'This is for bank staff';

  @override
  String approveAsks(String name) {
    return '$name is asking for your approval';
  }

  @override
  String get approveAsksSomeone => 'Your approval is needed';

  @override
  String get approveHeldLabel => 'Money on hold';

  @override
  String approveToPayee(String name) {
    return 'Was being sent to $name';
  }

  @override
  String get approveWhyHeld => 'Why it was held';

  @override
  String approveTimeLeftTag(String time) {
    return '$time left';
  }

  @override
  String get approveUnknownBody =>
      'The details of this request are on the other phone. You can still approve or decline it.';

  @override
  String approveRefSuffix(String ref) {
    return 'Reference $ref';
  }

  @override
  String get loanYouCanGet => 'You can get up to';

  @override
  String loanRowSubtitle(String months, String monthly) {
    return '$months · $monthly a month';
  }

  @override
  String dpsPlanTitle(String amount) {
    return '$amount a month';
  }

  @override
  String get dpsProjectionLabel => 'At maturity, about';

  @override
  String get demoGroupScene => 'Scene';

  @override
  String get demoGroupSignals => 'Signals';

  @override
  String get demoGroupActions => 'Actions';

  @override
  String demoServerMsShort(String ms) {
    return 'Server $ms ms';
  }

  @override
  String get demoCashInDone => 'Cash in confirmed; the balance went up';

  @override
  String get demoCashInNone => 'No cash in is waiting for the agent';

  @override
  String get txnTypeDps => 'DPS deposit';

  @override
  String get dpsEmptyBody => 'Tap ‘Open a new DPS’ below.';

  @override
  String get cashInWriteFailed => 'Could not create the code. Try again.';

  @override
  String get approveNotYoursTitle => 'This request is for your trusted person';

  @override
  String get approveNotYoursBody =>
      'Only they can approve or decline it, on their own phone. If someone asks you to press approve here, they may be a scammer.';

  @override
  String get apaRoleCaption => 'Safety guide';

  @override
  String get demoVideoPresetDetail => 'Call on + scam call';

  @override
  String dpsPlanLine(String amount, String tenure) {
    return '$amount a month · $tenure';
  }

  @override
  String apaHeaderSeverity(String severity) {
    return 'FNA: $severity';
  }

  @override
  String get safetyCaptionPrefix => 'Phone safety:';

  @override
  String get loginBiometric => 'Log in with fingerprint or face';

  @override
  String get biometricReason => 'Confirm it is you to log in to FinNest';

  @override
  String get loginBiometricFailed => 'Could not confirm it is you. Try again.';

  @override
  String get loginWithPassword => 'Log in with password';

  @override
  String get loginFallbackNotEnrolled =>
      'No fingerprint or face is set up on this phone, so log in with your password.';

  @override
  String get loginFallbackWeak =>
      'This phone\'s fingerprint or face check is not secure enough, so log in with your password.';

  @override
  String get loginFallbackUnsupported =>
      'This phone has no fingerprint or face check, so log in with your password.';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginPasswordShow => 'Show password';

  @override
  String get loginPasswordHide => 'Hide password';

  @override
  String get loginPasswordWrong => 'That password does not match. Try again.';

  @override
  String loginDemoPasswordHint(String password) {
    return 'This is a demo login. Demo password: $password';
  }

  @override
  String get loginNoOtp =>
      'We never ask for an OTP: an OTP can be shared, your fingerprint or face cannot.';

  @override
  String get safetySearchHint => 'Search apps or issues';

  @override
  String get safetySearchClear => 'Clear search';

  @override
  String get safetyNothingFound => 'Nothing found';

  @override
  String get safetyNothingFoundBody => 'Try other words or clear the filters.';

  @override
  String get safetyClearFilters => 'Clear filters';

  @override
  String get safetyFiltersLabel => 'Filters';

  @override
  String get safetyFilterAll => 'All';

  @override
  String get safetyFilterDanger => 'Danger';

  @override
  String get safetyFilterCaution => 'Caution';

  @override
  String get safetyFilterInfo => 'Info';

  @override
  String get safetyCategoryPermissions => 'Permissions';

  @override
  String get safetyCategoryAccessibility => 'Accessibility';

  @override
  String get safetyCategoryScreen => 'Screen share & overlay';

  @override
  String get safetyCategoryUnknownApps => 'Unknown apps';

  @override
  String get safetyCategoryPhone => 'Phone settings';

  @override
  String get safetyCategoryOther => 'Other';

  @override
  String get safetySortLabel => 'Sort';

  @override
  String get safetySortSeverity => 'Danger first';

  @override
  String get safetySortName => 'Name (A-Z)';

  @override
  String get safetyCtaRevokePermission => 'Turn off permission';

  @override
  String get safetyCtaDisableService => 'Turn off service';

  @override
  String get safetyCtaStopNow => 'Stop it now';

  @override
  String get safetyCtaFixSetting => 'Fix in settings';

  @override
  String get safetyCtaAcknowledge => 'Got it';

  @override
  String get safetyAcknowledged => 'Noted';

  @override
  String get safetyCtaReturnHint => 'We check again when you come back.';

  @override
  String get unknownNumber => 'New number';

  @override
  String get payeeRecent => 'Recent';

  @override
  String get payeeSavedLine => 'Saved recipient';

  @override
  String get payeeUnfamiliarLine =>
      'New or unfamiliar recipient. Think once before you send.';

  @override
  String get reviewMoneySafe => 'The money was not sent. It is still with you.';

  @override
  String get reviewInReview => 'A review is under way.';

  @override
  String get reviewFinished =>
      'The review is finished. The money is still with you.';

  @override
  String get fraudDeskStaffTag => 'Staff view · demo';

  @override
  String get fraudDeskTabWatchList => 'Watched accounts';

  @override
  String get fraudDeskTabCases => 'Investigations';

  @override
  String get fraudDeskWatchListEmpty => 'No account is being watched now';

  @override
  String get fraudDeskWatchListEmptyBody =>
      'Accounts flagged by an investigation appear here.';

  @override
  String get fraudDeskWatchListError => 'Could not load the watch-list';

  @override
  String get fraudDeskRetry => 'Try again';

  @override
  String get fraudDeskCasesEmpty => 'No investigation opened from this phone';

  @override
  String get fraudDeskCasesEmptyBody =>
      'Pick a watched account and start an investigation.';

  @override
  String get fraudDeskStartCase => 'Start an investigation';

  @override
  String get fraudDeskPickTitle => 'Investigate which account?';

  @override
  String get fraudDeskPickEmpty =>
      'Every watched account already has an open investigation';

  @override
  String get fraudDeskCooldown => 'Once every 30 minutes. Try again later.';

  @override
  String get fraudDeskAnalystApproved => 'Analyst approved';

  @override
  String get fraudDeskNoCase => 'No investigation yet';

  @override
  String get fraudDeskRoleL1 => 'First layer';

  @override
  String get fraudDeskRoleL2 => 'Second layer';

  @override
  String get fraudDeskRoleController => 'Controller';

  @override
  String get fraudDeskRoleCashout => 'Cash-out agent';

  @override
  String get fraudDeskRoleVictim => 'Victim';

  @override
  String get fraudDeskRoleOther => 'Other';

  @override
  String get fraudDeskStatusSuspected => 'Suspected';

  @override
  String get fraudDeskStatusConfirmed => 'Confirmed';

  @override
  String get fraudDeskStatusCleared => 'Cleared';

  @override
  String get fraudDeskStatusUnknown => 'Unknown';

  @override
  String fraudDeskOpenedAt(String time) {
    return 'Opened $time';
  }

  @override
  String get fraudDeskStarted => 'Investigation started';

  @override
  String get fraudDeskStartFailed => 'Could not start the investigation.';

  @override
  String fraudDeskAccount(String id) {
    return 'Account $id';
  }

  @override
  String get czCaseTitle => 'Investigation';

  @override
  String get czStatusQueued => 'Queued';

  @override
  String get czStatusRunning => 'Running';

  @override
  String get czStatusDone => 'Done';

  @override
  String get czStatusFailed => 'Failed';

  @override
  String get czStatusUnknown => 'Unknown';

  @override
  String czRecommendation(String action) {
    return 'Recommendation: $action';
  }

  @override
  String get czActionFreeze => 'Freeze the account';

  @override
  String get czActionEdd => 'Enhanced due diligence';

  @override
  String get czActionMonitor => 'Keep monitoring';

  @override
  String get czActionClose => 'No action';

  @override
  String get czActionPending => 'Pending';

  @override
  String get czActionReviewer => 'To a risk reviewer';

  @override
  String get czPendingApproval =>
      'The agent\'s recommendation; analyst approval pending';

  @override
  String czModelScore(String percent) {
    return 'Model score $percent%';
  }

  @override
  String czCounts(String evidence, String ring) {
    return 'Evidence $evidence · Ring $ring';
  }

  @override
  String get czSummary => 'Summary';

  @override
  String get czShowOtherLanguage => 'Show Bangla';

  @override
  String get czEvidence => 'Evidence';

  @override
  String get czRing => 'Ring';

  @override
  String get czFailed => 'The investigation failed';

  @override
  String get czReviewerLine => 'A risk reviewer will look at it by hand.';

  @override
  String get czStubFallback => 'Scripted answer (investigator busy)';

  @override
  String get czStale => 'This investigation can no longer be found';

  @override
  String get czRunningLine =>
      'The investigation is running. It usually takes about a minute.';

  @override
  String get czRefreshFailed => 'Could not refresh now; it will try again.';

  @override
  String czModelVersion(String version) {
    return 'Model: $version';
  }

  @override
  String get czShowAppLanguage => 'Show English';

  @override
  String get behaviourModeSection => 'Behaviour';

  @override
  String get behaviourModeLabel => 'Behaviour signal';

  @override
  String get behaviourModeLive => 'Live';

  @override
  String get behaviourModeOff => 'Off';

  @override
  String get behaviourModeStranger => 'Someone else';

  @override
  String get behaviourModeOffNote => 'Behaviour signal off.';

  @override
  String get behaviourModeStrangerNote => 'Simulated: someone else\'s touch.';

  @override
  String get enrolToggle => 'Enrolling';

  @override
  String get enrolHint =>
      'Demo: while on, each PIN entry\'s behaviour is saved on this phone.';

  @override
  String enrolCount(String count) {
    return 'Enrolled sessions: $count';
  }

  @override
  String get enrolExport => 'Write to file';

  @override
  String enrolExported(String path) {
    return 'Written to: $path';
  }

  @override
  String get enrolExportFailed => 'Could not write the file. Try again.';

  @override
  String get enrolClear => 'Clear';

  @override
  String get enrolCleared => 'Enrolled sessions cleared.';

  @override
  String get stepUpConfirmTitle => 'Confirm once';

  @override
  String get stepUpIsThisYou => 'Is this you?';

  @override
  String get actionKeepMoney => 'Keep my money with me';

  @override
  String get stepUpBiometricButton => 'Yes, confirm with my fingerprint';

  @override
  String get stepUpBiometricReason => 'Use your fingerprint to send the money.';

  @override
  String get stepUpAskTrusted => 'Ask your trusted person';

  @override
  String get stepUpCancel => 'Cancel';

  @override
  String get stepUpFailed => 'Not verified. Ask your trusted person.';

  @override
  String get stepUpExhausted =>
      'Three checks did not pass. Ask your trusted person now.';

  @override
  String get stepUpReleasedTitle => 'Sent after checking on this phone';

  @override
  String get stepUpReleasedDemoNote =>
      'Demo: the server still records this transfer as held.';

  @override
  String get stepUpHistorySubtitle => 'Sent after checking on this phone';

  @override
  String get storySection => 'Stories';

  @override
  String get storySuspectPayee => 'Suspicious recipient';

  @override
  String get storySuspectPayeeNote =>
      'Demo: what the server sees in this story: a clean phone, the behaviour signal off and a suspicious recipient.';

  @override
  String get storyStranger => 'Someone else is using the phone';

  @override
  String get storyStrangerNote =>
      'Demo: what the server sees in this story: a touch that does not match the owner\'s, so the transfer is held.';

  @override
  String get storyInvestigation => 'See the investigation';

  @override
  String get storyInvestigationNote =>
      'Demo: what the server sees in this story: the watch-list and the investigation.';

  @override
  String get behaviourModeTapPattern => 'Tap pattern changed';

  @override
  String get behaviourModeShaking => 'Shaking hand, phone held differently';

  @override
  String get behaviourModeCoached =>
      'Someone is telling them: slow, halting typing';

  @override
  String get behaviourModeTapPatternNote => 'Simulated: a changed tap pattern.';

  @override
  String get behaviourModeShakingNote =>
      'Simulated: a shaking hand, the phone held differently.';

  @override
  String get behaviourModeCoachedNote =>
      'Simulated: someone is telling them what to type.';

  @override
  String get storyTapPattern => 'The tap pattern has changed';

  @override
  String get storyTapPatternNote =>
      'Demo: what the server sees in this story: where the taps land and how hard does not match the owner; everything else is as before. The server answers: the behaviour does not match the owner, so the transfer is held. The records are tagged \"Simulated\".';

  @override
  String get storyShaking => 'A shaking hand';

  @override
  String get storyShakingNote =>
      'Demo: what the server sees in this story: how much the phone moves and how it is held does not match the owner; everything else is as before. The server answers: the behaviour does not match the owner, so the transfer is held. The records are tagged \"Simulated\".';

  @override
  String get storyCoached => 'Someone is telling them what to do';

  @override
  String get storyCoachedNote =>
      'Demo: what the server sees in this story: the owner\'s own hand, but the PIN typing speed and pauses have changed: slow, halting, a digit deleted and typed again. The call is switched on too, because the server holds for this only during a call. In today\'s demo the server answers: the behaviour does not match the owner, and someone seems to be telling them what to do; the owner\'s behaviour has not yet been learned from this phone, so both come. The records are tagged \"Simulated\".';

  @override
  String get voiceSourceBundled => 'Bundled clip';

  @override
  String get voiceSourceServerClip => 'Server clip';

  @override
  String get voiceSourceServerLive => 'Server live audio';

  @override
  String get voiceSourceGemini => 'Gemini voice (Vertex AI)';

  @override
  String get voiceSourceOnDevice => 'The phone\'s own voice';

  @override
  String get voiceSourceNone => 'No audio played';

  @override
  String voiceSourceNote(String source) {
    return 'Demo: the last audio came from: $source';
  }

  @override
  String get demoPreviewGeminiVoice => 'Hear the Gemini voice';

  @override
  String get overlayBlockedLabel => 'Blocked';

  @override
  String get simulatedTagOff => 'Simulated: behaviour off';

  @override
  String get simulatedTagStranger => 'Simulated: someone else\'s touch';

  @override
  String get simulatedTagTapPattern => 'Simulated: changed tap pattern';

  @override
  String get simulatedTagShaking => 'Simulated: a shaking hand';

  @override
  String get simulatedTagCoached => 'Simulated: someone is coaching';

  @override
  String pendingSummaryTitle(int count, String countText) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countText transfers are held',
      one: '1 transfer is held',
    );
    return '$_temp0';
  }

  @override
  String get pendingSummarySee => 'See ›';

  @override
  String get historyFilterHeld => 'Held';

  @override
  String get fraudDeskFactPrefix => 'Fact:';

  @override
  String get czNoEvidence => 'No evidence found';

  @override
  String czCountsNoEvidence(String ring) {
    return 'No evidence found · Ring $ring';
  }

  @override
  String get czCitedTxns => 'Transfers named in the summary';

  @override
  String get txnTypeReceived => 'Money received';

  @override
  String get behaviourModeLiveHelp => 'This phone\'s real touch is sent';

  @override
  String get behaviourModeOffHelp =>
      'Behaviour signal off: the server sees no behaviour';

  @override
  String get behaviourModeStrangerHelp =>
      'Simulated: someone else\'s touch; the server will hold';

  @override
  String get demoPreviewPlaying => 'Playing…';

  @override
  String get demoPreviewStop => 'Stop';

  @override
  String get approveNotConfirmedLine => 'Not confirmed by your trusted person';

  @override
  String get czStatusDegraded => 'Done, citations not verified';

  @override
  String get fnaTalk => 'Talk';

  @override
  String get fnaHearIt => 'Hear it';

  @override
  String get fnaHearStop => 'Stop';

  @override
  String get fnaStateConnecting => 'Connecting…';

  @override
  String get fnaStateListening => 'FNA is listening';

  @override
  String get fnaStateThinking => 'FNA is thinking…';

  @override
  String get fnaStateSpeaking => 'FNA is speaking';

  @override
  String get fnaStatePaused => 'Paused · Tap to talk';

  @override
  String get fnaPinStrip =>
      'Do not say your PIN or any code out loud, not even to FNA.';

  @override
  String get fnaNumberHidden =>
      'A number was hidden. Never tell anyone a code.';

  @override
  String get fnaMicRationale =>
      'FNA needs the microphone to talk with you. FNA listens only while this screen is open. It never hears your phone calls.';

  @override
  String get fnaMicTurnOn => 'Turn on microphone';

  @override
  String get fnaOpenSettings => 'Open settings';

  @override
  String get fnaTypeInstead => 'Type instead';

  @override
  String get fnaStop => 'Stop';

  @override
  String get fnaPause => 'Pause';

  @override
  String get fnaResume => 'Resume';

  @override
  String get fnaEnd => 'End';

  @override
  String get fnaVoiceDown =>
      'Voice is not working right now. Type your question and FNA will read the answer out.';

  @override
  String get fnaOffline =>
      'No internet. Pick a question below. The answers are on your phone.';

  @override
  String fnaCallCardTitle(String time) {
    return 'Suspicious call · $time';
  }

  @override
  String get fnaCallAskedFor => 'They asked for';

  @override
  String get fnaCallTheySaid => 'They said';

  @override
  String get fnaCallDoNow => 'What to do now';

  @override
  String get fnaCallNextTime => 'Next time';

  @override
  String get fnaCallHelpline => 'Call the helpline';

  @override
  String get fnaCallDoHangUp =>
      'If they call again, hang up. Do not send money or share any code.';

  @override
  String get fnaCallDoCareful => 'Be careful and do not hurry.';

  @override
  String get fnaSecretCard => 'Card number';

  @override
  String get fnaNoCallYet =>
      'No suspicious call was caught yet. If someone asks for a code, tell FNA what they said.';

  @override
  String get fnaQuickSummary => 'About the last call';

  @override
  String get fnaVoiceControls => 'Voice controls';

  @override
  String get fnaSecretSpoken =>
      'You said a number that looks like a code, so it was hidden. Never tell anyone a code or PIN, not even FNA.';

  @override
  String fnaHearItLabel(String text) {
    return 'Hear it: $text';
  }

  @override
  String fnaHearStopLabel(String text) {
    return 'Stop reading: $text';
  }

  @override
  String get fnaShowAll => 'Show all';

  @override
  String get fnaShowLess => 'Show less';
}
