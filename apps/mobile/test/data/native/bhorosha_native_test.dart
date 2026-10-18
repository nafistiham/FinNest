import 'dart:async';
import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('bhorosha_native_test');
  const eventChannel = EventChannel('bhorosha_native_test/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void mock(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(methodChannel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  MethodChannelBhoroshaNative subject({
    Duration timeout = const Duration(milliseconds: 60),
  }) => MethodChannelBhoroshaNative(
    methodChannel: methodChannel,
    eventChannel: eventChannel,
    signalsTimeout: timeout,
    bundleTimeout: timeout,
    integrityTimeout: timeout,
    attestationTimeout: timeout,
    controlTimeout: timeout,
  );

  setUp(calls.clear);
  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  group('getSignals', () {
    test('decodes a full map into contract models', () async {
      mock(
        (_) async => <Object?, Object?>{
          'signals': <Object?, Object?>{
            'call_state': 'OFFHOOK',
            'audio_mode': 'MODE_IN_CALL',
            'subscription_changed_hours': 3.5,
            'accessibility_services': <Object?>['com.evil.rat'],
            'screen_capture': true,
            'screen_recording': false,
            'obscured_touch': true,
          },
          'device': <Object?, Object?>{
            'model': 'Google Pixel 6',
            'os': 'Android 14',
            'rooted': false,
            'sim_serial_hash': 'abc',
            'sim_changed_at': '2026-10-15T10:00:00Z',
          },
        },
      );

      final result = await subject().getSignals();

      expect(result.signals.callState, CallState.offhook);
      expect(result.signals.audioMode, 'MODE_IN_CALL');
      expect(result.signals.subscriptionChangedHours, 3.5);
      expect(result.signals.accessibilityServices, ['com.evil.rat']);
      expect(result.signals.screenCapture, isTrue);
      expect(result.signals.screenRecording, isFalse);
      expect(result.signals.obscuredTouch, isTrue);
      expect(result.device.model, 'Google Pixel 6');
      expect(result.device.os, 'Android 14');
      expect(result.device.simSerialHash, 'abc');
      expect(result.device.simChangedAt, '2026-10-15T10:00:00Z');
      expect(calls.single.method, 'getSignals');
    });

    test('integer hours and null changed_at decode', () async {
      mock(
        (_) async => <Object?, Object?>{
          'signals': <Object?, Object?>{'subscription_changed_hours': 2},
          'device': <Object?, Object?>{'sim_changed_at': null},
        },
      );
      final result = await subject().getSignals();
      expect(result.signals.subscriptionChangedHours, 2.0);
      expect(result.device.simChangedAt, isNull);
    });

    test('returns defaults when the channel never answers', () async {
      final never = Completer<Object?>();
      mock((_) => never.future);

      final result = await subject(timeout: const Duration(milliseconds: 40))
          .getSignals();

      expect(result, NativeSignals.defaults());
      expect(result.signals.callState, CallState.idle);
      expect(result.device.model, '');
    });

    test('returns defaults when the plugin is missing', () async {
      // No handler registered: MissingPluginException.
      final result = await subject().getSignals();
      expect(result, NativeSignals.defaults());
    });

    test('returns defaults on PlatformException', () async {
      mock((_) async => throw PlatformException(code: 'native_error'));
      expect(await subject().getSignals(), NativeSignals.defaults());
    });

    test('returns defaults on malformed call_state', () async {
      mock(
        (_) async => <Object?, Object?>{
          'signals': <Object?, Object?>{'call_state': 'BUSY'},
        },
      );
      expect(await subject().getSignals(), NativeSignals.defaults());
    });
  });

  group('getAppSafetyBundle', () {
    // The App Safety collector's reply: the AppSafetyRequest body as a JSON string.
    const collectorJson = <String, Object?>{
      'installed_apps': <Object?>[
        <String, Object?>{
          'package': 'com.demo.takanow',
          'label': 'TakaNow Loan',
          'installer': 'com.android.chrome',
          'version': '1.0',
          'permissions': <Object?>[
            'android.permission.READ_SMS',
            'android.permission.SYSTEM_ALERT_WINDOW',
          ],
          'has_accessibility_service': true,
          'accessibility_enabled': true,
          'target_sdk': 35,
          'first_install': '2026-10-16T09:12:03Z',
        },
        <String, Object?>{
          'package': 'com.android.settings',
          'label': 'Settings',
          'installer': 'system',
          'version': null,
          'permissions': <Object?>[],
          'has_accessibility_service': false,
          'accessibility_enabled': false,
          'target_sdk': 34,
          'first_install': '2009-01-01T00:00:00Z',
        },
      ],
      'device': <String, Object?>{
        'overlay_holders': <Object?>['com.demo.takanow'],
        'device_admins': <Object?>[],
        'dev_options': true,
        'adb': true,
        'rooted': false,
        'play_protect': true,
      },
      'integrity_token': null,
    };

    test('decodes the collector JSON string', () async {
      mock((_) async => jsonEncode(collectorJson));

      final bundle = await subject().getAppSafetyBundle();

      expect(bundle.installedApps, hasLength(2));
      final app = bundle.installedApps.first;
      expect(app.package, 'com.demo.takanow');
      expect(app.installer, 'com.android.chrome');
      expect(app.version, '1.0');
      expect(app.hasAccessibilityService, isTrue);
      expect(app.accessibilityEnabled, isTrue);
      expect(app.targetSdk, 35);
      expect(app.firstInstall, '2026-10-16T09:12:03Z');
      final system = bundle.installedApps.last;
      expect(system.installer, 'system');
      expect(system.version, '');
      expect(bundle.device.overlayHolders, ['com.demo.takanow']);
      expect(bundle.device.devOptions, isTrue);
      expect(bundle.device.adb, isTrue);
      expect(bundle.device.playProtect, isTrue);
      expect(calls.single.method, 'getAppSafetyBundle');
    });

    test('also accepts an already-decoded map', () async {
      mock((_) async => collectorJson);
      final bundle = await subject().getAppSafetyBundle();
      expect(bundle.installedApps, hasLength(2));
    });

    test(
      'returns the unavailable bundle (never posted, M16) on malformed JSON',
      () async {
        mock((_) async => '{not json');
        expect(
          await subject().getAppSafetyBundle(),
          AppSafetyBundle.unavailable,
        );

        mock((_) async => '[1, 2]');
        expect(
          await subject().getAppSafetyBundle(),
          AppSafetyBundle.unavailable,
        );
      },
    );

    test(
      'returns the unavailable bundle (never posted, M16) on error',
      () async {
        mock((_) async => throw PlatformException(code: 'native_error'));
        final bundle = await subject().getAppSafetyBundle();
        expect(bundle, AppSafetyBundle.unavailable);
        expect(bundle.failed, isTrue);
        expect(bundle.isEmpty, isTrue);
      },
    );

    test(
      'returns the unavailable bundle (never posted, M16) on timeout',
      () async {
        mock((_) => Completer<Object?>().future);
        expect(
          await subject(timeout: const Duration(milliseconds: 40))
              .getAppSafetyBundle(),
          AppSafetyBundle.unavailable,
        );
      },
    );

    test('returns the unavailable bundle (never posted, M16) when an app lacks a package', () async {
      mock((_) async => '{"installed_apps": [{"label": "nameless"}]}');
      expect(await subject().getAppSafetyBundle(), AppSafetyBundle.unavailable);
    });
  });

  group('getAppSafetyAttestation', () {
    test('decodes bundle string, hash and token', () async {
      mock(
        (_) async => <Object?, Object?>{
          'bundle':
              '{"installed_apps":[{"package":"com.demo.takanow"}],'
              '"device":{"adb":true},"integrity_token":null}',
          'bundle_hash': 'ab' * 32,
          'integrity_token': 'tok.en',
        },
      );

      final att = await subject().getAppSafetyAttestation();

      expect(att.bundle.installedApps.single.package, 'com.demo.takanow');
      expect(att.bundle.device.adb, isTrue);
      expect(att.bundleHash, 'ab' * 32);
      expect(att.integrityToken, 'tok.en');
      expect(calls.single.method, 'getAppSafetyAttestation');
    });

    test('null token and empty hash decode to null/empty', () async {
      mock(
        (_) async => <Object?, Object?>{
          'bundle': <Object?, Object?>{'installed_apps': <Object?>[]},
          'integrity_token': null,
        },
      );
      final att = await subject().getAppSafetyAttestation();
      expect(att.integrityToken, isNull);
      expect(att.bundleHash, '');
      expect(att.bundle, AppSafetyBundle.empty);
    });

    test('falls back to getAppSafetyBundle on timeout', () async {
      mock((call) {
        if (call.method == 'getAppSafetyAttestation') {
          return Completer<Object?>().future;
        }
        return Future<Object?>.value(
          '{"installed_apps":[{"package":"com.x"}],"device":{}}',
        );
      });
      final att = await subject(timeout: const Duration(milliseconds: 40))
          .getAppSafetyAttestation();
      expect(att.bundle.installedApps.single.package, 'com.x');
      expect(att.bundleHash, '');
      expect(att.integrityToken, isNull);
      expect(calls.map((c) => c.method), [
        'getAppSafetyAttestation',
        'getAppSafetyBundle',
      ]);
    });

    test('is unavailable when the plugin is missing', () async {
      final att = await subject().getAppSafetyAttestation();
      expect(att.bundle, AppSafetyBundle.unavailable);
      expect(att.bundle.failed, isTrue);
      expect(att.integrityToken, isNull);
    });
  });

  group('integrity', () {
    test('prepareIntegrity is skipped for an empty number', () async {
      mock((_) async => null);
      await subject().prepareIntegrity('');
      await subject().prepareIntegrity('   ');
      expect(calls, isEmpty);
    });

    test('prepareIntegrity forwards the project number', () async {
      mock((_) async => null);
      await subject().prepareIntegrity('123456789012');
      expect(calls.single.method, 'prepareIntegrity');
      expect(calls.single.arguments, {'cloudProjectNumber': '123456789012'});
    });

    test('getIntegrityToken returns the token', () async {
      mock((_) async => 'tok.en');
      expect(await subject().getIntegrityToken('h'), 'tok.en');
      expect(calls.single.arguments, {'requestHash': 'h'});
    });

    test('getIntegrityToken is null on error, null and timeout', () async {
      mock((_) async => throw PlatformException(code: 'x'));
      expect(await subject().getIntegrityToken('h'), isNull);

      mock((_) async => null);
      expect(await subject().getIntegrityToken('h'), isNull);

      mock((_) => Completer<Object?>().future);
      expect(
        await subject(timeout: const Duration(milliseconds: 40))
            .getIntegrityToken('h'),
        isNull,
      );
    });
  });

  group('controls', () {
    test('encode their arguments', () async {
      mock((_) async => null);
      final native = subject();
      await native.setSecure(true);
      await native.openAppDetails('com.demo.takanow');
      await native.playPcm(Uint8List.fromList([1, 2, 3]), 24000);
      await native.stopPcm();

      expect(calls.map((c) => c.method), [
        'setSecure',
        'openAppDetails',
        'playPcm',
        'stopPcm',
      ]);
      expect(calls[0].arguments, {'on': true});
      expect(calls[1].arguments, {'package': 'com.demo.takanow'});
      final pcmArgs = calls[2].arguments as Map<Object?, Object?>;
      expect(pcmArgs['bytes'], Uint8List.fromList([1, 2, 3]));
      expect(pcmArgs['sampleRate'], 24000);
    });

    test('never throw when the plugin is missing', () async {
      final native = subject();
      await native.setSecure(false);
      await native.openAppDetails('x');
      await native.playPcm(Uint8List(0), 24000);
      await native.stopPcm();
      expect(await native.requestPhoneStatePermission(), isFalse);
    });

    test('setSecure always sends an explicit on, and a native refusal '
        '(no activity) is logged, never thrown', () async {
      mock((_) async => throw PlatformException(code: 'no_activity'));
      final native = subject();
      await native.setSecure(true);
      await native.setSecure(false);
      expect(calls.map((c) => c.arguments), [
        {'on': true},
        {'on': false},
      ]);
    });

    test('requestPhoneStatePermission forwards the grant', () async {
      mock((_) async => true);
      expect(await subject().requestPhoneStatePermission(), isTrue);
    });
  });

  group('events', () {
    test('NativeEvent.fromMap decodes all four types', () {
      expect(
        NativeEvent.fromMap({'type': 'call_state', 'value': 'RINGING'}),
        const CallStateEvent(CallState.ringing),
      );
      expect(
        NativeEvent.fromMap({'type': 'screen_capture', 'value': true}),
        const ScreenCaptureEvent(true),
      );
      expect(
        NativeEvent.fromMap({'type': 'screen_recording', 'value': false}),
        const ScreenRecordingEvent(false),
      );
      expect(
        NativeEvent.fromMap({'type': 'obscured_touch'}),
        const ObscuredTouchEvent(),
      );
    });

    test('NativeEvent.fromMap drops malformed maps', () {
      expect(NativeEvent.fromMap(null), isNull);
      expect(NativeEvent.fromMap('call_state'), isNull);
      expect(NativeEvent.fromMap(<Object?, Object?>{}), isNull);
      expect(NativeEvent.fromMap({'type': 'unknown'}), isNull);
      expect(NativeEvent.fromMap({'type': 'call_state'}), isNull);
      expect(
        NativeEvent.fromMap({'type': 'call_state', 'value': 'BUSY'}),
        isNull,
      );
      expect(
        NativeEvent.fromMap({'type': 'screen_capture', 'value': 1}),
        isNull,
      );
      expect(
        NativeEvent.fromMap({'type': 'screen_recording', 'value': 'yes'}),
        isNull,
      );
    });

    test('events stream decodes and drops malformed items', () async {
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (Object? args, MockStreamHandlerEventSink sink) {
            sink.success({'type': 'call_state', 'value': 'OFFHOOK'});
            sink.success({'type': 'bogus'});
            sink.success('not a map');
            sink.success({'type': 'screen_capture', 'value': true});
            sink.success({'type': 'obscured_touch'});
            sink.endOfStream();
          },
        ),
      );

      final native = subject();
      expect(native.events.isBroadcast, isTrue);
      final received = await native.events.toList();

      expect(received, [
        const CallStateEvent(CallState.offhook),
        const ScreenCaptureEvent(true),
        const ObscuredTouchEvent(),
      ]);
    });
  });

  group('FakeBhoroshaNative', () {
    test('records calls, applies delay and emits events', () async {
      final fake = FakeBhoroshaNative(
        integrityToken: 't',
        delay: const Duration(milliseconds: 5),
      );
      final sw = Stopwatch()..start();
      await fake.setSecure(true);
      sw.stop();
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4)));

      await fake.openAppDetails('p');
      await fake.playPcm(Uint8List(2), 24000);
      await fake.prepareIntegrity('1');
      expect(await fake.getIntegrityToken('h'), 't');
      expect(fake.secureCalls, [true]);
      expect(fake.openedPackages, ['p']);
      expect(fake.pcmChunks, hasLength(1));
      expect(fake.prepared, ['1']);
      expect(await fake.getSignals(), NativeSignals.defaults());
      expect(await fake.getAppSafetyBundle(), AppSafetyBundle.empty);
      expect(
        await fake.getAppSafetyAttestation(),
        const AppSafetyAttestation(
          bundle: AppSafetyBundle.empty,
          integrityToken: 't',
        ),
      );
      fake.attestation = const AppSafetyAttestation(
        bundle: AppSafetyBundle.empty,
        bundleHash: 'h',
      );
      expect((await fake.getAppSafetyAttestation()).bundleHash, 'h');

      final events = fake.events.take(1).toList();
      fake.emit(const ObscuredTouchEvent());
      expect(await events, [const ObscuredTouchEvent()]);
      await fake.dispose();
    });
  });
}
