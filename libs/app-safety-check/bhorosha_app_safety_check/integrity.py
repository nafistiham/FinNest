"""Play Integrity and the attestation that makes the check robust to a modified client.

Threat model: "mod APK" builds are common in Bangladesh. A patched FinNest client could post a
clean, fabricated bundle (empty app list, Play installers, no accessibility) and collect a SAFE. The server therefore
treats client-collected evidence as *claims* until a Play Integrity token says three things at once:

1. the request came from the genuine, Play-signed FinNest build (`appIntegrity.appRecognitionVerdict == PLAY_RECOGNIZED`,
   package name and signing certificate as registered),
2. on a device that passes Google's integrity checks (`deviceIntegrity.deviceRecognitionVerdict` contains
   MEETS_DEVICE_INTEGRITY or MEETS_STRONG_INTEGRITY; BASIC only, VIRTUAL or nothing is a rooted / custom-ROM / emulator phone),
3. and that the token was minted *for this exact bundle*: `requestDetails.requestHash` must equal the SHA-256 of the
   canonical bundle (`bundle_hash`). A token minted for one app list cannot vouch for another, and a replayed token
   cannot vouch for new evidence.

The prototype is not on Play, so a real token cannot carry these verdicts yet; the demo path signs the same shape with an
HMAC under a shared secret (minted server-side by `/v1/appsafety/demo-token` so the app never holds the secret), expires
in ten minutes, and is accepted only in demo mode. `AttestationLevel` is what the rules act on (see rules.attestation_hits).
Sources: https://developer.android.com/google/play/integrity/verdicts and .../standard, accessed 2026-10-16.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import time
from dataclasses import replace
from typing import Any, Literal

from bhorosha_app_safety_check import schema as s
from bhorosha_app_safety_check.schema import AppRow, DeviceRow, IntegrityVerdict

log = logging.getLogger(__name__)
DEMO_PREFIX = "demo"
DEMO_TOKEN_TTL_S = 600  # a demo token is minted for one check; a stolen one cannot raise verdicts forever
NONE = IntegrityVerdict(source="none")

AttestationLevel = Literal["none", "failed", "tampered", "mismatch", "unbound", "virtual", "basic", "device", "strong"]
APP_RECOGNITION_VALUES = ("PLAY_RECOGNIZED", "UNRECOGNIZED_VERSION", "UNEVALUATED")
DEVICE_RECOGNITION_VALUES = ("MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY", "MEETS_STRONG_INTEGRITY", "MEETS_VIRTUAL_INTEGRITY")
LICENSING_VALUES = ("LICENSED", "UNLICENSED", "UNEVALUATED")


# --- bundle binding ------------------------------------------------------------


def bundle_hash(apps: tuple[AppRow, ...], device: DeviceRow) -> str:
    """SHA-256 (hex) over the canonical JSON of what the phone reported. The client computes the same bytes and puts the
    digest in the Play Integrity requestHash, which is how a token becomes a signature over the evidence."""
    canonical = {
        "installed_apps": [
            {
                "package": a.package, "label": a.label, "installer": a.installer, "version": a.version,
                "permissions": sorted(a.permissions), "has_accessibility_service": a.has_accessibility_service,
                "accessibility_enabled": a.accessibility_enabled, "target_sdk": a.target_sdk, "first_install": a.first_install,
                "has_notification_listener": a.has_notification_listener, "has_hce_service": a.has_hce_service,
                "is_default_sms_app": a.is_default_sms_app, "launcher_icon_hidden": a.launcher_icon_hidden,
                "installer_declares_install_packages": a.installer_declares_install_packages,
            }
            for a in sorted(apps, key=lambda a: a.package)
        ],
        "device": {
            "overlay_holders": sorted(device.overlay_holders), "device_admins": sorted(device.device_admins), "dev_options": device.dev_options,
            "adb": device.adb, "rooted": device.rooted, "play_protect": device.play_protect, "sdk_int": device.sdk_int,
            "default_sms_package": device.default_sms_package, "nfc_default_payment_package": device.nfc_default_payment_package,
        },
    }
    return hashlib.sha256(json.dumps(canonical, separators=(",", ":"), sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def attestation_level(verdict: IntegrityVerdict, expected_bundle_hash: str, *, expected_package: str, expected_cert_digests: tuple[str, ...] = ()) -> AttestationLevel:
    """Reduce a verdict to the one word the rules act on."""
    if verdict.source == "none":
        return "none"
    if verdict.source == "failed":
        return "failed"
    if verdict.app_recognition == "UNRECOGNIZED_VERSION":
        return "tampered"
    if verdict.package_name and verdict.package_name != expected_package:
        return "tampered"
    # When the signing certificate is configured, a token that carries no digest at all is as bad as a wrong one (an
    # absent list must not skip the check).
    if expected_cert_digests and not set(verdict.certificate_digests) & set(expected_cert_digests):
        return "tampered"
    if verdict.request_hash is None:
        return "unbound"
    if not isinstance(verdict.request_hash, str) or not hmac.compare_digest(verdict.request_hash, expected_bundle_hash):
        return "mismatch"
    recognised = set(verdict.device_recognition)
    if "MEETS_STRONG_INTEGRITY" in recognised:
        return "strong"
    if "MEETS_DEVICE_INTEGRITY" in recognised:
        return "device"
    if "MEETS_BASIC_INTEGRITY" in recognised:
        return "basic"
    if "MEETS_VIRTUAL_INTEGRITY" in recognised:
        return "virtual"
    # Bound and recognised app, but Google would not vouch for the device at all (unevaluated or empty).
    return "basic" if verdict.app_recognition == "PLAY_RECOGNIZED" else "unbound"


# --- token helpers --------------------------------------------------------------


def _b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64d(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _signature(secret: str, payload: str) -> str:
    return _b64e(hmac.new(secret.encode("utf-8"), payload.encode("ascii"), hashlib.sha256).digest())


def sign_demo_verdict(
    secret: str,
    apps_detected: list[str],
    play_protect_verdict: str = "NO_ISSUES",
    request_hash: str | None = None,
    ttl_s: int = DEMO_TOKEN_TTL_S,
    now: float | None = None,
    *,
    app_recognition: str = "PLAY_RECOGNIZED",
    device_recognition: list[str] | None = None,
    package_name: str = "com.bhorosha.app",
    licensing: str = "LICENSED",
    certificate_digests: list[str] | None = None,
) -> str:
    """Produce a demo token. `/v1/appsafety/demo-token` mints these for the app's demo panel; the eval calls it directly.

    Defaults describe a genuine build on a healthy phone; the demo panel's "modded app" switch sets
    app_recognition="UNRECOGNIZED_VERSION", its "rooted phone" switch passes device_recognition=[].
    """
    unknown = [v for v in apps_detected if v not in s.APPS_DETECTED_VALUES]
    if unknown or play_protect_verdict not in s.PLAY_PROTECT_VERDICT_VALUES:
        raise ValueError(f"unknown Play Integrity values: {unknown or play_protect_verdict}")
    if app_recognition not in APP_RECOGNITION_VALUES or licensing not in LICENSING_VALUES:
        raise ValueError(f"unknown Play Integrity values: {app_recognition} {licensing}")
    device = ["MEETS_DEVICE_INTEGRITY"] if device_recognition is None else list(device_recognition)
    if any(v not in DEVICE_RECOGNITION_VALUES for v in device):
        raise ValueError(f"unknown deviceRecognitionVerdict: {device}")
    body = {
        "appsDetected": list(apps_detected), "playProtectVerdict": play_protect_verdict, "requestHash": request_hash,
        "appRecognitionVerdict": app_recognition, "deviceRecognitionVerdict": device, "packageName": package_name,
        "appLicensingVerdict": licensing, "exp": int((now if now is not None else time.time()) + ttl_s),
        "certificateSha256Digest": list(certificate_digests or []),
    }
    payload = _b64e(json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8"))
    return f"{DEMO_PREFIX}.{payload}.{_signature(secret, payload)}"


def is_demo_token(token: str | None) -> bool:
    return bool(token) and token.startswith(DEMO_PREFIX + ".")


def verify_demo_token(token: str, secret: str, now: float | None = None) -> IntegrityVerdict | None:
    """The verdict inside a demo token, or None when the signature, shape or expiry is wrong (logged, never raised)."""
    try:
        _, payload, signature = token.split(".", 2)
        if not hmac.compare_digest(signature, _signature(secret, payload)):
            log.warning("demo integrity token rejected: bad signature")
            return None
        body = json.loads(_b64d(payload))
        if int(body.get("exp", 0)) < (now if now is not None else time.time()):
            log.warning("demo integrity token rejected: expired")
            return None
        return from_decoded_payload(
            {
                "requestDetails": {"requestHash": body.get("requestHash")},
                "appIntegrity": {"appRecognitionVerdict": body.get("appRecognitionVerdict", "PLAY_RECOGNIZED"), "packageName": body.get("packageName"), "certificateSha256Digest": body.get("certificateSha256Digest") or []},
                "deviceIntegrity": {"deviceRecognitionVerdict": body.get("deviceRecognitionVerdict", ["MEETS_DEVICE_INTEGRITY"])},
                "accountDetails": {"appLicensingVerdict": body.get("appLicensingVerdict", "LICENSED")},
                "environmentDetails": {"appAccessRiskVerdict": {"appsDetected": body.get("appsDetected", [])}, "playProtectVerdict": body.get("playProtectVerdict", "UNEVALUATED")},
            },
            source="demo",
        )
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        log.warning("demo integrity token rejected: %s", exc.__class__.__name__)
        return None


def from_environment_details(details: dict[str, Any], source: str, request_hash: str | None = None) -> IntegrityVerdict:
    """Map the `environmentDetails` object of a decoded token payload onto our verdict row (other fields default)."""
    detected = tuple(str(v) for v in (details.get("appAccessRiskVerdict") or {}).get("appsDetected", []) if str(v) in s.APPS_DETECTED_VALUES)
    protect = str(details.get("playProtectVerdict") or "UNEVALUATED")
    if protect not in s.PLAY_PROTECT_VERDICT_VALUES:
        protect = "UNEVALUATED"
    return IntegrityVerdict(source=source, apps_detected=detected, play_protect_verdict=protect, request_hash=request_hash)  # type: ignore[arg-type]


def from_decoded_payload(payload: dict[str, Any], source: str = "google") -> IntegrityVerdict:
    """`tokenPayloadExternal` from playintegrity.googleapis.com decodeIntegrityToken -> verdict (all sections)."""
    request = payload.get("requestDetails") or {}
    app = payload.get("appIntegrity") or {}
    device = payload.get("deviceIntegrity") or {}
    account = payload.get("accountDetails") or {}
    # Typed on the way in: a non-string requestHash (an int in a forged payload) used to reach hmac.compare_digest and
    # raise TypeError out of the route. Anything present becomes a string, which then simply fails to match.
    raw_hash = request.get("requestHash")
    base = from_environment_details(payload.get("environmentDetails") or {}, source=source, request_hash=None if raw_hash in (None, "") else str(raw_hash))
    app_recognition = str(app.get("appRecognitionVerdict") or "UNEVALUATED")
    licensing = str(account.get("appLicensingVerdict") or "UNEVALUATED")
    return replace(
        base,
        app_recognition=app_recognition if app_recognition in APP_RECOGNITION_VALUES else "UNEVALUATED",
        package_name=str(app["packageName"]) if app.get("packageName") else None,
        certificate_digests=tuple(str(d) for d in app.get("certificateSha256Digest", []) or []),
        device_recognition=tuple(str(v) for v in device.get("deviceRecognitionVerdict", []) or [] if str(v) in DEVICE_RECOGNITION_VALUES),
        licensing=licensing if licensing in LICENSING_VALUES else "UNEVALUATED",
        timestamp_ms=int(request["timestampMillis"]) if str(request.get("timestampMillis", "")).isdigit() else None,
    )


def decode_google_token(token: str, package_name: str, *, timeout_s: float = 3.0) -> IntegrityVerdict | None:
    """Decode a real standard token via Google. Needs Application Default Credentials with the playintegrity scope and the
    app published on Play; any failure returns None and is logged."""
    try:
        import google.auth
        import google.auth.transport.requests
        import requests

        credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/playintegrity"])
        credentials.refresh(google.auth.transport.requests.Request())
        url = f"https://playintegrity.googleapis.com/v1/{package_name}:decodeIntegrityToken"
        resp = requests.post(url, json={"integrity_token": token}, headers={"Authorization": f"Bearer {credentials.token}"}, timeout=timeout_s)
        resp.raise_for_status()
        return from_decoded_payload(resp.json().get("tokenPayloadExternal") or {})
    except Exception as exc:  # noqa: BLE001 - an integrity outage degrades to "unevaluated", never a 500
        log.warning("play integrity decode failed: %s", exc.__class__.__name__)
        return None


def resolve(token: str | None, *, demo_secret: str, demo_allowed: bool, package_name: str, google_enabled: bool = False) -> IntegrityVerdict:
    """The one entry point: real token when it is one (and the Google path is switched on), demo token when demo mode allows
    it, else none. A token that was offered but could not be verified is `failed`, which the rules treat as suspicious:
    an honest client has no reason to present a bad token."""
    if not token:
        return NONE
    if is_demo_token(token):
        if not demo_allowed:
            log.warning("demo integrity token offered while demo mode is off; ignored")
            return IntegrityVerdict(source="failed")
        return verify_demo_token(token, demo_secret) or IntegrityVerdict(source="failed")
    if not google_enabled:
        log.info("non-demo integrity token ignored: RISK_MW_APPSAFETY_GOOGLE_INTEGRITY_ENABLED is false")
        return NONE
    return decode_google_token(token, package_name) or IntegrityVerdict(source="failed")
