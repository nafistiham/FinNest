/// The in-memory search index of the safety knowledge base.
///
/// About 80 short bilingual chunks fit in memory easily, so the index is two
/// plain BM25 tables built once at load: one over words, one over character
/// 3-grams. Words give precision; 3-grams catch Bangla inflections
/// (চাইছে / চায়), spelling variants and English plurals that the word table
/// misses. The two scores are scaled per query and added.
///
/// Min-max scaling always gives the best chunk 1.0, so it cannot tell an
/// unrelated question from a good one. An absolute gate does that instead:
/// a chunk is a hit only when a content word of the query (or of its synonym
/// expansion) occurs in it, or when most of the query's 3-gram weight does.
library;

import 'dart:math' as math;

import 'package:bhorosha/features/apa/knowledge/bangla_normalizer.dart';
import 'package:bhorosha/features/apa/knowledge/kb_types.dart';

class KbIndex {
  /// Builds the index over [chunks]. [synonyms] are the asset's groups;
  /// [extraSynonyms] are added after them.
  KbIndex(
    List<KbChunk> chunks, {
    List<List<String>> synonyms = const [],
    List<List<String>> extraSynonyms = KbIndex.extraSynonymGroups,
  }) : _chunks = List.unmodifiable(chunks),
       _synonyms = _SynonymTable([...synonyms, ...extraSynonyms]) {
    final wordDocs = <List<String>>[];
    final gramDocs = <List<String>>[];
    for (final c in _chunks) {
      final words = BanglaNormalizer.tokens(_documentText(c));
      wordDocs.add(words);
      gramDocs.add([for (final w in words) ...BanglaNormalizer.trigrams(w)]);
    }
    _words = _Bm25(wordDocs);
    _grams = _Bm25(gramDocs);
  }

  /// BM25 term-frequency saturation.
  static const double k1 = 1.2;

  /// BM25 length normalisation.
  static const double b = 0.75;

  /// Weight of the word score in the fused score.
  static const double wordWeight = 0.6;

  /// Weight of the 3-gram score in the fused score.
  static const double gramWeight = 0.4;

  /// Fused score below which a gated chunk is still dropped. It trims the
  /// long tail of weak partial matches.
  static const double floor = 0.3;

  /// Share of the query's 3-gram weight a chunk must contain to pass the
  /// gate without enough whole-word matches.
  static const double strongGramCoverage = 0.6;

  /// Share of the query's content words (each with its synonyms) a chunk
  /// must contain to pass the gate on words. One stray common word in a
  /// four-word off-topic question is not enough.
  static const double minWordCoverage = 0.3;

  /// Query-weight of a word that was added by synonym expansion (the words
  /// the customer actually said weigh 1).
  static const double expansionWeight = 0.5;

  /// Groups the asset does not have, found by the retrieval eval. Kept in
  /// code so the asset stays content only. Like the asset, they hold no
  /// brand, institution or third-party number (2026-10-18).
  static const List<List<String>> extraSynonymGroups = [
    [
      'remote app',
      'remote',
      'রিমোট',
      'remote control',
      'screen share',
      'screen sharing',
      'স্ক্রিন শেয়ার',
    ],
    [
      'stolen',
      'চুরি',
      'lost',
      'হারিয়ে',
      'হারানো',
      'phone lost',
      'ফোন হারিয়েছে',
    ],
    ['warn', 'warning', 'সতর্ক', 'সতর্কতা', 'alert', 'flagged'],
    ['dial', 'ডায়াল', 'ussd', 'code dial', 'কোড ডায়াল'],
    ['threat', 'হুমকি', 'blackmail', 'ব্ল্যাকমেইল', 'harass', 'হয়রানি'],
    [
      'caller id',
      'কলার আইডি',
      'real number',
      'আসল নম্বর',
      'spoof',
      'spoofing',
      'showed',
      'shows the number',
      'নম্বর দেখাচ্ছে',
      'bank number',
      'false number',
      'fake number',
      'নকল নম্বর',
    ],
    ['how many', 'কয়টা', 'কয়টি', 'কতগুলো', 'কতটা'],
    ['advance', 'অগ্রিম', 'আগে টাকা', 'fee', 'ফি', 'registration fee'],
    [
      'shared',
      'share',
      'শেয়ার',
      'told',
      'leak',
      'বলে দিয়েছি',
      'বলে ফেলেছি',
      'দিয়ে দিয়েছি',
      'দিয়ে ফেলেছি',
      'ফেলেছি',
    ],
  ];

  /// Words that carry no topic in either language. They are dropped from
  /// queries so "what is the weather" matches nothing; chunks keep them.
  static final Set<String> stopWords = {
    for (final w in _stopWordList) ...BanglaNormalizer.tokens(w),
  };

  static const List<String> _stopWordList = [
    // English.
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'am', 'to',
    'of', 'in', 'on', 'at', 'for', 'with', 'and', 'or', 'but', 'i', 'me',
    'my', 'you', 'your', 'it', 'its', 'this', 'that', 'these', 'what', 'why',
    'how', 'when', 'where', 'who', 'do', 'does', 'did', 'can', 'could',
    'should', 'will', 'would', 'so', 'if', 'he', 'she', 'his', 'her', 'they',
    'them', 'we', 'our', 'us', 'not', 'no', 'yes', 'from', 'by', 'about',
    'there', 'as', 'up', 'out', 'get', 'got', 'has', 'have', 'had', 'just',
    'now', 'then', 'than', 'very', 'any', 'some', 'all', 'one', 'into',
    'unless', 'safe', 'real', 'please', 'tell', 'know',
    // Bangla (written after the fold, so ী/ি variants are both covered).
    'কি', 'কী', 'আমি', 'আমার', 'আমাকে', 'আমরা', 'তুমি', 'আপনি', 'আপনার',
    'সে', 'তার', 'এই', 'ওই', 'এটা', 'ওটা', 'এটি', 'আর', 'ও', 'এবং', 'বা',
    'না', 'নেই', 'হ্যাঁ', 'তো', 'যে', 'যদি', 'কেন', 'কোথায়', 'কীভাবে',
    'কিভাবে', 'কখন', 'কে', 'করব', 'করবো', 'করে', 'করি', 'করছে', 'হবে',
    'হয়', 'হচ্ছে', 'আছে', 'ছিল', 'থেকে', 'দিয়ে', 'জন্য', 'একটা', 'একজন',
    'এখন', 'এখনই', 'কিন্তু', 'তাহলে', 'বলছে', 'বলল', 'দেব', 'দিব', 'চাই',
    'দেখব', 'জিনিস', 'একই', 'উপর', 'আরেকটা', 'লাগানো', 'হঠাৎ',
    'কাজ', 'আসল', 'আসছে', 'এসে',
  ];

  final List<KbChunk> _chunks;
  final _SynonymTable _synonyms;
  late final _Bm25 _words;
  late final _Bm25 _grams;

  int get length => _chunks.length;

  /// Best [k] chunks for [query], best first; empty when nothing passes the
  /// gate and the floor. Ties break by chunk id so results are stable.
  List<KbHit> search(String query, {int k = 4}) {
    if (k <= 0 || _chunks.isEmpty) return const [];
    final raw = BanglaNormalizer.tokens(query);
    final content = [
      for (final t in raw)
        if (!stopWords.contains(t)) t,
    ];
    if (content.isEmpty) return const [];

    final wordQuery = _weightedWords(raw, content);
    final wordCoverage = _wordCoverage(raw, content);
    final gramQuery = <String, double>{
      for (final t in content)
        for (final g in BanglaNormalizer.trigrams(t)) g: 1,
    };
    final wordScores = _words.scores(wordQuery);
    final gramScores = _grams.scores(gramQuery);
    final coverage = _grams.coverage(gramQuery);

    final wordNorm = _minMax(wordScores);
    final gramNorm = _minMax(gramScores);
    final hits = <KbHit>[];
    for (var i = 0; i < _chunks.length; i++) {
      final gated =
          (wordScores[i] > 0 && wordCoverage[i] >= minWordCoverage) ||
          coverage[i] >= strongGramCoverage;
      if (!gated) continue;
      final fused = wordWeight * wordNorm[i] + gramWeight * gramNorm[i];
      if (fused >= floor) hits.add(KbHit(_chunks[i], fused));
    }
    hits.sort((x, y) {
      final byScore = y.score.compareTo(x.score);
      return byScore != 0 ? byScore : x.chunk.id.compareTo(y.chunk.id);
    });
    return hits.length > k ? hits.sublist(0, k) : hits;
  }

  /// The query's content words at weight 1 plus their synonyms at
  /// [expansionWeight]. Phrases are matched on [raw] so "no network" still
  /// expands although "no" is a stop word.
  Map<String, double> _weightedWords(List<String> raw, List<String> content) {
    final weights = <String, double>{};
    for (final word in _synonyms.expand(raw)) {
      if (!stopWords.contains(word)) weights[word] = expansionWeight;
    }
    for (final t in content) {
      weights[t] = 1;
    }
    return weights;
  }

  /// Per chunk, the share of [content] words found in it, where a word
  /// counts when it or one of its synonyms (from [raw]'s groups) occurs.
  List<double> _wordCoverage(List<String> raw, List<String> content) {
    final out = List<double>.filled(_chunks.length, 0);
    for (final t in content) {
      final forms = {t, ..._synonyms.expandToken(raw, t)};
      for (var i = 0; i < _chunks.length; i++) {
        if (forms.any(_words.contains(i))) out[i] += 1 / content.length;
      }
    }
    return out;
  }

  /// Both titles twice (the title boost), both texts, then the tags. The
  /// helpline placeholder is not a word the customer says, so it is dropped.
  static String _documentText(KbChunk c) => [
    c.titleBn,
    c.titleBn,
    c.titleEn,
    c.titleEn,
    c.textBn,
    c.textEn,
    ...c.tags,
  ].join(' ').replaceAll('{{HELPLINE}}', ' ');

  static List<double> _minMax(List<double> xs) {
    if (xs.isEmpty) return xs;
    final lo = xs.reduce(math.min);
    final hi = xs.reduce(math.max);
    final span = hi - lo;
    if (span <= 0) return List.filled(xs.length, 0);
    return [for (final x in xs) (x - lo) / span];
  }
}

/// Synonym groups as folded token lists, matched as words or phrases.
class _SynonymTable {
  _SynonymTable(List<List<String>> groups)
    : _groups = [
        for (final g in groups)
          [
            for (final member in g)
              if (BanglaNormalizer.tokens(member) case final t
                  when t.isNotEmpty)
                t,
          ],
      ];

  /// Each group is a list of members; each member is its folded tokens.
  final List<List<List<String>>> _groups;

  /// Every token of every group that [query] touches.
  Set<String> expand(List<String> query) {
    final out = <String>{};
    for (final group in _groups) {
      if (group.any((member) => _containsPhrase(query, member))) {
        for (final member in group) {
          out.addAll(member);
        }
      }
    }
    return out;
  }

  /// The tokens of every group with a member that contains [token] and
  /// occurs in [query] (as a word or a phrase).
  Set<String> expandToken(List<String> query, String token) {
    final out = <String>{};
    for (final group in _groups) {
      final touched = group.any(
        (member) => member.contains(token) && _containsPhrase(query, member),
      );
      if (touched) {
        for (final member in group) {
          out.addAll(member);
        }
      }
    }
    return out;
  }

  static bool _containsPhrase(List<String> query, List<String> phrase) {
    for (var i = 0; i + phrase.length <= query.length; i++) {
      var match = true;
      for (var j = 0; j < phrase.length && match; j++) {
        match = query[i + j] == phrase[j];
      }
      if (match) return true;
    }
    return false;
  }
}

/// One Okapi BM25 table over pre-tokenised documents.
class _Bm25 {
  _Bm25(List<List<String>> docs)
    : _tf = [for (final d in docs) <String, int>{}..addAll(_counts(d))],
      _length = [for (final d in docs) d.length] {
    final total = _length.fold<int>(0, (s, l) => s + l);
    _avgLength = docs.isEmpty ? 0 : total / docs.length;
    final df = <String, int>{};
    for (final tf in _tf) {
      for (final term in tf.keys) {
        df[term] = (df[term] ?? 0) + 1;
      }
    }
    final n = docs.length;
    _idf = {
      for (final e in df.entries)
        e.key: math.log(1 + (n - e.value + 0.5) / (e.value + 0.5)),
    };
  }

  final List<Map<String, int>> _tf;
  final List<int> _length;
  late final double _avgLength;
  late final Map<String, double> _idf;

  /// Whether document [i] contains [term]; curried for `any`.
  bool Function(String term) contains(int i) =>
      (term) => _tf[i].containsKey(term);

  /// BM25 of every document for [query] (term -> query weight).
  List<double> scores(Map<String, double> query) {
    final out = List<double>.filled(_tf.length, 0);
    for (final MapEntry(key: term, value: qw) in query.entries) {
      final idf = _idf[term];
      if (idf == null) continue;
      for (var i = 0; i < _tf.length; i++) {
        final f = _tf[i][term];
        if (f == null) continue;
        final norm =
            KbIndex.k1 * (1 - KbIndex.b + KbIndex.b * _length[i] / _avgLength);
        out[i] += qw * idf * f * (KbIndex.k1 + 1) / (f + norm);
      }
    }
    return out;
  }

  /// Per document, the idf-weighted share of [query]'s terms it contains
  /// (0 to 1). Terms unknown to the whole index count as missing.
  List<double> coverage(Map<String, double> query) {
    final out = List<double>.filled(_tf.length, 0);
    var total = 0.0;
    var maxIdf = 0.0;
    for (final v in _idf.values) {
      if (v > maxIdf) maxIdf = v;
    }
    for (final term in query.keys) {
      final idf = _idf[term] ?? maxIdf;
      total += idf;
      if (_idf[term] == null) continue;
      for (var i = 0; i < _tf.length; i++) {
        if (_tf[i].containsKey(term)) out[i] += idf;
      }
    }
    if (total <= 0) return out;
    return [for (final x in out) x / total];
  }

  static Map<String, int> _counts(List<String> terms) {
    final out = <String, int>{};
    for (final t in terms) {
      out[t] = (out[t] ?? 0) + 1;
    }
    return out;
  }
}
