/// Riverpod entry point of the API layer.
library;

import 'package:bhorosha/data/api/risk_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The [RiskApi] the rest of the app reads.
///
/// Deliberately unimplemented here: identity is only known once Task 3's
/// Firebase bootstrap has run, so `lib/data/providers.dart` overrides this in
/// `ProviderScope(overrides: [...])`, for example
///
/// ```dart
/// riskApiProvider.overrideWith(
///   (ref) => RiskApiClient(
///     baseUrl: AppEnv.riskApiBaseUrl,
///     identity: ref.watch(identityHeadersProvider), // Demo or Bearer
///   ),
/// )
/// ```
///
/// Tests and previews override it with `FakeRiskApi()` instead.
final riskApiProvider = Provider<RiskApi>(
  (ref) => throw UnimplementedError(
    'riskApiProvider is overridden in lib/data/providers.dart (Task 3) '
    'once identity headers are known; tests use FakeRiskApi.',
  ),
);
