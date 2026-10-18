/// Apa's curated guidance (`assets/apa/rules.json`): the five safety rules,
/// the rotating tips and the plain-language list of what holds a transfer.
///
/// The asset is the source of truth. Until the pubspec lists `assets/apa/`,
/// loading it fails and [ApaContent.embedded] (the same JSON compiled in)
/// is used; a test keeps the two identical.
library;

import 'dart:convert';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/logic/apa_content_data.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One bilingual entry: a rule, a tip or a hold explainer.
class ApaGuideItem {
  const ApaGuideItem({
    required this.id,
    required this.titleBn,
    required this.titleEn,
    required this.bodyBn,
    required this.bodyEn,
  });

  /// The `{helpline}` placeholder is filled from `AppEnv.helpline` here, in
  /// Bangla digits for the `*_bn` fields and Latin digits for `*_en`.
  factory ApaGuideItem.fromJson(Map<String, dynamic> j) {
    String bn(String key, [String? alt]) => ApaHelpline.fill(
      (j[key] ?? (alt == null ? null : j[alt]) ?? '') as String,
      english: false,
    );
    String en(String key, [String? alt]) => ApaHelpline.fill(
      (j[key] ?? (alt == null ? null : j[alt]) ?? '') as String,
      english: true,
    );
    return ApaGuideItem(
      id: (j['id'] ?? j['code'] ?? '') as String,
      titleBn: bn('title_bn'),
      titleEn: en('title_en'),
      bodyBn: bn('body_bn', 'bn'),
      bodyEn: en('body_en', 'en'),
    );
  }

  final String id;
  final String titleBn;
  final String titleEn;
  final String bodyBn;
  final String bodyEn;
}

class ApaContent {
  const ApaContent({
    required this.rules,
    required this.tips,
    required this.holds,
  });

  factory ApaContent.parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    List<ApaGuideItem> list(String key) => [
      for (final item in (json[key] as List<dynamic>? ?? const []))
        ApaGuideItem.fromJson(item as Map<String, dynamic>),
    ];
    return ApaContent(
      rules: list('rules'),
      tips: list('tips'),
      holds: list('holds'),
    );
  }

  static const assetPath = 'assets/apa/rules.json';

  /// The compiled-in copy of [assetPath].
  static final ApaContent embedded = ApaContent.parse(apaContentJson);

  /// The five rules, in order.
  final List<ApaGuideItem> rules;

  /// One is shown on Home when all is clear (rotates daily).
  final List<ApaGuideItem> tips;

  /// What can hold a transfer, keyed by the risk-mw reason code.
  final List<ApaGuideItem> holds;

  ApaGuideItem? rule(String id) => rules.where((r) => r.id == id).firstOrNull;

  /// Loads [assetPath] from [bundle]; [embedded] when it is missing or bad.
  static Future<ApaContent> load(AssetBundle bundle) async {
    try {
      return ApaContent.parse(await bundle.loadString(assetPath));
    } on Object catch (e) {
      Log.d('apa', 'guide asset not bundled (${e.runtimeType}); embedded copy');
      return embedded;
    }
  }
}

final apaContentProvider = FutureProvider<ApaContent>(
  (_) => ApaContent.load(rootBundle),
);

/// The content right now: the loaded asset, or the embedded copy meanwhile.
final apaContentSyncProvider = Provider<ApaContent>(
  (ref) => ref.watch(apaContentProvider).value ?? ApaContent.embedded,
);
