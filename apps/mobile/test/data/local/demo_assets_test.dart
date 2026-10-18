import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/local/demo_assets.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_bundle.dart';

void main() {
  late DemoAssets assets;
  setUp(() => assets = DemoAssets(bundle: DiskAssetBundle()));

  test('personas.json loads both personas with the seed facts', () async {
    final rina = await assets.persona(Persona.rina);
    expect(rina.profile.nameBn, 'রিনা আক্তার');
    expect(rina.profile.acctId, 'acct_rina');
    expect(rina.profile.balanceBdt, 9841);
    expect(rina.profile.p95SendBdt, 5000);
    expect(rina.profile.district, 'Gazipur');
    expect(PinCheck.matches('1234', rina.pinSha256), isTrue);
    expect(rina.transactions, hasLength(6));
    expect(rina.transactions.first.txnId, 'txn_011989');
    expect(rina.savedPayees.map((p) => p.nameBn), ['মা', 'রফিক ইসলাম']);

    final rahima = await assets.persona(Persona.rahima);
    expect(rahima.profile.nameEn, 'Rahima Begum');
    expect(rahima.profile.balanceBdt, 3260);
    expect(PinCheck.matches('2468', rahima.pinSha256), isTrue);
    expect(PinCheck.matches('1234', rahima.pinSha256), isFalse);
    expect(rahima.transactions.first.channel, 'ussd');
    expect(rahima.savedPayees.map((p) => p.acctId), [
      'acct_rafiq',
      'acct_rina',
    ]);
    expect(assets.personaIfLoaded(Persona.rahima), isNotNull);
  });

  test(
    'scam_script.json is six alternating Turns with the stub keywords',
    () async {
      final turns = await assets.scamScript();
      expect(turns, hasLength(6));
      for (var i = 0; i < turns.length; i++) {
        expect(
          turns[i].speaker,
          i.isEven ? Turn.callerSpeaker : Turn.userSpeaker,
        );
        if (i > 0) expect(turns[i].ts, greaterThan(turns[i - 1].ts));
      }
      expect(
        turns.first.text,
        'ফিননেস্ট কাস্টমার কেয়ার থেকে বলছি, অভিযোগের কারণে আপনার একাউন্ট ব্লক হয়ে যাবে — এখনই পিন রিসেট করুন, কোডটা বলুন।',
      );
      final callerText = turns
          .where((t) => t.speaker == Turn.callerSpeaker)
          .map((t) => t.text)
          .join(' ');
      for (final word in ['ওটিপি', 'কোড', 'পিন']) {
        expect(callerText, contains(word));
      }
    },
  );

  test('fake_apps.json is the TakaNow InstalledApp', () async {
    final apps = await assets.fakeApps();
    expect(apps, hasLength(1));
    final app = apps.single;
    expect(app.package, 'com.demo.takanow');
    expect(app.label, 'TakaNow');
    expect(app.installer, isNull);
    expect(app.hasAccessibilityService, isTrue);
    expect(app.accessibilityEnabled, isTrue);
    expect(app.targetSdk, 28);
    expect(app.permissions, contains('android.permission.READ_SMS'));
    expect(app.permissions, hasLength(7));
  });
}
