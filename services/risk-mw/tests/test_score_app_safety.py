"""The phone sends its App Safety Check result with the score request (`app_safety`), so the decision does not
depend on what this instance remembers, and a CAUTION becomes a weighted reason."""

from app import appsafety_engine


def _score(client, body):
    resp = client.post("/v1/risk/score", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _codes(out):
    return {r["code"] for r in out["reasons"]}


def _ctx(verdict="BLOCK", risk=0.9, **extra):
    return {
        "verdict": verdict,
        "risk_score": risk,
        "findings": [{"package": "com.evil.remote", "signal": "accessibility_control", "severity": "critical"}],
        "apps_to_uninstall": ["com.evil.remote"],
        "recommended_action": "UNINSTALL",
        "attestation": "device",
        "check_id": "chk_1",
        "source": "check",
        **extra,
    }


def test_a_block_carried_by_the_phone_blocks_without_a_stored_verdict(client, score_body):
    assert appsafety_engine.latest_verdict("rina") is None
    out = _score(client, {**score_body, "app_safety": _ctx("BLOCK")})
    assert out["decision"] == "block" and "APP_SAFETY_BLOCK" in _codes(out)


def test_the_phone_cannot_lower_a_stored_or_flagged_verdict(client, score_body):
    body = {**score_body, "demo_flags": {"app_safety_verdict": "BLOCK"}, "app_safety": _ctx("SAFE", 0.0)}
    out = _score(client, body)
    assert out["decision"] == "block" and "APP_SAFETY_BLOCK" in _codes(out)


def test_a_caution_raises_the_risk_score_and_names_the_reason_but_allows(client, score_body):
    out = _score(client, {**score_body, "app_safety": _ctx("CAUTION", 0.55)})
    assert out["decision"] == "allow"
    assert "APP_SAFETY_CAUTION" in _codes(out)
    caution = next(r for r in out["reasons"] if r["code"] == "APP_SAFETY_CAUTION")
    assert caution["weight"] == 0.55 and caution["text_bn"] and caution["text_en"]
    assert out["risk_score"] >= 0.55


def test_a_caution_rides_along_a_hold_and_the_hold_still_decides(client, score_body):
    body = {**score_body, "demo_flags": {"sim_swap": True}, "app_safety": _ctx("CAUTION", 0.4)}
    out = _score(client, body)
    assert out["decision"] == "hold" and {"SIM_CHANGED_24H", "APP_SAFETY_CAUTION"} <= _codes(out)


def test_safe_adds_nothing(client, score_body):
    out = _score(client, {**score_body, "app_safety": _ctx("SAFE", 0.0, findings=[], apps_to_uninstall=[])})
    assert out["decision"] == "allow" and not {"APP_SAFETY_BLOCK", "APP_SAFETY_CAUTION"} & _codes(out)


def test_the_block_is_optional_and_strict(client, score_body):
    assert client.post("/v1/risk/score", json=score_body).status_code == 200
    bad = {**score_body, "app_safety": {**_ctx(), "raw_response": {}}}
    assert client.post("/v1/risk/score", json=bad).status_code == 422
    out_of_range = {**score_body, "app_safety": _ctx("CAUTION", 1.5)}
    assert client.post("/v1/risk/score", json=out_of_range).status_code == 422


def test_the_phone_copy_lands_in_the_audit_record(client, score_body, monkeypatch):
    from app import audit

    seen = {}
    monkeypatch.setattr(audit, "record", lambda kind, uid, inputs, outputs, ms: seen.update({"kind": kind, "inputs": inputs}) or "a1")
    _score(client, {**score_body, "app_safety": _ctx("CAUTION", 0.3)})
    assert seen["kind"] == "score" and seen["inputs"]["app_safety"]["findings"][0]["package"] == "com.evil.remote"


# --- the block is trimmed, never refused (2026-10-18) -----------------------------------------------
# A refused score is a transfer that cannot be verified: the money does not move. So a block that is too big is cut to
# what the decision and the audit need, most severe first, and the audit says how much was cut.


def _audited(client, monkeypatch, body):
    from app import audit

    seen = {}
    monkeypatch.setattr(audit, "record", lambda kind, uid, inputs, outputs, ms: seen.update({"inputs": inputs}) or "a1")
    _score(client, body)
    return seen["inputs"]["app_safety"]


def _finding(i, severity):
    return {"package": f"com.app.n{i}", "signal": "OVERLAY_ABILITY", "severity": severity}


def test_an_oversized_block_is_trimmed_not_refused(client, score_body, monkeypatch):
    # The criticals come last, so keeping them first proves the order is by severity, not by position.
    findings = [_finding(i, "low") for i in range(4000)] + [_finding(i, "high") for i in range(4000, 4990)]
    findings += [{**_finding(i, "critical"), "package": "p" * 300} for i in range(4990, 5000)]
    kept = _audited(client, monkeypatch, {**score_body, "app_safety": _ctx("CAUTION", 0.4, findings=findings)})
    assert len(kept["findings"]) == 50 and kept["findings_dropped"] == 4950
    assert [f["severity"] for f in kept["findings"][:10]] == ["critical"] * 10
    assert {f["severity"] for f in kept["findings"][10:]} == {"high"}
    assert len(kept["findings"][0]["package"]) == 255


def test_trimming_keeps_the_phones_order_within_a_severity(client, score_body, monkeypatch):
    findings = [_finding(i, "high") for i in range(60)]
    kept = _audited(client, monkeypatch, {**score_body, "app_safety": _ctx("CAUTION", 0.4, findings=findings)})
    assert [f["package"] for f in kept["findings"]] == [f"com.app.n{i}" for i in range(50)]


def test_a_block_within_the_limits_is_untouched(client, score_body, monkeypatch):
    sent = _ctx("CAUTION", 0.4)
    kept = _audited(client, monkeypatch, {**score_body, "app_safety": sent})
    assert kept["findings_dropped"] == 0 and kept["check_id"] == "chk_1"
    assert [{k: f[k] for k in ("package", "signal", "severity")} for f in kept["findings"]] == sent["findings"]


def test_long_lists_and_strings_are_clipped(client, score_body, monkeypatch):
    sent = _ctx("CAUTION", 0.4, apps_to_uninstall=[f"com.app.n{i}" for i in range(80)], check_id="c" * 400,
                findings=[{"package": "com.x", "signal": "S" * 100, "severity": "high"}])
    kept = _audited(client, monkeypatch, {**score_body, "app_safety": sent})
    assert len(kept["apps_to_uninstall"]) == 50 and len(kept["check_id"]) == 255
    assert len(kept["findings"][0]["signal"]) == 64


def test_a_wrong_value_is_still_refused(client, score_body):
    # Size is trimmed; a value outside the contract is still a client bug and still a 422.
    bad = {**score_body, "app_safety": _ctx("CAUTION", 0.4, findings=[_finding(1, "severe")])}
    assert client.post("/v1/risk/score", json=bad).status_code == 422


# --- a phone's result counts only while it is valid (D3 and D4) ------------------------------------
# The phone may send a result from an earlier Home load. It counts until the server's own valid_until; without one,
# until checked_at plus the server's TTL (15 min for SAFE/CAUTION, 24 h for BLOCK); with neither (or unreadable dates),
# it still counts, because it can only raise the verdict, and the server logs it. A simulated verdict counts only in demo
# mode.

from datetime import UTC, datetime, timedelta  # noqa: E402


def _at(**delta):
    return (datetime.now(UTC) + timedelta(**delta)).isoformat()


def test_an_expired_block_from_the_phone_is_ignored(client, score_body):
    out = _score(client, {**score_body, "app_safety": _ctx("BLOCK", valid_until=_at(minutes=-1))})
    assert out["decision"] == "allow" and "APP_SAFETY_BLOCK" not in _codes(out)


def test_a_block_still_valid_blocks(client, score_body):
    out = _score(client, {**score_body, "app_safety": _ctx("BLOCK", valid_until=_at(hours=1))})
    assert out["decision"] == "block"


def test_a_block_with_only_checked_at_uses_the_server_ttl(client, score_body):
    old = _score(client, {**score_body, "app_safety": _ctx("BLOCK", checked_at=_at(hours=-25))})
    recent = _score(client, {**score_body, "app_safety": _ctx("BLOCK", checked_at=_at(hours=-23))})
    assert old["decision"] == "allow" and recent["decision"] == "block"


def test_a_caution_with_only_checked_at_lasts_fifteen_minutes(client, score_body):
    old = _score(client, {**score_body, "app_safety": _ctx("CAUTION", 0.4, checked_at=_at(minutes=-16))})
    recent = _score(client, {**score_body, "app_safety": _ctx("CAUTION", 0.4, checked_at=_at(minutes=-14))})
    assert "APP_SAFETY_CAUTION" not in _codes(old) and "APP_SAFETY_CAUTION" in _codes(recent)


def test_an_undated_block_still_counts(client, score_body, caplog):
    with caplog.at_level("INFO", logger="app.appsafety_engine"):
        out = _score(client, {**score_body, "app_safety": _ctx("BLOCK")})
    assert out["decision"] == "block" and "app_safety_undated" in caplog.text


def test_an_unreadable_date_counts_as_undated(client, score_body):
    out = _score(client, {**score_body, "app_safety": _ctx("BLOCK", valid_until="tomorrow-ish", checked_at="??")})
    assert out["decision"] == "block"


def test_a_date_without_a_timezone_is_read_as_utc(client, score_body):
    naive = (datetime.now(UTC) - timedelta(minutes=1)).replace(tzinfo=None).isoformat()
    out = _score(client, {**score_body, "app_safety": _ctx("BLOCK", valid_until=naive)})
    assert out["decision"] == "allow"


def test_a_simulated_block_counts_only_in_demo_mode():
    from app.contracts import AppSafetyContext
    from app.settings import Settings

    ctx = AppSafetyContext.model_validate(_ctx("BLOCK", simulated_verdict=True))
    now = datetime.now(UTC)
    assert appsafety_engine.carried(ctx, now, Settings(demo_mode=True)) == ctx
    assert appsafety_engine.carried(ctx, now, Settings(demo_mode=False)) is None
    real = AppSafetyContext.model_validate(_ctx("BLOCK"))
    assert appsafety_engine.carried(real, now, Settings(demo_mode=False)) == real
    assert appsafety_engine.carried(None, now, Settings()) is None


def test_an_ignored_block_is_kept_in_the_audit_with_its_reason(client, score_body, monkeypatch):
    from app import audit

    seen = {}
    monkeypatch.setattr(audit, "record", lambda kind, uid, inputs, outputs, ms: seen.update({"inputs": inputs}) or "a1")
    _score(client, {**score_body, "app_safety": _ctx("BLOCK", valid_until=_at(minutes=-1))})
    assert seen["inputs"]["app_safety"] is None
    assert seen["inputs"]["app_safety_ignored"]["reason"] == "expired"
    assert seen["inputs"]["app_safety_ignored"]["sent"]["verdict"] == "BLOCK"


# --- CAUTION is named from any source and never reads high (D2) --------------------------------------
# The fused verdict decides whether the reason appears; the weight is the risk of the source that said CAUTION (the
# phone's copy or this instance's own check; the demo panel alone gets a default), capped below band_high so an allowed
# transfer never reads "high". An allow-only reason must not hide the session model either.

AS_RINA = {"X-Demo-User": "rina"}


def _stored(verdict, risk):
    from app.settings import Settings

    appsafety_engine.remember_verdict("rina", verdict, risk, app_count=40, flagged=frozenset(), attestation="none",
                                      settings=Settings())


def _caution(out):
    return next((r for r in out["reasons"] if r["code"] == "APP_SAFETY_CAUTION"), None)


def _score_as_rina(client, body):
    resp = client.post("/v1/risk/score", json=body, headers=AS_RINA)
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_a_stored_caution_without_the_phone_block_is_named(client, score_body):
    _stored("CAUTION", 0.5)
    out = _score_as_rina(client, score_body)
    assert out["decision"] == "allow" and _caution(out)["weight"] == 0.5


def test_a_caution_never_reads_high(client, score_body):
    out = _score_as_rina(client, {**score_body, "app_safety": _ctx("CAUTION", 0.9)})
    assert out["decision"] == "allow" and _caution(out)["weight"] == 0.59
    assert out["band"] == "medium" and out["risk_score"] < 0.6


def test_a_demo_flag_caution_alone_gets_the_default_weight(client, score_body):
    out = _score_as_rina(client, {**score_body, "demo_flags": {"app_safety_verdict": "CAUTION"}})
    assert _caution(out)["weight"] == 0.45


def test_the_stronger_cautions_risk_is_the_weight(client, score_body):
    _stored("CAUTION", 0.5)
    out = _score_as_rina(client, {**score_body, "app_safety": _ctx("CAUTION", 0.3)})
    assert _caution(out)["weight"] == 0.5


def test_a_phone_safe_does_not_lend_its_zero_to_a_stored_caution(client, score_body):
    _stored("CAUTION", 0.5)
    out = _score_as_rina(client, {**score_body, "app_safety": _ctx("SAFE", 0.0, findings=[], apps_to_uninstall=[])})
    assert _caution(out)["weight"] == 0.5


def test_a_block_is_not_also_a_caution(client, score_body):
    _stored("CAUTION", 0.5)
    out = _score_as_rina(client, {**score_body, "app_safety": _ctx("BLOCK")})
    assert out["decision"] == "block" and _caution(out) is None


def test_a_caution_never_hides_an_unusual_session(client, score_body, monkeypatch):
    # Before: any hit stopped MODEL_RISK, so a CAUTION (an allow) turned the model's step-up into an allow.
    from app import session_model

    monkeypatch.setattr(session_model, "predict", lambda *a, **k: 0.9)
    out = _score_as_rina(client, {**score_body, "app_safety": _ctx("CAUTION", 0.4)})
    assert out["decision"] == "step_up" and {"MODEL_RISK", "APP_SAFETY_CAUTION"} <= _codes(out)


# --- a block reason that says what was found (Task 5) ------------------------------------------------
# The app shows APP_SAFETY_BLOCK's text verbatim on the block overlay. It names the most dangerous phone fact (the same
# closed set FNA's warning uses) and the next step, in the app's own words for the safety page; anything unmapped, or a
# demo-panel block with no check behind it, gets the general line.

import re  # noqa: E402

import pytest  # noqa: E402

from app import appsafety_text  # noqa: E402
from app.warnings import planner  # noqa: E402


def _block_reason(out):
    return next(r for r in out["reasons"] if r["code"] == "APP_SAFETY_BLOCK")


def _blocked_with(*pairs):
    findings = [{"package": "com.x", "signal": s, "severity": sev} for s, sev in pairs]
    return _ctx("BLOCK", findings=findings)


def test_every_phone_fact_has_block_text():
    assert set(appsafety_text.BLOCK_TEXT) == set(planner.PHONE_FACTS)


def test_the_block_reason_names_what_was_found(client, score_body):
    out = _score_as_rina(client, {**score_body, "app_safety": _blocked_with(("SMS_ROLE_TAKEOVER", "critical"))})
    reason = _block_reason(out)
    assert (reason["text_bn"], reason["text_en"]) == appsafety_text.BLOCK_TEXT["READS_MESSAGES"]
    assert "messages" in reason["text_en"] and out["decision"] == "block" and reason["weight"] == 0.95


def test_the_most_dangerous_fact_words_the_reason(client, score_body):
    out = _score_as_rina(client, {**score_body, "app_safety": _blocked_with(("LOAN_APP_DATA_HARVEST", "high"), ("KNOWN_RAT", "critical"))})
    assert _block_reason(out)["text_en"] == appsafety_text.BLOCK_TEXT["REMOTE_CONTROL"][1]


def test_an_unmapped_finding_gets_the_general_text(client, score_body):
    out = _score_as_rina(client, {**score_body, "app_safety": _blocked_with(("OVERLAY_ABILITY", "critical"))})
    assert (_block_reason(out)["text_bn"], _block_reason(out)["text_en"]) == appsafety_text.GENERAL


def test_a_demo_panel_block_gets_the_general_text(client, score_body):
    out = _score_as_rina(client, {**score_body, "demo_flags": {"app_safety_verdict": "BLOCK"}})
    assert _block_reason(out)["text_en"] == appsafety_text.GENERAL[1]


def test_a_stored_block_names_its_own_findings(client, score_body):
    from app.contracts import AppSafetyResponse, Finding
    from app.settings import Settings

    finding = Finding(package="com.x", signal="BRAND_IMPERSONATION", severity="critical", evidence="e",
                      explanation_bn="ব্যাখ্যা", explanation_en="why")
    response = AppSafetyResponse(verdict="BLOCK", risk_score=0.95, findings=(finding,), recommended_action="UNINSTALL",
                                 apps_to_uninstall=("com.x",), user_message_bn="", user_message_en="", simulated_verdict=False)
    appsafety_engine.remember_verdict("rina", "BLOCK", 0.95, app_count=40, flagged=frozenset({"com.x"}), attestation="none",
                                      settings=Settings(), response=response)
    out = _score_as_rina(client, score_body)
    assert _block_reason(out)["text_en"] == appsafety_text.BLOCK_TEXT["FAKE_APP"][1]


def test_a_broken_fact_lookup_still_blocks_with_the_general_text(client, score_body, monkeypatch):
    from app.warnings import signals

    def broken(uid):
        raise RuntimeError("store down")
    monkeypatch.setattr(signals, "phone_facts", broken)
    out = _score_as_rina(client, {**score_body, "app_safety": _blocked_with(("KNOWN_RAT", "high"))})
    assert out["decision"] == "block" and _block_reason(out)["text_en"] == appsafety_text.GENERAL[1]


FORBIDDEN = re.compile(r"Bhorosha|ভরসা|\bApa\b|আপা|[!?০-৯0-9]")


@pytest.mark.parametrize("fact", [*appsafety_text.BLOCK_TEXT, None])
def test_block_text_keeps_the_copy_rules(fact):
    bn, en = appsafety_text.BLOCK_TEXT[fact] if fact else appsafety_text.GENERAL
    assert not FORBIDDEN.search(bn) and not FORBIDDEN.search(en)
    assert bn.endswith("।") and bn.count("।") == 2 and en.endswith(".") and en.count(". ") == 1
    assert "ফোনের নিরাপত্তা" in bn and "phone safety" in en.lower()   # the next step names the app's own safety page
    assert "এখন করা যাবে না" in bn and "cannot go ahead now" in en  # true for a transfer and for a PIN reset alike


# --- final review fixes (2026-10-18): hostile shapes are refused or trimmed, never a 500 -----------------------------

def test_a_severity_of_the_wrong_type_is_a_422_not_a_500(client, score_body):
    bad = {**score_body, "app_safety": _ctx("CAUTION", 0.4, findings=[{"package": "x", "signal": "S", "severity": ["high"]}])}
    assert client.post("/v1/risk/score", json=bad).status_code == 422


def test_findings_dropped_is_the_servers_count_never_the_phones(client, score_body, monkeypatch):
    findings = [_finding(i, "high") for i in range(60)]
    kept = _audited(client, monkeypatch, {**score_body, "app_safety": _ctx("CAUTION", 0.4, findings=findings, findings_dropped="3")})
    assert kept["findings_dropped"] == 10
    kept = _audited(client, monkeypatch, {**score_body, "app_safety": _ctx("CAUTION", 0.4, findings_dropped=7)})
    assert kept["findings_dropped"] == 0


def test_a_date_at_the_end_of_time_counts_as_undated(client, score_body):
    out = _score(client, {**score_body, "app_safety": _ctx("BLOCK", checked_at="9999-12-31T23:59:59+00:00")})
    assert out["decision"] == "block"
