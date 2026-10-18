/// Fully populated instances of every contract model (no nullable field left
/// null), shared by the parity and round-trip tests.
library;

import 'package:bhorosha/data/contracts/contracts.dart';

const deviceInfo = DeviceInfo(
  model: 'Pixel 6',
  os: 'Android 14',
  rooted: false,
  simSerialHash: 'ab12',
  simChangedAt: '2026-10-15T10:00:00Z',
);

const deviceSignals = DeviceSignals(
  callState: CallState.offhook,
  audioMode: 'in_call',
  subscriptionChangedHours: 3.5,
  accessibilityServices: ['com.example.a11y/.Service'],
  screenCapture: true,
  screenRecording: false,
  obscuredTouch: true,
);

final behaviour = Behaviour(features: List<double>.generate(55, (i) => i / 10));

final signalsRequest = SignalsRequest(
  sessionId: 'sess_1',
  device: deviceInfo,
  signals: deviceSignals,
  integrityToken: 'tok',
  behaviour: behaviour,
  simulated: ['call_state', 'screen_capture'],
);

const signalsResponse = SignalsResponse(stored: true);

const txn = Txn(
  type: TxnType.sendMoney,
  amountBdt: 7900,
  toAccount: '017XXXXX412',
  isNewPayee: true,
  txnId: 'txn_1',
);

const demoFlags = DemoFlags(
  simSwap: true,
  callActive: true,
  screenShare: false,
  callerInContacts: false,
  appSafetyVerdict: SafetyVerdict.caution,
  inboundMuleScore: 0.2,
  scamScore: 0.85,
);

const scoreRequest = ScoreRequest(
  userId: 'rina',
  sessionId: 'sess_1',
  txn: txn,
  demoFlags: demoFlags,
  appSafety: appSafetyContext,
);

/// The same request without the app-safety block, as the app sends it until
/// `RISK_MW_APP_SAFETY_IN_SCORE` is on.
const scoreRequestBare = ScoreRequest(
  userId: 'rina',
  sessionId: 'sess_1',
  txn: txn,
  demoFlags: demoFlags,
);

const reason = Reason(
  code: 'SCAM_CONVERSATION',
  weight: 0.9,
  textBn: 'কলে কেউ আপনার ওটিপি চেয়েছে।',
  textEn: 'Someone on the call asked for your OTP.',
);

const actionItem = ActionItem(
  type: 'delay_new_payee',
  params: {'minutes': 30, 'ratio': 0.5, 'label': 'x', 'force': true},
);

const scoreResponse = ScoreResponse(
  decision: Decision.hold,
  riskScore: 0.91,
  band: Band.critical,
  reasons: [reason],
  actions: [
    actionItem,
    ActionItem(type: 'trusted_contact_check'),
  ],
  modelVersion: 'rules-v1',
  identitySource: 'demo',
  payeeScoreBefore: 0.41,
  payeeScoreWithThisTransfer: 0.87,
  payeeMovedFeature: 'inbound_count_24h',
  payeeScoreAsOf: '2026-11-03T10:00:00+00:00',
);

const installedApp = InstalledApp(
  package: 'com.takanow.app',
  label: 'TakaNow',
  installer: 'com.android.packageinstaller',
  version: '1.2.3',
  permissions: ['android.permission.BIND_ACCESSIBILITY_SERVICE'],
  hasAccessibilityService: true,
  accessibilityEnabled: true,
  targetSdk: 33,
  firstInstall: '2026-10-10T08:00:00Z',
  hasNotificationListener: true,
  hasHceService: true,
  isDefaultSmsApp: true,
  launcherIconHidden: true,
  installerDeclaresInstallPackages: true,
);

const deviceState = DeviceState(
  overlayHolders: ['com.takanow.app'],
  deviceAdmins: ['com.corp.mdm'],
  devOptions: true,
  adb: true,
  rooted: false,
  playProtect: true,
  sdkInt: 34,
  defaultSmsPackage: 'com.google.android.apps.messaging',
  nfcDefaultPaymentPackage: 'com.google.android.gms',
);

const appSafetyRequest = AppSafetyRequest(
  installedApps: [installedApp],
  device: deviceState,
  integrityToken: 'tok',
);

const finding = Finding(
  package: 'com.takanow.app',
  signal: 'accessibility_sideloaded',
  severity: 'high',
  evidence: 'BIND_ACCESSIBILITY_SERVICE, sideloaded',
  explanationBn: 'এই অ্যাপ আপনার স্ক্রিন পড়তে পারে।',
  explanationEn: 'This app can read your screen.',
  titleBn: 'স্ক্রিন পড়ার অনুমতি',
  titleEn: 'Screen-reading permission',
  scope: Finding.scopeApp,
);

const uninstallTarget = UninstallTarget(
  package: 'com.takanow.app',
  label: 'TakaNow',
  primarySignal: 'accessibility_sideloaded',
  deepLink: 'package:com.takanow.app',
);

const appSafetyResponse = AppSafetyResponse(
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  findings: [finding],
  recommendedAction: 'uninstall',
  appsToUninstall: ['com.takanow.app'],
  userMessageBn: 'একটি বিপজ্জনক অ্যাপ পাওয়া গেছে।',
  userMessageEn: 'A dangerous app was found.',
  simulatedVerdict: true,
  modelVersion: 'appsafety-v2',
  agreesWithClassifier: false,
  disagreementReason: 'judge saw a benign installer',
  attestation: 'strong',
  resolution: 'UNINSTALL_AND_RECHECK',
  recheckLiftsBlock: true,
  uninstallTargets: [uninstallTarget],
  checkId: 'chk_1',
  validUntil: '2026-10-17T08:00:00Z',
);

/// What the phone sends with the score, built from [appSafetyResponse].
const appSafetyContext = AppSafetyContext(
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  findings: [
    AppSafetyFinding(
      package: 'com.takanow.app',
      signal: 'accessibility_sideloaded',
      severity: 'high',
      scope: Finding.scopeApp,
    ),
  ],
  appsToUninstall: ['com.takanow.app'],
  recommendedAction: 'uninstall',
  resolution: 'UNINSTALL_AND_RECHECK',
  attestation: 'strong',
  simulatedVerdict: true,
  modelVersion: 'appsafety-v2',
  checkId: 'chk_1',
  validUntil: '2026-10-17T08:00:00Z',
);

const scoreRequestWithAppSafety = ScoreRequest(
  userId: 'rina',
  sessionId: 'sess_1',
  txn: txn,
  appSafety: appSafetyContext,
);

const appSafetyLatest = AppSafetyLatest(
  uid: 'rina',
  known: true,
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  flaggedPackages: ['com.takanow.app'],
  attestation: 'strong',
  checkedAt: '2026-10-16T08:00:00Z',
  validUntil: '2026-10-17T08:00:00Z',
  source: 'server',
  facts: ['FAKE_LOAN_APP'],
);

const demoIntegrityRequest = DemoIntegrityRequest(
  installedApps: [installedApp],
  device: deviceState,
  appsDetected: ['com.takanow.app'],
  playProtectVerdict: 'POSSIBLE_RISK',
  appRecognition: DemoIntegrityRequest.appRecognitionUnevaluated,
  deviceRecognition: ['MEETS_BASIC_INTEGRITY'],
  bound: false,
);

const demoIntegrityResponse = DemoIntegrityResponse(
  integrityToken: 'eyJ.demo.token',
  bundleHash: 'ab12cd34',
  expiresInS: 300,
);

const interveneRequest = InterveneRequest(
  userId: 'rina',
  trigger: 'call_active',
  txn: txn,
  transcriptSnippet: 'আপনার ওটিপি বলুন',
  sessionId: 'sess_1',
  interventionId: 'iv-0123456789abcdef',
);

const interveneResponse = InterveneResponse(
  intervene: true,
  scriptBn: 'আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন।',
  scriptEn: 'This is your FinNest Assistant. You are on a call right now.',
  audioAssetId: 'apa_hold_call_active',
  ui: UiMode.fullscreen,
  actions: [actionItem],
  cooldownS: 120,
  interventionId: 'iv-fedcba9876543210',
  identitySource: 'demo',
);

const turn = Turn(speaker: Turn.callerSpeaker, text: 'ওটিপি বলুন', ts: 12.5);

const scamTurnRequest = ScamTurnRequest(
  sessionId: 'sess_1',
  turns: [
    turn,
    Turn(speaker: Turn.userSpeaker, text: 'কেন?', ts: 14),
  ],
  pendingAction: 'send_money',
  amountBdt: 7900,
);

const scamTurnResponse = ScamTurnResponse(
  scamType: 'otp_request',
  urgency: 'high',
  requestedSecret: 'otp',
  confidence: 0.85,
  evidenceQuote: 'ওটিপি বলুন',
  recommendedAction: 'hold',
  rollingScore: 0.85,
);

const apaContext = ApaContext(lastRisk: 0.91, screen: 'pin_pad');

const apaTurnRequest = ApaTurnRequest(
  userId: 'rina',
  textBn: 'কী হলো?',
  context: apaContext,
);

const apaTurnResponse = ApaTurnResponse(
  replyBn: 'আপনার লেনদেন আটকে রাখা হয়েছে।',
  replyEn: 'Your transaction is on hold.',
  toolCalls: ['get_last_risk'],
);

const trustedContactRequest = TrustedContactRequest(
  interventionId: 'int_1',
  contactUid: 'rafiq',
);

const trustedContactResponse = TrustedContactResponse(
  requestId: 'req_1',
  expiresAt: '2026-10-16T12:00:00Z',
);

const trustedContactDecision = TrustedContactDecision(
  requestId: 'req_1',
  status: TrustedContactDecision.statusApproved,
  decidedBy: 'rafiq',
  contactVerified: true,
);

// --- Case Zero -----------------------------------------------------

const investigateResponse = InvestigateResponse(
  caseId: 'CZ-0002',
  streamUrl: '/v1/investigations/CZ-0002/events',
);

const caseEvidence = CaseEvidence(
  rowId: 'txn_011308',
  claim: 'Seed acct_01070 forwarded received funds rapidly within minutes.',
);

const caseReport = CaseReport(
  caseId: 'CZ-0002',
  acctId: 'acct_01070',
  status: CaseStatus.done,
  summaryEn: 'Victim acct_rina transferred Tk 7,900 to acct_01070.',
  summaryBn: 'ভুক্তভোগী acct_rina থেকে ৭,৯০০ টাকা।',
  evidence: [caseEvidence],
  ring: ['acct_01070', 'acct_00036'],
  confidence: 0.8697,
  recommendedAction: 'freeze',
  modelVersion: 'mule-lgbm-0.1+gemini-3.8-flash',
);
