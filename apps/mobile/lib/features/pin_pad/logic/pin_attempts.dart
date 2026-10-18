/// Wrong-PIN counter and pause, per signed-in user.
///
/// Kept outside the PIN pad's `State` on purpose: backing out of the pad
/// and tapping Next again builds a new pad, and that must not reset the
/// count or skip the 30 s pause. The provider is keepAlive (not autoDispose)
/// and keyed by uid; a right PIN clears it, and the per-user session reset
/// (logout, persona switch, demo login) invalidates every entry.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class PinAttempts {
  const PinAttempts({this.wrong = 0, this.pauseUntil});

  /// Wrong PINs since the last right PIN or the last pause.
  final int wrong;

  /// End of the current pause on the feature clock; `null` when none.
  final DateTime? pauseUntil;

  /// Whole seconds left of the pause at [now] (rounded up), 0 when none.
  int secondsLeft(DateTime now) {
    final until = pauseUntil;
    if (until == null) return 0;
    final ms = until.difference(now).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PinAttempts &&
          wrong == other.wrong &&
          pauseUntil == other.pauseUntil;

  @override
  int get hashCode => Object.hash(wrong, pauseUntil);

  @override
  String toString() => 'PinAttempts($wrong, pauseUntil: $pauseUntil)';
}

/// Every user's [PinAttempts], keyed by uid.
class PinAttemptsBook extends Notifier<Map<String, PinAttempts>> {
  @override
  Map<String, PinAttempts> build() => const {};

  /// [uid]'s attempts; none recorded reads as a clean slate.
  PinAttempts of(String uid) => state[uid] ?? const PinAttempts();

  void _put(String uid, PinAttempts a) => state = {...state, uid: a};

  /// Records one wrong PIN for [uid]. The [max]th starts a pause of [pause]
  /// from [now] and resets the count; returns `true` when this call started
  /// it.
  bool recordWrong(
    String uid, {
    required int max,
    required Duration pause,
    required DateTime now,
  }) {
    final current = of(uid);
    final wrong = current.wrong + 1;
    if (wrong >= max) {
      _put(uid, PinAttempts(pauseUntil: now.add(pause)));
      return true;
    }
    _put(uid, PinAttempts(wrong: wrong, pauseUntil: current.pauseUntil));
    return false;
  }

  /// The pause ran out on screen: the pad accepts input again.
  void endPause(String uid) {
    final current = of(uid);
    if (current.pauseUntil != null) {
      _put(uid, PinAttempts(wrong: current.wrong));
    }
  }

  /// A right PIN: nothing is held against [uid] any more.
  void clear(String uid) {
    if (!state.containsKey(uid)) return;
    state = {...state}..remove(uid);
  }

  /// Logout, persona switch, demo login: every user starts clean.
  void clearAll() => state = const {};
}

/// keepAlive: survives the PIN pad being disposed.
final pinAttemptsProvider =
    NotifierProvider<PinAttemptsBook, Map<String, PinAttempts>>(
      PinAttemptsBook.new,
    );
