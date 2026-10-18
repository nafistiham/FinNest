// Schema checks of the bundled safety knowledge base, read from disk so they
// run without the Flutter asset bundle.
import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/features/apa/knowledge/bangla_normalizer.dart';
import 'package:bhorosha/features/apa/knowledge/kb_index.dart';
import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:flutter_test/flutter_test.dart';

/// Private businesses nothing in the asset may name (FinNest and public
/// agencies only). Matched as folded words or phrases in
/// titles, texts, tags, synonyms and source ids, names and urls. Public
/// agencies (Bangladesh Bank, BTRC, Bangladesh Police, 999, CID, BFIU, the
/// Election Commission) are allowed.
// Real brand names are kept only so the test can recognise them.
const _bannedPrivate = [
  // Mobile money and banks other than FinNest.
  'bkash', 'বিকাশ', 'nagad', 'নগদ', 'rocket', 'রকেট', 'upay', 'dbbl', //
  'dutch bangla', 'dutch-bangla', 'ডাচ বাংলা', 'brac', 'ব্র্যাক', 'city bank',
  'islami bank', 'ইসলামী ব্যাংক', 'pubali', 'পূবালী', 'eastern bank',
  'prime bank',
  // Telecom operators.
  'grameenphone', 'গ্রামীণফোন', 'gp', 'robi', 'banglalink', 'বাংলালিংক',
  'airtel', 'এয়ারটেল', 'teletalk', 'টেলিটক',
  // Apps and platforms.
  'anydesk', 'এনিডেস্ক', 'teamviewer', 'টিমভিউয়ার', 'quicksupport',
  'facebook', 'ফেসবুক', 'fb', 'messenger', 'মেসেঞ্জার', 'instagram',
  'ইনস্টাগ্রাম', 'whatsapp', 'হোয়াটসঅ্যাপ', 'telegram', 'টেলিগ্রাম', 'imo',
  'ইমো', 'viber', 'ভাইবার', 'daraz', 'দারাজ', 'google', 'গুগল',
  'play protect', 'প্লে প্রোটেক্ট', 'play store', 'android', 'অ্যান্ড্রয়েড',
  'flexiload',
  // News outlets.
  'tbs', 'tbsnews', 'daily star', 'thedailystar', 'dhaka tribune',
  'dhakatribune', 'dismislab', 'ittefaq', 'banglanews24', 'financial express',
  'thefinancialexpress', 'bss',
];

/// The public numbers the asset may give besides `{{HELPLINE}}`: the
/// national emergency line, the Bangladesh Bank complaint line, the BTRC SIM
/// check code, and the CID and Police Cyber Support for Women lines.
const _publicNumbers = {'999', '16236', '16001', '01320010148', '01320000888'};

/// A run of 3 or more digits (Latin or Bengali): only the helpline and
/// [_publicNumbers] may be that long.
final _longNumber = RegExp(r'[0-9০-৯]{3,}');

/// Whether [text] contains [entity] as whole folded words.
bool _hasEntity(String text, String entity) {
  final words = BanglaNormalizer.tokens(text);
  final phrase = BanglaNormalizer.tokens(entity);
  if (phrase.isEmpty) return false;
  for (var i = 0; i + phrase.length <= words.length; i++) {
    var all = true;
    for (var j = 0; j < phrase.length; j++) {
      if (words[i + j] != phrase[j]) {
        all = false;
        break;
      }
    }
    if (all) return true;
  }
  return false;
}

void main() {
  late Map<String, dynamic> json;
  late SafetyKnowledgeBase kb;

  setUpAll(() {
    final source = File(SafetyKnowledgeBase.assetPath).readAsStringSync();
    json = jsonDecode(source) as Map<String, dynamic>;
    kb = SafetyKnowledgeBase.parse(source);
  });

  Iterable<String> contentOf(KbChunk c) => [
    c.titleBn,
    c.titleEn,
    c.textBn,
    c.textEn,
    ...c.tags,
  ];

  test('has a version, the policy and 77 chunks with unique ids', () {
    expect(kb.version, 'safety_kb.v1');
    expect(json['updated'], '2026-10-18');
    expect(json['policy'], contains('FinNest and public agencies only'));
    expect(kb.chunks, hasLength(77));
    final ids = kb.chunks.map((c) => c.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('every kind is known and every kind is used', () {
    final kinds = kb.chunks.map((c) => c.kind).toSet();
    expect(KbKind.all.containsAll(kinds), isTrue, reason: '$kinds');
    expect(kinds, KbKind.all);
  });

  test('titles and texts are non-empty in both languages', () {
    for (final c in kb.chunks) {
      for (final field in [c.titleBn, c.titleEn, c.textBn, c.textEn]) {
        expect(field.trim(), isNotEmpty, reason: c.id);
      }
    }
  });

  test('every source id is defined and has a known level', () {
    final sources = json['sources'] as Map<String, dynamic>;
    for (final s in sources.values) {
      expect([
        'official',
        'news',
        'agency',
      ], contains((s as Map<String, dynamic>)['level']));
    }
    for (final c in kb.chunks) {
      expect(c.sources, isNotEmpty, reason: c.id);
      for (final s in c.sources) {
        expect(sources.containsKey(s), isTrue, reason: '${c.id}: $s');
      }
    }
  });

  test('no private business in titles, texts, tags, synonyms or sources', () {
    final fields = <(String, String)>[
      for (final c in kb.chunks)
        for (final f in contentOf(c)) (c.id, f),
      for (final g in json['synonyms'] as List<dynamic>)
        for (final w in g as List<dynamic>) ('synonyms', w as String),
      for (final g in KbIndex.extraSynonymGroups)
        for (final w in g) ('KbIndex.extraSynonymGroups', w),
      for (final e in (json['sources'] as Map<String, dynamic>).entries) ...[
        (e.key, e.key),
        (e.key, (e.value as Map<String, dynamic>)['name'] as String? ?? ''),
        (e.key, (e.value as Map<String, dynamic>)['url'] as String? ?? ''),
      ],
    ];
    for (final (where, field) in fields) {
      for (final entity in _bannedPrivate) {
        expect(
          _hasEntity(field, entity),
          isFalse,
          reason: '$where: "$entity" in "$field"',
        );
      }
    }
  });

  test('source urls are public-agency sites or FinNest; news has none', () {
    final sources = json['sources'] as Map<String, dynamic>;
    final allowed = RegExp(
      r'^(https://(www\.)?[a-z0-9.-]+\.gov(\.bd)?/|'
      r'https://www\.(police|cid|bb\.org|btrc|ecs)\.|about:finnest$)',
    );
    for (final e in sources.entries) {
      final s = e.value as Map<String, dynamic>;
      final url = s['url'] as String? ?? '';
      if (s['level'] == 'news') {
        expect(url, isEmpty, reason: e.key);
        continue;
      }
      if (url.isEmpty) continue;
      expect(allowed.hasMatch(url), isTrue, reason: '${e.key}: $url');
    }
    expect((sources['news_reports'] as Map?)?['name'], 'News reports');
  });

  test('no number but the helpline and the public lines', () {
    for (final c in kb.chunks) {
      for (final field in contentOf(c)) {
        final rest = field.replaceAll('{{HELPLINE}}', '');
        for (final m in _longNumber.allMatches(rest)) {
          final ascii = BanglaNormalizer.fold(m.group(0)!);
          expect(_publicNumbers, contains(ascii), reason: '${c.id}: "$field"');
        }
      }
    }
  });

  test('the helpline chunks are FinNest and the public agencies', () {
    final helplines = kb.chunks.where((c) => c.kind == KbKind.helpline);
    expect(helplines.map((c) => c.id).toSet(), {
      'helpline_finnest',
      'helpline_999',
      'helpline_cid_cyber',
      'helpline_pcsw',
      'helpline_bb_cipc',
    });
  });

  test('every playbook has signs, do now and prevent', () {
    final ids = kb.chunks.map((c) => c.id).toSet();
    final playbooks = kb.chunks.map((c) => c.playbook).nonNulls.toSet();
    expect(playbooks, hasLength(13));
    for (final p in playbooks) {
      for (final part in ['__signs', '__do_now', '__prevent']) {
        expect(ids, contains('$p$part'));
      }
    }
  });

  test('{{HELPLINE}} is the only placeholder', () {
    final token = RegExp(r'\{\{[^}]*\}\}');
    for (final c in kb.chunks) {
      for (final field in contentOf(c)) {
        for (final m in token.allMatches(field)) {
          expect(m.group(0), '{{HELPLINE}}', reason: c.id);
        }
        final rest = field.replaceAll('{{HELPLINE}}', '');
        expect(rest.contains('{{'), isFalse, reason: '${c.id}: "$field"');
        expect(rest.contains('}}'), isFalse, reason: '${c.id}: "$field"');
      }
    }
  });

  test('textOf fills the helpline in the digits of the language', () {
    final c = kb.chunks.firstWhere((c) => c.textEn.contains('{{HELPLINE}}'));
    expect(kb.textOf(c, english: true), contains(ApaHelpline.en));
    expect(kb.textOf(c, english: false), contains(ApaHelpline.bn));
    expect(kb.textOf(c, english: true), isNot(contains('{{')));
    expect(kb.textOf(c, english: false), isNot(contains('{{')));
  });

  test('titleOf and byId', () {
    final c = kb.byId('pin')!;
    expect(kb.titleOf(c, english: true), c.titleEn);
    expect(kb.titleOf(c, english: false), c.titleBn);
    expect(kb.byId('no_such_chunk'), isNull);
  });

  test('sourceLevelOf gives a generic level, never a source name', () {
    const levels = {'official guidance', 'news report', 'FinNest app'};
    for (final c in kb.chunks) {
      expect(levels, contains(kb.sourceLevelOf(c)), reason: c.id);
    }
    expect(kb.sourceLevelOf(kb.byId('app_payment_hold')!), 'FinNest app');
    expect(kb.sourceLevelOf(kb.byId('pin')!), 'official guidance');
  });

  test('an empty knowledge base searches to nothing', () {
    expect(SafetyKnowledgeBase.empty().search('otp'), isEmpty);
  });

  test('a wrong shape is a FormatException', () {
    expect(
      () => SafetyKnowledgeBase.fromJson({'chunks': 'nope'}),
      throwsFormatException,
    );
  });
}
