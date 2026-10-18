/// The bundled safety knowledge base (`assets/fna_kb/safety_kb.v1.json`)
/// and its on-device search.
///
/// Nothing about a question leaves the phone here: the asset is parsed once,
/// [KbIndex] is built once, and every search runs in memory.
library;

import 'dart:convert';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/knowledge/kb_index.dart';
import 'package:bhorosha/features/apa/knowledge/kb_types.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SafetyKnowledgeBase implements SafetyKnowledge {
  SafetyKnowledgeBase._(
    this._sourceLevels, {
    required this.version,
    required this.chunks,
    required List<List<String>> synonyms,
  }) : _byId = {for (final c in chunks) c.id: c},
       _index = KbIndex(chunks, synonyms: synonyms);

  /// Parses the decoded asset. Throws [FormatException] on a wrong shape.
  factory SafetyKnowledgeBase.fromJson(Map<String, dynamic> json) {
    try {
      final sources = (json['sources'] as Map<String, dynamic>? ?? const {});
      return SafetyKnowledgeBase._(
        {
          for (final e in sources.entries)
            e.key: (e.value as Map<String, dynamic>)['level'] as String? ?? '',
        },
        version: json['version'] as String? ?? '',
        chunks: List.unmodifiable([
          for (final c in json['chunks'] as List<dynamic>? ?? const [])
            _chunkFromJson(c as Map<String, dynamic>),
        ]),
        synonyms: [
          for (final g in json['synonyms'] as List<dynamic>? ?? const [])
            [for (final w in g as List<dynamic>) w as String],
        ],
      );
    } on TypeError catch (e) {
      throw FormatException('safety kb: bad shape ($e)');
    }
  }

  /// Parses the asset's source text (tests and [load]).
  factory SafetyKnowledgeBase.parse(String source) =>
      SafetyKnowledgeBase.fromJson(jsonDecode(source) as Map<String, dynamic>);

  /// A knowledge base with no chunks: every search is empty, so FNA falls
  /// back to its fixed "I do not know, call the helpline" line.
  factory SafetyKnowledgeBase.empty() => SafetyKnowledgeBase._(
    const {},
    version: '',
    chunks: const [],
    synonyms: const [],
  );

  static const assetPath = 'assets/fna_kb/safety_kb.v1.json';

  /// The source id of FinNest's own product facts.
  static const appSourceId = 'finnest_app';

  /// Loads [assetPath] from [bundle] (the root bundle by default). A missing
  /// or broken asset gives [SafetyKnowledgeBase.empty], never an error, so
  /// the assistant still runs and answers with the helpline line.
  static Future<SafetyKnowledgeBase> load([AssetBundle? bundle]) async {
    try {
      final source = await (bundle ?? rootBundle).loadString(assetPath);
      final watch = Stopwatch()..start();
      final kb = SafetyKnowledgeBase.parse(source);
      Log.d(
        'fna.kb',
        '${kb.version}: ${kb.chunks.length} chunks in '
            '${watch.elapsedMilliseconds} ms',
      );
      return kb;
    } on Object catch (e) {
      Log.w('fna.kb', 'knowledge base not loaded; search disabled', e);
      return SafetyKnowledgeBase.empty();
    }
  }

  /// The asset's `version`, e.g. `safety_kb.v1`.
  final String version;

  /// Every chunk, in asset order.
  final List<KbChunk> chunks;

  final Map<String, String> _sourceLevels;
  final Map<String, KbChunk> _byId;
  final KbIndex _index;

  @override
  List<KbHit> search(String query, {int k = 4}) {
    try {
      return _index.search(query, k: k);
    } on Object catch (e) {
      // The tool contract says search never throws; an empty list makes the
      // model use the helpline line instead of guessing.
      Log.w('fna.kb', 'search failed', e);
      return const [];
    }
  }

  @override
  KbChunk? byId(String id) => _byId[id];

  @override
  String textOf(KbChunk chunk, {required bool english}) =>
      (english ? chunk.textEn : chunk.textBn).replaceAll(
        '{{HELPLINE}}',
        english ? ApaHelpline.en : ApaHelpline.bn,
      );

  @override
  String titleOf(KbChunk chunk, {required bool english}) =>
      english ? chunk.titleEn : chunk.titleBn;

  /// External official or agency guidance outranks FinNest's own facts,
  /// which outrank news. Source names are never returned: they can name
  /// real brands.
  @override
  String sourceLevelOf(KbChunk chunk) {
    final levels = {for (final s in chunk.sources) _levelOf(s)};
    if (levels.contains(_official)) return _official;
    if (levels.contains(_app)) return _app;
    if (levels.contains(_news)) return _news;
    return _official;
  }

  static const _official = 'official guidance';
  static const _app = 'FinNest app';
  static const _news = 'news report';

  String _levelOf(String sourceId) {
    if (sourceId == appSourceId) return _app;
    return switch (_sourceLevels[sourceId]) {
      'official' || 'agency' => _official,
      'news' => _news,
      _ => '',
    };
  }

  static KbChunk _chunkFromJson(Map<String, dynamic> j) => KbChunk(
    id: j['id'] as String,
    kind: j['kind'] as String,
    titleBn: j['title_bn'] as String? ?? '',
    titleEn: j['title_en'] as String? ?? '',
    textBn: j['text_bn'] as String? ?? '',
    textEn: j['text_en'] as String? ?? '',
    tags: [
      for (final t in j['tags'] as List<dynamic>? ?? const []) t as String,
    ],
    sources: [
      for (final s in j['sources'] as List<dynamic>? ?? const []) s as String,
    ],
  );
}

/// The knowledge base, loaded once per app run.
final safetyKnowledgeProvider = FutureProvider<SafetyKnowledge>(
  (ref) => SafetyKnowledgeBase.load(),
);
