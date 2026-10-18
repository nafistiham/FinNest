import 'package:bhorosha/data/api/identity_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DemoIdentityHeaders sends X-Demo-User', () async {
    expect(await const DemoIdentityHeaders('rina').headers(), {
      'X-Demo-User': 'rina',
    });
  });

  test('BearerIdentityHeaders sends the Firebase ID token', () async {
    final identity = BearerIdentityHeaders(() async => 'id.token.x');
    expect(await identity.headers(), {'Authorization': 'Bearer id.token.x'});
  });

  test('BearerIdentityHeaders always adds X-Demo-User when a fallback uid '
      'is set', () async {
    final identity = BearerIdentityHeaders(
      () async => 'id.token.x',
      fallbackDemoUid: 'rina',
    );
    expect(await identity.headers(), {
      'Authorization': 'Bearer id.token.x',
      'X-Demo-User': 'rina',
    });
  });

  test(
    'BearerIdentityHeaders falls back to the demo uid when signed out',
    () async {
      final identity = BearerIdentityHeaders(
        () async => null,
        fallbackDemoUid: 'rahima',
      );
      expect(await identity.headers(), {'X-Demo-User': 'rahima'});
    },
  );

  test(
    'BearerIdentityHeaders sends nothing without token or fallback',
    () async {
      final identity = BearerIdentityHeaders(() async => '');
      expect(await identity.headers(), isEmpty);
    },
  );
}
