import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/appearance.dart';
import 'app/env.dart';
import 'app/locale.dart';
import 'core/audio/apa_audio.dart';
import 'core/log.dart';
import 'data/firebase/firebase_bootstrap.dart';
import 'data/native/bhorosha_native.dart';
import 'data/providers.dart';
import 'features/intervention/logic/audioplayers_apa_audio.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Edge-to-edge (Android 15 default): the app bar and bottom bar paint the
  // surface under transparent system bars.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Firebase is optional at boot: absent today, configured
  // once flutterfire has written real options. Every firebase_* consumer is
  // gated on this status through the providers.
  final firebaseStatus = await FirebaseBootstrap.tryInit();
  Log.i('boot', 'firebase=$firebaseStatus recording=${AppEnv.recording}');

  // Play Integrity warm-up is off the eleven-seconds path; a no-op when the
  // cloud project number is not configured.
  final native = MethodChannelBhoroshaNative();
  unawaited(native.prepareIntegrity(AppEnv.cloudProjectNumber));

  // Apa's voice: one low-latency player per bundled clip, created now so the
  // first clip follows the ScoreResponse within 300 ms.
  final audio = AudioplayersApaAudio();
  unawaited(audio.preload());

  // The saved language, so the first frame is already in it.
  final savedLocale = await LocaleNotifier.load();
  // The saved preset, mode and text size, for the same reason.
  final savedAppearance = await Appearance.load();

  runApp(
    ProviderScope(
      overrides: [
        ...dataOverrides(firebaseStatus),
        nativeProvider.overrideWithValue(native),
        apaAudioProvider.overrideWithValue(audio),
        initialLocaleProvider.overrideWithValue(savedLocale),
        initialAppearanceProvider.overrideWithValue(savedAppearance),
      ],
      child: const BhoroshaApp(),
    ),
  );
}
