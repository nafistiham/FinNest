import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:bhorosha/features/intervention/logic/step_up_policy.dart';
import 'package:bhorosha/features/login/logic/biometric_auth.dart';
import 'package:flutter_test/flutter_test.dart';

const mismatch = Reason(
  code: 'ATO_BEHAVIOUR_MISMATCH',
  weight: 1,
  textBn: 'নিরাপত্তার জন্য একবার আপনার পরিচয় নিশ্চিত করতে চাই।',
  textEn: 'For your safety we want to confirm it is you.',
);
const coldStart = Reason(
  code: 'ATO_BEHAVIOUR_MISMATCH_COLD_START',
  weight: 0.9,
  textBn: 'পরিচয় নিশ্চিত করুন।',
  textEn: 'Confirm it is you.',
);
const mule = Reason(
  code: 'DEST_MULE_RISK',
  weight: 0.87,
  textBn: 'প্রাপক ঝুঁকিপূর্ণ।',
  textEn: 'Risky recipient.',
);
const coaching = Reason(
  code: 'COACHING_SUSPECTED',
  weight: 0.9,
  textBn: 'কেউ বলে দিচ্ছে।',
  textEn: 'Someone is guiding you.',
);

const quiet = SignalSources();

ScoreResponse hold({
  List<Reason> reasons = const [mismatch],
  SignalSources? sources = quiet,
}) => ScoreResponse(
  decision: Decision.hold,
  riskScore: 1,
  band: Band.critical,
  reasons: reasons,
  actions: const [],
  modelVersion: 'test',
  signalSources: sources,
);

StepUpDecision decide({
  ScoreResponse? score,
  bool callActiveLocal = false,
  double amount = 500,
  double p95 = 5000,
  BiometricStrength strength = BiometricStrength.strong,
  BehaviourMode mode = BehaviourMode.live,
  int attempts = 0,
}) => stepUpFor(
  score: score ?? hold(),
  callActiveLocal: callActiveLocal,
  amountBdt: amount,
  personaP95: p95,
  strength: strength,
  mode: mode,
  attempts: attempts,
);

void main() {
  test('every condition met: offer', () {
    expect(decide(), const StepUpOffer());
    expect(decide().offered, isTrue);
    expect(
      decide(score: hold(reasons: const [mismatch, coldStart])),
      const StepUpOffer(),
    );
  });

  test('(a) a non-identity reason keeps the hold', () {
    expect(
      decide(score: hold(reasons: const [mismatch, mule])),
      const StepUpKeep(StepUpBlock.notIdentityOnly),
    );
    expect(
      decide(score: hold(reasons: const [coaching])),
      const StepUpKeep(StepUpBlock.notIdentityOnly),
      reason: 'coaching never offers it',
    );
    expect(
      decide(score: hold(reasons: const [])),
      const StepUpKeep(StepUpBlock.notIdentityOnly),
    );
  });

  test('(b) a call: the server saw one, or the phone did', () {
    for (final source in [SignalSource.device, SignalSource.demo]) {
      expect(
        decide(
          score: hold(sources: SignalSources(callActive: source)),
        ),
        const StepUpKeep(StepUpBlock.callActive),
        reason: source.wire,
      );
    }
    expect(
      decide(callActiveLocal: true),
      const StepUpKeep(StepUpBlock.callActive),
    );
  });

  test('(b) a missing signal_sources is unknown: the hold stays', () {
    expect(
      decide(score: hold(sources: null)),
      const StepUpKeep(StepUpBlock.callActive),
    );
  });

  test('(b) an unknown call source keeps the hold; only none passes', () {
    expect(
      decide(
        score: hold(
          sources: const SignalSources(callActive: SignalSource.unknown),
        ),
      ),
      const StepUpKeep(StepUpBlock.callActive),
    );
    final parsed = SignalSources.fromJson(const {'call_active': 'carrier'});
    expect(
      decide(score: hold(sources: parsed)),
      const StepUpKeep(StepUpBlock.callActive),
    );
    expect(
      decide(
        score: hold(
          sources: SignalSources.fromJson(const {'call_active': 'none'}),
        ),
      ),
      const StepUpOffer(),
    );
  });

  test('(c) above the persona p95 keeps the hold; at p95 offers', () {
    expect(decide(amount: 5001), const StepUpKeep(StepUpBlock.overP95));
    expect(decide(amount: 5000), const StepUpOffer());
    expect(
      decide(amount: 2500, p95: 2000),
      const StepUpKeep(StepUpBlock.overP95),
    );
  });

  test('(d) only a strong biometric', () {
    for (final s in [
      BiometricStrength.weakOnly,
      BiometricStrength.notEnrolled,
      BiometricStrength.unsupported,
    ]) {
      expect(
        decide(strength: s),
        const StepUpKeep(StepUpBlock.biometricWeak),
        reason: s.name,
      );
    }
  });

  test('(e) a replayed or switched-off behaviour ends at the hold: every '
      'mode but live', () {
    expect(decide(), const StepUpOffer());
    for (final m in BehaviourMode.values.where(
      (m) => m != BehaviourMode.live,
    )) {
      expect(
        decide(mode: m),
        const StepUpKeep(StepUpBlock.replayed),
        reason: m.name,
      );
    }
  });

  test('(f) three attempts per session', () {
    expect(decide(attempts: 2), const StepUpOffer());
    expect(
      decide(attempts: maxStepUpAttempts),
      const StepUpKeep(StepUpBlock.attemptsExhausted),
    );
  });

  test(
    '(0) not a demo-panel build: no server-side release yet, so the hold '
    'stays for the trusted contact',
    () {
      expect(
        stepUpFor(
          score: hold(),
          callActiveLocal: false,
          amountBdt: 500,
          personaP95: 5000,
          strength: BiometricStrength.strong,
          mode: BehaviourMode.live,
          attempts: 0,
          demoPanel: false,
        ),
        const StepUpKeep(StepUpBlock.serverReleaseMissing),
      );
      // Checked first: it wins over every other condition.
      expect(
        stepUpFor(
          score: hold(reasons: const [mule]),
          callActiveLocal: true,
          amountBdt: 9000,
          personaP95: 5000,
          strength: BiometricStrength.unsupported,
          mode: BehaviourMode.replayStranger,
          attempts: 9,
          demoPanel: false,
        ),
        const StepUpKeep(StepUpBlock.serverReleaseMissing),
      );
    },
  );
}
