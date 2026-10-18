import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/domain/risk/decision_routing.dart';
import 'package:bhorosha/features/intervention/logic/action_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DecisionRouting.containerFor', () {
    final rows = <({Decision d, UiMode? ui, Container want})>[
      (d: Decision.hold, ui: null, want: Container.fullscreen),
      (d: Decision.hold, ui: UiMode.banner, want: Container.fullscreen),
      (d: Decision.hold, ui: UiMode.fullscreen, want: Container.fullscreen),
      (d: Decision.hold, ui: UiMode.callApa, want: Container.fullscreen),
      (d: Decision.block, ui: null, want: Container.fullscreen),
      (d: Decision.block, ui: UiMode.banner, want: Container.fullscreen),
      (d: Decision.delay, ui: null, want: Container.banner),
      (d: Decision.delay, ui: UiMode.banner, want: Container.banner),
      (d: Decision.delay, ui: UiMode.fullscreen, want: Container.fullscreen),
      (d: Decision.delay, ui: UiMode.callApa, want: Container.banner),
      (d: Decision.stepUp, ui: null, want: Container.banner),
      (d: Decision.stepUp, ui: UiMode.banner, want: Container.banner),
      (d: Decision.stepUp, ui: UiMode.fullscreen, want: Container.fullscreen),
      (d: Decision.allow, ui: null, want: Container.banner),
      (d: Decision.allow, ui: UiMode.fullscreen, want: Container.banner),
    ];

    for (final row in rows) {
      test('${row.d.wire} + ${row.ui?.wire ?? 'no ui'} → ${row.want.name}', () {
        expect(DecisionRouting.containerFor(row.d, row.ui), row.want);
      });
    }
  });

  group('DecisionRouting.mergeActions', () {
    const holdScore = ActionItem(
      type: 'hold_transaction',
      params: {'minutes': 60},
    );
    const trustedScore = ActionItem(
      type: 'trusted_contact_check',
      params: {'expires_in_minutes': 30},
    );
    const delayIntervene = ActionItem(
      type: 'delay_new_payee',
      params: {'minutes': 60},
    );
    const trustedIntervene = ActionItem(
      type: 'trusted_contact_check',
      params: {'expires_in_minutes': 15},
    );

    test('dedupes by type and the score item wins; the money-stays family '
        '(hold, delay, freeze) collapses to the first one', () {
      final merged = DecisionRouting.mergeActions(
        [holdScore, trustedScore],
        [delayIntervene, trustedIntervene],
      );
      // The intervene's 60-minute delay is the same outcome as the score's
      // hold: two names for one button confuse the customer.
      expect(merged, [holdScore, trustedScore]);
      expect(
        DecisionRouting.mergeActions(const [], [delayIntervene, holdScore]),
        [delayIntervene],
      );
      expect(
        merged.singleWhere((a) => a.type == 'trusted_contact_check').params,
        {'expires_in_minutes': 30},
      );
    });

    test('order: score items first, then new intervene items in order', () {
      const a = ActionItem(type: 'a');
      const b = ActionItem(type: 'b');
      const c = ActionItem(type: 'c');
      const d = ActionItem(type: 'd');
      expect(DecisionRouting.mergeActions([c, a], [d, a, b]), [c, a, d, b]);
    });

    test('a server-sent biometric_step_up is dropped from both sides', () {
      const a = ActionItem(type: 'a');
      const stepUp = ActionItem(type: 'biometric_step_up');
      expect(DecisionRouting.mergeActions([stepUp, a], [stepUp]), [a]);
      expect(DecisionRouting.clientOnlyStepUp, ActionLabels.biometricStepUp);
    });

    test('empty score keeps every intervene item', () {
      expect(
        DecisionRouting.mergeActions(const [], [
          delayIntervene,
          trustedIntervene,
        ]),
        [delayIntervene, trustedIntervene],
      );
    });

    test('empty intervene keeps the score items', () {
      expect(DecisionRouting.mergeActions([holdScore], const []), [holdScore]);
    });

    test('duplicates inside one list keep the first occurrence', () {
      const first = ActionItem(type: 'x', params: {'n': 1});
      const second = ActionItem(type: 'x', params: {'n': 2});
      expect(DecisionRouting.mergeActions([first, second], const []), [first]);
    });

    test('result is unmodifiable', () {
      final merged = DecisionRouting.mergeActions([holdScore], const []);
      expect(() => merged.add(trustedScore), throwsUnsupportedError);
    });
  });
}
