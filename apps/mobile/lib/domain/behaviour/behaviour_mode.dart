/// What the app posts as `behaviour` on `/v1/risk/signals`: the measured
/// vector, nothing, or the owner's vector replayed with one behaviour block
/// changed (a stranger's hand, another tap pattern, a shaking hand, a coached
/// victim).
///
/// Session-scoped on purpose: the mode and the enrolment toggle live in
/// memory only, are never part of `DemoState` (which syncs to Firestore and
/// would leak into another phone's recording, design review 6) and go back
/// to their defaults on a cold start and on every persona switch (both
/// providers rebuild when the signed-in uid changes).
library;

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum BehaviourMode {
  /// The measured 55-float vector (the real product path).
  live,

  /// No `behaviour` block at all: the server has no behaviour to score.
  off,

  /// The owner's last enrolled row with a stranger's touch (see
  /// `BehaviourReplay.stranger`: tap pattern and shaking together), else the
  /// live vector perturbed. Every replay below uses the same base.
  replayStranger,

  /// Only the tap and contact morphology changes
  /// (`BehaviourReplay.tapPattern`).
  replayTapPattern,

  /// Only the IMU grip changes (`BehaviourReplay.shaking`).
  replayShaking,

  /// Only the tempo changes, morphology untouched (`BehaviourReplay.coached`).
  replayCoached;

  /// The posted behaviour is not the measured one: the local records are
  /// tagged `simulated` and the overlay shows the "সিমুলেটেড" tag.
  bool get simulated => this != live;

  /// The owner's vector replayed with a perturbation (every mode but [live]
  /// and [off]).
  bool get replayed => this != live && this != off;

  /// The mode a cold start and a persona switch begin in, from the
  /// `BEHAVIOUR_MODE` dart-define ([AppEnv.behaviourMode]): `off` posts no
  /// behaviour block, anything else (`live`, the default) the measured
  /// vector.
  static BehaviourMode fromDefine(String value) =>
      value.trim().toLowerCase() == 'off' ? off : live;

  /// [fromDefine] of this build's `BEHAVIOUR_MODE`.
  static BehaviourMode get startMode => fromDefine(AppEnv.behaviourMode);
}

/// The signed-in uid, or `null`; watching it resets a session-scoped value
/// on every sign-in, sign-out and persona switch.
String? _watchUid(Ref ref) =>
    ref.watch(currentUserProvider.select((u) => u.value?.uid));

/// The mode a cold start and a persona switch begin in:
/// [BehaviourMode.startMode]. Tests of the live product path override it.
final behaviourStartModeProvider = Provider<BehaviourMode>(
  (_) => BehaviourMode.startMode,
);

class BehaviourModeController extends Notifier<BehaviourMode> {
  @override
  BehaviourMode build() {
    _watchUid(ref);
    return ref.watch(behaviourStartModeProvider);
  }

  void set(BehaviourMode mode) => state = mode;
}

/// The current [BehaviourMode]; [behaviourStartModeProvider] (`live` unless
/// the build passed `--dart-define=BEHAVIOUR_MODE=off`) after a cold start or
/// a persona switch. Live stays the default; a build whose phone the per-user
/// models do not fit (every ordinary send held with `ATO_BEHAVIOUR_MISMATCH`)
/// can start off. The demo panel's radio still switches it for the session.
final behaviourModeProvider =
    NotifierProvider<BehaviourModeController, BehaviourMode>(
      BehaviourModeController.new,
    );

class BehaviourEnrolling extends Notifier<bool> {
  @override
  bool build() {
    _watchUid(ref);
    return false;
  }

  void set(bool on) => state = on;
}

/// "নথিভুক্ত করা হচ্ছে": while on (and the mode is live) every scored PIN
/// entry appends its measured vector to the `EnrolmentStore`. Off after a
/// cold start or a persona switch.
final behaviourEnrollingProvider = NotifierProvider<BehaviourEnrolling, bool>(
  BehaviourEnrolling.new,
);
