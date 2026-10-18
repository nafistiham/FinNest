import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/data/contracts/score.dart';
import 'package:bhorosha/features/intervention/logic/action_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppLocalizations bn;
  late AppLocalizations en;

  setUpAll(() async {
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('interpolates minutes as Bangla digits', () {
    // hold_transaction names the outcome, not the analyst window: no number
    // on the button.
    const a = ActionItem(type: 'hold_transaction', params: {'minutes': 60});
    expect(ActionLabels.labelFor(bn, a), 'টাকা আমার কাছেই থাকুক');
    expect(
      ActionLabels.labelFor(
        bn,
        const ActionItem(type: 'delay_new_payee', params: {'minutes': 60}),
      ),
      contains('৬০'),
    );
    expect(
      ActionLabels.labelFor(
        bn,
        const ActionItem(type: 'freeze_pin_reset', params: {'minutes': 120}),
      ),
      'পিন বদল ১২০ মিনিট বন্ধ রাখুন',
    );
    expect(
      ActionLabels.labelFor(
        bn,
        const ActionItem(
          type: 'trusted_contact_check',
          params: {'expires_in_minutes': 30},
        ),
      ),
      'আপনজনের মত নিন (৩০ মিনিট)',
    );
  });

  test('keeps Latin digits in English', () {
    const a = ActionItem(type: 'hold_transaction', params: {'minutes': 60});
    expect(ActionLabels.labelFor(en, a), 'Keep my money with me');
  });

  test('accepts doubles and strings from the wire', () {
    expect(
      ActionLabels.labelFor(
        bn,
        const ActionItem(type: 'delay_new_payee', params: {'minutes': 60.0}),
      ),
      '৬০ মিনিট পরে পাঠান',
    );
    expect(
      ActionLabels.labelFor(
        bn,
        const ActionItem(type: 'delay_new_payee', params: {'minutes': '45'}),
      ),
      '৪৫ মিনিট পরে পাঠান',
    );
  });

  test('never invents a number when the param is missing', () {
    expect(
      ActionLabels.labelFor(bn, const ActionItem(type: 'delay_new_payee')),
      '— মিনিট পরে পাঠান',
    );
  });

  test('labels the parameterless types', () {
    expect(
      ActionLabels.labelFor(bn, const ActionItem(type: 'step_up_verification')),
      'আবার যাচাই করুন',
    );
    expect(
      ActionLabels.labelFor(bn, const ActionItem(type: 'block_transaction')),
      'লেনদেন বাতিল করুন',
    );
    expect(
      ActionLabels.labelFor(bn, const ActionItem(type: 'ask_apa')),
      'এফএনএ-কে জিজ্ঞাসা করুন',
    );
  });

  test(
    'unknown types get the generic label; the raw type stays off screen',
    () {
      const a = ActionItem(type: 'teleport_funds', params: {'to': 'mars'});
      expect(ActionLabels.labelFor(bn, a), bn.actionUnknown);
      expect(ActionLabels.labelFor(en, a), 'Other action');
      expect(ActionLabels.isKnown('teleport_funds'), isFalse);
      expect(ActionLabels.isKnown('hold_transaction'), isTrue);
    },
  );
}
