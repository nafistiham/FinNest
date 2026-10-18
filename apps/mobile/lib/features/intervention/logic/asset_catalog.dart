import '../../../core/ids.dart';

/// The bundled FinNest Assistant clips and the exact server scripts they were
/// rendered from (mirroring `intervene.py` `SCRIPTS` in risk-mw).
/// Rendered by `tool/render_apa_audio_gemini.py` with Gemini 3.8 Flash Lite
/// TTS, voice Sulafat, bn-BD, the same expressive delivery as the live lines
/// (Bangladeshi Bengali, Gemini, expressive; never the phone's own
/// voice), so a fallback clip sounds like the live voice.
/// Clips are also indexed by `sha256(script text)` so a line that arrives
/// without an asset id, or with an id the client has never seen, still finds
/// its clip when the text matches (audio paragraph). The
/// pre-rebrand "আপা বলছি" scripts stay indexed under [legacyScripts] until the
/// server copy change is deployed, so the live service keeps
/// resolving to the same clips.
abstract final class AssetCatalog {
  /// The stub `/v1/apa/turn` reply: indexed by hash, no clip yet.
  static const String apaTextDefault = 'apa_text_default';

  /// Asset id -> bundled file (declared under `assets/audio/` in pubspec).
  static const Map<String, String> byId = {
    'apa_hold_call_active': 'assets/audio/apa_hold_call_active.ogg',
    'apa_hold_screen_share': 'assets/audio/apa_hold_screen_share.ogg',
    'apa_delay_new_payee': 'assets/audio/apa_delay_new_payee.ogg',
    'apa_generic_caution': 'assets/audio/apa_generic_caution.ogg',
  };

  /// Clip length in milliseconds, measured from the shipped OGG/Opus files.
  /// `PlayerMode.lowLatency` (SoundPool) fires no completion event, so the
  /// queue uses these to know when the next clip may start.
  static const Map<String, int> durationMs = {
    'apa_hold_call_active': 15567,
    'apa_hold_screen_share': 7167,
    'apa_delay_new_payee': 11087,
    'apa_generic_caution': 8047,
  };

  /// Asset id -> the exact Bangla script the server sends for it. Copied
  /// byte-for-byte from `intervene.py` `apa_turn` in risk-mw.
  static const Map<String, String> scripts = {
    'apa_hold_call_active': 'আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন। কলে থাকা অবস্থায় পিন বদলানো বা কোড বলা নিরাপদ নয়। আমি এটা এক ঘণ্টার জন্য আটকে রাখলাম। আপনার আপনজন কাউকে দিয়ে যাচাই করিয়ে নিন।',
    'apa_hold_screen_share': 'আপনার স্ক্রিন এখন অন্য কেউ দেখছে। আগে স্ক্রিন শেয়ার বন্ধ করুন, তারপর আবার চেষ্টা করুন।',
    'apa_delay_new_payee': 'এই নম্বরে আপনি আগে কখনো টাকা পাঠাননি, আর অঙ্কটাও বড়। এক ঘণ্টা পরে পাঠানো যাবে। চাইলে আপনার আপনজনকে দিয়ে এখনই অনুমোদন করাতে পারেন।',
    'apa_generic_caution': 'আমি ফিননেস্ট সহকারী বলছি। একটু থামুন। এই লেনদেনটি নিয়ে আমার কিছু সন্দেহ আছে, চলুন একবার যাচাই করি।',
    apaTextDefault: 'আমি ফিননেস্ট সহকারী বলছি। আপনি যা করতে চাইছেন তা আমি দেখছি। কেউ যদি ফোনে কোড বা পিন চায়, কখনো দেবেন না। বলুন, কী সাহায্য করতে পারি?',
  };

  /// Asset id -> scripts the server sent before: the pre-rebrand "আপা" lines
  /// and the first FinNest stub line without "বলছি" (the exact-intro rule).
  /// The clips were re-rendered with the new wording;
  /// these keep the old texts resolving to the same clip while the deployed
  /// service still sends them. [bySha256] keys them, so the same id may
  /// appear under more than one old text.
  static const Map<String, String> legacyScripts = {
    'apa_hold_call_active': 'আপা বলছি। আপনি এখন কলে আছেন। কলে থাকা অবস্থায় পিন বদলানো বা কোড বলা নিরাপদ নয়। আমি এটা এক ঘণ্টার জন্য আটকে রাখলাম। আপনার আপনজন কাউকে দিয়ে যাচাই করিয়ে নিন।',
    'apa_generic_caution': 'আপা বলছি। একটু থামুন। এই লেনদেনটি নিয়ে আমার কিছু সন্দেহ আছে, চলুন একবার যাচাই করি।',
    apaTextDefault: 'আমি আপা। আপনি যা করতে চাইছেন তা আমি দেখছি। কেউ যদি ফোনে কোড বা পিন চায়, কখনো দেবেন না। বলুন, কী সাহায্য করতে পারি?',
  };

  /// Older FinNest stub text (before the "বলছি" intro), same clip slot.
  static const Map<String, String> olderScripts = {
    apaTextDefault: 'আমি ফিননেস্ট সহকারী। আপনি যা করতে চাইছেন তা আমি দেখছি। কেউ যদি ফোনে কোড বা পিন চায়, কখনো দেবেন না। বলুন, কী সাহায্য করতে পারি?',
  };

  /// `sha256Hex(script)` -> asset id, for every known script, current and
  /// legacy.
  static final Map<String, String> bySha256 = {
    for (final e in legacyScripts.entries) sha256Hex(e.value): e.key,
    for (final e in olderScripts.entries) sha256Hex(e.value): e.key,
    for (final e in scripts.entries) sha256Hex(e.value): e.key,
  };

  /// Bundled file for [id], or null when no clip ships for it (unknown ids and
  /// [apaTextDefault]).
  static String? fileFor(String id) => byId[id];

  /// Asset id whose script is exactly [scriptBn], or null.
  static String? idForScript(String scriptBn) =>
      scriptBn.isEmpty ? null : bySha256[sha256Hex(scriptBn)];
}
