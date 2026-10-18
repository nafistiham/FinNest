import 'package:bhorosha/data/api/api_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerFailure.fromBody', () {
    test('keeps msg and loc of the first FastAPI validation error', () {
      final f = ServerFailure.fromBody(422, {
        'detail': [
          {
            'type': 'missing',
            'loc': ['body', 'session_id'],
            'msg': 'Field required',
            'input': {'user_id': 'rina'},
          },
          {
            'type': 'missing',
            'loc': ['body', 'txn'],
            'msg': 'Field required',
          },
        ],
      });
      expect(f.status, 422);
      expect(f.serverMessage, 'Field required (body.session_id)');
      expect(f.isClientError, isTrue);
      expect(
        f.toString(),
        'ServerFailure(422): Field required (body.session_id)',
      );
    });

    test('keeps a string detail', () {
      final f = ServerFailure.fromBody(404, {
        'detail': 'unknown trusted-contact request',
      });
      expect(f.serverMessage, 'unknown trusted-contact request');
    });

    test('tolerates bodies without detail', () {
      expect(ServerFailure.fromBody(500, null).serverMessage, isNull);
      expect(ServerFailure.fromBody(500, 'oops').serverMessage, isNull);
      expect(ServerFailure.fromBody(500, {'error': 1}).serverMessage, isNull);
      expect(
        ServerFailure.fromBody(500, {'detail': <Object?>[]}).serverMessage,
        isNull,
      );
      expect(ServerFailure.fromBody(502, {}).isServerError, isTrue);
    });
  });

  test('failures are const and describe themselves', () {
    const failures = <ApiFailure>[
      NetworkFailure(),
      TimeoutFailure('deadline exceeded', Duration(seconds: 2)),
      ContractFailure('Missing required key "decision"'),
      ServerFailure(500),
    ];
    expect(failures.map((f) => f.toString()), [
      'NetworkFailure: network unreachable',
      'TimeoutFailure: deadline exceeded after 2000 ms',
      'ContractFailure: Missing required key "decision"',
      'ServerFailure(500)',
    ]);
    expect(
      const TimeoutFailure().toString(),
      'TimeoutFailure: request timed out',
    );
    for (final f in failures) {
      expect(f, isA<Exception>());
    }
  });
}
