import 'package:flutter/material.dart';

import '../../../app/l10n.dart';
import 'demo_panel_sheet.dart';

/// Full-page host of the demo panel for the `/demo` route (adb-reachable);
/// the sheet opened from the logo shows the same [DemoPanelBody].
class DemoPanelScreen extends StatelessWidget {
  const DemoPanelScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.demoPanel)),
    body: const DemoPanelBody(showTitle: false),
  );
}
