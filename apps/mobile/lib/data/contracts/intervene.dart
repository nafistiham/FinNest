/// `/v1/intervene` request and response (contracts.py).
library;

import 'dart:typed_data';

import 'package:bhorosha/data/contracts/common.dart';
import 'package:bhorosha/data/contracts/score.dart';

/// `class InterveneRequest(Strict)`.
class InterveneRequest {
  const InterveneRequest({
    required this.userId,
    required this.trigger,
    required this.txn,
    this.transcriptSnippet,
    this.sessionId,
    this.interventionId,
  });

  factory InterveneRequest.fromJson(Map<String, dynamic> json) =>
      InterveneRequest(
        userId: requireString(json, 'user_id'),
        trigger: requireString(json, 'trigger'),
        txn: requireObject(json, 'txn', Txn.fromJson),
        transcriptSnippet: readStringOrNull(json, 'transcript_snippet'),
        sessionId: readStringOrNull(json, 'session_id'),
        interventionId: readStringOrNull(json, 'intervention_id'),
      );

  final String userId;
  final String trigger;
  final Txn txn;
  final String? transcriptSnippet;

  /// Additive, max 128 chars: the call the warning is for.
  final String? sessionId;

  /// Additive, max 64 chars: the hold the warning is for, the
  /// `intervention_id` of the score's actions. Without it the server finds
  /// the hold from `txn.txn_id`.
  final String? interventionId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user_id': userId,
    'trigger': trigger,
    'txn': txn.toJson(),
    'transcript_snippet': transcriptSnippet,
    // Omitted when null: the deployed service forbids extra keys
    // and does not know these yet (AppEnv.riskMwSessionFields).
    'session_id': ?sessionId,
    'intervention_id': ?interventionId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InterveneRequest &&
          userId == other.userId &&
          trigger == other.trigger &&
          txn == other.txn &&
          transcriptSnippet == other.transcriptSnippet &&
          sessionId == other.sessionId &&
          interventionId == other.interventionId;

  @override
  int get hashCode => Object.hash(
    userId,
    trigger,
    txn,
    transcriptSnippet,
    sessionId,
    interventionId,
  );

  @override
  String toString() => 'InterveneRequest(${toJson()})';
}

/// `class InterveneResponse(Strict)`: `script_bn` is Apa's line (FR-3).
class InterveneResponse {
  const InterveneResponse({
    required this.intervene,
    required this.scriptBn,
    required this.scriptEn,
    this.audioAssetId,
    required this.ui,
    required this.actions,
    required this.cooldownS,
    this.lines = const [],
    this.earcon = true,
    this.vibrate = true,
    this.speakOnDevice = false,
    this.warningId,
    this.interventionId,
    this.identitySource,
  });

  factory InterveneResponse.fromJson(Map<String, dynamic> json) =>
      InterveneResponse(
        intervene: requireBool(json, 'intervene'),
        scriptBn: requireString(json, 'script_bn'),
        scriptEn: requireString(json, 'script_en'),
        audioAssetId: readStringOrNull(json, 'audio_asset_id'),
        ui: requireEnum(json, 'ui', UiMode.fromWire),
        actions: requireList(json, 'actions', objectItem(ActionItem.fromJson)),
        cooldownS: requireInt(json, 'cooldown_s'),
        lines: readList(json, 'lines', objectItem(ApaLine.fromJson)),
        earcon: readBool(json, 'earcon', true),
        vibrate: readBool(json, 'vibrate', true),
        speakOnDevice: readBool(json, 'speak_on_device', false),
        warningId: readStringOrNull(json, 'warning_id'),
        interventionId: readStringOrNull(json, 'intervention_id'),
        identitySource: readStringOrNull(json, 'identity_source'),
      );

  final bool intervene;
  final String scriptBn;
  final String scriptEn;
  final String? audioAssetId;
  final UiMode ui;
  final List<ActionItem> actions;
  final int cooldownS;

  /// Additive field: Apa's warning written for this call,
  /// one validated line each, with its own `/v1/apa/why-audio` token and,
  /// when pre-rendered, a `/v1/apa/clips/{clip_id}`. Empty from older servers.
  final List<ApaLine> lines;

  /// Additive field: the earcon and the vibration fire at 0 ms.
  final bool earcon;
  final bool vibrate;

  /// Additive field: some line has no server audio. The app still tries
  /// Gemini TTS before the phone's own voice.
  final bool speakOnDevice;

  /// Additive field: null on the floor (no validated words).
  final String? warningId;

  /// Additive field: the server's id for this intervention, owned by the
  /// caller; once auth is on, the only id `POST /v1/actions/trusted-contact`
  /// accepts. Null from older servers.
  final String? interventionId;

  /// Additive field, as on `ScoreResponse`.
  final String? identitySource;

  /// The server's intervention id for this hold: [interventionId] when the
  /// server sent one, else the `intervention_id` param of [actions] (the
  /// hold `/v1/risk/score` recorded); null when neither names one.
  String? get serverInterventionId =>
      interventionId ?? interventionIdOf(actions);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'intervene': intervene,
    'script_bn': scriptBn,
    'script_en': scriptEn,
    'audio_asset_id': audioAssetId,
    'ui': ui.wire,
    'actions': actions.map((a) => a.toJson()).toList(),
    'cooldown_s': cooldownS,
    'lines': lines.map((l) => l.toJson()).toList(),
    'earcon': earcon,
    'vibrate': vibrate,
    'speak_on_device': speakOnDevice,
    'warning_id': warningId,
    'intervention_id': interventionId,
    'identity_source': identitySource,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InterveneResponse &&
          intervene == other.intervene &&
          scriptBn == other.scriptBn &&
          scriptEn == other.scriptEn &&
          audioAssetId == other.audioAssetId &&
          ui == other.ui &&
          listEq(actions, other.actions) &&
          cooldownS == other.cooldownS &&
          listEq(lines, other.lines) &&
          earcon == other.earcon &&
          vibrate == other.vibrate &&
          speakOnDevice == other.speakOnDevice &&
          warningId == other.warningId &&
          interventionId == other.interventionId &&
          identitySource == other.identitySource;

  @override
  int get hashCode => Object.hash(
    intervene,
    scriptBn,
    scriptEn,
    audioAssetId,
    ui,
    hashList(actions),
    cooldownS,
    hashList(lines),
    earcon,
    vibrate,
    speakOnDevice,
    warningId,
    interventionId,
    identitySource,
  );

  @override
  String toString() => 'InterveneResponse(${toJson()})';
}

/// The first non-empty `intervention_id` param of [actions]: the server
/// puts the hold's id on every action of a hold (`interventions.py`
/// `with_intervention_id`). Null when no action carries one.
String? interventionIdOf(List<ActionItem> actions) {
  for (final a in actions) {
    final id = a.params['intervention_id'];
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}

/// `class ApaLine(Strict)`: one validated line of the assistant's generated
/// warning. Every field but [textBn] is optional here, so an older server
/// that omits them still parses.
class ApaLine {
  const ApaLine({
    this.role = '',
    required this.textBn,
    this.textEn = '',
    this.token,
    this.expiresAt,
    this.clipId,
    this.speakOnDevice = false,
  });

  factory ApaLine.fromJson(Map<String, dynamic> json) => ApaLine(
    role: readString(json, 'role', ''),
    textBn: requireString(json, 'text_bn'),
    textEn: readString(json, 'text_en', ''),
    token: readStringOrNull(json, 'token'),
    expiresAt: readStringOrNull(json, 'expires_at'),
    clipId: readStringOrNull(json, 'clip_id'),
    speakOnDevice: readBool(json, 'speak_on_device', false),
  );

  /// `A` attention, `T` tactic, `R` rule, `X` action.
  final String role;
  final String textBn;
  final String textEn;

  /// Lets `POST /v1/apa/why-audio` speak [textBn] and nothing else.
  final String? token;
  final String? expiresAt;

  /// A pre-rendered line: `GET /v1/apa/clips/{clip_id}`.
  final String? clipId;

  /// The server has no audio for this line.
  final bool speakOnDevice;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role,
    'text_bn': textBn,
    'text_en': textEn,
    'token': token,
    'expires_at': expiresAt,
    'clip_id': clipId,
    'speak_on_device': speakOnDevice,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApaLine &&
          role == other.role &&
          textBn == other.textBn &&
          textEn == other.textEn &&
          token == other.token &&
          expiresAt == other.expiresAt &&
          clipId == other.clipId &&
          speakOnDevice == other.speakOnDevice;

  @override
  int get hashCode => Object.hash(
    role,
    textBn,
    textEn,
    token,
    expiresAt,
    clipId,
    speakOnDevice,
  );

  @override
  String toString() => 'ApaLine(${toJson()})';
}

/// `class ApaWhyAudioRequest(Strict)`: `POST /v1/apa/why-audio`, a WAV of one
/// line the server signed (24 kHz mono 16-bit), or 204 when it has none.
class ApaWhyAudioRequest {
  const ApaWhyAudioRequest({
    required this.userId,
    required this.textBn,
    this.token,
  });

  final String userId;
  final String textBn;
  final String? token;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user_id': userId,
    'text_bn': textBn,
    'token': token,
  };

  @override
  String toString() =>
      'ApaWhyAudioRequest(user_id: $userId, '
      'text_bn: ${textBn.length} chars)';
}

/// Audio bytes from `GET /v1/apa/clips/{clip_id}` (OGG Opus or WAV) or
/// `POST /v1/apa/why-audio` (WAV). Not JSON, so not a parity-tested model.
class ApaAudioBytes {
  const ApaAudioBytes(this.bytes, {this.mimeType = 'audio/wav'});

  final Uint8List bytes;
  final String mimeType;

  @override
  String toString() => 'ApaAudioBytes(${bytes.length} bytes, $mimeType)';
}
