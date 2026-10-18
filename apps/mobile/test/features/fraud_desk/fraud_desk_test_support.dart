/// Fixtures and fakes of the Fraud desk tests. Not a test file.
library;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/router.dart' show routeObserverProvider;
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/case_zero_client.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/case_link_repo.dart';
import 'package:bhorosha/features/fraud_desk/logic/fraud_desk_providers.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final deskNow = DateTime.utc(2026, 10, 17, 8);

const watchList = PayeeRisk(
  version: 'payee-risk/1',
  generatedAt: '2026-10-17T04:47:08+00:00',
  payees: [
    PayeeRiskEntry(
      acctId: 'acct_01070',
      status: 'suspected',
      caseId: 'CZ-0002',
      role: 'mule_L1',
      facts: ['Forwarded received funds within minutes.'],
    ),
    PayeeRiskEntry(
      acctId: 'acct_01341',
      status: 'confirmed',
      caseId: 'CZ-0002',
      role: 'controller',
      analystApproved: true,
    ),
    PayeeRiskEntry(acctId: 'acct_00036', status: 'cleared', role: 'mule_L2'),
    PayeeRiskEntry(acctId: 'acct_till_AG-0192', status: 'odd', role: 'x'),
  ],
);

CaseReport report({
  String caseId = 'CZ-0002',
  String acctId = 'acct_01070',
  CaseStatus status = CaseStatus.done,
  String action = 'freeze',
  String modelVersion = 'mule-lgbm-0.1+gemini',
  String summaryEn = 'The seed forwarded funds rapidly.',
  String summaryBn = 'অ্যাকাউন্টটি দ্রুত টাকা সরিয়েছে।',
  List<CaseEvidence>? evidence,
}) => CaseReport(
  caseId: caseId,
  acctId: acctId,
  status: status,
  summaryEn: summaryEn,
  summaryBn: summaryBn,
  evidence:
      evidence ??
      (status == CaseStatus.done
          ? const [
              CaseEvidence(rowId: 'txn_011308', claim: 'Rapid forwarding.'),
            ]
          : const []),
  ring: status == CaseStatus.done
      ? const ['acct_01070', 'acct_01341', 'acct_00036']
      : const [],
  confidence: status == CaseStatus.done ? 0.8697 : 0.0,
  recommendedAction: action,
  modelVersion: modelVersion,
);

/// [CaseDeskApi] with a scripted watch-list and the cases on a
/// [FakeRiskApi] (so the fake's `postInvestigate` / `getCase` are used).
class FakeCaseDesk implements CaseDeskApi {
  FakeCaseDesk({PayeeRisk? list}) : list = list ?? watchList;

  final FakeRiskApi risk = FakeRiskApi();
  PayeeRisk list;
  Object? listFailure;
  int listCalls = 0;

  @override
  Future<PayeeRisk> getPayeeRisk() async {
    listCalls++;
    final f = listFailure;
    if (f != null) throw f;
    return list;
  }

  @override
  Future<InvestigateResponse> postInvestigate(String acctId) =>
      risk.postInvestigate(acctId);

  @override
  Future<CaseReport> getCase(String caseId) => risk.getCase(caseId);
}

/// Everything the desk reads, faked.
class DeskHarness {
  DeskHarness._(SharedPreferences prefs)
    : links = CaseLinkRepo(prefs: Future.value(prefs)),
      clock = FakeClock(deskNow);

  /// Call inside the test body. The preferences are read in the real zone
  /// (`runAsync`); the repo and its futures are made in the test's zone,
  /// where a future born in the real zone would never resolve.
  static Future<DeskHarness> create(
    WidgetTester tester, [
    Map<String, Object> values = const {},
  ]) async {
    final prefs = await tester.runAsync(() {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    });
    return DeskHarness._(prefs!);
  }

  final FakeCaseDesk desk = FakeCaseDesk();
  final CaseLinkRepo links;
  final FakeClock clock;
  final List<Duration> waited = [];

  /// The app's route observer, so a test navigator can report coverage.
  final RouteObserver<ModalRoute<void>> routes = RouteObserver();

  List<Override> get overrides => [
    caseDeskApiProvider.overrideWithValue(desk),
    caseLinkRepoProvider.overrideWithValue(links),
    clockProvider.overrideWithValue(clock),
    fraudDeskUidProvider.overrideWithValue('rina'),
    routeObserverProvider.overrideWithValue(routes),
    fraudDeskDelayProvider.overrideWithValue((d) async => waited.add(d)),
    // The bundled personas' masked numbers (assets load outside the test
    // zone), so a named account masks to its number.
    knownPhonesProvider.overrideWith(
      (ref) async => const {'acct_rina': '017XXXXX412'},
    ),
  ];
}

/// Pumps [child] as the app's home with the app theme at [width] dp.
Future<void> pumpDesk(
  WidgetTester tester,
  DeskHarness h,
  Widget child, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('bn'),
  double width = 412,
  double height = 915,
}) async {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = Size(width * 3, height * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides,
      child: MaterialApp(
        theme: buildTheme(brightness, locale: locale),
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: child,
      ),
    ),
  );
}

/// A few frames: lets the futures resolve without waiting for endless
/// animations (skeletons, the running pulse) to settle.
Future<void> frames(WidgetTester tester, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
