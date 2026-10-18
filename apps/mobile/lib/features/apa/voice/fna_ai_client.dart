/// The one `FirebaseAI` client of FNA: Gemini Live, the chat agent and Gemini
/// TTS on the same location all read [fnaAiProvider], so every request carries
/// limited-use App Check tokens.
///
/// Why one provider: `FirebaseAI.agentPlatform` caches its instance by
/// `<app name>::agentPlatform::<location>` and ignores
/// `useLimitedUseAppCheckTokens` on a cache hit (firebase_ai 5.0.0,
/// `firebase_ai.dart` lines 69-73). Whoever calls it first for a location
/// fixes the flag for the whole process. A stray
/// `FirebaseAI.agentPlatform(location: 'us-central1')` without the flag
/// (today `FirebaseApaGenerator` and `FirebaseApaLiveService` do this) that
/// runs first silently turns limited-use tokens off for Live and text alike.
/// Route every such caller through this provider. Gemini TTS
/// uses the `global` location, which is a separate cache entry.
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Live client ([AppEnv.apaLiveLocation]), or `null` when Firebase is
/// not configured (the same gate as `apaLiveServiceProvider`): callers then
/// use their offline path and never touch `firebase_ai`.
final fnaAiProvider = Provider<FirebaseAI?>(
  (ref) => _clientFor(ref, AppEnv.apaLiveLocation),
);

/// The text client ([AppEnv.fnaTextLocation], `global` by default): the chat
/// agent and the older Gemini text path. The Gemini 3.x text models are not
/// served on the Live location in this project, so text needs its own
/// location (a separate `agentPlatform` cache entry).
final fnaTextAiProvider = Provider<FirebaseAI?>(
  (ref) => _clientFor(ref, AppEnv.fnaTextLocation),
);

FirebaseAI? _clientFor(Ref ref, String location) {
  if (ref.watch(firebaseStatusProvider) != FirebaseStatus.configured) {
    return null;
  }
  try {
    return fnaAgentPlatform(location);
  } on Object catch (e) {
    // No default Firebase app after all: behave as unconfigured.
    Log.w('fna.ai', 'FirebaseAI unavailable', e);
    return null;
  }
}

/// Every `FirebaseAI.agentPlatform` call in the app goes through here, so the
/// first call for a location (which fixes the cached instance) always asks
/// for limited-use App Check tokens.
FirebaseAI fnaAgentPlatform(String location) => FirebaseAI.agentPlatform(
  location: location,
  useLimitedUseAppCheckTokens: true,
);
