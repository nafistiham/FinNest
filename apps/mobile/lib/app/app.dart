import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firebase/messaging.dart';
import '../data/providers.dart';
import 'appearance.dart';
import 'l10n.dart';
import 'locale.dart';
import 'router.dart';
import 'theme/theme.dart';
import 'widgets/demo_banner.dart';

/// Root widget. Bangla is the default locale; English is the parallel, chosen
/// with the language toggle ([localeProvider]); a switch rebuilds the tree.
///
/// After the first frame it wires FCM through [Messaging.init] with the
/// router, which is a complete no-op while Firebase is absent (deep links
/// still route through the manifest intent filter and go_router).
class BhoroshaApp extends ConsumerStatefulWidget {
  const BhoroshaApp({super.key});

  @override
  ConsumerState<BhoroshaApp> createState() => _BhoroshaAppState();
}

class _BhoroshaAppState extends ConsumerState<BhoroshaApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Messaging.init(
          status: ref.read(firebaseStatusProvider),
          router: ref.read(routerProvider),
          // Foreground pushes: the approve feature's incoming-request banner
          // is wired once a shell above the router hosts it; until then the
          // tap path (onMessageOpenedApp) already routes to /approve/:id.
          onForegroundMessage: null,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final locale = ref.watch(localeProvider);
    final preset = ref.watch(themePresetProvider);
    final textSize = ref.watch(textSizeProvider);
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    return MaterialApp.router(
      onGenerateTitle: (context) => context.l10n.appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, preset: preset, locale: locale),
      darkTheme: buildTheme(Brightness.dark, preset: preset, locale: locale),
      themeMode: ref.watch(themeModeProvider),
      // A preset or mode switch lerps the palette.
      themeAnimationDuration: reduceMotion
          ? Duration.zero
          : BhMotion.standard.slow,
      themeAnimationCurve: BhCurves.slow,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      routerConfig: router,
      // Text size: the system scale x the chosen factor, clamped to
      // 1.0..1.4 so the money screens never overflow (5.4); then the demo /
      // recording strip above every route.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: bhTextScaler(media.textScaler, textSize),
          ),
          child: DemoBannerShell(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
