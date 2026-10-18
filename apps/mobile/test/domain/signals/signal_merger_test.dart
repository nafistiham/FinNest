import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/signals/signal_merger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const idle = DeviceSignals();
  const realCall = DeviceSignals(callState: CallState.offhook);
  const realCapture = DeviceSignals(screenCapture: true);

  group('SignalMerger.merge', () {
    final rows =
        <
          ({
            String name,
            DeviceSignals real,
            DemoState demo,
            DeviceSignals want,
          })
        >[
          (
            name: 'nothing set: real passes through',
            real: idle,
            demo: DemoState.initial,
            want: idle,
          ),
          (
            name: 'demo callActive forces OFFHOOK',
            real: idle,
            demo: const DemoState(callActive: true),
            want: const DeviceSignals(callState: CallState.offhook),
          ),
          (
            name: 'demo screenShare forces screenCapture',
            real: idle,
            demo: const DemoState(screenShare: true),
            want: const DeviceSignals(screenCapture: true),
          ),
          (
            name: 'real call survives a demo without the toggle',
            real: realCall,
            demo: DemoState.initial,
            want: realCall,
          ),
          (
            name: 'real capture survives a demo without the toggle',
            real: realCapture,
            demo: DemoState.initial,
            want: realCapture,
          ),
          (
            name:
                'demo ringing-to-offhook: demo wins over a RINGING real state',
            real: const DeviceSignals(callState: CallState.ringing),
            demo: const DemoState(callActive: true),
            want: const DeviceSignals(callState: CallState.offhook),
          ),
          (
            name: 'other real fields are untouched',
            real: const DeviceSignals(
              audioMode: 'in_call',
              subscriptionChangedHours: 3,
              accessibilityServices: ['a/.S'],
              screenRecording: true,
              obscuredTouch: true,
            ),
            demo: const DemoState(callActive: true, screenShare: true),
            want: const DeviceSignals(
              callState: CallState.offhook,
              audioMode: 'in_call',
              subscriptionChangedHours: 3,
              accessibilityServices: ['a/.S'],
              screenCapture: true,
              screenRecording: true,
              obscuredTouch: true,
            ),
          ),
        ];

    for (final row in rows) {
      test(row.name, () {
        expect(SignalMerger.merge(row.real, row.demo), row.want);
      });
    }
  });

  group('SignalMerger.flags', () {
    final rows =
        <
          ({
            String name,
            DeviceSignals merged,
            DemoState demo,
            SafetyVerdict? last,
            DemoFlags want,
          })
        >[
          (
            name: 'all defaults',
            merged: idle,
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(),
          ),
          (
            name: 'demo simSwap',
            merged: idle,
            demo: const DemoState(simSwap: true),
            last: null,
            want: const DemoFlags(simSwap: true),
          ),
          (
            name: 'subscription changed 3 h ago → simSwap',
            merged: const DeviceSignals(subscriptionChangedHours: 3),
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(simSwap: true),
          ),
          (
            name: 'subscription changed 48 h ago → no simSwap',
            merged: const DeviceSignals(subscriptionChangedHours: 48),
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(),
          ),
          (
            name: 'subscription changed exactly 24 h ago → no simSwap',
            merged: const DeviceSignals(subscriptionChangedHours: 24),
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(),
          ),
          (
            name: 'OFFHOOK → callActive',
            merged: realCall,
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(callActive: true),
          ),
          (
            name: 'RINGING → callActive',
            merged: const DeviceSignals(callState: CallState.ringing),
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(callActive: true),
          ),
          (
            name: 'screenCapture → screenShare',
            merged: realCapture,
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(screenShare: true),
          ),
          (
            name: 'screenRecording → screenShare',
            merged: const DeviceSignals(screenRecording: true),
            demo: DemoState.initial,
            last: null,
            want: const DemoFlags(screenShare: true),
          ),
          (
            name: 'callerInContacts and scamScore pass through from demo',
            merged: idle,
            demo: const DemoState(callerInContacts: true, scamScore: 0.85),
            last: null,
            want: const DemoFlags(callerInContacts: true, scamScore: 0.85),
          ),
          (
            name: 'last verdict used when nothing is forced',
            merged: idle,
            demo: DemoState.initial,
            last: SafetyVerdict.caution,
            want: const DemoFlags(appSafetyVerdict: SafetyVerdict.caution),
          ),
          (
            name: 'forced verdict beats the last verdict',
            merged: idle,
            demo: const DemoState(forcedSafetyVerdict: SafetyVerdict.block),
            last: SafetyVerdict.safe,
            want: const DemoFlags(appSafetyVerdict: SafetyVerdict.block),
          ),
        ];

    for (final row in rows) {
      test(row.name, () {
        expect(
          SignalMerger.flags(row.merged, row.demo, lastVerdict: row.last),
          row.want,
        );
      });
    }

    test('wire shape never carries persona or forced verdict keys', () {
      const demo = DemoState(
        persona: Persona.rina,
        forcedSafetyVerdict: SafetyVerdict.caution,
        callActive: true,
      );
      final json = SignalMerger.flags(
        SignalMerger.merge(idle, demo),
        demo,
      ).toJson();
      expect(json.keys, isNot(contains('persona')));
      expect(json.keys, isNot(contains('forced_safety_verdict')));
      expect(json.keys, {
        'sim_swap',
        'call_active',
        'screen_share',
        'caller_in_contacts',
        'app_safety_verdict',
        'inbound_mule_score',
        'scam_score',
      });
      expect(json['call_active'], isTrue);
      expect(json['app_safety_verdict'], 'CAUTION');
    });

    test('merge then flags: the video preset yields callActive', () {
      const demo = DemoState(callActive: true, scamScore: 0.85);
      final flags = SignalMerger.flags(SignalMerger.merge(idle, demo), demo);
      expect(flags.callActive, isTrue);
      expect(flags.scamScore, 0.85);
      expect(flags.simSwap, isFalse);
    });
  });
}
