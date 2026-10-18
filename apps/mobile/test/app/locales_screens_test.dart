/// Every main screen in both languages: no exception, no overflow, the
/// screen's own copy in the active language, and (in English) no Bangla
/// digit anywhere in app chrome.
library;

import 'package:bhorosha/app/locale.dart';
import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/features/approve/logic/approve_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_harness.dart';

const _bnDigit = r'[০-৯]';

/// Any Bangla letter or sign (the whole Bengali block).
const _bnScript = r'[ঀ-৿]';

/// Screens whose every text must be English in English mode: no Bangla
/// letters anywhere (ledger names included) other than the "বাংলা" toggle
/// segment and the taka sign.
const _englishOnly = {'Home', 'History'};

class _Case {
  const _Case(
    this.name, {
    required this.location,
    required this.bn,
    required this.en,
    this.persona = Persona.rina,
    this.seedApprove = false,
    this.settle = true,
  });

  final String name;
  final String? location;
  final List<String> bn;
  final List<String> en;
  final Persona? persona;
  final bool seedApprove;

  /// The approve screen ticks every second; it is pumped, not settled.
  final bool settle;
}

const _requestId = '7f3c2a1e-9b4d-4c11-8e2f-5d6a7b8c9d0e';

final _cases = [
  const _Case(
    'Login',
    location: null,
    persona: null,
    bn: [
      'আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন',
      'কে লগইন করবেন?',
      'রিনা আক্তার',
      'গাজীপুর',
    ],
    en: [
      'Log in with fingerprint or face',
      'Who is logging in?',
      'Rina Akter',
      'Gazipur',
    ],
  ),
  const _Case(
    'Home',
    location: Routes.home,
    bn: ['টাকা পাঠান', 'স্বাগতম, রিনা', '৯,৮৪১'],
    en: ['Send money', 'Welcome, Rina', '9,841'],
  ),
  const _Case(
    'History',
    location: Routes.history,
    // No day header here: the newest seed row lands two hours ago, which is
    // "yesterday" in Dhaka for a run between midnight and 02:00.
    bn: ['লেনদেন', 'গার্মেন্টস বেতন', 'নতুন নম্বর', 'রফিক ইসলাম'],
    en: ['History', 'Garment wages', 'New number', 'Rafiq Islam'],
  ),
  const _Case(
    'Send money',
    location: Routes.send,
    bn: ['কাকে পাঠাবেন', 'নতুন নম্বরে পাঠান'],
    en: ['Who are you sending to', 'Send to a new number'],
  ),
  const _Case(
    'Result done',
    location: '${Routes.result}?state=done&amount=5000',
    bn: ['টাকা পাঠানো হয়েছে', '৫,০০০'],
    en: ['Money sent', '5,000'],
  ),
  const _Case(
    'Result held',
    location: '${Routes.result}?state=held&amount=7900',
    bn: ['আপনার টাকা নিরাপদে আটকে আছে', '৭,৯০০'],
    en: ['Your money is safely on hold', '7,900'],
  ),
  const _Case(
    'Safety',
    location: Routes.safety,
    bn: ['ফোনের নিরাপত্তা', 'নিরাপদ'],
    en: ['Phone safety', 'Safe'],
  ),
  const _Case(
    'Approve known',
    location: '/approve/$_requestId',
    seedApprove: true,
    settle: false,
    bn: ['রিনা আপনার মত চাইছেন', '৳ ৭,৯০০', 'অনুমোদন করুন'],
    en: ['Rina is asking for your approval', '৳ 7,900', 'Approve'],
  ),
  const _Case(
    'Approve unknown',
    location: '/approve/$_requestId',
    settle: false,
    bn: ['আপনজনের অনুরোধ', 'রেফারেন্স ', 'অনুমোদন করুন'],
    en: ['A request from someone who trusts you', 'Reference ', 'Approve'],
  ),
  const _Case(
    'Loans',
    location: Routes.loans,
    bn: ['ঋণ', 'আবেদন করুন'],
    en: ['Loans', 'Apply'],
  ),
  const _Case(
    'Savings',
    location: Routes.savings,
    bn: ['সঞ্চয়', 'নতুন ডিপিএস খুলুন'],
    en: ['Savings', 'Open a new DPS'],
  ),
];

Future<void> _seedApprove(ProviderContainer c) async {
  final now = DateTime.now();
  await c
      .read(ledgerRepoProvider)
      .create(
        'rina',
        LedgerTxn(
          txnId: 'txn_lang_1',
          ts: now,
          type: 'send_money',
          amountBdt: 7900,
          fromAcct: 'acct_rina',
          toAcct: 'acct_ma',
          status: LedgerStatus.held,
          counterpartyNameBn: 'মা',
          interventionId: 'int_lang_1',
        ),
      );
  await c
      .read(interventionRepoProvider)
      .upsert(
        InterventionRecord(
          id: 'int_lang_1',
          uid: 'rina',
          txnId: 'txn_lang_1',
          trigger: 'new_payee',
          scriptBn: 'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন।',
          reasons: const [],
          actions: const [ActionItem(type: 'trusted_contact_check')],
          status: InterventionStatus.pending,
          createdAt: now,
          requestId: _requestId,
          expiresAt: now.add(const Duration(minutes: 10)),
          contactUid: 'rafiq',
        ),
      );
}

void main() {
  for (final locale in const [Locale('bn'), Locale('en')]) {
    for (final k in _cases) {
      testWidgets('${k.name} in ${locale.languageCode}', (tester) async {
        final semantics = tester.ensureSemantics();
        final h = ScreenHarness();
        final c = await pumpApp(
          tester,
          harness: h,
          persona: k.persona,
          extraOverrides: [
            initialLocaleProvider.overrideWithValue(locale),
            // The approve cases view the request as its trusted contact
            // (anyone else gets the read-only screen).
            if (k.location?.startsWith('/approve/') ?? false)
              approveViewerUidProvider.overrideWithValue('rafiq'),
          ],
        );
        if (k.seedApprove) await _seedApprove(c);
        final location = k.location;
        if (location != null) {
          routerOf(c).go(location);
          if (k.settle) {
            await tester.pumpAndSettle();
          } else {
            for (var i = 0; i < 5; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
          }
        }

        expect(tester.takeException(), isNull, reason: 'overflow or error');
        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.locale, locale);

        final expected = locale.languageCode == 'en' ? k.en : k.bn;
        for (final s in expected) {
          // A visible text, or (amounts drawn in digit slots, 3.4) part of
          // a spoken label.
          final found =
              find.text(s).evaluate().isNotEmpty ||
              find.textContaining(s).evaluate().isNotEmpty ||
              find
                  .bySemanticsLabel(RegExp(RegExp.escape(s)))
                  .evaluate()
                  .isNotEmpty;
          expect(found, isTrue, reason: '"$s" on ${k.name}');
        }
        final texts = allTexts(tester);
        if (locale.languageCode == 'en') {
          final bnDigitTexts = texts
              .where((t) => RegExp(_bnDigit).hasMatch(t))
              .toList();
          expect(bnDigitTexts, isEmpty, reason: 'Bangla digits in English');
          if (_englishOnly.contains(k.name)) {
            final bangla = texts
                .where((t) => t != 'বাংলা')
                .map((t) => t.replaceAll('৳', ''))
                .where((t) => RegExp(_bnScript).hasMatch(t))
                .toList();
            expect(bangla, isEmpty, reason: 'Bangla letters in English');
          }
        }
        // Never the raw request id as a title.
        expect(texts.where((t) => t.contains(_requestId)), isEmpty);

        // Dispose the scope so the approve ticker is cancelled.
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      });
    }
  }
}
