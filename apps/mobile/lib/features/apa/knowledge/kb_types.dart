/// Shared types of the on-device safety knowledge base.
///
/// The knowledge base is a bundled asset (`assets/fna_kb/safety_kb.v1.json`)
/// searched on the phone. FNA's voice and text agents reach it only through
/// the `search_safety_knowledge` tool; the offline guide reads it directly.
library;

/// One curated chunk, in both languages.
class KbChunk {
  const KbChunk({
    required this.id,
    required this.kind,
    required this.titleBn,
    required this.titleEn,
    required this.textBn,
    required this.textEn,
    this.tags = const [],
    this.sources = const [],
  });

  /// `snake_case`; playbook chunks end in `__signs`, `__do_now`, `__prevent`.
  final String id;

  /// One of [KbKind].
  final String kind;
  final String titleBn;
  final String titleEn;

  /// Raw text; may contain the `{{HELPLINE}}` placeholder.
  final String textBn;
  final String textEn;
  final List<String> tags;

  /// Source ids defined in the asset's `sources` map.
  final List<String> sources;

  /// The scam id of a playbook chunk (`fake_agent_care_call` for
  /// `fake_agent_care_call__do_now`), else `null`.
  String? get playbook {
    final i = id.indexOf('__');
    return kind == KbKind.playbook && i > 0 ? id.substring(0, i) : null;
  }
}

abstract final class KbKind {
  static const playbook = 'playbook';
  static const concept = 'concept';
  static const action = 'action';
  static const appFeature = 'app_feature';
  static const helpline = 'helpline';
  static const all = {playbook, concept, action, appFeature, helpline};
}

/// One search result.
class KbHit {
  const KbHit(this.chunk, this.score);
  final KbChunk chunk;

  /// Higher is better; only comparable within one search.
  final double score;
}

/// What the tools and the offline guide need from the knowledge base.
abstract class SafetyKnowledge {
  /// Best [k] chunks for [query] (Bangla, English or mixed), best first.
  /// Empty when nothing scores above the floor. Never throws.
  List<KbHit> search(String query, {int k = 4});

  /// The chunk with [id], or `null`.
  KbChunk? byId(String id);

  /// The chunk's text in the app language with `{{HELPLINE}}` filled in.
  String textOf(KbChunk chunk, {required bool english});

  /// The chunk's title in the app language.
  String titleOf(KbChunk chunk, {required bool english});

  /// A generic label of the chunk's best source for the model: `official
  /// guidance`, `news report` or `FinNest app`. Never a source name (source
  /// names can contain real brands).
  String sourceLevelOf(KbChunk chunk);
}
