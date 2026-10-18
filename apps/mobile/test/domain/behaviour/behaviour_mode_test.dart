import 'dart:async';

import 'package:bhorosha/app/env.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

UserProfile user(Persona p) => UserProfile(
  uid: p.uid,
  nameBn: p.uid,
  nameEn: p.uid,
  phoneMasked: '',
  persona: p,
  trustedContactUid: 'rafiq',
  p95SendBdt: 5000,
  acctId: p.acctId,
  balanceBdt: 0,
);

void main() {
  late StreamController<UserProfile?> users;
  late ProviderContainer c;

  setUp(() async {
    users = StreamController<UserProfile?>.broadcast();
    c = ProviderContainer(
      overrides: [currentUserProvider.overrideWith((_) => users.stream)],
    );
    addTearDown(c.dispose);
    addTearDown(users.close);
    c.listen(behaviourModeProvider, (_, _) {});
    c.listen(behaviourEnrollingProvider, (_, _) {});
    users.add(user(Persona.rina));
    await pumpEventQueue();
  });

  test('defaults: live, not enrolling (cold start; BEHAVIOUR_MODE unset)', () {
    expect(AppEnv.behaviourMode, 'live');
    expect(BehaviourMode.startMode, BehaviourMode.live);
    expect(c.read(behaviourModeProvider), BehaviourMode.live);
    expect(c.read(behaviourEnrollingProvider), isFalse);
    expect(BehaviourMode.live.simulated, isFalse);
    expect(BehaviourMode.off.simulated, isTrue);
    expect(BehaviourMode.replayStranger.simulated, isTrue);
  });

  test('every mode but live is simulated; every mode but live and off is a '
      'replay', () {
    for (final m in BehaviourMode.values) {
      expect(m.simulated, m != BehaviourMode.live, reason: m.name);
      expect(
        m.replayed,
        m != BehaviourMode.live && m != BehaviourMode.off,
        reason: m.name,
      );
    }
    expect(BehaviourMode.values, hasLength(6));
  });

  test('a persona switch resets the mode and the enrolment switch', () async {
    c.read(behaviourModeProvider.notifier).set(BehaviourMode.replayStranger);
    c.read(behaviourEnrollingProvider.notifier).set(true);
    expect(c.read(behaviourModeProvider), BehaviourMode.replayStranger);
    expect(c.read(behaviourEnrollingProvider), isTrue);

    users.add(user(Persona.rahima));
    await pumpEventQueue();
    expect(c.read(behaviourModeProvider), BehaviourMode.live);
    expect(c.read(behaviourEnrollingProvider), isFalse);
  });

  test(
    'a sign-out resets it too; the same user re-emitting does not',
    () async {
      c.read(behaviourModeProvider.notifier).set(BehaviourMode.off);
      users.add(user(Persona.rina));
      await pumpEventQueue();
      expect(c.read(behaviourModeProvider), BehaviourMode.off);

      users.add(null);
      await pumpEventQueue();
      expect(c.read(behaviourModeProvider), BehaviourMode.live);
    },
  );

  test('BEHAVIOUR_MODE: only "off" (any case, trimmed) starts off', () {
    expect(BehaviourMode.fromDefine('off'), BehaviourMode.off);
    expect(BehaviourMode.fromDefine(' OFF '), BehaviourMode.off);
    expect(BehaviourMode.fromDefine('live'), BehaviourMode.live);
    expect(BehaviourMode.fromDefine(''), BehaviourMode.live);
    expect(BehaviourMode.fromDefine('replayStranger'), BehaviourMode.live);
  });

  test('an off start mode (the define) is what a persona switch returns to; '
      'the demo panel radio still switches it', () async {
    final off = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((_) => users.stream),
        behaviourStartModeProvider.overrideWithValue(BehaviourMode.off),
      ],
    );
    addTearDown(off.dispose);
    off.listen(behaviourModeProvider, (_, _) {});
    users.add(user(Persona.rina));
    await pumpEventQueue();
    expect(off.read(behaviourModeProvider), BehaviourMode.off);
    off.read(behaviourModeProvider.notifier).set(BehaviourMode.live);
    expect(off.read(behaviourModeProvider), BehaviourMode.live);
    users.add(user(Persona.rahima));
    await pumpEventQueue();
    expect(off.read(behaviourModeProvider), BehaviourMode.off);
  });
}
