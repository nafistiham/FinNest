/// Firebase Cloud Messaging wiring.
///
/// Everything that touches `firebase_messaging` lives in this file and runs
/// only when [FirebaseStatus.configured] was returned by the bootstrap.
/// With Firebase absent, [Messaging.init] returns at once and the deep link
/// `bhorosha://approve/<id>` still works through the manifest intent filter
/// and go_router (adb-testable).
library;

import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/features/approve/logic/approve_link.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:go_router/go_router.dart';

/// Called for a push that arrives while the app is in the foreground, with
/// the parsed `deep_link` (empty when the payload carries none) and the raw
/// data map for the approve deep link.
typedef ForegroundMessageHandler = void Function(
  String deepLink,
  Map<String, dynamic> data,
);

/// Background isolate entry point. Registered only in the configured branch
/// of [Messaging.init]; it must stay top-level and only log (the app's
/// providers do not exist in that isolate).
@pragma('vm:entry-point')
Future<void> bhoroshaBackgroundMessageHandler(RemoteMessage message) async {
  Log.i(
    Messaging.tag,
    'background message ${message.messageId ?? '?'} '
    'keys=${message.data.keys.join(',')}',
  );
}

abstract final class Messaging {
  static const tag = 'fcm';

  /// Payload key carrying `bhorosha://approve/<id>` (server `actions.py`).
  static const deepLinkKey = 'deep_link';

  static StreamSubscription<RemoteMessage>? _opened;
  static StreamSubscription<RemoteMessage>? _foreground;

  /// Wires FCM when [status] is [FirebaseStatus.configured]; a complete
  /// no-op otherwise. Never throws: any Firebase error is logged and the
  /// app keeps running without push.
  static Future<void> init({
    required FirebaseStatus status,
    required GoRouter router,
    required ForegroundMessageHandler? onForegroundMessage,
  }) async {
    if (status != FirebaseStatus.configured) {
      Log.i(tag, 'firebase $status, push disabled; deep links only');
      return;
    }
    try {
      await _initConfigured(router, onForegroundMessage);
    } on Object catch (e, st) {
      Log.e(tag, 'init failed, continuing without push', e, st);
    }
  }

  /// Drops the stream subscriptions (tests and hot restart).
  static Future<void> dispose() async {
    await _opened?.cancel();
    await _foreground?.cancel();
    _opened = null;
    _foreground = null;
  }

  static Future<void> _initConfigured(
    GoRouter router,
    ForegroundMessageHandler? onForegroundMessage,
  ) async {
    final messaging = FirebaseMessaging.instance;

    FirebaseMessaging.onBackgroundMessage(bhoroshaBackgroundMessageHandler);

    final settings = await messaging.requestPermission(provisional: true);
    Log.i(tag, 'permission ${settings.authorizationStatus.name}');

    // Cold start from a notification tap.
    final initial = await messaging.getInitialMessage();
    if (initial != null) _open(router, initial);

    // Background → foreground via a notification tap.
    await _opened?.cancel();
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(
      (m) => _open(router, m),
    );

    // Already in the foreground: hand the shell what it needs for a banner.
    await _foreground?.cancel();
    _foreground = FirebaseMessaging.onMessage.listen((m) {
      final link = deepLinkOf(m.data);
      Log.i(tag, 'foreground message, link=${link != null}');
      onForegroundMessage?.call(link?.toString() ?? '', m.data);
    });
  }

  /// The approve deep link in a payload, or `null` when absent or malformed.
  static ApproveLink? deepLinkOf(Map<String, dynamic> data) {
    final raw = data[deepLinkKey];
    return raw is String ? ApproveLink.tryParse(raw) : null;
  }

  static void _open(GoRouter router, RemoteMessage message) =>
      openData(router, message.data);

  /// Routes a tapped notification's [data] (`getInitialMessage` on a cold
  /// start, `onMessageOpenedApp` from the background) to its approve link.
  /// Signed out, the router's guard keeps the link for after login.
  static void openData(GoRouter router, Map<String, dynamic> data) {
    final link = deepLinkOf(data);
    if (link == null) {
      Log.w(tag, 'opened message without a valid deep link');
      return;
    }
    Log.i(tag, 'routing to approve');
    router.go(link.toRoute());
  }
}
