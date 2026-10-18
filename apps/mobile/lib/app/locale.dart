/// The app language the customer chose (Bangla by default, English as the
/// parallel). `MaterialApp.router(locale:)` watches [localeProvider], so a
/// switch rebuilds every open screen at once; the choice is kept in
/// SharedPreferences under [LocaleNotifier.prefsKey].
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';

/// The locale read from SharedPreferences before `runApp` (see `main.dart`),
/// so the first frame is already in the saved language. `null` (tests, or a
/// failed read) leaves [LocaleNotifier] to restore it asynchronously.
final initialLocaleProvider = Provider<Locale?>((_) => null);

final localeProvider = NotifierProvider<LocaleNotifier, Locale>(
  LocaleNotifier.new,
);

class LocaleNotifier extends Notifier<Locale> {
  static const prefsKey = 'locale';
  static const bangla = Locale('bn');
  static const english = Locale('en');
  static const supported = [bangla, english];

  /// Set once the user picked a language in this run; a slower restore must
  /// not overwrite it.
  bool _chosen = false;

  @override
  Locale build() {
    final initial = ref.watch(initialLocaleProvider);
    if (initial != null) return initial;
    restore();
    return bangla;
  }

  /// Reads the saved language; a missing, unknown or unreadable value keeps
  /// Bangla.
  static Future<Locale?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return parse(prefs.getString(prefsKey));
    } on Object catch (e) {
      Log.w('locale', 'could not read the saved language', e);
      return null;
    }
  }

  static Locale? parse(String? code) => switch (code) {
    'bn' => bangla,
    'en' => english,
    _ => null,
  };

  /// Applies the saved language, unless the user already chose one.
  Future<void> restore() async {
    final saved = await load();
    if (saved != null && !_chosen && saved != state) state = saved;
  }

  /// Switches the whole app now and saves the choice.
  Future<void> set(Locale locale) async {
    final next = parse(locale.languageCode) ?? bangla;
    _chosen = true;
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, next.languageCode);
    } on Object catch (e) {
      Log.w('locale', 'could not save the language', e);
    }
  }

  /// Bangla <-> English.
  Future<void> toggle() => set(state.languageCode == 'en' ? bangla : english);
}
