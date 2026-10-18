/// The motion sensors run only while a scored pay flow is open: a cash in never starts them, and leaving `/pay` (back from step 1,
/// "হোমে ফিরুন" on the result) stops them.
library;

import 'dart:async';

import 'package:bhorosha/app/router.dart';
import 'package:bhorosha/domain/behaviour/behaviour_sample.dart';
import 'package:bhorosha/features/pay/logic/pay_controller.dart';
import 'package:bhorosha/features/pay/logic/pay_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pay_test_support.dart';

/// Counts listeners so a test can see the stream start and stop.
class _CountingImu implements ImuSource {
  int listening = 0;
  int started = 0;

  @override
  Stream<ImuSample> samples() {
    late StreamController<ImuSample> c;
    c = StreamController<ImuSample>(
      onListen: () {
        listening++;
        started++;
      },
      onCancel: () {
        listening--;
      },
    );
    return c.stream;
  }
}

void main() {
  testWidgets('send: IMU on at step 1, off after "হোমে ফিরুন" on the result', (
    tester,
  ) async {
    final imu = _CountingImu();
    final h = ScreenHarness(imu: imu);
    final c = await pumpPay(tester, harness: h, location: PayPaths.send);
    expect(imu.listening, 1);
    expect(c.read(payControllerProvider.notifier).imuRunning, isTrue);

    routerOf(c).go(PayPaths.result(PayKind.send, state: 'done', amount: 500));
    await tester.pumpAndSettle();
    expect(imu.listening, 1, reason: 'the result is still inside /pay');

    await tester.tap(find.byKey(const Key('result_home')));
    await tester.pumpAndSettle();
    expect(locationOf(c), Routes.home);
    expect(imu.listening, 0);
    expect(c.read(payControllerProvider.notifier).imuRunning, isFalse);
  });

  testWidgets('back from step 1 stops the IMU', (tester) async {
    final imu = _CountingImu();
    final h = ScreenHarness(imu: imu);
    final c = await pumpPay(
      tester,
      harness: h,
      location: PayPaths.start(PayKind.cashOut),
    );
    expect(imu.listening, 1);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(locationOf(c), Routes.home);
    expect(imu.listening, 0);
  });

  testWidgets('cash in, recharge and bill never start the IMU', (tester) async {
    for (final kind in [PayKind.cashIn, PayKind.recharge, PayKind.bill]) {
      final imu = _CountingImu();
      final h = ScreenHarness(imu: imu);
      await pumpPay(tester, harness: h, location: PayPaths.start(kind));
      expect(imu.started, 0, reason: kind.slug);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
