/// Gemini TTS on Vertex AI through Firebase AI Logic for FNA's dynamic lines
/// (dynamic text sent from the backend is voiced by the Vertex AI Gemini TTS
/// model, not the on-device one).
///
/// The same engine, voice and delivery as risk-mw `app/tts.py`, so the
/// phone and the server sound alike:
/// `gemini-3.8-flash-lite-tts` on the `global` location, prebuilt voice
/// `Sulafat`, and the urgent style, which the 3.8 engine takes as
/// `speech_metadata.style` because it reads its text as a verbatim
/// transcript. No API key: `FirebaseAI.agentPlatform` (Vertex) carries the
/// App Check token.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';

import '../../../app/env.dart';
import '../../../core/log.dart';
import '../../apa/voice/fna_ai_client.dart';
import 'wav.dart';

const _tag = 'voice.gemini';

/// FNA's voice, copied from risk-mw `app/tts.py` and `app/settings.py`.
abstract final class FnaVoiceStyle {
  /// `Settings.tts_voice`.
  static const voiceName = 'Sulafat';
  static const languageCode = 'bn-BD';

  /// `tts.URGENT_STYLE` (from `scripts/render_apa_audio.py STYLES["urgent"]`)
  /// as the server sends it in `speech_metadata.style`: `.rstrip(": ")`.
  /// The delivery. Bangladeshi Bengali (Dhaka, not Kolkata), spoken as a
  /// trustworthy, professional, empathetic financial customer-care agent:
  /// calm and clear, never excited, dramatic or over-familiar.
  static const urgentStyle =
      'Speak in Bangladeshi Bengali with the natural Dhaka accent and '
      'pronunciation, as a trustworthy, professional, empathetic and helpful '
      'financial customer-care agent speaking to a customer: soft-spoken, '
      'low-key and unhurried, in an even, level tone at a slow, steady pace, '
      'like a bank call-centre agent calmly reading a notice. Composed and '
      'reassuring, with only gentle emphasis on the key words; no urgency, '
      'no drama, no raised voice, never excited, intense, emotional, '
      'over-familiar or panicked';

  /// Only the Gemini 2.x TTS models take the style before the text
  /// (`tts.PROMPT_STYLE_MODELS`); any other model gets it as metadata, so a
  /// verbatim engine never reads the English direction aloud.
  static bool takesPromptStyle(String model) => model.startsWith('gemini-2.');

  /// The English delivery: the same agent, speaking English with a
  /// Bangladeshi accent, for the English UI (the spoken line follows the
  /// app language).
  static const englishStyle =
      'Speak in clear, natural English with a Bangladeshi accent, as a '
      'trustworthy, professional, empathetic and helpful financial '
      'customer-care agent speaking to a customer: soft-spoken, low-key and '
      'unhurried, in an even, level tone at a slow, steady pace, like a bank '
      'call-centre agent calmly reading a notice. Composed and reassuring, '
      'with only gentle emphasis on the key words; no urgency, no drama, no '
      'raised voice, never excited, intense, emotional, over-familiar or '
      'panicked';

  /// `en-US` for the English UI; everything else is Bangla.
  static const englishLanguageCode = 'en-US';

  static String styleFor(String languageCode) =>
      languageCode.startsWith('en') ? englishStyle : urgentStyle;
}

/// One synthesis: audio bytes and their mime type as the model sent them
/// (`audio/L16;codec=pcm;rate=24000` for raw PCM).
class GeminiTtsAudio {
  const GeminiTtsAudio(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;

  /// A playable WAV: a WAV as is, raw PCM wrapped in a 44-byte header.
  Uint8List toWav() =>
      Wav.isWav(bytes) ? bytes : Wav.wrapPcm(bytes, rate: Wav.rateOf(mimeType));
}

/// One model call for [textBn]; `null` or a throw is a failure.
typedef GeminiTtsEngine = Future<GeminiTtsAudio?> Function(String textBn);

/// The same engine with the language of the line (`en-US` for the English
/// UI): a line in another language than Bangla needs it.
typedef GeminiTtsEngineIn = Future<GeminiTtsAudio?> Function(
  String text,
  String languageCode,
);

/// The session's Gemini TTS: a WAV per text, cached (LRU, [maxEntries]),
/// under a [deadline], and at most one model call per text for the whole
/// session (the cost guard): a text that failed, timed out or was evicted is
/// never sent again, so it goes to the phone's own voice. Never throws.
class GeminiTts {
  GeminiTts({
    required this._engine,
    this.engineIn,
    bool Function()? enabled,
    this.deadline = const Duration(seconds: 6),
    this.maxEntries = 16,
  }) : _enabled = enabled ?? (() => true);

  final GeminiTtsEngine _engine;

  /// The engine with a language, for lines that are not Bangla.
  final GeminiTtsEngineIn? engineIn;
  final bool Function() _enabled;
  final Duration deadline;
  final int maxEntries;

  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  final Set<String> _attempted = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// Model calls made this session (tests and the demo panel).
  int calls = 0;

  /// Whether this path is on: Firebase configured and `AppEnv.geminiTts`.
  bool get enabled => _enabled();

  /// Texts cached right now, oldest first (tests).
  /// The texts cached this session (the language prefix of the key dropped).
  List<String> get cachedTexts => List.unmodifiable([
    for (final k in _cache.keys) k.substring(k.indexOf('|') + 1),
  ]);

  /// A WAV of [textBn] in FNA's voice, or `null` (off, failed, past the
  /// deadline, or already tried this session).
  Future<Uint8List?> wav(
    String textBn, {
    String languageCode = FnaVoiceStyle.languageCode,
  }) async {
    if (!enabled || textBn.trim().isEmpty) return null;
    // The app language decides what is spoken: the same text in two
    // languages is two renders.
    final key = '$languageCode|$textBn';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      Log.d(_tag, 'cache hit (${textBn.length} chars)');
      return hit;
    }
    final pending = _inFlight[key];
    final Future<Uint8List?> call;
    if (pending != null) {
      call = pending;
    } else {
      if (!_attempted.add(key)) {
        Log.d(_tag, 'already tried this session; not calling again');
        return null;
      }
      calls++;
      call = _synthesise(textBn, languageCode, key);
      _inFlight[key] = call;
      unawaited(call.whenComplete(() => _inFlight.remove(key)));
    }
    try {
      return await call.timeout(deadline);
    } on TimeoutException {
      // A late answer still fills the cache for a replay; it never plays now.
      Log.w(_tag, 'no audio within ${deadline.inMilliseconds} ms');
      return null;
    }
  }

  Future<Uint8List?> _synthesise(
    String textBn,
    String languageCode,
    String key,
  ) async {
    final clock = Stopwatch()..start();
    try {
      final GeminiTtsAudio? audio;
      if (languageCode == FnaVoiceStyle.languageCode) {
        audio = await _engine(textBn);
      } else if (engineIn case final inLanguage?) {
        audio = await inLanguage(textBn, languageCode);
      } else {
        Log.w(_tag, 'no engine for $languageCode');
        return null;
      }
      if (audio == null || audio.bytes.isEmpty) {
        Log.w(_tag, 'no audio part in the answer');
        return null;
      }
      final wav = audio.toWav();
      _cache[key] = wav;
      while (_cache.length > maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      Log.i(
        _tag,
        '${audio.bytes.length} bytes (${audio.mimeType}) in '
        '${clock.elapsedMilliseconds} ms',
      );
      return wav;
    } on Object catch (e) {
      Log.w(_tag, 'synthesis failed', e);
      return null;
    }
  }
}

/// [GeminiTtsEngine] on `firebase_ai` 5.0: `FirebaseAI.agentPlatform` is the
/// Vertex AI backend (5.0's name for `vertexAI`), so App Check and the
/// project's Vertex quota apply, never an API key. The model is created on
/// first use, so a missing Firebase app throws inside the call.
class FirebaseGeminiTtsEngine {
  FirebaseGeminiTtsEngine({
    this.model = AppEnv.geminiTtsModel,
    this.fallbackModel = AppEnv.geminiTtsFallbackModel,
    this.location = AppEnv.geminiTtsLocation,
    this.style = AppEnv.geminiTtsStyle,
    this.open,
  });

  /// The model in use: Lite TTS, or the fallback once it answered "not
  /// found" (risk-mw `app/tts.py` moves engines the same way).
  String model;
  final String fallbackModel;
  final String location;

  /// Whether the delivery goes with the line (off for the session once
  /// Vertex rejects the metadata field).
  bool style;

  /// Builds a model for an id: injected in tests, Vertex otherwise.
  final GenerativeModel Function(String model)? open;

  /// One model per language (the generation config carries the language).
  final Map<String, GenerativeModel> _models = {};

  /// Builds the model for [id]: the injected opener in tests, Vertex
  /// through Firebase AI otherwise.
  GenerativeModel _modelFor(String id, String languageCode) =>
      open?.call(id) ??
      fnaAgentPlatform(location).generativeModel(
        model: id,
        generationConfig: generationConfigFor(languageCode),
      );

  /// The request body's one content, mirroring `tts.contents()`: a 2.x model
  /// gets the style before the text; any other gets it as the text part's
  /// `speechMetadata.style`. `firebase_ai` 5.0 has no field for that, so the
  /// part goes out as an [UnknownPart], which serialises its map verbatim;
  /// nothing that could be read aloud is added to the text.
  static Content contentFor(
    String model,
    String textBn, {
    bool style = true,
    String languageCode = FnaVoiceStyle.languageCode,
  }) {
    if (!style) return Content('user', [TextPart(textBn)]);
    final delivery = FnaVoiceStyle.styleFor(languageCode);
    if (FnaVoiceStyle.takesPromptStyle(model)) {
      return Content('user', [TextPart('$delivery: $textBn')]);
    }
    return Content('user', [
      UnknownPart({
        'text': textBn,
        'speechMetadata': {'style': delivery},
      }),
    ]);
  }

  static GenerationConfig get generationConfig =>
      generationConfigFor(FnaVoiceStyle.languageCode);

  /// Audio out, the one voice, the language of the app.
  static GenerationConfig generationConfigFor(String languageCode) =>
      GenerationConfig(
        responseModalities: [ResponseModalities.audio],
        speechConfig: SpeechConfig(
          voiceName: FnaVoiceStyle.voiceName,
          languageCode: languageCode,
        ),
      );

  Future<GeminiTtsAudio?> call(String textBn) =>
      callIn(textBn, FnaVoiceStyle.languageCode);

  /// [textBn] spoken in [languageCode] (`bn-BD`, or `en-US` for the
  /// English UI) with the delivery for that language.
  Future<GeminiTtsAudio?> callIn(String textBn, String languageCode) async {
    var generative = _models[languageCode] ??= _modelFor(model, languageCode);
    GenerateContentResponse response;
    try {
      response = await generative.generateContent([
        contentFor(model, textBn, style: style, languageCode: languageCode),
      ]);
    } on Object catch (e) {
      // A Preview model can vanish: "not found" moves this line and the
      // rest of the session to the fallback model (one extra call, once).
      if (model != fallbackModel && notFound(e)) {
        Log.w(_tag, 'model $model not found; falling back to $fallbackModel');
        model = fallbackModel;
        _models.clear();
        generative = _models[languageCode] = _modelFor(model, languageCode);
        response = await generative.generateContent([
          contentFor(model, textBn, style: style, languageCode: languageCode),
        ]);
      } else {
        // If Vertex rejects the metadata field, later lines go without the
        // style; this line is not retried (one call per text, the cost
        // guard).
        if (style && _rejectsStyle(e)) {
          style = false;
          Log.w(_tag, 'speechMetadata rejected; no style for the session');
        }
        rethrow;
      }
    }
    for (final part
        in response.candidates.firstOrNull?.content.parts ?? const <Part>[]) {
      if (part is InlineDataPart && part.bytes.isNotEmpty) {
        return GeminiTtsAudio(part.bytes, part.mimeType);
      }
    }
    return null;
  }

  /// 404, or a 400 naming the model: the same test as risk-mw `app/tts.py`.
  static bool notFound(Object e) {
    final s = e.toString();
    return s.contains('NOT_FOUND') ||
        s.contains('404') ||
        (s.contains('not found') && s.contains('model'));
  }

  static bool _rejectsStyle(Object e) {
    final s = e.toString();
    return s.contains('speechMetadata') ||
        s.contains('speech_metadata') ||
        s.contains('Unknown name');
  }
}
