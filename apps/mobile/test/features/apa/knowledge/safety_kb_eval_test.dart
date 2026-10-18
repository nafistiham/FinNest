// Retrieval eval of the on-device safety search.
//
// A case is a hit when any of its expected ids is in the top 3. An expected
// id that ends in `__` or `_` is a prefix: any chunk of that playbook (or
// family, e.g. `helpline_`) counts.
//
// Every question and keyword query names no private business, like the
// asset; one
// robustness test checks that a customer who says a brand still finds the
// right chunks through the other words.
import 'dart:io';

import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:flutter_test/flutter_test.dart';

const _top = 3;

/// Questions as a customer says them.
const _customerCases = <(String, List<String>)>[
  (
    'মোবাইল ব্যাংকিং থেকে ফোন করে পিন চাইছে, দেব?',
    ['fake_agent_care_call__', 'no_one_asks_pin', 'pin'],
  ),
  (
    'একজন বলছে ভুল করে আমার নম্বরে টাকা পাঠিয়েছে, ফেরত চাইছে। কী করব?',
    ['wrong_send_return__', 'check_transaction', 'action_check_transaction'],
  ),
  ('I got an SMS that I won a lottery. Is it real?', ['lottery_prize__']),
  ('ওটিপি আর পিন কি একই জিনিস?', ['pin_vs_otp', 'otp', 'pin']),
  (
    'হঠাৎ ফোনে নেটওয়ার্ক নেই, আর ওটিপি আসছে। কী হচ্ছে?',
    ['sim_swap__', 'sim_swap_detect'],
  ),
  ('আমার নামে কয়টা সিম আছে কীভাবে দেখব?', ['sim_count_check']),
  (
    'Caller says he is police and I will be arrested unless I pay.',
    ['police_impersonation__'],
  ),
  (
    '৯৯৯ নম্বর থেকে কল এসে পিন চাইল, এটা কি আসল?',
    ['police_impersonation__', 'caller_id_spoofing', 'no_one_asks_pin'],
  ),
  (
    'Customer care asked me to install a remote-control app. Should I?',
    ['screen_share_remote__', 'screen_sharing', 'sideloaded_apk'],
  ),
  ('এই অ্যাপ অ্যাক্সেসিবিলিটি পারমিশন চাইছে, দেব?', ['accessibility_abuse']),
  ('ফোনের অ্যাপ স্ক্যান কী কাজ করে?', ['phone_app_scan']),
  (
    'SMS says update NID or my account will be blocked, with a link.',
    ['fake_kyc_nid_update__', 'phishing_link'],
  ),
  (
    'আম্মু ফোন করে বলল ভাইয়ের অ্যাক্সিডেন্ট, এখনই টাকা পাঠাতে হবে, '
        'কিন্তু নম্বরটা অচেনা।',
    ['relative_emergency__'],
  ),
  ('বন্ধু মেসেজে টাকা ধার চাইছে, নতুন নম্বরে।', ['social_account_takeover__']),
  (
    'I paid an advance to a shop page and they blocked me.',
    ['fake_ecommerce_link__', 'complaint_escalation'],
  ),
  (
    'লোন অ্যাপ আমার কন্টাক্টে ছবি পাঠানোর হুমকি দিচ্ছে।',
    ['fake_job_or_loan_app__'],
  ),
  ('ঘরে বসে চাকরি, আগে টাকা দিতে বলছে।', ['fake_job_or_loan_app__']),
  ('দোকানের কিউআর কোডের উপর আরেকটা স্টিকার লাগানো।', ['qr_code_scam__']),
  (
    'Free 10GB, dial this code SMS. Safe?',
    ['recharge_cashback__', 'phishing_link'],
  ),
  (
    'I accidentally sent money to a wrong number. Can I get it back?',
    ['reverse_mistaken_send', 'action_wrong_send'],
  ),
  (
    'আমি ভুল করে ওটিপি বলে দিয়েছি, এখন কী করব?',
    ['lock_account', 'action_shared_otp'],
  ),
  (
    'How do I block my wallet if my phone is stolen?',
    ['lock_account', 'action_lost_phone_sim'],
  ),
  (
    'Why did the app warn me this call is a scam?',
    ['app_call_warning', 'caller_id_spoofing'],
  ),
  (
    'সাইবার প্রতারণার অভিযোগ কোথায় করব?',
    ['complaint_escalation', 'action_report_complain', 'helpline_'],
  ),
  (
    'The caller showed the real bank number on screen, so is it safe?',
    ['caller_id_spoofing'],
  ),
];

/// Queries as the voice model writes them: bilingual keywords.
const _modelCases = <(String, List<String>)>[
  (
    'OTP কোড শেয়ার প্রতারণা মোবাইল ব্যাংকিং',
    ['action_shared_otp', 'otp', 'fake_agent_care_call__', 'no_one_asks_pin'],
  ),
  ('police arrest threat payment পুলিশ গ্রেফতার', ['police_impersonation__']),
  ('SIM swap no network OTP সিম বদল', ['sim_swap__', 'sim_swap_detect']),
  (
    'wrong number money return ভুল নম্বর টাকা ফেরত',
    ['wrong_send_return__', 'reverse_mistaken_send', 'action_wrong_send'],
  ),
  (
    'remote control app screen share স্ক্রিন শেয়ার',
    ['screen_share_remote__', 'screen_sharing'],
  ),
  ('loan app threat contacts লোন অ্যাপ হুমকি', ['fake_job_or_loan_app__']),
  (
    'complaint helpline cyber crime অভিযোগ সাইবার',
    ['complaint_escalation', 'action_report_complain', 'helpline_'],
  ),
  ('lottery prize SMS লটারি পুরস্কার', ['lottery_prize__']),
];

const _offTopic = [
  'what is the weather in Paris',
  'ফুটবল খেলার স্কোর',
  'recipe for chicken biryani',
];

bool _matches(String id, String expected) =>
    expected.endsWith('_') ? id.startsWith(expected) : id == expected;

/// Number of hits; prints every miss with what came back instead.
int _score(
  SafetyKnowledge kb,
  List<(String, List<String>)> cases,
  String label,
) {
  var hits = 0;
  for (final (query, expected) in cases) {
    final top = kb.search(query, k: _top).map((h) => h.chunk.id).toList();
    final hit = top.any((id) => expected.any((e) => _matches(id, e)));
    if (hit) {
      hits++;
    } else {
      // ignore: avoid_print
      print('[$label] MISS "$query" -> $top (want $expected)');
    }
  }
  // ignore: avoid_print
  print('[$label] $hits/${cases.length} in top $_top');
  return hits;
}

void main() {
  late SafetyKnowledgeBase kb;

  setUpAll(() {
    kb = SafetyKnowledgeBase.parse(
      File(SafetyKnowledgeBase.assetPath).readAsStringSync(),
    );
  });

  test('customer questions: at least 23 of 25 in the top 3', () {
    expect(_customerCases, hasLength(25));
    expect(_score(kb, _customerCases, 'customer'), greaterThanOrEqualTo(23));
  });

  test('model keyword queries: at least 7 of 8 in the top 3', () {
    expect(_modelCases, hasLength(8));
    expect(_score(kb, _modelCases, 'model'), greaterThanOrEqualTo(7));
  });

  test('a question that names a brand still finds the fake-agent and OTP '
      'chunks, with no brand word in the knowledge base', () {
    const q = 'বিকাশ এজেন্ট ফোন করে ওটিপি চাইছে';
    final top = kb.search(q, k: _top).map((h) => h.chunk.id).toList();
    // ignore: avoid_print
    print('[brand] "$q" -> $top');
    const want = ['fake_agent_care_call__', 'otp', 'action_shared_otp'];
    expect(
      top.any((id) => want.any((e) => _matches(id, e))),
      isTrue,
      reason: '$top',
    );
    final asset = File(SafetyKnowledgeBase.assetPath).readAsStringSync();
    expect(asset.toLowerCase(), isNot(contains('bkash')));
    expect(asset, isNot(contains('বিকাশ')));
  });

  test('off-topic questions return nothing', () {
    for (final q in _offTopic) {
      expect(
        kb.search(q).map((h) => h.chunk.id),
        isEmpty,
        reason: 'off-topic "$q" should not match',
      );
    }
  });

  test('an empty or stop-word-only query returns nothing', () {
    expect(kb.search(''), isEmpty);
    expect(kb.search('   ।?'), isEmpty);
    expect(kb.search('what is this'), isEmpty);
    expect(kb.search('otp', k: 0), isEmpty);
  });

  test('results are best first, capped at k, and deterministic', () {
    const q = 'OTP কোড শেয়ার';
    final a = kb.search(q);
    final b = kb.search(q);
    expect(a.length, lessThanOrEqualTo(4));
    expect(a.map((h) => h.chunk.id), b.map((h) => h.chunk.id));
    for (var i = 1; i < a.length; i++) {
      expect(a[i - 1].score, greaterThanOrEqualTo(a[i].score));
    }
  });

  test('index builds under 200 ms and a search runs under 20 ms', () {
    final source = File(SafetyKnowledgeBase.assetPath).readAsStringSync();
    final build = Stopwatch()..start();
    final fresh = SafetyKnowledgeBase.parse(source);
    build.stop();
    fresh.search('warm up');
    final search = Stopwatch()..start();
    const runs = 50;
    for (var i = 0; i < runs; i++) {
      fresh.search(_customerCases[i % _customerCases.length].$1);
    }
    search.stop();
    // ignore: avoid_print
    print(
      'build ${build.elapsedMilliseconds} ms, search '
      '${(search.elapsedMicroseconds / runs / 1000).toStringAsFixed(2)} ms',
    );
    expect(build.elapsedMilliseconds, lessThan(200));
    expect(search.elapsedMicroseconds / runs, lessThan(20000));
  });
}
