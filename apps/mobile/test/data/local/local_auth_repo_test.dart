import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/local/local_auth_repo.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_bundle.dart';

void main() {
  late LocalAuthRepo repo;
  setUp(() => repo = LocalAuthRepo(DemoAssets(bundle: DiskAssetBundle())));
  tearDown(() => repo.dispose());

  test('demoLogin emits the Rina profile and sets the demo header', () async {
    final seen = <UserProfile?>[];
    final sub = repo.watch().listen(seen.add);
    await pumpEventQueue();
    expect(seen, [null]);
    expect(await repo.identity.headers(), {'X-Demo-User': 'demo'});

    final profile = await repo.demoLogin(Persona.rina);
    await pumpEventQueue();
    expect(profile.nameEn, 'Rina Akter');
    expect(profile.trustedContactUid, 'rafiq');
    expect(profile.balanceBdt, 9841);
    expect(seen.last, profile);
    expect(repo.current, profile);
    expect(await repo.identity.headers(), {'X-Demo-User': 'rina'});

    // The same identity object follows a persona switch.
    final identity = repo.identity;
    await repo.demoLogin(Persona.rahima);
    expect(await identity.headers(), {'X-Demo-User': 'rahima'});
    await sub.cancel();
  });

  test('signOut emits null and drops the uid from the header', () async {
    await repo.demoLogin(Persona.rina);
    final seen = <UserProfile?>[];
    final sub = repo.watch().listen(seen.add);
    await repo.signOut();
    await pumpEventQueue();
    expect(seen.last, isNull);
    expect(repo.current, isNull);
    expect(await repo.identity.headers(), {'X-Demo-User': 'demo'});
    await sub.cancel();
  });

  test('passkeyLogin throws the typed exception while not deployed', () async {
    await expectLater(
      repo.passkeyLogin,
      throwsA(
        isA<PasskeyUnavailableException>().having(
          (e) => e.reason,
          'reason',
          NotDeployedPasskeyAuth.reason,
        ),
      ),
    );
    expect(
      await const NotDeployedPasskeyAuth().login(),
      isA<PasskeyUnavailable>(),
    );
  });
}
