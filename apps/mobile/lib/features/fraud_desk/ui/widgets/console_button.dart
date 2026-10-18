/// The Fraud desk's bottom-bar primary "কনসোল খুলুন": hands the Case Zero
/// console URL to the system browser (no WebView).
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/l10n.dart';
import '../../../../app/widgets/bh_button.dart';
import '../../../../core/log.dart';

/// Opens [Uri] in an external browser; `true` when it did.
typedef UrlOpener = Future<bool> Function(Uri uri);

/// The default [UrlOpener].
Future<bool> externalBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

class ConsoleButton extends StatefulWidget {
  const ConsoleButton({required this.url, required this.open, super.key});

  final String url;

  /// Injectable for tests (url_launcher has no channel under `flutter test`).
  final UrlOpener open;

  static const buttonKey = Key('open_console');

  @override
  State<ConsoleButton> createState() => _ConsoleButtonState();
}

class _ConsoleButtonState extends State<ConsoleButton> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await widget.open(Uri.parse(widget.url));
    } on Object catch (e) {
      Log.w('fraud_desk', 'launch failed', e);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.openConsoleFailed)));
    }
  }

  @override
  Widget build(BuildContext context) => BhButton(
    key: ConsoleButton.buttonKey,
    label: context.l10n.openConsole,
    icon: Icons.open_in_new,
    loading: _busy,
    onPressed: _open,
  );
}
