import 'dart:io';

import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/pay/logic/billers.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_ledger.dart';
import 'package:bhorosha/features/pay/logic/pay_rules.dart';
import 'package:bhorosha/features/pay/pay_routes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _rina = UserProfile(
  uid: 'rina',
  nameBn: 'রিনা আক্তার',
  nameEn: 'Rina Akter',
  phoneMasked: '017XXXXX412',
  persona: Persona.rina,
  trustedContactUid: 'rafiq',
  p95SendBdt: 5000,
  acctId: 'acct_rina',
  balanceBdt: 9841,
);

void main() {
  group('PayKind', () {
    test('slugs round-trip; anything else is null', () {
      for (final k in PayKind.values) {
        expect(PayKind.parse(k.slug), k);
      }
      expect(PayKind.parse('loans'), isNull);
      expect(PayKind.parse(null), isNull);
      expect(PayKind.cashOut.slug, 'cashout');
    });

    test('only send and cash out are scored; cash in has no PIN', () {
      expect(PayKind.values.where((k) => k.scored), [
        PayKind.send,
        PayKind.cashOut,
      ]);
      expect(PayKind.cashIn.usesPin, isFalse);
      expect(PayKind.values.map((k) => k.ledgerType), [
        'send_money',
        'cash_out',
        'cash_in',
        'recharge',
        'payment',
        'dps_deposit',
      ]);
      // DPS: PIN, a fixed amount (the plan's instalment), not scored.
      expect(PayKind.dps.usesPin, isTrue);
      expect(PayKind.dps.fixedAmount, isTrue);
      expect(PayKind.parse('dps'), PayKind.dps);
      expect(PayPaths.beforePin(PayKind.dps), PayPaths.savings);
    });
  });

  group('PayRules', () {
    test('cash-out fee is ceil(1.5 %), zero elsewhere', () {
      expect(PayRules.feeFor(PayKind.cashOut, 2000), 30);
      expect(PayRules.feeFor(PayKind.cashOut, 50), 1);
      expect(PayRules.feeFor(PayKind.cashOut, 1001), 16);
      expect(PayRules.feeFor(PayKind.cashOut, 0), 0);
      expect(PayRules.feeFor(PayKind.send, 2000), 0);
    });

    test('amount checks per kind (2.2 table)', () {
      expect(PayRules.checkAmount(PayKind.send, 0), AmountCheck.empty);
      expect(PayRules.checkAmount(PayKind.send, 1), AmountCheck.ok);
      expect(PayRules.checkAmount(PayKind.cashOut, 49), AmountCheck.belowMin);
      expect(PayRules.checkAmount(PayKind.cashOut, 50), AmountCheck.ok);
      expect(PayRules.checkAmount(PayKind.recharge, 9), AmountCheck.outOfRange);
      expect(
        PayRules.checkAmount(PayKind.recharge, 1001),
        AmountCheck.outOfRange,
      );
      expect(PayRules.checkAmount(PayKind.recharge, 1000), AmountCheck.ok);
      expect(PayRules.enforceBalance, isFalse);
    });

    test('four quick amounts per amount-step kind; 7,900 stays on send', () {
      expect(PayRules.quickAmounts(PayKind.send), [500, 1000, 5000, 7900]);
      expect(PayRules.quickAmounts(PayKind.cashOut), hasLength(4));
      expect(PayRules.quickAmounts(PayKind.recharge), [50, 100, 200, 500]);
    });

    test('phone numbers: normalise, validate, group', () {
      expect(PayRules.normalisePhone('+880 1712-345678'), '01712345678');
      expect(PayRules.normalisePhone('8801712345678'), '01712345678');
      expect(PayRules.checkPhone('0171234567'), PhoneCheck.incomplete);
      expect(PayRules.checkPhone('01712345678'), PhoneCheck.valid);
      expect(PayRules.checkPhone('01212345678'), PhoneCheck.invalid);
      expect(PayRules.checkPhone('02712345678'), PhoneCheck.invalid);
      expect(PayRules.groupPhone('01712345678'), '01712-345678');
      expect(PayRules.groupPhone('019XXXXX881'), '019XX-XXX881');
      expect(PayRules.groupPhone('0171'), '0171');
      expect(PayRules.agentMasked('AG-0027'), '017XXXXX027');
    });

    test('cash-in codes are FN- (FinNest) plus four unambiguous characters; '
        'the old BH- prefix is gone', () {
      expect(PayRules.cashInCodePrefix, 'FN');
      for (var i = 0; i < 50; i++) {
        final code = PayRules.newCashInCode();
        expect(code, matches(RegExp(r'^FN-[2-9A-HJ-NP-Z]{4}$')));
        expect(code, isNot(startsWith('BH')));
      }
    });
  });

  test('operators by prefix', () {
    expect(Operator.forNumber('017XXXXX412'), Operator.a);
    expect(Operator.forNumber('01312345678'), Operator.a);
    expect(Operator.forNumber('018'), Operator.b);
    expect(Operator.forNumber('016'), Operator.e);
    expect(Operator.forNumber('019'), Operator.c);
    expect(Operator.forNumber('014'), Operator.c);
    expect(Operator.forNumber('015'), Operator.d);
    expect(Operator.forNumber('01'), isNull);
  });

  test('billers.json: three billers with account lengths and amounts', () {
    final billers = BillerCatalog.parse(
      File(BillerCatalog.path).readAsStringSync(),
    );
    expect(billers.map((b) => b.id), ['desco', 'wasa', 'titas']);
    expect(billers.map((b) => b.accountDigits), [8, 10, 9]);
    expect(billers.map((b) => b.amountBdt), [1240, 615, 1080]);
    final bill = Bill(biller: billers.first, account: '12345678');
    expect(bill.accountGrouped, '1234 5678');
    expect(bill.acctId, 'biller_desco_12345678');
  });

  group('PayLedger.rowFor', () {
    final ts = DateTime.utc(2026, 10, 17, 6);
    PayIntent intent(PayKind k) => PayIntent(kind: k, sessionId: 's');

    test('send: payee name, debit of the amount', () {
      final row = PayLedger.rowFor(
        intent(PayKind.send).copyWith(
          counterparty: const Counterparty(acctId: 'acct_rahima', nameBn: 'মা'),
          amountBdt: 5000,
        ),
        _rina,
        txnId: 't1',
        ts: ts,
        status: LedgerStatus.done,
      );
      expect(row.type, 'send_money');
      expect(row.toAcct, 'acct_rahima');
      expect(row.amountBdt, 5000);
      expect(row.counterpartyNameBn, 'মা');
      expect(row.isDebitFor('acct_rina'), isTrue);
    });

    test('cash out: amount + fee to the agent till, generic name', () {
      final row = PayLedger.rowFor(
        intent(PayKind.cashOut).copyWith(
          counterparty: const Counterparty(acctId: 'AG-0027', nameBn: 'এজেন্ট'),
          amountBdt: 2000,
          feeBdt: 30,
        ),
        _rina,
        txnId: 't2',
        ts: ts,
        status: LedgerStatus.done,
      );
      expect(row.type, 'cash_out');
      expect(row.amountBdt, 2030);
      expect(row.toAcct, 'AG-0027');
      expect(row.channel, 'agent');
      expect(row.counterpartyNameBn, 'এজেন্ট ক্যাশ আউট');
    });

    test('recharge: operator (Bangla name) and the masked number in ASCII '
        'digits; the English form uses the operator\'s English name', () {
      final row = PayLedger.rowFor(
        intent(PayKind.recharge).copyWith(
          counterparty: const Counterparty(
            acctId: 'mob_017XXXXX412',
            nameBn: 'রিনা',
            subtitle: '017XXXXX412',
          ),
          amountBdt: 100,
          operator: Operator.a,
        ),
        _rina,
        txnId: 't3',
        ts: ts,
        status: LedgerStatus.done,
      );
      expect(row.type, 'recharge');
      expect(row.toAcct, 'mob_017XXXXX412');
      expect(row.counterpartyNameBn, 'অপারেটর ক · 017XX-XXX412');
      expect(
        PayLedger.nameEnFor(
          intent(PayKind.recharge).copyWith(
            counterparty: const Counterparty(
              acctId: 'mob_017XXXXX412',
              nameBn: 'রিনা',
              subtitle: '017XXXXX412',
            ),
            operator: Operator.a,
          ),
        ),
        'Operator A · 017XX-XXX412',
      );
    });

    test('bill: payment row named after the bill', () {
      final billers = BillerCatalog.parse(
        File(BillerCatalog.path).readAsStringSync(),
      );
      final bill = Bill(biller: billers.first, account: '12345678');
      final row = PayLedger.rowFor(
        intent(PayKind.bill).copyWith(
          bill: bill,
          counterparty: Counterparty(acctId: bill.acctId, nameBn: 'ডেসকো'),
          amountBdt: 1240,
        ),
        _rina,
        txnId: 't4',
        ts: ts,
        status: LedgerStatus.done,
      );
      expect(row.type, 'payment');
      expect(row.toAcct, 'biller_desco_12345678');
      expect(row.counterpartyNameBn, 'ডেসকো বিদ্যুৎ বিল');
    });

    test('cash in: a credit from the code, requested', () {
      final row = PayLedger.rowFor(
        intent(PayKind.cashIn).copyWith(amountBdt: 1000),
        _rina,
        txnId: 't5',
        ts: ts,
        status: LedgerStatus.requested,
        cashInCode: 'BH-4K7Q',
      );
      expect(row.type, 'cash_in');
      expect(row.fromAcct, 'cashin_BH-4K7Q');
      expect(row.toAcct, 'acct_rina');
      expect(row.isCreditFor('acct_rina'), isTrue);
      expect(row.isRequestedCashIn, isTrue);
      expect(row.counterpartyNameBn, 'এজেন্ট ক্যাশ ইন');
    });
  });

  test('recent agents: distinct cash-out tills, newest first, two at most', () {
    LedgerTxn out(String id, String to) => LedgerTxn(
      txnId: id,
      ts: DateTime.utc(2026),
      type: 'cash_out',
      amountBdt: 100,
      fromAcct: 'acct_rina',
      toAcct: to,
    );
    final agents = recentAgents([
      out('a', 'AG-0027'),
      out('b', 'AG-0027'),
      out('c', 'AG-0011'),
      out('d', 'AG-0005'),
    ], 'acct_rina');
    expect(agents.map((a) => a.acctId), ['AG-0027', 'AG-0011']);
    expect(agents.first.subtitle, '017XXXXX027');
    expect(agents.first.isSaved, isTrue);
  });

  group('routes', () {
    test('legacy /send paths map onto /pay/send, query kept', () {
      expect(payLegacyRedirect(Uri.parse('/send')), '/pay/send');
      expect(payLegacyRedirect(Uri.parse('/send/pin')), '/pay/send/pin');
      expect(
        payLegacyRedirect(Uri.parse('/send/result?state=done&amount=5')),
        '/pay/send/result?state=done&amount=5',
      );
      expect(payLegacyRedirect(Uri.parse('/home')), isNull);
      expect(payLegacyRedirect(Uri.parse('/sending')), isNull);
    });

    test('PayPaths build every step', () {
      expect(PayPaths.start(PayKind.cashOut), '/pay/cashout');
      expect(PayPaths.amount(PayKind.recharge), '/pay/recharge/amount');
      expect(PayPaths.beforePin(PayKind.bill), '/pay/bill/confirm');
      expect(PayPaths.beforePin(PayKind.send), '/pay/send/amount');
      expect(PayPaths.code(PayKind.cashIn), '/pay/cashin/code');
      expect(
        PayPaths.result(
          PayKind.send,
          state: 'held',
          amount: 7900,
          banner: true,
          intervention: 'int_1',
        ),
        '/pay/send/result?state=held&amount=7900&banner=1&intervention=int_1',
      );
    });
  });

  group('PayController', () {
    late ProviderContainer c;
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      c = ProviderContainer(
        overrides: [imuSourceProvider.overrideWithValue(const NoImuSource())],
      );
    });
    tearDown(() => c.dispose());

    PayController ctl() => c.read(payControllerProvider.notifier);

    test('begin(kind) resets to a fresh intent of that kind', () {
      ctl()
        ..begin(PayKind.send)
        ..setAmount(500);
      final session = c.read(payControllerProvider).sessionId;
      ctl().begin(PayKind.cashOut);
      final s = c.read(payControllerProvider);
      expect(s.kind, PayKind.cashOut);
      expect(s.amountBdt, 0);
      expect(s.sessionId, session);
      expect(c.read(sessionRepoProvider).sessionId, session);
    });

    test('digits are refused past the maximum; 00 is both or neither', () {
      ctl().begin(PayKind.send);
      for (final d in [9, 9, 9, 9, 9, 9, 9, 9]) {
        expect(ctl().appendDigit(d), isTrue);
      }
      expect(ctl().appendDigit(9), isFalse);
      expect(c.read(payControllerProvider).amountBdt, PayRules.maxAmount);
      expect(ctl().appendDoubleZero(), isFalse);
      ctl().clearAmount();
      expect(ctl().appendDoubleZero(), isTrue);
      expect(c.read(payControllerProvider).amountBdt, 0);
      ctl().appendDigit(5);
      ctl().appendDoubleZero();
      expect(c.read(payControllerProvider).amountBdt, 500);
      ctl().backspaceAmount();
      expect(c.read(payControllerProvider).amountBdt, 50);
    });

    test('cash out recomputes the fee with every key', () {
      ctl()
        ..begin(PayKind.cashOut)
        ..setAmount(2000);
      final s = c.read(payControllerProvider);
      expect(s.feeBdt, 30);
      expect(s.debitBdt, 2030);
    });

    test('a bill fixes the amount; the numpad cannot change it', () {
      final billers = BillerCatalog.parse(
        File(BillerCatalog.path).readAsStringSync(),
      );
      ctl()
        ..begin(PayKind.bill)
        ..setBill(Bill(biller: billers[1], account: '1234567890'));
      expect(ctl().appendDigit(1), isFalse);
      ctl().setAmount(5);
      final s = c.read(payControllerProvider);
      expect(s.amountBdt, 615);
      expect(s.fixedAmountBdt, 615);
      expect(s.counterparty?.acctId, 'biller_wasa_1234567890');
      expect(s.canProceed, isTrue);
    });

    test('recharge picks the operator from the prefix', () {
      ctl()
        ..begin(PayKind.recharge)
        ..selectCounterparty(
          const Counterparty(
            acctId: 'mob_018XXXXX207',
            nameBn: 'রফিক',
            subtitle: '018XXXXX207',
          ),
        );
      expect(c.read(payControllerProvider).operator, Operator.b);
    });

    test('compat names point at the same provider', () {
      expect(
        identical(sendMoneyControllerProvider, payControllerProvider),
        isTrue,
      );
    });
  });

  // Keep the asset bundle import used (billers default loader).
  test('BillerCatalog.load reads through a bundle', () async {
    final billers = await BillerCatalog.load(_FileBundle());
    expect(billers, hasLength(3));
  });
}

class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(File(key).readAsBytesSync());
}
