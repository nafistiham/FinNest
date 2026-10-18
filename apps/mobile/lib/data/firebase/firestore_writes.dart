/// Firestore write acknowledgements.
///
/// A Firestore `set`/`update` applies to the local cache at once (every
/// snapshot listener sees it), but its future completes only when the server
/// acknowledges the write, which offline is never. The repos below hand the
/// write to [fireAndLog] instead of awaiting it, so no caller (the PIN flow
/// above all) can hang on a missing network; a rejected write is logged.
library;

import 'dart:async';

import 'package:bhorosha/core/log.dart';

const _tag = 'firestore';

/// Lets [write] complete in the background and logs a failure; returns at
/// once.
void fireAndLog(Future<void> write, String what) {
  unawaited(
    write.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) => Log.w(_tag, '$what failed', e),
    ),
  );
}
