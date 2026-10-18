import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/in_memory_demo_state_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('emits initial, then every write, to a listener', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = InMemoryDemoStateRepo();
    final seen = <DemoState>[];
    final sub = repo.watch('rina').listen(seen.add);
    await pumpEventQueue();
    expect(seen, [DemoState.initial]);

    const on = DemoState(callActive: true);
    await repo.write('rina', on);
    await repo.write('rina', on.copyWith(simSwap: true));
    await pumpEventQueue();
    expect(seen, [DemoState.initial, on, on.copyWith(simSwap: true)]);

    await sub.cancel();
    await repo.dispose();
  });

  test('persists under demo_state/<uid> and reloads from it', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = InMemoryDemoStateRepo();
    const s = DemoState(
      screenShare: true,
      scamScore: 0.85,
      persona: Persona.rina,
    );
    await repo.write('rina', s);

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('demo_state/rina')!) as Map;
    expect(stored['screen_share'], isTrue);
    expect(stored['scam_score'], 0.85);
    expect(stored['persona'], 'rina');

    // A fresh instance (next launch) sees the stored value first.
    final again = InMemoryDemoStateRepo();
    expect(await again.watch('rina').first, s);
    // Other users are untouched.
    expect(await again.watch('rahima').first, DemoState.initial);
    await repo.dispose();
    await again.dispose();
  });

  test('reset writes initial and emits it', () async {
    SharedPreferences.setMockInitialValues({
      'demo_state/rina': jsonEncode(
        const DemoState(
          simSwap: true,
          forcedSafetyVerdict: SafetyVerdict.block,
        ).toDoc(),
      ),
    });
    final repo = InMemoryDemoStateRepo();
    final seen = <DemoState>[];
    final sub = repo.watch('rina').listen(seen.add);
    await pumpEventQueue();
    expect(seen.single.simSwap, isTrue);

    await repo.reset('rina');
    await pumpEventQueue();
    expect(seen.last, DemoState.initial);
    final prefs = await SharedPreferences.getInstance();
    expect(
      DemoState.fromDoc(
        (jsonDecode(prefs.getString('demo_state/rina')!) as Map)
            .cast<String, dynamic>(),
      ),
      DemoState.initial,
    );
    await sub.cancel();
    await repo.dispose();
  });

  test('unreadable stored JSON falls back to initial', () async {
    SharedPreferences.setMockInitialValues({'demo_state/rina': 'not json'});
    final repo = InMemoryDemoStateRepo();
    expect(await repo.watch('rina').first, DemoState.initial);
    await repo.dispose();
  });
}
