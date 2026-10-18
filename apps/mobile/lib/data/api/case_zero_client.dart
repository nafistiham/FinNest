/// Reads the Case Zero service directly (not through risk-mw): the
/// watch-list of payees under investigation.
library;

import 'dart:io';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/api/risk_api_client.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:dio/dio.dart';

/// Talks JSON to the Case Zero root (`AppEnv.caseZeroUrl`). The watch-list
/// is public demo data: no identity or auth headers are sent. Every outcome
/// is a contract model or an [ApiFailure].
class CaseZeroClient {
  CaseZeroClient(
    Dio dio,
    String baseUrl, {
    this.payeeRiskDeadline = const Duration(seconds: 3),
  }) : _dio = dio {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = payeeRiskDeadline
      ..responseType = ResponseType.plain
      ..headers[HttpHeaders.acceptHeader] = Headers.jsonContentType;
  }

  static const payeeRiskPath = '/api/payee-risk';

  final Dio _dio;

  /// Overall budget of [getPayeeRisk], connect included. A slow list is "no
  /// claim", never a reason to block a customer screen.
  final Duration payeeRiskDeadline;

  /// `GET {base}/api/payee-risk`.
  Future<PayeeRisk> getPayeeRisk() async {
    final json = await sendWithDeadline(
      (cancel) => _dio.get<String>(
        payeeRiskPath,
        cancelToken: cancel,
        options: Options(receiveTimeout: payeeRiskDeadline),
      ),
      payeeRiskDeadline,
    );
    return parseContract(json, PayeeRisk.fromJson);
  }
}

/// The three Case Zero calls the staff Fraud desk makes: the watch-list from the Case Zero host, and start / read a case
/// through risk-mw. One seam so widget tests can script every outcome.
abstract interface class CaseDeskApi {
  /// `GET {caseZero}/api/payee-risk`.
  Future<PayeeRisk> getPayeeRisk();

  /// `POST /v1/investigate`; 429 → [RateLimited], 502 →
  /// [InvestigatorUnavailable].
  Future<InvestigateResponse> postInvestigate(String acctId);

  /// `GET /v1/investigations/{caseId}`; 404 → [CaseNotFound].
  Future<CaseReport> getCase(String caseId);
}

/// [CaseDeskApi] over the app's clients: the watch-list straight from Case
/// Zero, the cases through the [RiskApi] (live or fake).
///
/// Case calls speak as [staffUser] (`X-Demo-User`, per call), never as the
/// signed-in customer persona, so an investigation is audited to staff and
/// stored under the staff key.
class LiveCaseDeskApi implements CaseDeskApi {
  const LiveCaseDeskApi({
    required this.watchList,
    required this.risk,
    this.staffUser = AppEnv.staffDemoUser,
  });

  final CaseZeroClient watchList;
  final RiskApi risk;

  /// The staff uid the desk's case calls carry.
  final String staffUser;

  @override
  Future<PayeeRisk> getPayeeRisk() => watchList.getPayeeRisk();

  @override
  Future<InvestigateResponse> postInvestigate(String acctId) =>
      risk.postInvestigate(acctId, asUser: staffUser);

  @override
  Future<CaseReport> getCase(String caseId) =>
      risk.getCase(caseId, asUser: staffUser);
}
