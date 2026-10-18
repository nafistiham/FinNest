/// "Demo flag wins over real signal".
///
/// The server never reads `demo_state/{uid}`; the app owns the merge and
/// sends the result as `ScoreRequest.demo_flags`. Pure Dart, no I/O.
library;

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';

abstract final class SignalMerger {
  /// A SIM that changed within this many hours counts as a swap.
  static const double simSwapWindowHours = 24;

  /// Overlays the demo toggles on the real device signals: `demo.callActive`
  /// forces `callState` to OFFHOOK and `demo.screenShare` forces
  /// `screenCapture` on; every other field passes through unchanged.
  static DeviceSignals merge(DeviceSignals real, DemoState demo) =>
      real.copyWith(
        callState: demo.callActive ? CallState.offhook : null,
        screenCapture: demo.screenShare ? true : null,
      );

  /// The `SignalsRequest.simulated` names: the posted fields whose value
  /// [merge] changed, in the server's `KNOWN_SIMULATED` vocabulary (risk-mw
  /// `app/device_signals.py`), so it can tell a measured signal from a forced
  /// one. [real] is what the phone measured, [merged] what is posted:
  ///
  /// - `call_state` only when the phone was not already OFFHOOK (a real
  ///   call stays `device` even with the demo toggle on);
  /// - `screen_capture` only when the phone did not already report capture
  ///   (a real `screen_recording` is never touched, so never named).
  ///
  /// `sim_swap` is never named: the demo
  /// SIM swap goes through `DemoFlags` and changes no posted field, and the
  /// server expands that flag name to its SIM fields, which would report a
  /// real SIM change as `demo`. Empty when the merge changed nothing.
  /// Replayed behaviour vectors are not named here (unknown names are
  /// dropped server-side; the local records carry that tag).
  static List<String> simulatedNames(
    DeviceSignals real,
    DeviceSignals merged,
  ) => [
    if (merged.callState != real.callState) 'call_state',
    if (merged.screenCapture != real.screenCapture) 'screen_capture',
  ];

  /// The `DemoFlags` sent to `/v1/risk/score`:
  ///
  /// - `simSwap` = `demo.simSwap || merged.subscriptionChangedHours < 24`;
  /// - `callActive` = `merged.callState != IDLE`;
  /// - `screenShare` = `merged.screenCapture || merged.screenRecording`;
  /// - `callerInContacts`, `scamScore` from the demo state;
  /// - `appSafetyVerdict` = forced verdict, else [lastVerdict], else SAFE.
  ///
  /// `persona` and `forced_safety_verdict` never reach the wire: [DemoFlags]
  /// has no such keys and the server has `extra="forbid"`.
  static DemoFlags flags(
    DeviceSignals merged,
    DemoState demo, {
    SafetyVerdict? lastVerdict,
  }) {
    final hours = merged.subscriptionChangedHours;
    final realSimSwap = hours != null && hours < simSwapWindowHours;
    return demo
        .toDemoFlags(appSafetyVerdict: lastVerdict)
        .copyWith(
          simSwap: demo.simSwap || realSimSwap,
          callActive: merged.callState != CallState.idle,
          screenShare: merged.screenCapture || merged.screenRecording,
        );
  }
}
