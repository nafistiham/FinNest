import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'samples.dart' as s;

/// `ScoreRequest.app_safety`, the App Safety Check result the phone
/// sends with the score, is the important data points of the check, never
/// the user-facing copy.
void main() {
  test('fromResponse keeps the data points and drops the copy', () {
    final ctx = AppSafetyContext.fromResponse(s.appSafetyResponse);
    expect(ctx, s.appSafetyContext);
    expect(ctx.source, AppSafetyContext.sourceCheck);
    final json = ctx.toJson();
    expect(json.keys, isNot(contains('user_message_bn')));
    expect(json.keys, isNot(contains('uninstall_targets')));
    expect(json['findings'], [
      {
        'package': 'com.takanow.app',
        'signal': 'accessibility_sideloaded',
        'severity': 'high',
        'scope': 'app',
      },
    ]);
  });

  test('fromLatest carries the standing verdict with its source', () {
    final ctx = AppSafetyContext.fromLatest(s.appSafetyLatest)!;
    expect(ctx.verdict, SafetyVerdict.block);
    expect(ctx.riskScore, 0.97);
    expect(ctx.appsToUninstall, ['com.takanow.app']);
    expect(ctx.checkedAt, '2026-10-16T08:00:00Z');
    expect(ctx.source, AppSafetyContext.sourceLatest);
    expect(ctx.findings, isEmpty);
  });

  test('an unknown standing verdict gives nothing to send', () {
    expect(
      AppSafetyContext.fromLatest(
        const AppSafetyLatest(uid: 'rina', known: false),
      ),
      isNull,
    );
  });

  test('the score request leaves app_safety out when there is none', () {
    expect(s.scoreRequestBare.toJson().keys, isNot(contains('app_safety')));
    expect(
      s.scoreRequestWithAppSafety.toJson()['app_safety'],
      s.appSafetyContext.toJson(),
    );
  });
}
