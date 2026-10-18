import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Minimal structured logger. Never pass PIN digits, tokens, request bodies or
/// feature vectors to it; callers log route, status and timings only.
abstract final class Log {
  static void d(String tag, String message) => _emit(tag, message, 500);
  static void i(String tag, String message) => _emit(tag, message, 800);
  static void w(String tag, String message, [Object? error]) => _emit(
    tag,
    error == null ? message : '$message: ${error.runtimeType}',
    900,
  );
  static void e(String tag, String message, [Object? error, StackTrace? st]) =>
      _emit(
        tag,
        error == null ? message : '$message: ${error.runtimeType}',
        1000,
        st,
      );

  static void _emit(String tag, String message, int level, [StackTrace? st]) {
    if (!kDebugMode && level < 900) return;
    developer.log(message, name: 'bhorosha.$tag', level: level, stackTrace: st);
    // developer.log never reaches logcat on Android; debug builds also print
    // so `adb logcat -s flutter` shows the same line on a device.
    if (kDebugMode) {
      debugPrint('bhorosha.$tag: $message${st == null ? '' : '\n$st'}');
    }
  }
}
