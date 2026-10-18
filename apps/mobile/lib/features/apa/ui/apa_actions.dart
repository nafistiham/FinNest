/// What an Apa action button does on screen (sheet bubbles and the Home
/// card share it). In-sheet effects go through the controller; navigation
/// closes the modal sheet first so the next screen is not hidden behind it.
library;

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/safety/logic/external_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// `apaSafetyRoute`. A literal so the Apa feature does not import the router
/// (which imports every screen of the app).
const apaSafetyRoute = '/safety';

/// Pushes [location], popping the modal sheet first when [inModal].
void apaNavigate(
  BuildContext context,
  String location, {
  required bool inModal,
}) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    Log.w('apa', 'no router: cannot open $location');
    return;
  }
  if (inModal) Navigator.of(context).maybePop();
  router.push(location);
}

/// The trusted-contact request page of the first held transfer, if any.
String? apaApproveLocation(WidgetRef ref) {
  final id = ref.read(apaSnapshotProvider).pendingRequestId;
  return id == null ? null : '/approve/${Uri.encodeComponent(id)}';
}

/// Runs [action] from inside the Apa sheet.
Future<void> runApaActionInSheet(
  BuildContext context,
  WidgetRef ref,
  ApaAction action, {
  required bool inModal,
}) async {
  final controller = ref.read(apaControllerProvider.notifier);
  switch (action) {
    case ApaAction.openSafety:
      apaNavigate(context, apaSafetyRoute, inModal: inModal);
    case ApaAction.openApproveOrHeld:
      final approve = apaApproveLocation(ref);
      if (approve != null) {
        apaNavigate(context, approve, inModal: inModal);
      } else {
        await controller.askWhyHeld();
      }
    case ApaAction.callHelpline:
      await ExternalLinks.callBank(ref.read(uriLauncherProvider));
    case ApaAction.openApaScamCheck:
    case ApaAction.learnRules:
      await controller.runAction(action);
    case ApaAction.none:
      break;
  }
}
