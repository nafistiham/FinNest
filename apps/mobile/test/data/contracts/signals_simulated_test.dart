import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SignalsRequest.simulated', () {
    test('omitted from the wire when empty', () {
      final json = const SignalsRequest(sessionId: 's').toJson();
      expect(json.containsKey('simulated'), isFalse);
    });

    test('sent as a list when non-empty, and parsed back', () {
      const r = SignalsRequest(
        sessionId: 's',
        simulated: ['call_state', 'sim_swap'],
      );
      final json = r.toJson();
      expect(json['simulated'], ['call_state', 'sim_swap']);
      expect(SignalsRequest.fromJson(json), r);
    });

    test('missing key parses as empty; equality includes it', () {
      final r = SignalsRequest.fromJson({'session_id': 's'});
      expect(r.simulated, isEmpty);
      expect(
        r == const SignalsRequest(sessionId: 's', simulated: ['call_state']),
        isFalse,
      );
    });
  });
}
