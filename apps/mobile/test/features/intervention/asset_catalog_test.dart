import 'package:bhorosha/core/ids.dart';
import 'package:bhorosha/features/intervention/logic/asset_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fourIds = [
    'apa_hold_call_active',
    'apa_hold_screen_share',
    'apa_delay_new_payee',
    'apa_generic_caution',
  ];

  test('maps the four ids to bundled files', () {
    expect(AssetCatalog.byId.keys, unorderedEquals(fourIds));
    for (final id in fourIds) {
      expect(AssetCatalog.fileFor(id), 'assets/audio/$id.ogg');
      // Gemini's Sulafat, at a customer-care pace: the shortest line is 6.6 s.
      expect(AssetCatalog.durationMs[id], greaterThan(5000));
    }
  });

  test('indexes every known script by sha256, including the apa_turn stub', () {
    expect(AssetCatalog.scripts.length, 5);
    expect(AssetCatalog.legacyScripts.length, 3);
    expect(AssetCatalog.olderScripts.length, 1);
    expect(AssetCatalog.bySha256.length, 9);
    for (final e in AssetCatalog.scripts.entries) {
      expect(AssetCatalog.bySha256[sha256Hex(e.value)], e.key);
      expect(AssetCatalog.idForScript(e.value), e.key);
    }
  });

  test('the pre-rebrand server scripts still resolve to the same clips', () {
    for (final e in AssetCatalog.legacyScripts.entries) {
      expect(e.value, isNot(equals(AssetCatalog.scripts[e.key])));
      expect(AssetCatalog.idForScript(e.value), e.key);
    }
    for (final e in AssetCatalog.olderScripts.entries) {
      expect(e.value, isNot(equals(AssetCatalog.scripts[e.key])));
      expect(AssetCatalog.idForScript(e.value), e.key);
    }
  });

  test('the stub line introduces the assistant with the exact phrase', () {
    expect(
      AssetCatalog.scripts[AssetCatalog.apaTextDefault],
      startsWith('আমি ফিননেস্ট সহকারী বলছি।'),
    );
  });

  test('the exact server scripts resolve to their clip', () {
    expect(
      AssetCatalog.idForScript(
        'আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন। কলে থাকা অবস্থায় পিন বদলানো বা কোড বলা নিরাপদ নয়। আমি এটা এক ঘণ্টার জন্য আটকে রাখলাম। আপনার আপনজন কাউকে দিয়ে যাচাই করিয়ে নিন।',
      ),
      'apa_hold_call_active',
    );
    expect(
      AssetCatalog.idForScript(
        'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন। এই লেনদেনটি নিয়ে আমার কিছু সন্দেহ আছে, চলুন একবার যাচাই করি।',
      ),
      'apa_generic_caution',
    );
  });

  test('apa_text_default is indexed but has no file yet', () {
    final stub = AssetCatalog.scripts[AssetCatalog.apaTextDefault]!;
    expect(AssetCatalog.idForScript(stub), AssetCatalog.apaTextDefault);
    expect(AssetCatalog.fileFor(AssetCatalog.apaTextDefault), isNull);
  });

  test('unknown ids and texts return null', () {
    expect(AssetCatalog.fileFor('apa_future_clip'), isNull);
    expect(AssetCatalog.idForScript('কিছু অন্য কথা'), isNull);
    expect(AssetCatalog.idForScript(''), isNull);
    // A one-character change misses the index: the hash is exact on purpose.
    expect(
      AssetCatalog.idForScript(
        'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন। এই লেনদেনটি নিয়ে আমার কিছু সন্দেহ আছে, চলুন একবার যাচাই করি',
      ),
      isNull,
    );
  });
}
