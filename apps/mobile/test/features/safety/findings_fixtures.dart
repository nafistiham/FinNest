/// A findings response with one finding of most kinds, for the search,
/// filter, sort and CTA tests.
library;

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';

import 'safety_test_support.dart';

const flashApp = InstalledApp(
  package: 'com.demo.flash',
  label: 'Flashlight Pro',
  installer: 'com.demo.dropper',
  version: '2.0',
);

const dropperFinding = Finding(
  package: 'com.demo.flash',
  signal: 'DROPPER_INSTALLED',
  severity: 'high',
  evidence: 'installer=com.demo.dropper',
  explanationBn: 'অচেনা একটি অ্যাপ এটি বসিয়েছে।',
  explanationEn: 'An unknown app installed this one.',
  titleBn: 'অচেনা অ্যাপ দিয়ে ইনস্টল',
  titleEn: 'Installed by a dropper',
);

const overlayFinding = Finding(
  package: 'com.demo.flash',
  signal: 'OVERLAY_CAPABLE',
  severity: 'medium',
  evidence: 'SYSTEM_ALERT_WINDOW',
  explanationBn: 'এটি অন্য অ্যাপের উপরে পর্দা দেখাতে পারে।',
  explanationEn: 'It can show a screen on top of other apps.',
  titleBn: 'স্ক্রিনের উপরে দেখায়',
  titleEn: 'Draws over apps',
);

const rootedFinding = Finding(
  package: '',
  signal: 'DEVICE_ROOTED',
  severity: 'high',
  evidence: 'su binary present',
  explanationBn: 'এই ফোনের সুরক্ষা খুলে ফেলা হয়েছে।',
  explanationEn: 'This phone\'s protection has been removed.',
  titleBn: 'ফোন রুট করা',
  titleEn: 'Phone rooted',
  scope: Finding.scopeDevice,
);

const capturingFinding = Finding(
  package: '',
  signal: 'INTEGRITY_CAPTURING',
  severity: 'high',
  evidence: 'appAccessRiskVerdict=KNOWN_CAPTURING',
  explanationBn: 'কেউ এখন আপনার পর্দা দেখছে।',
  explanationEn: 'Someone is watching your screen now.',
  titleBn: 'স্ক্রিন রেকর্ড হচ্ছে',
  titleEn: 'Screen is being captured',
  scope: Finding.scopeDevice,
);

const richFindings = <Finding>[
  blockFinding,
  dropperFinding,
  overlayFinding,
  mediumFinding,
  rootedFinding,
  deviceFinding,
  capturingFinding,
];

const richLabels = <String, String>{
  'com.demo.takanow': 'TakaNow',
  'com.demo.flash': 'Flashlight Pro',
  'com.example.bank': 'Bank',
};

const richBundle = AppSafetyBundle(
  installedApps: [realApp, flashApp],
  device: DeviceState(devOptions: true, rooted: true),
);

const richResponse = AppSafetyResponse(
  verdict: SafetyVerdict.block,
  riskScore: 0.97,
  findings: richFindings,
  recommendedAction: 'uninstall',
  appsToUninstall: ['com.demo.takanow'],
  userMessageBn: 'TakaNow অ্যাপটি বিপজ্জনক। এখনই আনইনস্টল করুন।',
  userMessageEn: 'TakaNow is dangerous. Uninstall it now.',
  simulatedVerdict: true,
  modelVersion: 'test',
  attestation: 'device',
  resolution: 'UNINSTALL_AND_RECHECK',
  recheckLiftsBlock: true,
  uninstallTargets: [takaNowTarget],
  checkId: 'chk-rich',
);

/// A finding of [signal] on an app (or the device), for the mapping table.
Finding appFinding(
  String signal, {
  String package = 'com.demo.x',
  String scope = Finding.scopeApp,
  String severity = 'medium',
}) => Finding(
  package: package,
  signal: signal,
  severity: severity,
  evidence: '',
  explanationBn: 'ব্যাখ্যা',
  explanationEn: 'Explanation',
  titleBn: 'শিরোনাম',
  titleEn: 'Title',
  scope: scope,
);
