import 'dart:io';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/signals/signal_merger.dart';
import 'package:flutter_test/flutter_test.dart';

/// risk-mw's `KNOWN_SIMULATED`, read from the server source rather than a
/// hand copy: the `FLAG_FIELDS` keys of
/// `app/device_signals.py` and every field they list. `null` when the
/// server source is not next to the app (an app-only checkout).
Set<String>? knownSimulatedFromServer() {
  final file = File('../../services/risk-mw/app/device_signals.py');
  if (!file.existsSync()) return null;
  final src = file.readAsStringSync();
  final block = RegExp(
    r'FLAG_FIELDS[^=]*=\s*\{(.*?)\n\}',
    dotAll: true,
  ).firstMatch(src);
  if (block == null) return null;
  final names = <String>{};
  for (final line in RegExp(
    r'"(\w+)":\s*\(([^)]*)\)',
  ).allMatches(block.group(1)!)) {
    names.add(line.group(1)!);
    for (final f in RegExp(r'"(\w+)"').allMatches(line.group(2)!)) {
      names.add(f.group(1)!);
    }
  }
  return names;
}

const idle = DeviceSignals();

List<String> namesFor(DeviceSignals real, DemoState demo) =>
    SignalMerger.simulatedNames(real, SignalMerger.merge(real, demo));

void main() {
  group('SignalMerger.simulatedNames: only what the merge changed', () {
    test('nothing forced → empty', () {
      expect(namesFor(idle, DemoState.initial), isEmpty);
    });

    test('callActive on an idle phone → call_state', () {
      expect(namesFor(idle, const DemoState(callActive: true)), ['call_state']);
    });

    test('callActive while the phone really is on a call → nothing (the '
        'call is measured, not demo)', () {
      const onCall = DeviceSignals(callState: CallState.offhook);
      expect(namesFor(onCall, const DemoState(callActive: true)), isEmpty);
    });

    test('a ringing phone forced to OFFHOOK is a change → call_state', () {
      const ringing = DeviceSignals(callState: CallState.ringing);
      expect(namesFor(ringing, const DemoState(callActive: true)), [
        'call_state',
      ]);
    });

    test('simSwap is never named: no posted field changes and the server '
        'would expand the flag to its SIM fields', () {
      expect(namesFor(idle, const DemoState(simSwap: true)), isEmpty);
      const realSwap = DeviceSignals(subscriptionChangedHours: 2);
      expect(namesFor(realSwap, const DemoState(simSwap: true)), isEmpty);
    });

    test('screenShare → screen_capture; already capturing → nothing', () {
      expect(namesFor(idle, const DemoState(screenShare: true)), [
        'screen_capture',
      ]);
      const capturing = DeviceSignals(screenCapture: true);
      expect(namesFor(capturing, const DemoState(screenShare: true)), isEmpty);
    });

    test('a real screen_recording is never named', () {
      const recording = DeviceSignals(screenRecording: true);
      expect(namesFor(recording, const DemoState(screenShare: true)), [
        'screen_capture',
      ]);
    });

    test('all forced on an idle phone, in a stable order; other panel state '
        'adds nothing', () {
      expect(
        namesFor(
          idle,
          const DemoState(
            callActive: true,
            simSwap: true,
            screenShare: true,
            callerInContacts: true,
            scamScore: 0.9,
          ),
        ),
        ['call_state', 'screen_capture'],
      );
    });

    test('every name it can emit is in the server KNOWN_SIMULATED set', () {
      final known = knownSimulatedFromServer();
      if (known == null) {
        markTestSkipped('risk-mw source not next to the app');
        return;
      }
      expect(known, containsAll(<String>['call_state', 'sim_swap']));
      final all = namesFor(
        idle,
        const DemoState(callActive: true, simSwap: true, screenShare: true),
      );
      expect(all, isNotEmpty);
      expect(known, containsAll(all));
    });
  });
}
