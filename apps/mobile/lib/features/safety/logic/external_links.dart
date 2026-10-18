/// External destinations of the findings screen's resolution block: the Play
/// Store page of this app and the bank's hotline. Launching is behind a
/// provider so widget tests record URIs instead of reaching the platform.
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/core/log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [uri] outside the app; `true` when something handled it.
typedef UriLauncher = Future<bool> Function(Uri uri);

final uriLauncherProvider = Provider<UriLauncher>(
  (_) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

abstract final class ExternalLinks {
  static const String appPackage = 'com.bhorosha.app';

  /// The fictional FinNest helpline ([AppEnv.helpline]); never a real
  /// company's number.
  static const String bankHotline = AppEnv.helpline;

  static final Uri playMarket = Uri.parse('market://details?id=$appPackage');
  static final Uri playWeb = Uri.parse(
    'https://play.google.com/store/apps/details?id=$appPackage',
  );

  /// `tel:` takes digits only: the display form's dashes are dropped.
  static final Uri bankCall = Uri.parse(
    'tel:${bankHotline.replaceAll(RegExp(r'[^0-9+]'), '')}',
  );

  /// Play Store app first, the web store page when it is not installed.
  static Future<bool> openPlayStore(UriLauncher launch) async {
    if (await _try(launch, playMarket)) return true;
    return _try(launch, playWeb);
  }

  static Future<bool> callBank(UriLauncher launch) => _try(launch, bankCall);

  static Future<bool> _try(UriLauncher launch, Uri uri) async {
    try {
      return await launch(uri);
    } on Object catch (e) {
      Log.w('links', 'could not open ${uri.scheme}', e);
      return false;
    }
  }
}
