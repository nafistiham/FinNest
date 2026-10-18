/// How the app looks: the colour preset, light / dark /
/// system mode and the text size. Each choice applies at once (the theme
/// lerps through `AnimatedTheme`) and is kept in SharedPreferences under
/// `theme_preset`, `theme_mode` and `text_size`. `main.dart` reads them
/// before `runApp` ([Appearance.load] → [initialAppearanceProvider]) so the
/// first frame is already right; without that (tests) the notifiers restore
/// them asynchronously, like the locale.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import 'theme/palette.dart';

const _tag = 'appearance';

/// Normal = the system text scale; large = system scale x 1.15. The final
/// scale is clamped to [minScale, maxScale] app-wide (see [bhTextScaler]).
enum BhTextSize {
  normal('normal', 1.0),
  large('large', 1.15);

  const BhTextSize(this.id, this.factor);

  final String id;
  final double factor;

  static BhTextSize? parse(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// Clamp of the app-wide text scale so money screens never overflow.
const minTextScale = 1.0;
const maxTextScale = 1.4;

/// The text scaler `MaterialApp.builder` installs: the system scale times
/// [size]'s factor, clamped to [minTextScale]..[maxTextScale].
TextScaler bhTextScaler(TextScaler system, BhTextSize size) {
  final scale = (system.scale(100) / 100 * size.factor).clamp(
    minTextScale,
    maxTextScale,
  );
  return TextScaler.linear(scale);
}

String themeModeId(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'system',
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
};

ThemeMode? parseThemeMode(String? id) => switch (id) {
  'system' => ThemeMode.system,
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => null,
};

/// The three appearance choices together.
@immutable
class Appearance {
  const Appearance({
    this.preset = BhPreset.teal,
    this.mode = ThemeMode.system,
    this.textSize = BhTextSize.normal,
  });

  static const defaults = Appearance();

  static const presetKey = 'theme_preset';
  static const modeKey = 'theme_mode';
  static const textSizeKey = 'text_size';

  final BhPreset preset;
  final ThemeMode mode;
  final BhTextSize textSize;

  /// Reads the saved choices. Unknown values fall back to the defaults (and
  /// are logged); an unreadable store returns `null`.
  static Future<Appearance?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return fromPrefs(prefs);
    } on Object catch (e) {
      Log.w(_tag, 'could not read the saved appearance', e);
      return null;
    }
  }

  static Appearance fromPrefs(SharedPreferences prefs) => Appearance(
    preset: _read(prefs, presetKey, BhPreset.parse) ?? defaults.preset,
    mode: _read(prefs, modeKey, parseThemeMode) ?? defaults.mode,
    textSize: _read(prefs, textSizeKey, BhTextSize.parse) ?? defaults.textSize,
  );

  static T? _read<T>(
    SharedPreferences prefs,
    String key,
    T? Function(String?) parse,
  ) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    final value = parse(raw);
    if (value == null) Log.w(_tag, 'unknown $key "$raw", using the default');
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.preset == preset &&
      other.mode == mode &&
      other.textSize == textSize;

  @override
  int get hashCode => Object.hash(preset, mode, textSize);

  @override
  String toString() =>
      'Appearance(${preset.id}, ${themeModeId(mode)}, ${textSize.id})';
}

/// The appearance read before `runApp`; `null` (tests, failed read) lets
/// the notifiers restore asynchronously.
final initialAppearanceProvider = Provider<Appearance?>((_) => null);

final themePresetProvider = NotifierProvider<ThemePresetNotifier, BhPreset>(
  ThemePresetNotifier.new,
);

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

final textSizeProvider = NotifierProvider<TextSizeNotifier, BhTextSize>(
  TextSizeNotifier.new,
);

/// One persisted appearance choice.
abstract class _PrefNotifier<T> extends Notifier<T> {
  String get prefsKey;
  T pick(Appearance a);
  String idOf(T value);

  /// Set once the user chose in this run; a slower restore must not win.
  bool _chosen = false;

  @override
  T build() {
    final initial = ref.watch(initialAppearanceProvider);
    if (initial != null) return pick(initial);
    _restore();
    return pick(Appearance.defaults);
  }

  Future<void> _restore() async {
    final saved = await Appearance.load();
    if (saved == null || _chosen) return;
    final value = pick(saved);
    if (value != state) state = value;
  }

  /// Applies [value] now and saves it.
  Future<void> set(T value) async {
    _chosen = true;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, idOf(value));
    } on Object catch (e) {
      Log.w(_tag, 'could not save $prefsKey', e);
    }
  }
}

class ThemePresetNotifier extends _PrefNotifier<BhPreset> {
  @override
  String get prefsKey => Appearance.presetKey;
  @override
  BhPreset pick(Appearance a) => a.preset;
  @override
  String idOf(BhPreset value) => value.id;
}

class ThemeModeNotifier extends _PrefNotifier<ThemeMode> {
  @override
  String get prefsKey => Appearance.modeKey;
  @override
  ThemeMode pick(Appearance a) => a.mode;
  @override
  String idOf(ThemeMode value) => themeModeId(value);
}

class TextSizeNotifier extends _PrefNotifier<BhTextSize> {
  @override
  String get prefsKey => Appearance.textSizeKey;
  @override
  BhTextSize pick(Appearance a) => a.textSize;
  @override
  String idOf(BhTextSize value) => value.id;
}

/// `ref.read` of either a `Ref` or a `WidgetRef`.
typedef AppearanceReader = T Function<T>(ProviderListenable<T> provider);

/// Back to Teal trust, system mode, normal text (the demo panel's "সব রিসেট"
/// calls this so a presenter always starts from the defaults).
Future<void> resetAppearance(AppearanceReader read) async {
  const d = Appearance.defaults;
  await Future.wait([
    read(themePresetProvider.notifier).set(d.preset),
    read(themeModeProvider.notifier).set(d.mode),
    read(textSizeProvider.notifier).set(d.textSize),
  ]);
}
