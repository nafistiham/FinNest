"""/v1/appsafety/check with the App Safety engine behind it, and the join into /v1/risk/score.

The package has its own unit tests (libs/app-safety-check/tests). These cover what only the route can prove: the
acceptance scenarios of spec US-1 through the HTTP contract, the demo Play Integrity token, the uid-keyed join into
the risk score, and the FR-4 fallback when Gemini fails.
"""

from __future__ import annotations

import pytest

from app import appsafety_engine
from app.contracts import AppSafetyResponse

PLAY, CHROME = "com.android.vending", "com.android.chrome"


def _app(package, label, installer=PLAY, perms=(), service=False, enabled=False, version="1.0"):
    return {"package": package, "label": label, "installer": installer, "version": version, "permissions": [f"android.permission.{p}" for p in perms], "has_accessibility_service": service, "accessibility_enabled": enabled}


CLEAN = [_app("com.whatsapp", "WhatsApp", PLAY, ("READ_CONTACTS", "CAMERA")), _app("com.google.android.apps.maps", "Maps", PLAY, ("ACCESS_FINE_LOCATION",)), _app("com.android.settings", "Settings", "system")]
TAKANOW = _app("com.demo.takanow", "TakaNow Loan", CHROME, ("READ_CONTACTS", "READ_SMS", "RECEIVE_SMS", "READ_MEDIA_IMAGES", "ACCESS_FINE_LOCATION", "SYSTEM_ALERT_WINDOW", "REQUEST_INSTALL_PACKAGES"), service=True, enabled=True)


@pytest.fixture(autouse=True)
def _isolated_verdicts():
    """The client fixture is session-scoped: a BLOCK remembered for one uid must not leak into later score tests."""
    appsafety_engine.forget_verdicts()
    yield
    appsafety_engine.forget_verdicts()


def _check(client, apps, uid="appsafety-test", **extra):
    resp = client.post("/v1/appsafety/check", json={"installed_apps": apps, **extra}, headers={"X-Demo-User": uid})
    assert resp.status_code == 200, resp.text
    return AppSafetyResponse(**resp.json())


def test_us1_s1_sideloaded_accessibility_app_is_named_in_bangla(client):
    out = _check(client, CLEAN + [TAKANOW])
    assert out.verdict in ("CAUTION", "BLOCK")
    assert "SIDELOADED_ACCESSIBILITY" in {f.signal for f in out.findings}
    assert "TakaNow Loan" in out.user_message_bn and "আনইনস্টল" in out.user_message_bn
    assert out.apps_to_uninstall == ("com.demo.takanow",)
    assert out.model_version.startswith("appsafety") and out.simulated_verdict is True


def test_us1_s2_clean_play_device_is_safe_under_20(client):
    out = _check(client, CLEAN)
    assert out.verdict == "SAFE" and out.risk_score < 0.20 and out.apps_to_uninstall == () and out.recommended_action == "PROCEED"
    # demo mode: no token means "unattested", recorded as a soft low signal, never a CAUTION
    assert {f.signal for f in out.findings} <= {"UNATTESTED_CLIENT"} and out.attestation == "none" and out.resolution == "NONE"
    assert out.check_id.startswith("appsafety-test_") and out.valid_until


def _demo_token(client, apps, uid, **overrides):
    body = {"installed_apps": apps, **overrides}
    resp = client.post("/v1/appsafety/demo-token", json=body, headers={"X-Demo-User": uid})
    assert resp.status_code == 200, resp.text
    return resp.json()["integrity_token"]


def test_bound_demo_token_attests_the_bundle(client):
    token = _demo_token(client, CLEAN, "rina-bound")
    out = _check(client, CLEAN, uid="rina-bound", integrity_token=token)
    assert out.verdict == "SAFE" and out.attestation == "device" and out.findings == () and out.simulated_verdict is True


def test_modded_client_is_blocked_even_with_a_clean_bundle(client, score_body):
    token = _demo_token(client, CLEAN, "rina-modded", app_recognition="UNRECOGNIZED_VERSION")
    out = _check(client, CLEAN, uid="rina-modded", integrity_token=token)
    assert out.verdict == "BLOCK" and out.attestation == "tampered" and out.recommended_action == "BLOCK_AND_CALL_BANK" and out.resolution == "REINSTALL_FROM_PLAY"
    assert out.findings[0].signal == "CLIENT_TAMPERED" and out.findings[0].scope == "device" and out.findings[0].title_bn
    assert "প্লে স্টোর" in out.user_message_bn
    held = client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": "rina-modded"}).json()
    assert held["decision"] == "block"


def test_token_minted_for_another_bundle_is_a_mismatch(client):
    token = _demo_token(client, CLEAN, "rina-mismatch")  # minted for the clean list...
    out = _check(client, CLEAN + [TAKANOW], uid="rina-mismatch", integrity_token=token)  # ...sent with a different one
    assert out.verdict == "BLOCK" and out.attestation == "mismatch" and "BUNDLE_MISMATCH" in {f.signal for f in out.findings}
    token = _demo_token(client, CLEAN, "rina-mismatch2")
    out = _check(client, CLEAN, uid="rina-mismatch2", integrity_token=token)  # a clean phone that lies about the token's bundle...
    assert out.attestation == "device"


def test_empty_or_unattested_recheck_cannot_clear_a_block(client, score_body):
    uid = "rina-clear"
    assert _check(client, CLEAN + [TAKANOW], uid=uid).verdict == "BLOCK"
    empty = _check(client, [], uid=uid)  # the collector's timeout fallback, or a modded client
    assert empty.verdict == "BLOCK" and "IMPLAUSIBLE_BUNDLE" in {f.signal for f in empty.findings}
    assert client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": uid}).json()["decision"] == "block"
    bad = _demo_token(client, CLEAN, uid)[:-4] + "zzzz"  # a tampered token
    assert _check(client, CLEAN, uid=uid, integrity_token=bad).verdict == "BLOCK"
    assert client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": uid}).json()["decision"] == "block"
    # an honest re-check with the flagged app gone lifts it: uninstall -> re-check -> SAFE -> pay
    lifted = _check(client, CLEAN, uid=uid, integrity_token=_demo_token(client, CLEAN, uid))
    assert lifted.verdict == "SAFE"
    assert client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": uid}).json()["decision"] == "allow"


def test_recheck_still_listing_the_flagged_app_keeps_the_block(client, score_body):
    uid = "rina-still"
    assert _check(client, CLEAN + [TAKANOW], uid=uid).verdict == "BLOCK"
    out = _check(client, CLEAN + [TAKANOW], uid=uid)
    assert out.verdict == "BLOCK" and out.resolution == "UNINSTALL_AND_RECHECK" and out.uninstall_targets[0].deep_link == "package:com.demo.takanow"


def test_us1_s3_block_holds_the_next_transfer_for_the_same_uid_only(client, score_body):
    uid = "rina-s3"
    assert _check(client, CLEAN + [TAKANOW], uid=uid).verdict == "BLOCK"
    held = client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": uid}).json()
    assert held["decision"] == "block" and "APP_SAFETY_BLOCK" in {r["code"] for r in held["reasons"]}
    assert any(a["type"] == "block_transaction" for a in held["actions"])
    other = client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": "someone-else"}).json()
    assert other["decision"] == "allow"


def test_remembered_verdict_expires(client, score_body, monkeypatch):
    uid = "rina-ttl"
    _check(client, CLEAN + [TAKANOW], uid=uid)
    monkeypatch.setattr(appsafety_engine.time, "monotonic", lambda: 10**9)
    assert client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": uid}).json()["decision"] == "allow"


def test_demo_integrity_token_controlling_blocks_and_a_tampered_one_is_ignored(client):
    from bhorosha_app_safety_check.integrity import sign_demo_verdict

    from app.settings import get_settings

    token = _demo_token(client, CLEAN, "appsafety-test", apps_detected=["KNOWN_INSTALLED", "UNKNOWN_CONTROLLING"], play_protect_verdict="POSSIBLE_RISK")
    out = _check(client, CLEAN, integrity_token=token)
    assert out.verdict == "BLOCK" and out.simulated_verdict is True and out.recommended_action == "BLOCK_AND_CALL_BANK"
    assert {f.signal for f in out.findings} == {"INTEGRITY_CONTROLLING", "INTEGRITY_PLAY_PROTECT"}
    tampered = _check(client, CLEAN, uid="appsafety-test2", integrity_token=token[:-4] + "zzzz")
    assert tampered.verdict == "CAUTION" and tampered.attestation == "failed" and {f.signal for f in tampered.findings} == {"UNATTESTED_CLIENT"}
    assert sign_demo_verdict(appsafety_engine.demo_secret(get_settings()), []).startswith("demo.")


def test_engine_scores_the_phone_in_one_batch(client, monkeypatch):
    """Review of 2026-10-17: the real phone's 80 apps are scored by one predict_many, not 80 predicts."""
    calls = []
    real = appsafety_engine.classifier()
    monkeypatch.setattr(appsafety_engine, "_classify_many", lambda apps: (calls.append(len(apps)), [(p.probability, p.contributions) for p in real.predict_many(apps)])[1])
    monkeypatch.setattr(appsafety_engine._classify, "classify_many", appsafety_engine._classify_many, raising=False)
    out = _check(client, CLEAN + [TAKANOW], uid="batch")
    assert calls == [4] and out.verdict == "BLOCK"


def test_classifier_is_loaded_and_scores_sideloaded_sms_app(client):
    assert appsafety_engine.classifier() is not None
    sms_app = _app("com.x.sms", "Free SMS", CHROME, ("READ_SMS", "RECEIVE_SMS", "SEND_SMS", "READ_PHONE_STATE", "RECEIVE_BOOT_COMPLETED", "SYSTEM_ALERT_WINDOW", "GET_TASKS", "INTERNET"))
    out = _check(client, CLEAN + [sms_app])
    signals = {f.signal for f in out.findings}
    assert out.verdict != "SAFE" and signals & {"CLASSIFIER_HIGH", "LOAN_APP_DATA_HARVEST"}


def test_gemini_failure_degrades_to_caution_with_generic_message(client, monkeypatch):
    from bhorosha_app_safety_check import schema as s

    monkeypatch.setattr(appsafety_engine, "gemini_available", lambda settings: True)

    def boom(system, contents, schema):
        raise RuntimeError("quota exhausted")

    monkeypatch.setattr(appsafety_engine, "_gemini", boom)
    helper = _app("com.x.helper", "Helper", CHROME, ("READ_CONTACTS", "RECEIVE_SMS"))
    out = _check(client, CLEAN + [helper])
    assert out.verdict == "CAUTION" and out.agrees_with_classifier is None and "LOAN_APP_DATA_HARVEST" in {f.signal for f in out.findings}
    backup = _app("com.backup.pro", "Backup Pro", PLAY, ("READ_CONTACTS", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "READ_CALL_LOG"))
    assert _check(client, CLEAN + [backup]).verdict == "SAFE"  # soft hits only: a model outage does not frighten a Play-only phone
    assert _check(client, CLEAN).verdict == "SAFE"  # a clean device never calls the model and never becomes a CAUTION


def test_gemini_verdict_is_fused_through_the_route(client, monkeypatch):
    from bhorosha_app_safety_check.triage import TriageVerdict

    monkeypatch.setattr(appsafety_engine, "gemini_available", lambda settings: True)
    monkeypatch.setattr(appsafety_engine, "_gemini", lambda system, contents, schema: TriageVerdict(
        verdict="SAFE", risk_score=4, recommended_action="PROCEED", user_message_bn="সব ঠিক আছে।", user_message_en="All good.",
        agrees_with_classifier=False, disagreement_reason="Play-installed backup app from a known publisher",
    ))
    monkeypatch.setattr(appsafety_engine, "_classify", lambda perms: (0.9, (("android.permission.READ_CONTACTS", 1.0),)))
    backup = _app("com.backup.pro", "Backup Pro", PLAY, ("READ_CONTACTS", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "READ_CALL_LOG"))
    out = _check(client, CLEAN + [backup])
    assert out.verdict == "SAFE" and out.agrees_with_classifier is False and "publisher" in out.disagreement_reason
    out = _check(client, CLEAN + [TAKANOW])
    assert out.verdict == "BLOCK" and out.agrees_with_classifier is False and "overruled" in out.disagreement_reason


def test_unknown_fields_are_still_rejected(client):
    assert client.post("/v1/appsafety/check", json={"installed_apps": [{**TAKANOW, "surprise": 1}]}).status_code == 422


def test_warm_up_never_raises(monkeypatch):
    monkeypatch.setattr(appsafety_engine, "gemini_available", lambda settings: True)

    def boom(*a, **k):
        raise RuntimeError("cold")

    monkeypatch.setattr(appsafety_engine.genai_client, "call", boom)
    monkeypatch.setattr(appsafety_engine.genai_client, "warm_client", boom)
    appsafety_engine.warm_up()  # start-up never waits for it (review finding: the lifespan used to block up to 25 s)
    appsafety_engine.warm_up(wait=True)  # the background step logs a warning and returns
    assert appsafety_engine.classifier() is not None


def test_the_warm_up_call_names_its_arguments(monkeypatch):
    """Reordered genai_client.call (timeout_s before thinking_level); passed by position, the warm-up sent "minimal"
    as its timeout and 20.0 as its thinking level and quietly failed. Names keep it right in either order."""
    from app.settings import Settings

    seen = {}
    monkeypatch.setattr(appsafety_engine, "gemini_available", lambda settings: True)
    monkeypatch.setattr(appsafety_engine.genai_client, "warm_client", lambda: None)
    monkeypatch.setattr(appsafety_engine.genai_client, "call", lambda *a, **k: seen.update(args=a, kwargs=k))
    monkeypatch.setattr(appsafety_engine, "get_settings", lambda: Settings(appsafety_warm_up_call=True))
    appsafety_engine.warm_up(wait=True)
    assert seen["kwargs"]["thinking_level"] == appsafety_engine.THINKING_LEVEL and seen["kwargs"]["timeout_s"] == 20.0
    assert seen["kwargs"]["max_output_tokens"] == 256


# --- hardening checks, one test each ---------------------------------------------------------


def _fake_gemini(calls, verdict="BLOCK"):
    from bhorosha_app_safety_check.triage import TriageVerdict

    def call(system, contents, schema):
        calls.append(contents)
        return TriageVerdict(verdict=verdict, risk_score=95, recommended_action="DELAY_24H", apps_to_uninstall=["com.demo.takanow"], user_message_bn="TakaNow Loan অ্যাপটি আনইনস্টল করুন।", user_message_en="Uninstall TakaNow Loan.")

    return call


def test_gemini_quota_is_spent_only_when_the_model_is_called(client, monkeypatch):
    """Finding 1: /check sat under GENAI_QUOTA, so clean phones drained the shared bucket; out of quota it answered 429."""
    from app.ratelimit import SlidingWindowLimiter

    calls = []
    monkeypatch.setattr(appsafety_engine, "gemini_available", lambda settings: True)
    monkeypatch.setattr(appsafety_engine, "_gemini", _fake_gemini(calls))
    limiters = {"genai": SlidingWindowLimiter(1, 60), "genai_all": SlidingWindowLimiter(1, 60)}
    monkeypatch.setattr(client.app.state, "limiters", limiters)
    for i in range(3):
        assert _check(client, CLEAN, uid=f"clean-{i}").verdict == "SAFE"
    assert calls == [] and limiters["genai"].tracked_keys() == 0 and limiters["genai_all"].tracked_keys() == 0  # no slot spent
    first = _check(client, CLEAN + [TAKANOW], uid="quota-1")
    assert first.verdict == "BLOCK" and len(calls) == 1 and limiters["genai_all"].tracked_keys() == 1
    second = _check(client, CLEAN + [TAKANOW], uid="quota-2")  # the one slot is gone: rules answer, never 429
    assert second.verdict == "BLOCK" and len(calls) == 1 and second.agrees_with_classifier is None
    assert "TakaNow Loan" in second.user_message_bn and second.uninstall_targets[0].package == "com.demo.takanow"


def test_shrunken_recheck_keeps_the_block(client, score_body):
    """Finding 2: 3 of 20 apps tripped BUNDLE_SHRUNK -> CAUTION, and CAUTION replaced the stored BLOCK in demo mode."""
    uid = "rina-shrunk"
    many = CLEAN + [_app(f"com.vendor{i}.app", f"App {i}", PLAY, ("CAMERA",)) for i in range(17)]
    assert _check(client, many + [TAKANOW], uid=uid).verdict == "BLOCK"
    out = _check(client, CLEAN, uid=uid)  # three apps where there were twenty-one
    assert out.verdict == "BLOCK" and "BUNDLE_SHRUNK" in {f.signal for f in out.findings}
    assert client.post("/v1/risk/score", json=score_body, headers={"X-Demo-User": uid}).json()["decision"] == "block"
    assert _check(client, many, uid=uid).verdict == "SAFE"  # the honest re-check, flagged app gone, still lifts it


def test_kept_block_answer_carries_findings_and_the_uninstall_target(client):
    """Finding 5: the kept-BLOCK answer said UNINSTALL_AND_RECHECK with no findings and nothing to uninstall."""
    uid = "rina-kept"
    first = _check(client, CLEAN + [TAKANOW], uid=uid)
    assert first.verdict == "BLOCK"
    kept = _check(client, [], uid=uid)
    assert kept.verdict == "BLOCK" and kept.resolution == "UNINSTALL_AND_RECHECK" and kept.recheck_lifts_block is True
    assert [t.package for t in kept.uninstall_targets] == ["com.demo.takanow"] and kept.user_message_bn == first.user_message_bn
    signals = {f.signal for f in kept.findings}
    assert "SIDELOADED_ACCESSIBILITY" in signals and "IMPLAUSIBLE_BUNDLE" in signals  # the stored findings plus what this re-check found
    assert kept.valid_until == first.valid_until and kept.check_id != first.check_id and "kept" in kept.disagreement_reason


def test_recheck_lifts_block_is_derived(client, monkeypatch):
    """Finding 12: the flag was a constant True."""
    assert _check(client, CLEAN, uid="lift-safe").recheck_lifts_block is False
    assert _check(client, CLEAN + [TAKANOW], uid="lift-block").recheck_lifts_block is True  # uninstall, then check again
    modded = _demo_token(client, CLEAN, "lift-modded", app_recognition="UNRECOGNIZED_VERSION")
    out = _check(client, CLEAN, uid="lift-modded", integrity_token=modded)
    assert out.verdict == "BLOCK" and out.resolution == "REINSTALL_FROM_PLAY" and out.recheck_lifts_block is False
    from app.settings import get_settings

    monkeypatch.setattr(get_settings(), "demo_mode", False)  # production: an unattested client's re-check never lifts
    assert appsafety_engine.recheck_lifts("BLOCK", "UNINSTALL_AND_RECHECK", "none", get_settings()) is False
    assert appsafety_engine.recheck_lifts("BLOCK", "UNINSTALL_AND_RECHECK", "device", get_settings()) is True


def test_forged_token_with_a_non_string_hash_does_not_500(client):
    """Finding 6: an int requestHash reached hmac.compare_digest and raised TypeError out of the route."""
    import base64
    import json as _json
    import time as _time

    from bhorosha_app_safety_check import integrity

    from app.settings import get_settings

    body = {"appsDetected": [], "playProtectVerdict": "NO_ISSUES", "requestHash": 12345, "appRecognitionVerdict": "PLAY_RECOGNIZED", "deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"], "packageName": "com.bhorosha.app", "appLicensingVerdict": "LICENSED", "exp": int(_time.time()) + 60}
    payload = base64.urlsafe_b64encode(_json.dumps(body, separators=(",", ":"), sort_keys=True).encode()).rstrip(b"=").decode()
    token = f"demo.{payload}.{integrity._signature(appsafety_engine.demo_secret(get_settings()), payload)}"
    out = _check(client, CLEAN, uid="forged-int", integrity_token=token)
    assert out.attestation == "mismatch" and out.verdict == "BLOCK"


def test_demo_secret_is_random_when_unset_and_the_two_hash_paths_agree(client):
    """Findings 9 and 10: no secret in source; the token is minted over the hash the check computes."""
    from bhorosha_app_safety_check import integrity

    from app.contracts import AppSafetyRequest, DemoIntegrityRequest
    from app.settings import get_settings

    settings = get_settings()
    assert settings.demo_integrity_secret == "" and len(appsafety_engine.demo_secret(settings)) >= 32
    assert appsafety_engine.demo_secret(settings) == appsafety_engine.demo_secret(settings)
    payload = {"installed_apps": CLEAN + [TAKANOW], "device": {"overlay_holders": ["com.demo.takanow"], "sdk_int": 34}}
    minted = appsafety_engine.mint_demo_token(DemoIntegrityRequest(**payload), settings)
    assert minted.bundle_hash == integrity.bundle_hash(*appsafety_engine._rows(AppSafetyRequest(**payload)))


def test_2026_fields_flow_through_the_contract(client):
    dropper = _app("com.x.dropper", "Chrome", CHROME, ("REQUEST_INSTALL_PACKAGES",))
    payload = {**_app("com.x.payload", "Security Update", "com.x.dropper", ("READ_SMS", "RECEIVE_SMS")), "has_accessibility_service": True, "installer_declares_install_packages": True, "launcher_icon_hidden": True}
    resp = client.post("/v1/appsafety/check", json={"installed_apps": CLEAN + [dropper, payload], "device": {"sdk_int": 33, "default_sms_package": "com.google.android.apps.messaging"}}, headers={"X-Demo-User": "rina-2026"})
    assert resp.status_code == 200, resp.text
    out = AppSafetyResponse(**resp.json())
    signals = {f.signal for f in out.findings}
    assert out.verdict == "BLOCK" and {"DROPPER_INSTALLED", "BRAND_IMPERSONATION", "ICON_HIDDEN"} <= signals
    assert out.findings[0].severity == "critical" and out.uninstall_targets and all(t.deep_link.startswith("package:") for t in out.uninstall_targets)


def test_latest_verdict_is_readable_for_case_zero(client):
    assert client.get("/v1/appsafety/latest/nobody").json() == {"uid": "nobody", "known": False, "verdict": "SAFE", "risk_score": 0.0, "flagged_packages": [], "attestation": "none", "checked_at": "", "valid_until": "",
                                                                      "source": "server", "facts": []}  # Who checked, and the closed-set facts
    _check(client, CLEAN + [TAKANOW], uid="rina-latest")
    out = client.get("/v1/appsafety/latest/rina-latest").json()
    assert out["known"] is True and out["verdict"] == "BLOCK" and out["flagged_packages"] == ["com.demo.takanow"] and out["valid_until"] > out["checked_at"]
