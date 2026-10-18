import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/appearance.dart';
import '../../../app/l10n.dart';
import '../../../app/router.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/language_toggle.dart';
import '../../../app/widgets/section_header.dart';
import '../../../app/widgets/settings_row.dart';
import '../../../core/haptics.dart';
import '../logic/settings_actions.dart';
import 'widgets/preset_swatch_card.dart';

/// `/settings`: colour preset, light / dark / system,
/// text size with a live sample, language, phone safety, log out, and the
/// standing "never asks for your PIN or OTP" line. Every choice applies at
/// once (no Save button) and is remembered.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({
    this.haptics = const SystemHaptics(),
    this.version = '1.0',
    super.key,
  });

  final Haptics haptics;
  final String version;

  static Key presetKey(BhPreset p) => Key('preset_${p.id}');
  static Key modeKey(ThemeMode m) => Key('mode_${themeModeId(m)}');
  static Key textSizeKey(BhTextSize s) => Key('text_size_${s.id}');
  static const logoutKey = Key('settings_logout');
  static const safetyKey = Key('settings_safety');
  static const sampleKey = Key('settings_sample');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final preset = ref.watch(themePresetProvider);
    final mode = ref.watch(themeModeProvider);
    final size = ref.watch(textSizeProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          BhSpace.m,
          BhSpace.s,
          BhSpace.m,
          BhSpace.l,
        ),
        children: [
          SectionHeader(title: l10n.settingsAppearance),
          SettingsRow.control(
            title: l10n.settingsColour,
            child: LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - BhSpace.s) / 2;
                return Wrap(
                  spacing: BhSpace.s,
                  runSpacing: BhSpace.s,
                  children: [
                    for (final option in BhPreset.values)
                      SizedBox(
                        width: w,
                        child: PresetSwatchCard(
                          key: presetKey(option),
                          preset: option,
                          selected: option == preset,
                          onTap: () {
                            haptics.key();
                            ref.read(themePresetProvider.notifier).set(option);
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: BhSpace.m),
          SettingsRow.control(
            title: l10n.settingsMode,
            child: BhSegmented<ThemeMode>(
              haptics: haptics,
              selected: mode,
              onChanged: ref.read(themeModeProvider.notifier).set,
              segments: [
                BhSegment(
                  key: modeKey(ThemeMode.light),
                  value: ThemeMode.light,
                  label: l10n.modeLight,
                ),
                BhSegment(
                  key: modeKey(ThemeMode.dark),
                  value: ThemeMode.dark,
                  label: l10n.modeDark,
                ),
                BhSegment(
                  key: modeKey(ThemeMode.system),
                  value: ThemeMode.system,
                  label: l10n.modeSystem,
                ),
              ],
            ),
          ),
          const SizedBox(height: BhSpace.m),
          SettingsRow.control(
            title: l10n.settingsTextSize,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BhSegmented<BhTextSize>(
                  haptics: haptics,
                  selected: size,
                  onChanged: ref.read(textSizeProvider.notifier).set,
                  segments: [
                    BhSegment(
                      key: textSizeKey(BhTextSize.normal),
                      value: BhTextSize.normal,
                      label: l10n.textNormal,
                    ),
                    BhSegment(
                      key: textSizeKey(BhTextSize.large),
                      value: BhTextSize.large,
                      label: l10n.textLarge,
                    ),
                  ],
                ),
                const SizedBox(height: BhSpace.s),
                Container(
                  key: sampleKey,
                  color: p.surfaceVariant,
                  padding: const EdgeInsets.all(BhSpace.m),
                  // Already in the chosen size: the app-wide text scaler.
                  child: Text(l10n.settingsSample, style: text.bodyLarge),
                ),
              ],
            ),
          ),
          const SizedBox(height: BhSpace.l),
          SectionHeader(title: l10n.languageToggleLabel),
          const LanguageToggle(expanded: true),
          const SizedBox(height: BhSpace.l),
          SectionHeader(title: l10n.settingsAccount),
          SettingsRow.nav(
            key: safetyKey,
            icon: Icons.shield_outlined,
            title: l10n.safety,
            onTap: () => context.push(Routes.safety),
          ),
          SettingsRow.action(
            key: logoutKey,
            icon: Icons.logout,
            title: l10n.logout,
            destructive: true,
            onTap: () async {
              await logout(ref.read);
              if (context.mounted) context.go(Routes.login);
            },
          ),
          const SizedBox(height: BhSpace.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 20, color: p.info),
              const SizedBox(width: BhSpace.s),
              Expanded(
                child: Text(l10n.neverAsksPinOtp, style: text.bodySmall),
              ),
            ],
          ),
          const SizedBox(height: BhSpace.l),
          Text(
            l10n.settingsAbout(context.digits(version)),
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}
