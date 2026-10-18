/// The chat's large "Talk" button, the microphone explanation shown
/// before the first Android dialog, and the strip that explains why voice
/// mode handed over to the chat.
library;

import 'dart:async';

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/ui/fna_ui_flags.dart';
import 'package:bhorosha/features/apa/ui/widgets/apa_tile.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared by the button and the fallback strip: open voice mode, explaining
/// the microphone first when it is not granted yet; open the system settings
/// when it was denied for good. With TalkBack on, voice mode is tap to talk
/// (FNA does not listen while TalkBack reads).
Future<void> fnaStartVoice(
  BuildContext context,
  WidgetRef ref, {
  required VoidCallback onTypeInstead,
  bool permanentlyDenied = false,
}) async {
  final controller = ref.read(apaControllerProvider.notifier);
  if (permanentlyDenied) {
    await ref.read(fnaOpenSettingsProvider)();
    return;
  }
  final tapToTalk = MediaQuery.accessibleNavigationOf(context);
  final granted = await ref.read(fnaMicGrantedProvider)();
  if (granted) {
    await controller.startVoice(tapToTalk: tapToTalk);
    return;
  }
  if (!context.mounted) return;
  final go = await FnaMicRationale.show(context);
  if (go == true) {
    await controller.startVoice(tapToTalk: tapToTalk);
  } else if (go == false) {
    onTypeInstead();
  }
}

class FnaTalkButton extends ConsumerStatefulWidget {
  const FnaTalkButton({required this.onTypeInstead, super.key});

  /// Height of the button (dp): larger than the 56 dp minimum, the chat's
  /// one big target.
  static const height = 64.0;

  /// "Type instead" on the explanation: focus the text field.
  final VoidCallback onTypeInstead;

  @override
  ConsumerState<FnaTalkButton> createState() => _FnaTalkButtonState();
}

class _FnaTalkButtonState extends ConsumerState<FnaTalkButton> {
  late final ApaController _controller = ref.read(
    apaControllerProvider.notifier,
  );
  late final AppLifecycleListener _lifecycle;
  bool _permanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    // Back from the system settings: the microphone may be allowed now.
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  Future<void> _refresh() async {
    final denied = await _controller.micPermanentlyDenied();
    if (mounted && denied != _permanentlyDenied) {
      setState(() => _permanentlyDenied = denied);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(apaControllerProvider.select((s) => s.voiceFallback), (_, _) {
      unawaited(_refresh());
    });
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final fallback = ref.watch(
      apaControllerProvider.select((s) => s.voiceFallback),
    );
    final busy = ref.watch(apaControllerProvider.select((s) => s.busy));
    final settings =
        _permanentlyDenied ||
        fallback == FnaFallbackReason.micPermanentlyDenied;
    final label = settings ? l10n.fnaOpenSettings : l10n.fnaTalk;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('fna_talk'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(FnaTalkButton.height),
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          textStyle: theme.textTheme.titleMedium,
        ),
        onPressed: busy
            ? null
            : () => fnaStartVoice(
                context,
                ref,
                onTypeInstead: widget.onTypeInstead,
                permanentlyDenied: settings,
              ),
        icon: Icon(settings ? Icons.settings_outlined : Icons.mic, size: 28),
        label: Text(label, maxLines: 2, textAlign: TextAlign.center),
      ),
    );
  }
}

/// The microphone explanation (plan journey 1): FNA's tile, why the
/// microphone is needed and when it listens, "Turn on microphone" and
/// "Type instead". Resolves `true`, `false`, or `null` when dismissed.
class FnaMicRationale extends StatelessWidget {
  const FnaMicRationale({super.key});

  static Future<bool?> show(BuildContext context) => showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const FnaMicRationale(),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      key: const Key('fna_mic_rationale'),
      padding: EdgeInsets.fromLTRB(
        BhSpace.m,
        BhSpace.l,
        BhSpace.m,
        BhSpace.m + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: ApaTile(size: 56)),
          const SizedBox(height: BhSpace.m),
          Text(
            l10n.fnaMicRationale,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: BhSpace.l),
          FilledButton.icon(
            key: const Key('fna_mic_turn_on'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(BhSize.touch),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.mic),
            label: Text(l10n.fnaMicTurnOn),
          ),
          const SizedBox(height: BhSpace.s),
          OutlinedButton.icon(
            key: const Key('fna_mic_type_instead'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(BhSize.touch),
            ),
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.keyboard_outlined),
            label: Text(l10n.fnaTypeInstead),
          ),
        ],
      ),
    );
  }
}

/// Why voice mode handed over to the chat, as a strip above the chips:
/// voice down, no internet, or the microphone denied (with the button that
/// asks again, or opens the settings). "Close" dismisses it.
class FnaFallbackStrip extends ConsumerWidget {
  const FnaFallbackStrip({required this.reason, super.key});

  final FnaFallbackReason reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final ink = p.onInfoContainer;
    final mic =
        reason == FnaFallbackReason.micDenied ||
        reason == FnaFallbackReason.micPermanentlyDenied;
    final forGood = reason == FnaFallbackReason.micPermanentlyDenied;
    final text = switch (reason) {
      FnaFallbackReason.connectTimeout ||
      FnaFallbackReason.liveFailed => l10n.fnaVoiceDown,
      FnaFallbackReason.offline => l10n.fnaOffline,
      // The customer already read the explanation before the dialog.
      FnaFallbackReason.micDenied ||
      FnaFallbackReason.micPermanentlyDenied => l10n.apaMicDenied,
    };
    final controller = ref.read(apaControllerProvider.notifier);
    return Container(
      key: Key('fna_fallback_${reason.name}'),
      margin: const EdgeInsets.fromLTRB(BhSpace.m, BhSpace.s, BhSpace.m, 0),
      padding: const EdgeInsets.all(BhSpace.s),
      color: p.infoContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: ink),
              const SizedBox(width: BhSpace.s),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: ink),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: BhSpace.s,
            children: [
              TextButton(
                key: const Key('fna_fallback_close'),
                style: TextButton.styleFrom(
                  foregroundColor: ink,
                  minimumSize: const Size(BhSize.touch, BhSize.touch),
                ),
                onPressed: controller.dismissVoiceFallback,
                child: Text(l10n.close),
              ),
              if (mic)
                TextButton.icon(
                  key: const Key('fna_fallback_mic'),
                  style: TextButton.styleFrom(
                    foregroundColor: ink,
                    minimumSize: const Size(BhSize.touch, BhSize.touch),
                  ),
                  onPressed: () => forGood
                      ? ref.read(fnaOpenSettingsProvider)()
                      : controller.startVoice(
                          tapToTalk: MediaQuery.accessibleNavigationOf(context),
                        ),
                  icon: Icon(forGood ? Icons.settings_outlined : Icons.mic),
                  label: Text(
                    forGood ? l10n.fnaOpenSettings : l10n.fnaMicTurnOn,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
