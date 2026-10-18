import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/intervention/logic/reason_kind.dart';
import 'package:flutter_test/flutter_test.dart';

Reason r(String code, double w) =>
    Reason(code: code, weight: w, textBn: 'বাংলা', textEn: 'en');

void main() {
  test('of: every server code has its kind; unknown is other', () {
    expect(ReasonKind.of('ATO_BEHAVIOUR_MISMATCH'), ReasonKind.identity);
    expect(
      ReasonKind.of('ATO_BEHAVIOUR_MISMATCH_COLD_START'),
      ReasonKind.identity,
    );
    expect(ReasonKind.of('COACHING_SUSPECTED'), ReasonKind.coaching);
    expect(ReasonKind.of('DEST_MULE_RISK'), ReasonKind.mulePayee);
    expect(ReasonKind.of('NEW_PAYEE_ABOVE_P95'), ReasonKind.newPayeeAmount);
    expect(ReasonKind.of('CALL_ACTIVE_NON_CONTACT'), ReasonKind.callActive);
    expect(ReasonKind.of('SCREEN_SHARE_ACTIVE'), ReasonKind.screenShare);
    expect(ReasonKind.of('SIM_CHANGED_24H'), ReasonKind.simSwap);
    expect(ReasonKind.of('SCAM_CONVERSATION'), ReasonKind.scam);
    expect(ReasonKind.of('APP_SAFETY_BLOCK'), ReasonKind.appSafety);
    // The App Safety Check's CAUTION, which allows the payment.
    expect(ReasonKind.of('APP_SAFETY_CAUTION'), ReasonKind.appSafety);
    expect(ReasonKind.of('SOMETHING_NEW'), ReasonKind.other);
  });

  test('leading: the highest weight wins', () {
    expect(
      ReasonKind.leading([
        r('SCREEN_SHARE_ACTIVE', 0.4),
        r('ATO_BEHAVIOUR_MISMATCH', 1.0),
      ]),
      ReasonKind.identity,
    );
    expect(
      ReasonKind.leading([
        r('ATO_BEHAVIOUR_MISMATCH', 0.5),
        r('SCREEN_SHARE_ACTIVE', 0.9),
      ]),
      ReasonKind.screenShare,
    );
  });

  test('leading: ties go to the earlier kind in the enum order', () {
    expect(
      ReasonKind.leading([
        r('SCAM_CONVERSATION', 0.8),
        r('DEST_MULE_RISK', 0.8),
        r('ATO_BEHAVIOUR_MISMATCH', 0.8),
      ]),
      ReasonKind.identity,
    );
    expect(
      ReasonKind.leading([r('UNKNOWN', 0.8), r('SIM_CHANGED_24H', 0.8)]),
      ReasonKind.simSwap,
    );
  });

  test('leading: no reasons is null', () {
    expect(ReasonKind.leading(const []), isNull);
  });

  test('trigger prediction: identity and mule payee', () {
    expect(ReasonKind.identity.trigger, 'behaviour_mismatch');
    expect(ReasonKind.mulePayee.trigger, 'mule_payee');
    expect(ReasonKind.scam.trigger, isNull);
  });
}
