/// Per-trigger audio cooldown.
///
/// The client remembers `(trigger, until)` from the server's `cooldown_s`;
/// a repeat of the same trigger inside the window keeps the card but does
/// not replay Apa's audio. The demo panel's "reset cooldown" calls [reset].
library;

import 'package:bhorosha/core/clock.dart';

class Cooldown {
  Cooldown(this._clock, {this.alwaysSpeak = false});

  final Clock _clock;

  /// Demo builds (the demo panel on) speak on every hold: a presenter who
  /// re-runs a story within the server's cooldown otherwise hears nothing
  /// and thinks the audio is broken. Production keeps
  /// the cooldown so repeated holds do not nag.
  final bool alwaysSpeak;
  final Map<String, DateTime> _until = {};

  /// `true` when [trigger] is not inside an armed window.
  bool shouldSpeak(String trigger) {
    if (alwaysSpeak) return true;
    final until = _until[trigger];
    return until == null || !_clock.now().isBefore(until);
  }

  /// Opens (or extends) the window for [trigger] to now + [cooldownS].
  void arm(String trigger, int cooldownS) {
    _until[trigger] = _clock.now().add(Duration(seconds: cooldownS));
  }

  /// When the window for [trigger] closes, or `null` when none is armed.
  DateTime? until(String trigger) => _until[trigger];

  /// Clears every window (demo panel, persona switch).
  void reset() => _until.clear();
}
