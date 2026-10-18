/// State of one pay attempt, formerly
/// `SendMoneyController`.
///
/// The controller outlives the step screens because all of them read it:
/// the counterparty is chosen on step 1, the amount on step 2, both are
/// scored on the PIN pad, and a "try again" from the result screen returns
/// to the PIN pad with the same session. It also owns the behaviour
/// recorders that span those screens: the IMU window (started when the flow
/// opens so the ±1 s windows around the first PIN touch have history) and
/// the step-1 list swipe strokes.
library;

import 'dart:async';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:bhorosha/domain/behaviour/behaviour_sample.dart';
import 'package:bhorosha/domain/behaviour/imu_window.dart';
import 'package:bhorosha/domain/behaviour/swipe_recorder.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'billers.dart';
import 'pay_intent.dart';
import 'pay_ledger.dart';
import 'pay_rules.dart';

export 'pay_intent.dart';

const _tag = 'pay';

/// Accelerometer and gyroscope at ~50 Hz, merged into [ImuSample]s. The
/// default reads `sensors_plus`; tests override the provider with a fake
/// stream, since the plugin channel is absent under `flutter test`.
abstract class ImuSource {
  Stream<ImuSample> samples();
}

class SensorsPlusImuSource implements ImuSource {
  const SensorsPlusImuSource({this.period = SensorInterval.gameInterval});

  /// `SensorInterval.gameInterval` is 20 ms, i.e. 50 Hz.
  final Duration period;

  @override
  Stream<ImuSample> samples() {
    // The two sensors tick independently; the newest reading of each is
    // paired on every accelerometer tick, which sets the sample rate.
    var gx = 0.0, gy = 0.0, gz = 0.0;
    late StreamController<ImuSample> out;
    StreamSubscription<GyroscopeEvent>? gyro;
    StreamSubscription<AccelerometerEvent>? accel;
    out = StreamController<ImuSample>(
      onListen: () {
        gyro = gyroscopeEventStream(samplingPeriod: period).listen((g) {
          gx = g.x;
          gy = g.y;
          gz = g.z;
        }, onError: (Object e) => Log.w(_tag, 'gyroscope unavailable', e));
        accel = accelerometerEventStream(samplingPeriod: period).listen(
          (a) => out.add(
            ImuSample(
              tMs: DateTime.now().millisecondsSinceEpoch,
              ax: a.x,
              ay: a.y,
              az: a.z,
              gx: gx,
              gy: gy,
              gz: gz,
            ),
          ),
          onError: (Object e) => Log.w(_tag, 'accelerometer unavailable', e),
        );
      },
      onCancel: () async {
        await gyro?.cancel();
        await accel?.cancel();
      },
    );
    return out.stream;
  }
}

/// Silent source for tests and previews.
class NoImuSource implements ImuSource {
  const NoImuSource();
  @override
  Stream<ImuSample> samples() => const Stream.empty();
}

final imuSourceProvider = Provider<ImuSource>(
  (_) => const SensorsPlusImuSource(),
);

class PayController extends Notifier<PayIntent> {
  /// Amounts above this are refused on the numpad.
  static const maxAmount = PayRules.maxAmount;

  /// A Bangladeshi mobile number: 11 digits starting with 01.
  static const phoneLength = PayRules.phoneLength;

  final ImuWindow imuWindow = ImuWindow();
  final SwipeRecorder swipeRecorder = SwipeRecorder();
  StreamSubscription<ImuSample>? _imu;

  @override
  PayIntent build() {
    ref.onDispose(stopImu);
    return _fresh(PayKind.send);
  }

  PayIntent _fresh(PayKind kind) =>
      PayIntent(kind: kind, sessionId: ref.read(sessionRepoProvider).sessionId);

  /// A pay flow opened: clear the previous attempt and, for the scored
  /// kinds, start the IMU window (a recharge, bill or cash in never sends a
  /// behaviour vector, so its sensors stay off).
  void begin([PayKind kind = PayKind.send]) {
    swipeRecorder.reset();
    imuWindow.clear();
    state = _fresh(kind);
    if (kind.scored) {
      startImu();
    } else {
      unawaited(stopImu());
    }
  }

  /// Whether the IMU stream is running (tests).
  bool get imuRunning => _imu != null;

  void startImu() {
    if (_imu != null) return;
    try {
      _imu = ref
          .read(imuSourceProvider)
          .samples()
          .listen(
            imuWindow.add,
            onError: (Object e) => Log.w(_tag, 'imu stream error', e),
          );
    } on Object catch (e) {
      Log.w(_tag, 'imu start failed', e);
    }
  }

  Future<void> stopImu() async {
    final sub = _imu;
    _imu = null;
    await sub?.cancel();
  }

  // ---------------------------------------------------------------- step 1

  void selectCounterparty(Counterparty c) {
    state = state.copyWith(counterparty: c);
    if (state.kind == PayKind.recharge && state.operator == null) {
      final digits = c.subtitle.replaceAll(RegExp(r'[^0-9X]'), '');
      state = state.copyWith(operator: Operator.forNumber(digits));
    }
  }

  void clearCounterparty() => state = state.copyWith(counterparty: null);

  /// The payee line's audit fields: what was shown and
  /// what the customer did; both null clears an earlier record.
  void setPayeeWarning({required String? shown, required String? choice}) =>
      state = state.copyWith(warningShown: shown, warningChoice: choice);

  /// A saved payee of the send-money list.
  void selectPayee(Payee p) => selectCounterparty(
    Counterparty(
      acctId: p.acctId,
      nameBn: p.nameBn,
      nameEn: p.nameEn.isEmpty ? null : p.nameEn,
      subtitle: p.phoneMasked,
      isSaved: p.isSaved,
    ),
  );

  /// Recharge: the number's operator (customer override for ported numbers).
  void setOperator(Operator? op) => state = state.copyWith(operator: op);

  void setPostpaid(bool postpaid) => state = state.copyWith(postpaid: postpaid);

  /// Pay bill: the bill for one customer number; its amount is fixed.
  void setBill(Bill bill) {
    state = state.copyWith(
      bill: bill,
      counterparty: Counterparty(
        acctId: bill.acctId,
        nameBn: bill.biller.nameBn,
        nameEn: bill.biller.nameEn,
        subtitle: bill.account,
        avatar: const CounterpartyAvatar.initial(),
      ),
      fixedAmountBdt: bill.amountBdt,
      amountBdt: bill.amountBdt,
      feeBdt: 0,
    );
  }

  /// Savings: a new DPS plan's first instalment through the PIN step. The
  /// counterparty is the plan, the amount the fixed monthly instalment.
  void beginDps({required int monthlyBdt, required int tenureMonths}) {
    begin(PayKind.dps);
    state = state.copyWith(
      counterparty: const Counterparty(
        acctId: PayLedger.dpsAccount,
        nameBn: PayLedger.dpsName,
        nameEn: PayLedger.dpsNameEn,
        avatar: CounterpartyAvatar.icon(Icons.savings_outlined),
      ),
      amountBdt: monthlyBdt,
      fixedAmountBdt: monthlyBdt,
      feeBdt: 0,
      dpsTenureMonths: tenureMonths,
    );
  }

  // ---------------------------------------------------------------- amount

  void _amount(int a) => state = state.copyWith(
    amountBdt: a,
    feeBdt: PayRules.feeFor(state.kind, a),
  );

  /// Appends [d]; false (and no change) when the result would exceed
  /// [maxAmount] or the amount is fixed.
  bool appendDigit(int d) {
    if (state.fixedAmountBdt != null) return false;
    final next = state.amountBdt * 10 + d;
    if (next > maxAmount) return false;
    _amount(next);
    return true;
  }

  /// The "০০" key: both zeros or neither.
  bool appendDoubleZero() {
    if (state.fixedAmountBdt != null || state.amountBdt == 0) {
      return state.fixedAmountBdt == null;
    }
    final next = state.amountBdt * 100;
    if (next > maxAmount) return false;
    _amount(next);
    return true;
  }

  void backspaceAmount() {
    if (state.fixedAmountBdt != null) return;
    _amount(state.amountBdt ~/ 10);
  }

  void clearAmount() {
    if (state.fixedAmountBdt != null) return;
    _amount(0);
  }

  /// A quick amount: replaces the typed one, never adds.
  void setAmount(int amount) {
    if (state.fixedAmountBdt != null) return;
    _amount(amount.clamp(0, maxAmount));
  }

  /// Strokes recorded on the step-1 list so far.
  List<Stroke> get swipeStrokes => swipeRecorder.strokes;
}

final payControllerProvider = NotifierProvider<PayController, PayIntent>(
  PayController.new,
);

/// Compatibility names: existing callers keep compiling.
typedef SendMoneyController = PayController;
typedef SendMoneyState = PayIntent;
final sendMoneyControllerProvider = payControllerProvider;
