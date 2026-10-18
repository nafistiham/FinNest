"""Device signals posted to /v1/risk/signals reach the rules, and the answer says which inputs were simulated.

The earlier bug: /signals kept only the behaviour features, so a phone reporting an off-hook call, a fresh SIM and
screen capture was allowed a PIN reset that the same facts sent as demo flags would have held.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from app import device_signals, personas
from app.contracts import DemoFlags, SignalsRequest
from app.routers import risk
from app.sessions import SessionState
from app.settings import get_settings

RINA = {"X-Demo-User": "rina"}
SESSION = "s-device"
PIN_RESET = {"type": "pin_reset"}
T0 = datetime(2026, 11, 10, 14, 2, tzinfo=UTC)
NO_SOURCES = {"call_active": "none", "sim_swap": "none", "screen_share": "none", "caller_in_contacts": "none"}


def _signal(
    client, signals: dict, headers: dict[str, str] = RINA, device: dict | None = None, simulated: list[str] | None = None,
) -> None:
    body = {"session_id": SESSION, "signals": signals, **({"device": device} if device else {})}
    body = {**body, **({"simulated": simulated} if simulated is not None else {})}
    resp = client.post("/v1/risk/signals", json=body, headers=headers)
    assert resp.status_code == 200, resp.text


def _score(client, txn: dict = PIN_RESET, demo_flags: dict | None = None, user_id: str = "rina") -> dict:
    body = {"user_id": user_id, "session_id": SESSION, "txn": txn, "demo_flags": demo_flags or {}}
    resp = client.post("/v1/risk/score", json=body, headers=RINA)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _codes(result: dict) -> set[str]:
    return {r["code"] for r in result["reasons"]}


@pytest.fixture
def clock(monkeypatch):
    """Pin the route's clock; returns a setter to move it."""
    current = {"now": T0}
    monkeypatch.setattr(risk, "_now", lambda: current["now"])
    return lambda delta: current.update(now=T0 + delta)


# --- through the route ----------------------------------------------------------------------------------------------


def test_posted_signals_alone_hold_a_pin_reset(client):
    _signal(client, {"call_state": "OFFHOOK"})
    result = _score(client)
    assert result["decision"] == "hold"
    assert "CALL_ACTIVE_NON_CONTACT" in _codes(result)
    assert result["signal_sources"]["call_active"] == "device"


def test_a_risky_phone_is_held_and_every_source_is_device(client):
    _signal(client, {"call_state": "OFFHOOK", "subscription_changed_hours": 1, "screen_capture": True})
    result = _score(client)
    assert result["decision"] == "hold"
    assert {"CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H", "SCREEN_SHARE_ACTIVE"} <= _codes(result)
    assert result["signal_sources"] == {**NO_SOURCES, "call_active": "device", "sim_swap": "device", "screen_share": "device"}


def test_demo_flags_alone_are_named_demo(client):
    result = _score(client, demo_flags={"call_active": True, "sim_swap": True})
    assert result["decision"] == "hold"
    assert result["signal_sources"] == {**NO_SOURCES, "call_active": "demo", "sim_swap": "demo"}


def test_nothing_posted_and_nothing_flagged_is_none(client):
    result = _score(client)
    assert result["decision"] == "allow"
    assert result["signal_sources"] == NO_SOURCES


def test_a_posted_call_state_the_demo_panel_forced_is_named_demo(client):
    _signal(client, {"call_state": "OFFHOOK"}, simulated=["call_state"])
    result = _score(client)
    assert result["decision"] == "hold"
    assert result["signal_sources"]["call_active"] == "demo"


def test_simulated_may_name_the_demo_flag_instead_of_the_field(client):
    _signal(client, {"subscription_changed_hours": 1, "screen_capture": True}, simulated=["sim_swap", "screen_share"])
    result = _score(client)
    assert result["signal_sources"] == {**NO_SOURCES, "sim_swap": "demo", "screen_share": "demo"}


def test_a_real_reading_beside_a_simulated_one_is_still_device(client):
    _signal(client, {"screen_capture": True, "screen_recording": True}, simulated=["screen_capture"])
    assert _score(client)["signal_sources"]["screen_share"] == "device"


def test_a_client_flag_that_cancels_a_call_hold_is_visible(client, monkeypatch):
    """caller_in_contacts is a product rule (a call with a saved contact is not held), but it comes from the body."""
    rows: list[tuple[str, dict]] = []
    monkeypatch.setattr("app.audit.record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, outputs)) or "id")
    _signal(client, {"call_state": "OFFHOOK"})
    result = _score(client, demo_flags={"caller_in_contacts": True})
    assert "CALL_ACTIVE_NON_CONTACT" not in _codes(result)
    assert result["signal_sources"]["call_active"] == "device"
    assert result["signal_sources"]["caller_in_contacts"] == "demo"
    scored = [outputs for kind, outputs in rows if kind == "score"]
    assert scored and scored[0]["signal_sources"]["caller_in_contacts"] == "demo"


def test_a_call_state_older_than_the_window_does_not_fire(client, clock):
    _signal(client, {"call_state": "OFFHOOK"})
    clock(timedelta(seconds=get_settings().live_signal_fresh_s + 1))
    result = _score(client)
    assert result["decision"] == "allow"
    assert result["signal_sources"]["call_active"] == "none"


def test_a_sim_change_older_than_the_window_does_not_fire(client):
    _signal(client, {"subscription_changed_hours": get_settings().sim_change_hold_hours + 1})
    result = _score(client)
    assert "SIM_CHANGED_24H" not in _codes(result)
    assert result["signal_sources"]["sim_swap"] == "none"


def test_another_callers_signals_do_not_hold_rina(client):
    _signal(client, {"call_state": "OFFHOOK"}, headers={"X-Demo-User": "someone-else"})
    assert _score(client)["decision"] == "allow"


def test_the_audit_row_carries_the_sources(client, monkeypatch):
    rows: list[tuple[str, dict]] = []
    monkeypatch.setattr("app.audit.record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, outputs)) or "id")
    _signal(client, {"call_state": "RINGING"})
    _score(client)
    scored = [outputs for kind, outputs in rows if kind == "score"]
    assert scored and scored[0]["signal_sources"]["call_active"] == "device"


# --- the derivation, without HTTP -----------------------------------------------------------------------------------


def _state(signals: dict | None = None, device: dict | None = None, simulated: tuple[str, ...] = (), at: datetime = T0) -> SessionState:
    return SessionState(SignalsRequest(session_id=SESSION, signals=signals or {}, device=device or {}, simulated=simulated), at)


def _measured(state: SessionState, now: datetime = T0) -> device_signals.DeviceFlags:
    return device_signals.derive(state, now, get_settings()).device


def test_ringing_counts_as_a_call():
    assert _measured(_state({"call_state": "RINGING"})).call_active


def test_idle_is_no_call():
    assert not _measured(_state({"call_state": "IDLE"})).call_active


def test_screen_recording_counts_as_screen_share():
    assert _measured(_state({"screen_recording": True})).screen_share


def test_screen_capture_older_than_the_window_does_not_fire():
    later = T0 + timedelta(seconds=get_settings().live_signal_fresh_s + 1)
    assert not _measured(_state({"screen_capture": True}), later).screen_share


def test_sim_change_hours_age_with_the_signal():
    """23 h old when posted, scored two hours later: 25 h, outside a 24 h window."""
    state = _state({"subscription_changed_hours": get_settings().sim_change_hold_hours - 1})
    assert _measured(state).sim_swap
    assert not _measured(state, T0 + timedelta(hours=2)).sim_swap


def test_sim_changed_at_within_the_window_fires():
    assert _measured(_state(device={"sim_changed_at": (T0 - timedelta(hours=3)).isoformat()})).sim_swap


def test_sim_changed_at_outside_the_window_or_unreadable_does_not_fire():
    old = (T0 - timedelta(hours=get_settings().sim_change_hold_hours + 1)).isoformat()
    assert not _measured(_state(device={"sim_changed_at": old})).sim_swap
    assert not _measured(_state(device={"sim_changed_at": "yesterday"})).sim_swap


def test_a_sim_changed_at_in_the_future_is_unreadable():
    future = (T0 + timedelta(hours=1)).isoformat()
    derived = device_signals.derive(_state(device={"sim_changed_at": future}), T0, get_settings())
    assert not derived.device.sim_swap and not derived.simulated.sim_swap


def test_a_phone_clock_slightly_ahead_still_counts_as_just_changed():
    ahead = (T0 + timedelta(seconds=device_signals.CLOCK_SKEW_TOLERANCE_S - 1)).isoformat()
    assert _measured(_state(device={"sim_changed_at": ahead})).sim_swap


def test_a_simulated_field_is_reported_as_simulated_not_measured():
    derived = device_signals.derive(_state({"call_state": "OFFHOOK"}, simulated=("call_state",)), T0, get_settings())
    assert not derived.device.call_active
    assert derived.simulated.call_active


def test_no_session_derives_nothing():
    assert device_signals.derive(None, T0, get_settings()) == device_signals.DerivedSignals()


def test_fuse_ors_and_prefers_device_as_the_source():
    derived = device_signals.DerivedSignals(
        device=device_signals.DeviceFlags(call_active=True, sim_swap=True),
        simulated=device_signals.DeviceFlags(call_active=True),
    )
    flags, sources = device_signals.fuse(DemoFlags(call_active=True, screen_share=True), derived)
    assert (flags.call_active, flags.sim_swap, flags.screen_share) == (True, True, True)
    assert (sources.call_active, sources.sim_swap, sources.screen_share) == ("device", "device", "demo")


def test_fuse_leaves_the_original_flags_unchanged_and_returns_merged_ones():
    original = DemoFlags()
    merged, _ = device_signals.fuse(original, device_signals.DerivedSignals(device=device_signals.DeviceFlags(call_active=True)))
    assert original == DemoFlags()
    assert merged.call_active is True
    assert merged != original


# --- per-user p95 -----------------------------------------------------------------------------------------------------


def test_p95_comes_from_the_persona_row():
    settings = get_settings()
    assert personas.p95_amount_for("rahima", settings) == 2000
    assert personas.p95_amount_for("acct_rahima", settings) == 2000
    assert personas.p95_amount_for("nobody-we-know", settings) == settings.default_p95_amount_bdt


def test_personas_below_the_default_are_delayed_where_the_default_would_allow(client):
    """Amounts between each persona's own p95 and the 5,000 default: only a per-user lookup delays them."""
    default = get_settings().default_p95_amount_bdt

    def new_payee(amount: float) -> dict:
        return {"type": "send_money", "amount_bdt": amount, "to_account": "acct_new", "is_new_payee": True}

    for user_id in ("acct_rahima", "rafiq", "acct_newphone_benign"):
        own = personas.p95_amount_for(user_id, get_settings())
        assert own < default, user_id
        amount = (own + default) / 2
        assert "NEW_PAYEE_ABOVE_P95" in _codes(_score(client, txn=new_payee(amount), user_id=user_id)), user_id
        assert "NEW_PAYEE_ABOVE_P95" not in _codes(_score(client, txn=new_payee(amount), user_id="nobody-we-know"))


def test_the_persona_table_matches_the_seed_loader():
    """config/personas.json mirrors libs/synth/load_seed.py PERSONAS, the rows written to Firestore users/."""
    import load_seed

    expected = {p["uid"]: (acct, float(p["p95_send_bdt"])) for acct, p in load_seed.PERSONAS.items()}
    assert personas.table(get_settings()) == {
        **{uid: p95 for uid, (_, p95) in expected.items()},
        **{acct: p95 for acct, p95 in expected.values()},
    }
