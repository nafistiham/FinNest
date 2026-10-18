import 'dart:typed_data';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_http_adapter.dart';
import 'risk_api_client_test.dart' show client;

/// The audio routes:
/// `GET /v1/apa/clips/{id}` and `POST /v1/apa/why-audio`.
ResponseBody audioBody(
  List<int> bytes, {
  int status = 200,
  String type = 'audio/wav',
  Map<String, String> headers = const {},
}) => ResponseBody.fromBytes(
  bytes,
  status,
  headers: {
    Headers.contentTypeHeader: [type],
    for (final e in headers.entries) e.key: [e.value],
  },
);

void main() {
  final wav = FakeRiskApi.silentWav.bytes;

  test('getApaClip: GET the encoded id, bytes and mime back', () async {
    final adapter = always(() => audioBody(wav, type: 'audio/ogg'));
    final clip = await client(adapter).getApaClip('c 1');
    expect(adapter.last.method, 'GET');
    expect(adapter.last.uri.path, '/v1/apa/clips/c%201');
    expect(adapter.last.headers['X-Demo-User'], 'rina');
    expect(adapter.last.receiveTimeout, const Duration(seconds: 4));
    expect(clip.bytes, wav);
    expect(clip.mimeType, 'audio/ogg');
  });

  test('getApaClip: 404 (no clip, or the route is not deployed)', () async {
    final adapter = always(
      () => jsonBody({'detail': 'no such clip'}, status: 404),
    );
    expect(
      () => client(adapter).getApaClip('gone'),
      throwsA(isA<ServerFailure>().having((f) => f.status, 'status', 404)),
    );
  });

  test('postApaWhyAudio: the signed line out, the whole WAV back', () async {
    final adapter = always(() => audioBody(wav));
    final audio = await client(adapter).postApaWhyAudio(
      const ApaWhyAudioRequest(userId: 'rina', textBn: 'লাইন', token: 'tok'),
    );
    expect(adapter.last.method, 'POST');
    expect(adapter.last.uri.path, RiskRoutes.apaWhyAudio);
    expect(adapter.lastJson(), {
      'user_id': 'rina',
      'text_bn': 'লাইন',
      'token': 'tok',
    });
    expect(adapter.last.receiveTimeout, const Duration(seconds: 10));
    expect(audio!.bytes, Uint8List.fromList(wav));
    expect(audio.mimeType, 'audio/wav');
  });

  test('postApaWhyAudio: 204 is null (no live audio)', () async {
    final adapter = always(() => audioBody(const [], status: 204));
    final audio = await client(adapter).postApaWhyAudio(
      const ApaWhyAudioRequest(userId: 'rina', textBn: 'লাইন', token: 'tok'),
    );
    expect(audio, isNull);
  });

  test('postApaWhyAudio: 429 is RateLimited with Retry-After', () async {
    final adapter = always(
      () => jsonBody(
        {'detail': 'slow down'},
        status: 429,
        headers: {'retry-after': '17'},
      ),
    );
    expect(
      () => client(adapter).postApaWhyAudio(
        const ApaWhyAudioRequest(userId: 'rina', textBn: 'লাইন', token: 't'),
      ),
      throwsA(
        isA<RateLimited>().having((f) => f.retryAfterSeconds, 'retry', 17),
      ),
    );
  });

  group('InterveneResponse audio fields (additive)', () {
    test('an older server without them parses with the defaults', () {
      final r = InterveneResponse.fromJson({
        'intervene': true,
        'script_bn': 'ক',
        'script_en': 'k',
        'audio_asset_id': null,
        'ui': 'banner',
        'actions': <Object>[],
        'cooldown_s': 60,
      });
      expect(r.lines, isEmpty);
      expect(r.earcon, isTrue);
      expect(r.vibrate, isTrue);
      expect(r.speakOnDevice, isFalse);
      expect(r.warningId, isNull);
    });

    test('lines with clip ids and tokens round-trip', () {
      final json = {
        'intervene': true,
        'script_bn': 'ক খ',
        'script_en': 'k kh',
        'audio_asset_id': null,
        'ui': 'fullscreen',
        'actions': <Object>[],
        'cooldown_s': 300,
        'lines': [
          {
            'role': 'A',
            'text_bn': 'ক',
            'text_en': 'k',
            'token': 'tok',
            'expires_at': '2026-10-17T12:00:00+00:00',
            'clip_id': 'c1',
            'speak_on_device': false,
          },
          {'role': 'X', 'text_bn': 'খ', 'speak_on_device': true},
        ],
        'earcon': true,
        'vibrate': false,
        'speak_on_device': true,
        'warning_id': 'w1',
      };
      final r = InterveneResponse.fromJson(json);
      expect(r.lines, hasLength(2));
      expect(r.lines.first.clipId, 'c1');
      expect(r.lines.first.token, 'tok');
      expect(r.lines.last.token, isNull);
      expect(r.lines.last.speakOnDevice, isTrue);
      expect(r.vibrate, isFalse);
      expect(r.warningId, 'w1');
      expect(InterveneResponse.fromJson(r.toJson()), r);
    });
  });
}
