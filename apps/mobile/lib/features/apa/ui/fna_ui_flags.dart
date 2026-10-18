/// UI-side platform hooks of the FNA voice assistant: providers so
/// widget tests can override what the platform reports. The feature flag
/// itself is `fnaVoiceAgentEnabledProvider` (voice/fna_providers.dart).
library;

import 'package:bhorosha/core/log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// `true` when `RECORD_AUDIO` is already granted, so "Talk" skips the
/// microphone explanation. Never throws: a platform error reads as `false`.
final fnaMicGrantedProvider = Provider<Future<bool> Function()>(
  (_) => () async {
    try {
      return await Permission.microphone.isGranted;
    } on Object catch (e) {
      Log.w('fna.ui', 'microphone status failed', e);
      return false;
    }
  },
);

/// Opens this app's page in the system settings (microphone denied for good).
final fnaOpenSettingsProvider = Provider<Future<bool> Function()>(
  (_) => () async {
    try {
      return await openAppSettings();
    } on Object catch (e) {
      Log.w('fna.ui', 'openAppSettings failed', e);
      return false;
    }
  },
);
