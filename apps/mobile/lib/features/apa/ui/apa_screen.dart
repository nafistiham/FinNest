/// The `/apa` route: the sheet content hosted full-screen.
library;

import 'package:bhorosha/app/l10n.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_held_score.dart';
import 'package:bhorosha/features/apa/ui/apa_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ApaScreen extends ConsumerStatefulWidget {
  const ApaScreen({super.key, this.screen = 'apa'});

  /// `ApaContext.screen` sent with every turn.
  final String screen;

  @override
  ConsumerState<ApaScreen> createState() => _ApaScreenState();
}

class _ApaScreenState extends ConsumerState<ApaScreen> {
  late final ApaController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(apaControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.openFor(
        held: ref.read(apaHeldScoreProvider),
        screen: widget.screen,
      );
    });
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.apaSheetTitle)),
      body: const SafeArea(child: ApaSheetBody(showClose: false)),
    );
  }
}
