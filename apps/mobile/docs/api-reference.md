# FinNest app: API reference

Every route the app calls, with the exact request and response schemas. Source: the risk-mw OpenAPI document
(`risk-mw-0.2`) plus the app-side contract classes for the two audio routes. Headers on every call: `Authorization: Bearer <Firebase ID token>` and `X-Demo-User: <persona uid>`.
Generated from the OpenAPI export. Regenerate it when the risk-mw contracts change.

## Routes

- [`GET /health`](#api-get-health)
- [`POST /v1/appsafety/demo-token`](#api-post-v1-appsafety-demo-token)
- [`POST /v1/appsafety/check`](#api-post-v1-appsafety-check)
- [`GET /v1/appsafety/latest/{target_uid}`](#api-get-v1-appsafety-latest-target-uid)
- [`POST /v1/risk/signals`](#api-post-v1-risk-signals)
- [`POST /v1/risk/score`](#api-post-v1-risk-score)
- [`POST /v1/intervene`](#api-post-v1-intervene)
- [`POST /v1/actions/trusted-contact`](#api-post-v1-actions-trusted-contact)
- [`POST /v1/actions/trusted-contact/{request_id}/approve`](#api-post-v1-actions-trusted-contact-request-id-approve)
- [`POST /v1/actions/trusted-contact/{request_id}/decline`](#api-post-v1-actions-trusted-contact-request-id-decline)
- [`GET /v1/apa/clips/{clip_id}`](#api-get-v1-apa-clips-clip-id)
- [`POST /v1/apa/why-audio`](#api-post-v1-apa-why-audio)
- [`POST /v1/scam/turn`](#api-post-v1-scam-turn)
- [`POST /v1/apa/turn`](#api-post-v1-apa-turn)
- [`POST /v1/investigate`](#api-post-v1-investigate)
- [`GET /v1/investigations/{case_id}`](#api-get-v1-investigations-case-id)

<a id="api-get-health"></a>

## GET `/health`

Journey: Send money. The Pay screen opens for a scored kind. Warm-up only, the answer is ignored.

- Caller: `lib/features/pay/ui/pay_start_screen.dart`
- Timeout: default
- On failure: Ignored.

### Request body

No body.

### Response 200

```json
{
  "status": "ok"
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-appsafety-demo-token"></a>

## POST `/v1/appsafety/demo-token`

Journey: Home. Home load, when the phone has no real Play Integrity token. Demo mode only: outside it the server answers 404.

- Caller: `lib/features/safety/logic/app_safety_flow.dart`
- Timeout: 4 s
- On failure: The check runs with integrity_token null.

### Request body

| DemoIntegrityRequest | Type | Required | Notes |
|---|---|---|---|
| `installed_apps` | array of InstalledApp |  | default: every field at its own default. maxItems `500` |
| &nbsp;&nbsp;└ `package` | string | yes |  |
| &nbsp;&nbsp;└ `label` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `installer` | string or null |  |  |
| &nbsp;&nbsp;└ `version` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `permissions` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `has_accessibility_service` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `accessibility_enabled` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `target_sdk` | integer or null |  |  |
| &nbsp;&nbsp;└ `first_install` | string or null |  |  |
| &nbsp;&nbsp;└ `has_notification_listener` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `has_hce_service` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `is_default_sms_app` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `launcher_icon_hidden` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `installer_declares_install_packages` | boolean |  | default `false` |
| `device` | DeviceState |  | default: every field at its own default |
| &nbsp;&nbsp;└ `overlay_holders` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `device_admins` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `dev_options` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `adb` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `rooted` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `play_protect` | boolean |  | default `true` |
| &nbsp;&nbsp;└ `sdk_int` | integer or null |  |  |
| &nbsp;&nbsp;└ `default_sms_package` | string or null |  |  |
| &nbsp;&nbsp;└ `nfc_default_payment_package` | string or null |  |  |
| `apps_detected` | array of string |  | default: every field at its own default |
| `play_protect_verdict` | string |  | default `&quot;NO_ISSUES&quot;` |
| `app_recognition` | enum |  | one of `PLAY_RECOGNIZED`, `UNRECOGNIZED_VERSION`, `UNEVALUATED`. default `&quot;PLAY_RECOGNIZED&quot;` |
| `device_recognition` | array of string |  | default: every field at its own default |
| `bound` | boolean |  | default `true` |

```json
{
  "installed_apps": [{
    "package": "...",
    "label": "...",
    "installer": "...",
    "version": "...",
    "permissions": [string],
    "has_accessibility_service": true,
    "accessibility_enabled": true,
    "target_sdk": 0,
    "first_install": "...",
    "has_notification_listener": true,
    "has_hce_service": true,
    "is_default_sms_app": true,
    "launcher_icon_hidden": true,
    "installer_declares_install_packages": true
  }],
  "device": {
    "overlay_holders": [string],
    "device_admins": [string],
    "dev_options": true,
    "adb": true,
    "rooted": true,
    "play_protect": true,
    "sdk_int": 0,
    "default_sms_package": "...",
    "nfc_default_payment_package": "..."
  },
  "apps_detected": [string],
  "play_protect_verdict": "...",
  "app_recognition": "PLAY_RECOGNIZED|UNRECOGNIZED_VERSION|UNEVALUATED",
  "device_recognition": [string],
  "bound": true
}
```

### Response 200

| DemoIntegrityResponse | Type | Required | Notes |
|---|---|---|---|
| `integrity_token` | string | yes |  |
| `bundle_hash` | string | yes |  |
| `expires_in_s` | integer | yes |  |

```json
{
  "integrity_token": "...",
  "bundle_hash": "...",
  "expires_in_s": 0
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-appsafety-check"></a>

## POST `/v1/appsafety/check`

Journey: Home. Every Home load, every return from an uninstall, every manual retry.

- Caller: `lib/features/safety/logic/app_safety_flow.dart`
- Timeout: 4 s
- On failure: Badge "could not check", then GET /v1/appsafety/latest/{uid}.

### Request body

| AppSafetyRequest | Type | Required | Notes |
|---|---|---|---|
| `installed_apps` | array of InstalledApp |  | default: every field at its own default. maxItems `500` |
| &nbsp;&nbsp;└ `package` | string | yes |  |
| &nbsp;&nbsp;└ `label` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `installer` | string or null |  |  |
| &nbsp;&nbsp;└ `version` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `permissions` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `has_accessibility_service` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `accessibility_enabled` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `target_sdk` | integer or null |  |  |
| &nbsp;&nbsp;└ `first_install` | string or null |  |  |
| &nbsp;&nbsp;└ `has_notification_listener` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `has_hce_service` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `is_default_sms_app` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `launcher_icon_hidden` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `installer_declares_install_packages` | boolean |  | default `false` |
| `device` | DeviceState |  | default: every field at its own default |
| &nbsp;&nbsp;└ `overlay_holders` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `device_admins` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `dev_options` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `adb` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `rooted` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `play_protect` | boolean |  | default `true` |
| &nbsp;&nbsp;└ `sdk_int` | integer or null |  |  |
| &nbsp;&nbsp;└ `default_sms_package` | string or null |  |  |
| &nbsp;&nbsp;└ `nfc_default_payment_package` | string or null |  |  |
| `integrity_token` | string or null |  |  |

```json
{
  "installed_apps": [{
    "package": "...",
    "label": "...",
    "installer": "...",
    "version": "...",
    "permissions": [string],
    "has_accessibility_service": true,
    "accessibility_enabled": true,
    "target_sdk": 0,
    "first_install": "...",
    "has_notification_listener": true,
    "has_hce_service": true,
    "is_default_sms_app": true,
    "launcher_icon_hidden": true,
    "installer_declares_install_packages": true
  }],
  "device": {
    "overlay_holders": [string],
    "device_admins": [string],
    "dev_options": true,
    "adb": true,
    "rooted": true,
    "play_protect": true,
    "sdk_int": 0,
    "default_sms_package": "...",
    "nfc_default_payment_package": "..."
  },
  "integrity_token": "..."
}
```

### Response 200

| AppSafetyResponse | Type | Required | Notes |
|---|---|---|---|
| `verdict` | enum | yes | one of `SAFE`, `CAUTION`, `BLOCK` |
| `risk_score` | number | yes | minimum `0.0`. maximum `1.0` |
| `findings` | array of Finding | yes |  |
| &nbsp;&nbsp;└ `package` | string | yes |  |
| &nbsp;&nbsp;└ `signal` | string | yes |  |
| &nbsp;&nbsp;└ `severity` | enum | yes | one of `low`, `medium`, `high`, `critical` |
| &nbsp;&nbsp;└ `evidence` | string | yes |  |
| &nbsp;&nbsp;└ `explanation_bn` | string | yes |  |
| &nbsp;&nbsp;└ `explanation_en` | string | yes |  |
| &nbsp;&nbsp;└ `title_bn` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `title_en` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `scope` | enum |  | one of `app`, `device`. default `&quot;app&quot;` |
| `recommended_action` | string | yes |  |
| `apps_to_uninstall` | array of string | yes |  |
| `user_message_bn` | string | yes |  |
| `user_message_en` | string | yes |  |
| `simulated_verdict` | boolean | yes |  |
| `model_version` | string |  | default `&quot;&quot;` |
| `agrees_with_classifier` | boolean or null |  |  |
| `disagreement_reason` | string |  | default `&quot;&quot;` |
| `attestation` | string |  | default `&quot;none&quot;` |
| `resolution` | string |  | default `&quot;NONE&quot;` |
| `recheck_lifts_block` | boolean |  | default `false` |
| `uninstall_targets` | array of UninstallTarget |  | default: every field at its own default |
| &nbsp;&nbsp;└ `package` | string | yes |  |
| &nbsp;&nbsp;└ `label` | string | yes |  |
| &nbsp;&nbsp;└ `primary_signal` | string | yes |  |
| &nbsp;&nbsp;└ `deep_link` | string | yes |  |
| `check_id` | string |  | default `&quot;&quot;` |
| `valid_until` | string |  | default `&quot;&quot;` |

```json
{
  "verdict": "SAFE|CAUTION|BLOCK",
  "risk_score": 0.0,
  "findings": [{
    "package": "...",
    "signal": "...",
    "severity": "low|medium|high|critical",
    "evidence": "...",
    "explanation_bn": "...",
    "explanation_en": "...",
    "title_bn": "...",
    "title_en": "...",
    "scope": "app|device"
  }],
  "recommended_action": "...",
  "apps_to_uninstall": [string],
  "user_message_bn": "...",
  "user_message_en": "...",
  "simulated_verdict": true,
  "model_version": "...",
  "agrees_with_classifier": true,
  "disagreement_reason": "...",
  "attestation": "...",
  "resolution": "...",
  "recheck_lifts_block": true,
  "uninstall_targets": [{
    "package": "...",
    "label": "...",
    "primary_signal": "...",
    "deep_link": "..."
  }],
  "check_id": "...",
  "valid_until": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-get-v1-appsafety-latest-target-uid"></a>

## GET `/v1/appsafety/latest/{target_uid}`

Journey: Home. Only after a failed check. The standing verdict for the uid.

- Caller: `lib/features/safety/logic/app_safety_flow.dart`
- Timeout: 2 s
- On failure: Badge stays on "could not check". 404 while the route is not deployed.

| Path parameter | Type | Required |
|---|---|---|
| `target_uid` | string | yes |

### Request body

No body.

### Response 200

| AppSafetyLatest | Type | Required | Notes |
|---|---|---|---|
| `uid` | string | yes |  |
| `known` | boolean | yes |  |
| `verdict` | enum |  | one of `SAFE`, `CAUTION`, `BLOCK`. default `&quot;SAFE&quot;` |
| `risk_score` | number |  | default `0.0`. minimum `0.0`. maximum `1.0` |
| `flagged_packages` | array of string |  | default: every field at its own default |
| `attestation` | string |  | default `&quot;none&quot;` |
| `checked_at` | string |  | default `&quot;&quot;` |
| `valid_until` | string |  | default `&quot;&quot;` |

```json
{
  "uid": "...",
  "known": true,
  "verdict": "SAFE|CAUTION|BLOCK",
  "risk_score": 0.0,
  "flagged_packages": [string],
  "attestation": "...",
  "checked_at": "...",
  "valid_until": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-risk-signals"></a>

## POST `/v1/risk/signals`

Journey: Send money. After the PIN, before the score. Carries the device, the merged signals, the integrity token and the behaviour vector.

- Caller: `lib/features/send_money/logic/risk_flow.dart`
- Timeout: default
- On failure: Logged. The flow continues.

### Request body

| SignalsRequest | Type | Required | Notes |
|---|---|---|---|
| `session_id` | string | yes |  |
| `device` | DeviceInfo |  | default: every field at its own default |
| &nbsp;&nbsp;└ `model` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `os` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `rooted` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `sim_serial_hash` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `sim_changed_at` | string or null |  |  |
| &nbsp;&nbsp;└ `first_seen_at` | string or null |  |  |
| `signals` | DeviceSignals |  | default: every field at its own default |
| &nbsp;&nbsp;└ `call_state` | enum |  | one of `IDLE`, `RINGING`, `OFFHOOK`. default `&quot;IDLE&quot;` |
| &nbsp;&nbsp;└ `audio_mode` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `subscription_changed_hours` | number or null |  |  |
| &nbsp;&nbsp;└ `accessibility_services` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `screen_capture` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `screen_recording` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `obscured_touch` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `caller_in_contacts` | boolean or null |  |  |
| `integrity_token` | string or null |  |  |
| `behaviour` | Behaviour |  | default: every field at its own default |
| &nbsp;&nbsp;└ `features` | array of number |  | default: every field at its own default. maxItems `64` |
| `simulated` | array of string |  | default: every field at its own default. maxItems `32` |

```json
{
  "session_id": "...",
  "device": {
    "model": "...",
    "os": "...",
    "rooted": true,
    "sim_serial_hash": "...",
    "sim_changed_at": "...",
    "first_seen_at": "..."
  },
  "signals": {
    "call_state": "IDLE|RINGING|OFFHOOK",
    "audio_mode": "...",
    "subscription_changed_hours": 0.0,
    "accessibility_services": [string],
    "screen_capture": true,
    "screen_recording": true,
    "obscured_touch": true,
    "caller_in_contacts": true
  },
  "integrity_token": "...",
  "behaviour": {
    "features": [number]
  },
  "simulated": [string]
}
```

### Response 200

| SignalsResponse | Type | Required | Notes |
|---|---|---|---|
| `stored` | boolean | yes |  |

```json
{
  "stored": true
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-risk-score"></a>

## POST `/v1/risk/score`

Journey: Send money. After the signals. The decision for this transfer.

- Caller: `lib/features/send_money/logic/risk_flow.dart`
- Timeout: 2 s
- On failure: Unavailable. The money does not move.

The request may carry `app_safety`, the data points of the phone's last App Safety
Check. The server takes the stronger of its stored verdict, the demo flag and this block. A CAUTION adds the
weighted reason `APP_SAFETY_CAUTION` with decision allow. The app sends the block only with
`RISK_MW_APP_SAFETY_IN_SCORE=true`.

### Request body

| ScoreRequest | Type | Required | Notes |
|---|---|---|---|
| `user_id` | string | yes |  |
| `session_id` | string | yes |  |
| `txn` | Txn | yes |  |
| &nbsp;&nbsp;└ `type` | enum | yes | one of `pin_reset`, `new_payee`, `send_money` |
| &nbsp;&nbsp;└ `amount_bdt` | number |  | default `0.0`. minimum `0.0` |
| &nbsp;&nbsp;└ `to_account` | string or null |  |  |
| &nbsp;&nbsp;└ `is_new_payee` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `txn_id` | string or null |  |  |
| `demo_flags` | DemoFlags |  | default: every field at its own default |
| &nbsp;&nbsp;└ `sim_swap` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `call_active` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `screen_share` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `caller_in_contacts` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `app_safety_verdict` | enum |  | one of `SAFE`, `CAUTION`, `BLOCK`. default `&quot;SAFE&quot;` |
| &nbsp;&nbsp;└ `inbound_mule_score` | number |  | default `0.0`. minimum `0.0`. maximum `1.0` |
| &nbsp;&nbsp;└ `scam_score` | number |  | default `0.0`. minimum `0.0`. maximum `1.0` |
| `app_safety` | AppSafetyContext or null |  |  |
| &nbsp;&nbsp;└ `verdict` | enum | yes | one of `SAFE`, `CAUTION`, `BLOCK` |
| &nbsp;&nbsp;└ `risk_score` | number |  | default `0.0`. minimum `0.0`. maximum `1.0` |
| &nbsp;&nbsp;└ `findings` | array of AppSafetyFinding |  | default: every field at its own default |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `package` | string | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `signal` | string | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `severity` | enum | yes | one of `low`, `medium`, `high`, `critical` |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `scope` | enum |  | one of `app`, `device`. default `&quot;app&quot;` |
| &nbsp;&nbsp;└ `apps_to_uninstall` | array of string |  | default: every field at its own default |
| &nbsp;&nbsp;└ `recommended_action` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `resolution` | string |  | default `&quot;NONE&quot;` |
| &nbsp;&nbsp;└ `attestation` | string |  | default `&quot;none&quot;` |
| &nbsp;&nbsp;└ `simulated_verdict` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `model_version` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `check_id` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `checked_at` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `valid_until` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `source` | enum |  | one of `check`, `latest`. default `&quot;check&quot;` |

```json
{
  "user_id": "...",
  "session_id": "...",
  "txn": {
    "type": "pin_reset|new_payee|send_money",
    "amount_bdt": 0.0,
    "to_account": "...",
    "is_new_payee": true,
    "txn_id": "..."
  },
  "demo_flags": {
    "sim_swap": true,
    "call_active": true,
    "screen_share": true,
    "caller_in_contacts": true,
    "app_safety_verdict": "SAFE|CAUTION|BLOCK",
    "inbound_mule_score": 0.0,
    "scam_score": 0.0
  },
  "app_safety": {
    "verdict": "SAFE|CAUTION|BLOCK",
    "risk_score": 0.0,
    "findings": [{
      "package": "...",
      "signal": "...",
      "severity": "low|medium|high|critical",
      "scope": "app|device"
    }],
    "apps_to_uninstall": [string],
    "recommended_action": "...",
    "resolution": "...",
    "attestation": "...",
    "simulated_verdict": true,
    "model_version": "...",
    "check_id": "...",
    "checked_at": "...",
    "valid_until": "...",
    "source": "check|latest"
  }
}
```

### Response 200

| ScoreResponse | Type | Required | Notes |
|---|---|---|---|
| `decision` | enum | yes | one of `allow`, `step_up`, `delay`, `hold`, `block` |
| `risk_score` | number | yes | minimum `0.0`. maximum `1.0` |
| `band` | enum | yes | one of `low`, `medium`, `high`, `critical` |
| `reasons` | array of Reason | yes |  |
| &nbsp;&nbsp;└ `code` | string | yes |  |
| &nbsp;&nbsp;└ `weight` | number | yes | minimum `0.0`. maximum `1.0` |
| &nbsp;&nbsp;└ `text_bn` | string | yes |  |
| &nbsp;&nbsp;└ `text_en` | string | yes |  |
| `actions` | array of Action | yes |  |
| &nbsp;&nbsp;└ `type` | string | yes |  |
| &nbsp;&nbsp;└ `params` | object |  | default: every field at its own default |
| `model_version` | string | yes |  |
| `warning` | HoldWarning or null |  |  |
| &nbsp;&nbsp;└ `status` | enum | yes | one of `fresh`, `stale`, `call_start`, `none` |
| &nbsp;&nbsp;└ `warning` | ApaWarning or null |  |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `warning_id` | string | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `session_id` | string | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `ledger_hash` | string | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `stage` | enum | yes | one of `C0`, `C1`, `C2` |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `lines` | array of ApaLine | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `role` | enum | yes | one of `A`, `T`, `R`, `X` |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `text_bn` | string | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `text_en` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `token` | string or null |  |  |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `expires_at` | string or null |  |  |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `clip_id` | string or null |  |  |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `speak_on_device` | boolean |  | default `false` |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `created_at` | number | yes |  |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `gen_ms` | number |  | default `0.0` |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `render_ms` | object |  | default: every field at its own default |
| &nbsp;&nbsp;└ `earcon` | boolean |  | default `true` |
| &nbsp;&nbsp;└ `vibrate` | boolean |  | default `true` |
| &nbsp;&nbsp;└ `speak_on_device` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `stream_rest` | boolean |  | default `false` |
| `identity_source` | enum or null |  | one of `verified`, `demo` |
| `signal_sources` | SignalSources or null |  |  |
| &nbsp;&nbsp;└ `call_active` | enum |  | one of `device`, `demo`, `none`. default `&quot;none&quot;` |
| &nbsp;&nbsp;└ `sim_swap` | enum |  | one of `device`, `demo`, `none`. default `&quot;none&quot;` |
| &nbsp;&nbsp;└ `screen_share` | enum |  | one of `device`, `demo`, `none`. default `&quot;none&quot;` |
| &nbsp;&nbsp;└ `caller_in_contacts` | enum |  | one of `device`, `demo`, `none`. default `&quot;none&quot;` |
| `payee_score_before` | number or null |  |  |
| `payee_score_with_this_transfer` | number or null |  |  |
| `payee_moved_feature` | string or null |  |  |
| `payee_score_as_of` | string or null |  |  |

```json
{
  "decision": "allow|step_up|delay|hold|block",
  "risk_score": 0.0,
  "band": "low|medium|high|critical",
  "reasons": [{
    "code": "...",
    "weight": 0.0,
    "text_bn": "...",
    "text_en": "..."
  }],
  "actions": [{
    "type": "...",
    "params": ...
  }],
  "model_version": "...",
  "warning": {
    "status": "fresh|stale|call_start|none",
    "warning": {
      "warning_id": "...",
      "session_id": "...",
      "ledger_hash": "...",
      "stage": "C0|C1|C2",
      "lines": [{
        "role": "A|T|R|X",
        "text_bn": "...",
        "text_en": "...",
        "token": "...",
        "expires_at": "...",
        "clip_id": "...",
        "speak_on_device": true
      }],
      "created_at": 0.0,
      "gen_ms": 0.0,
      "render_ms": ...
    },
    "earcon": true,
    "vibrate": true,
    "speak_on_device": true,
    "stream_rest": true
  },
  "identity_source": "verified|demo",
  "signal_sources": {
    "call_active": "device|demo|none",
    "sim_swap": "device|demo|none",
    "screen_share": "device|demo|none",
    "caller_in_contacts": "device|demo|none"
  },
  "payee_score_before": 0.0,
  "payee_score_with_this_transfer": 0.0,
  "payee_moved_feature": "...",
  "payee_score_as_of": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-intervene"></a>

## POST `/v1/intervene`

Journey: Hold. Only when the decision is hold or delay, after the overlay has opened.

- Caller: `lib/features/send_money/logic/risk_flow.dart`
- Timeout: 4 s
- On failure: The predicted clip and the score reasons stand. Cooldown 300 s.

### Request body

| InterveneRequest | Type | Required | Notes |
|---|---|---|---|
| `user_id` | string | yes |  |
| `trigger` | string | yes |  |
| `txn` | Txn | yes |  |
| &nbsp;&nbsp;└ `type` | enum | yes | one of `pin_reset`, `new_payee`, `send_money` |
| &nbsp;&nbsp;└ `amount_bdt` | number |  | default `0.0`. minimum `0.0` |
| &nbsp;&nbsp;└ `to_account` | string or null |  |  |
| &nbsp;&nbsp;└ `is_new_payee` | boolean |  | default `false` |
| &nbsp;&nbsp;└ `txn_id` | string or null |  |  |
| `transcript_snippet` | string or null |  |  |
| `session_id` | string or null |  |  |
| `intervention_id` | string or null |  |  |

```json
{
  "user_id": "...",
  "trigger": "...",
  "txn": {
    "type": "pin_reset|new_payee|send_money",
    "amount_bdt": 0.0,
    "to_account": "...",
    "is_new_payee": true,
    "txn_id": "..."
  },
  "transcript_snippet": "...",
  "session_id": "...",
  "intervention_id": "..."
}
```

### Response 200

| InterveneResponse | Type | Required | Notes |
|---|---|---|---|
| `intervene` | boolean | yes |  |
| `script_bn` | string | yes |  |
| `script_en` | string | yes |  |
| `audio_asset_id` | string or null |  |  |
| `ui` | enum | yes | one of `banner`, `fullscreen`, `call_apa` |
| `actions` | array of Action | yes |  |
| &nbsp;&nbsp;└ `type` | string | yes |  |
| &nbsp;&nbsp;└ `params` | object |  | default: every field at its own default |
| `cooldown_s` | integer | yes | minimum `0.0` |
| `explanation_bn` | string or null |  |  |
| `explanation_en` | string or null |  |  |
| `lines` | array of ApaLine |  | default: every field at its own default |
| &nbsp;&nbsp;└ `role` | enum | yes | one of `A`, `T`, `R`, `X` |
| &nbsp;&nbsp;└ `text_bn` | string | yes |  |
| &nbsp;&nbsp;└ `text_en` | string |  | default `&quot;&quot;` |
| &nbsp;&nbsp;└ `token` | string or null |  |  |
| &nbsp;&nbsp;└ `expires_at` | string or null |  |  |
| &nbsp;&nbsp;└ `clip_id` | string or null |  |  |
| &nbsp;&nbsp;└ `speak_on_device` | boolean |  | default `false` |
| `earcon` | boolean |  | default `true` |
| `vibrate` | boolean |  | default `true` |
| `speak_on_device` | boolean |  | default `false` |
| `warning_id` | string or null |  |  |
| `ledger_hash` | string or null |  |  |
| `intervention_id` | string or null |  |  |
| `identity_source` | enum or null |  | one of `verified`, `demo` |
| `audio_token` | string or null |  |  |
| `audio_expires_at` | string or null |  |  |

```json
{
  "intervene": true,
  "script_bn": "...",
  "script_en": "...",
  "audio_asset_id": "...",
  "ui": "banner|fullscreen|call_apa",
  "actions": [{
    "type": "...",
    "params": ...
  }],
  "cooldown_s": 0,
  "explanation_bn": "...",
  "explanation_en": "...",
  "lines": [{
    "role": "A|T|R|X",
    "text_bn": "...",
    "text_en": "...",
    "token": "...",
    "expires_at": "...",
    "clip_id": "...",
    "speak_on_device": true
  }],
  "earcon": true,
  "vibrate": true,
  "speak_on_device": true,
  "warning_id": "...",
  "ledger_hash": "...",
  "intervention_id": "...",
  "identity_source": "verified|demo",
  "audio_token": "...",
  "audio_expires_at": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-actions-trusted-contact"></a>

## POST `/v1/actions/trusted-contact`

Journey: Hold. The user asks a trusted person from the overlay.

- Caller: `lib/features/approve/logic/trusted_contact_flow.dart`
- Timeout: default
- On failure: The overlay shows the failure line.

### Request body

| TrustedContactRequest | Type | Required | Notes |
|---|---|---|---|
| `intervention_id` | string | yes |  |
| `contact_uid` | string or null |  |  |

```json
{
  "intervention_id": "...",
  "contact_uid": "..."
}
```

### Response 200

| TrustedContactResponse | Type | Required | Notes |
|---|---|---|---|
| `request_id` | string | yes |  |
| `expires_at` | string | yes |  |

```json
{
  "request_id": "...",
  "expires_at": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-actions-trusted-contact-request-id-approve"></a>

## POST `/v1/actions/trusted-contact/{request_id}/approve`

Journey: Hold. The trusted contact taps approve. X-Demo-User is the contact's uid for this call.

- Caller: `lib/features/approve/logic/trusted_contact_flow.dart`
- Timeout: default
- On failure: 404 for an unknown request id.

| Path parameter | Type | Required |
|---|---|---|
| `request_id` | string | yes |

### Request body

No body.

### Response 200

| TrustedContactDecision | Type | Required | Notes |
|---|---|---|---|
| `request_id` | string | yes |  |
| `status` | enum | yes | one of `approved`, `declined`, `expired`, `pending` |
| `decided_by` | string or null |  |  |
| `contact_verified` | boolean or null |  |  |

```json
{
  "request_id": "...",
  "status": "approved|declined|expired|pending",
  "decided_by": "...",
  "contact_verified": true
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-actions-trusted-contact-request-id-decline"></a>

## POST `/v1/actions/trusted-contact/{request_id}/decline`

Journey: Hold. The trusted contact taps decline.

- Caller: `lib/features/approve/logic/trusted_contact_flow.dart`
- Timeout: default
- On failure: 404 for an unknown request id.

| Path parameter | Type | Required |
|---|---|---|
| `request_id` | string | yes |

### Request body

No body.

### Response 200

| TrustedContactDecision | Type | Required | Notes |
|---|---|---|---|
| `request_id` | string | yes |  |
| `status` | enum | yes | one of `approved`, `declined`, `expired`, `pending` |
| `decided_by` | string or null |  |  |
| `contact_verified` | boolean or null |  |  |

```json
{
  "request_id": "...",
  "status": "approved|declined|expired|pending",
  "decided_by": "...",
  "contact_verified": true
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-get-v1-apa-clips-clip-id"></a>

## GET `/v1/apa/clips/{clip_id}`

Journey: Hold. A served line names a clip and the app's own Gemini delivery did not play.

- Caller: `lib/features/intervention/logic/apa_voice.dart`
- Timeout: 4 s receive
- On failure: 404 for an unknown or expired clip. Next source in the voice chain.

| Path parameter | Type | Required |
|---|---|---|
| `clip_id` | string | yes |

### Request body

No body.

### Response 200

audio/ogg (Opus) or audio/wav bytes

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-apa-why-audio"></a>

## POST `/v1/apa/why-audio`

Journey: Hold. A served line has no clip. One signed line as WAV.

- Caller: `lib/features/intervention/logic/apa_voice.dart`
- Timeout: 10 s receive
- On failure: 204: the server has no live audio. 429: rate limited, Retry-After honoured.

### Request body

| ApaWhyAudioRequest | Type | Required | Notes |
|---|---|---|---|
| `user_id` | string | yes |  |
| `text_bn` | string | yes | Exactly the served line. |
| `token` | string or null |  | The line&#x27;s token from /v1/intervene. |

```json
{
  "user_id": "...",
  "text_bn": "...",
  "token": "..."
}
```

### Response 200

audio/wav bytes, 24 kHz mono 16-bit, buffered whole

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-scam-turn"></a>

## POST `/v1/scam/turn`

Journey: Assistant. The user pastes a caller's words into the FinNest Assistant.

- Caller: `lib/features/apa/logic/apa_controller.dart`
- Timeout: 6 s
- On failure: Chat shows "check failed". No score change.

### Request body

| ScamTurnRequest | Type | Required | Notes |
|---|---|---|---|
| `session_id` | string | yes |  |
| `turns` | array of Turn | yes | minItems `1` |
| &nbsp;&nbsp;└ `speaker` | enum | yes | one of `caller`, `user` |
| &nbsp;&nbsp;└ `text` | string | yes |  |
| &nbsp;&nbsp;└ `ts` | number | yes |  |
| `pending_action` | string or null |  |  |
| `amount_bdt` | number or null |  |  |
| `caller_number` | string or null |  |  |

```json
{
  "session_id": "...",
  "turns": [{
    "speaker": "caller|user",
    "text": "...",
    "ts": 0.0
  }],
  "pending_action": "...",
  "amount_bdt": 0.0,
  "caller_number": "..."
}
```

### Response 200

| ScamTurnResponse | Type | Required | Notes |
|---|---|---|---|
| `scam_type` | string | yes |  |
| `urgency` | enum | yes | one of `none`, `low`, `medium`, `high` |
| `requested_secret` | enum | yes | one of `none`, `otp`, `pin`, `password`, `other` |
| `confidence` | number | yes | minimum `0.0`. maximum `1.0` |
| `evidence_quote` | string | yes |  |
| `recommended_action` | string | yes |  |
| `rolling_score` | number | yes | minimum `0.0`. maximum `1.0` |
| `model_version` | string |  | default `&quot;&quot;` |
| `fallback_reason` | string or null |  |  |
| `verdict` | enum or null |  | one of `SAFE`, `UNCERTAIN`, `SCAM` |
| `tactics` | array of string |  | default: every field at its own default |
| `claimed_identity` | string or null |  |  |
| `ask` | string or null |  |  |
| `rule_hits` | array of string |  | default: every field at its own default |
| `matched_card` | string or null |  |  |
| `cards_version` | string or null |  |  |
| `ledger_hash` | string or null |  |  |
| `band` | enum or null |  | one of `possible`, `likely`, `almost_certain` |

```json
{
  "scam_type": "...",
  "urgency": "none|low|medium|high",
  "requested_secret": "none|otp|pin|password|other",
  "confidence": 0.0,
  "evidence_quote": "...",
  "recommended_action": "...",
  "rolling_score": 0.0,
  "model_version": "...",
  "fallback_reason": "...",
  "verdict": "SAFE|UNCERTAIN|SCAM",
  "tactics": [string],
  "claimed_identity": "...",
  "ask": "...",
  "rule_hits": [string],
  "matched_card": "...",
  "cards_version": "...",
  "ledger_hash": "...",
  "band": "possible|likely|almost_certain"
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-apa-turn"></a>

## POST `/v1/apa/turn`

Journey: Assistant. Chat text, after Gemini and the offline guide.

- Caller: `lib/features/apa/logic/apa_text_service.dart`
- Timeout: 8 s
- On failure: Chat shows the offline answer.

### Request body

| ApaTurnRequest | Type | Required | Notes |
|---|---|---|---|
| `user_id` | string | yes |  |
| `text_bn` | string | yes |  |
| `context` | ApaContext |  | default: every field at its own default |
| &nbsp;&nbsp;└ `last_risk` | number or null |  |  |
| &nbsp;&nbsp;└ `screen` | string or null |  |  |

```json
{
  "user_id": "...",
  "text_bn": "...",
  "context": {
    "last_risk": 0.0,
    "screen": "..."
  }
}
```

### Response 200

| ApaTurnResponse | Type | Required | Notes |
|---|---|---|---|
| `reply_bn` | string | yes |  |
| `reply_en` | string | yes |  |
| `tool_calls` | array of string | yes |  |

```json
{
  "reply_bn": "...",
  "reply_en": "...",
  "tool_calls": [string]
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-post-v1-investigate"></a>

## POST `/v1/investigate`

Journey: Fraud desk. Fraud desk, demo-panel builds, with the staff X-Demo-User.

- Caller: `lib/features/fraud_desk/logic/fraud_desk_providers.dart`
- Timeout: 10 s
- On failure: 502 investigator unavailable, 429 rate limited.

### Request body

| InvestigateRequest | Type | Required | Notes |
|---|---|---|---|
| `acct_id` | string | yes |  |

```json
{
  "acct_id": "..."
}
```

### Response 200

| InvestigateResponse | Type | Required | Notes |
|---|---|---|---|
| `case_id` | string | yes |  |
| `stream_url` | string | yes |  |

```json
{
  "case_id": "...",
  "stream_url": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.

<a id="api-get-v1-investigations-case-id"></a>

## GET `/v1/investigations/{case_id}`

Journey: Fraud desk. Polling the Case Zero report, partial while queued or running.

- Caller: `lib/features/fraud_desk/ui/case_screen.dart`
- Timeout: 10 s
- On failure: 404 not found, 502, 429.

| Path parameter | Type | Required |
|---|---|---|
| `case_id` | string | yes |

### Request body

No body.

### Response 200

| CaseReport | Type | Required | Notes |
|---|---|---|---|
| `case_id` | string | yes |  |
| `acct_id` | string | yes |  |
| `status` | enum | yes | one of `queued`, `running`, `done`, `degraded`, `failed` |
| `summary_en` | string | yes |  |
| `summary_bn` | string | yes |  |
| `evidence` | array of Evidence | yes |  |
| &nbsp;&nbsp;└ `row_id` | string | yes |  |
| &nbsp;&nbsp;└ `claim` | string | yes |  |
| `ring` | array of string | yes |  |
| `confidence` | number | yes | minimum `0.0`. maximum `1.0` |
| `recommended_action` | string | yes |  |
| `model_version` | string | yes |  |
| `redacted` | boolean |  | default `false` |
| `validation_errors` | array of string |  | default: every field at its own default |
| `limitations` | string |  | default `&quot;&quot;` |

```json
{
  "case_id": "...",
  "acct_id": "...",
  "status": "queued|running|done|degraded|failed",
  "summary_en": "...",
  "summary_bn": "...",
  "evidence": [{
    "row_id": "...",
    "claim": "..."
  }],
  "ring": [string],
  "confidence": 0.0,
  "recommended_action": "...",
  "model_version": "...",
  "redacted": true,
  "validation_errors": [string],
  "limitations": "..."
}
```

Errors: `422` validation (HTTPValidationError), `401` without identity when auth is on.
