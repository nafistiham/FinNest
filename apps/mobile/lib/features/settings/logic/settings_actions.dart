/// Settings actions that are not appearance (appearance lives in
/// `lib/app/appearance.dart`).
library;

import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/features/session/logic/session_reset.dart';

/// Logs the customer out (moved here from the Home menu): nothing of this
/// persona survives into the next login, then signs out.
/// The caller navigates to login.
Future<void> logout(ProviderReader read) async {
  final auth = read(authRepoProvider);
  final previous = auth.current?.uid;
  await resetSessionState(read, previousUid: previous);
  await auth.signOut();
}
