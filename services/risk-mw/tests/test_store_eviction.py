"""A full store drops settled and expired entries before live ones, and one caller holds at
most PER_OWNER_LIMIT entries, so she cannot push anyone else's pending request, intervention or signals out."""

from __future__ import annotations

from collections import OrderedDict
from datetime import UTC, datetime, timedelta

from app import bounded, interventions, sessions
from app.contracts import SignalsRequest
from app.routers import actions

NOW = datetime(2026, 11, 10, 14, 2, tzinfo=UTC)
SPAM = bounded.PER_OWNER_LIMIT + 8
TTL_S = 1800


def _owner(_key: str, value: tuple[str, bool]) -> str:
    return value[0]


def _stale(value: tuple[str, bool]) -> bool:
    return value[1]


# --- the helper -----------------------------------------------------------------------------------------------------


def test_make_room_drops_stale_entries_before_live_ones():
    items = OrderedDict([("live-old", ("u1", False)), ("stale", ("u2", True)), ("live", ("u3", False)), ("new", ("u4", False))])
    bounded.make_room(items, "new", owner_of=_owner, is_stale=_stale, limit=3)
    assert list(items) == ["live-old", "live", "new"]


def test_make_room_falls_back_to_the_oldest():
    items = OrderedDict([("a", ("u1", False)), ("b", ("u2", False)), ("c", ("u3", False))])
    bounded.make_room(items, "c", owner_of=_owner, is_stale=_stale, limit=2)
    assert list(items) == ["b", "c"]


def test_make_room_caps_one_owner_without_touching_anyone_else():
    items = OrderedDict([("other", ("u2", False))] + [(f"m{i}", ("u1", False)) for i in range(5)])
    bounded.make_room(items, "m4", owner_of=_owner, is_stale=_stale, limit=100, per_owner=3)
    assert list(items) == ["other", "m2", "m3", "m4"]


def test_make_room_never_drops_the_entry_just_added():
    items = OrderedDict([("a", ("u1", True)), ("new", ("u2", True))])
    bounded.make_room(items, "new", owner_of=_owner, is_stale=_stale, limit=1)
    assert list(items) == ["new"]


# --- sessions -------------------------------------------------------------------------------------------------------


def _session(at: datetime) -> sessions.SessionState:
    return sessions.SessionState(SignalsRequest(session_id="s"), at)


def test_one_caller_cannot_push_another_callers_session_out():
    store = sessions.SessionStore()
    limit = bounded.PER_OWNER_LIMIT + 4
    store.put(("rina", "s"), _session(NOW), limit, TTL_S)
    for index in range(SPAM):
        store.put(("spammer", f"s{index}"), _session(NOW), limit, TTL_S)
    assert store.get(("rina", "s"), NOW, TTL_S) is not None
    assert sum(store.get(("spammer", f"s{i}"), NOW, TTL_S) is not None for i in range(SPAM)) == bounded.PER_OWNER_LIMIT


def test_expired_sessions_go_before_live_ones():
    store = sessions.SessionStore()
    store.put(("rina", "live"), _session(NOW), 2, TTL_S)
    store.put(("rafiq", "old"), _session(NOW - timedelta(seconds=TTL_S + 1)), 2, TTL_S)
    store.put(("rahima", "new"), _session(NOW), 2, TTL_S)
    assert store.get(("rina", "live"), NOW, TTL_S) is not None
    assert store.get(("rahima", "new"), NOW, TTL_S) is not None


# --- interventions --------------------------------------------------------------------------------------------------


def test_one_caller_cannot_push_another_callers_intervention_out():
    store = interventions.InterventionStore(limit=bounded.PER_OWNER_LIMIT + 4)
    kept = store.open("rina", "call_active", now=NOW)
    spam = [store.open("spammer", "call_active", now=NOW) for _ in range(SPAM)]
    assert store.get(kept.intervention_id) is not None
    assert sum(store.get(i.intervention_id) is not None for i in spam) == bounded.PER_OWNER_LIMIT


def test_stale_interventions_go_before_fresh_ones():
    store = interventions.InterventionStore(limit=2)
    fresh = store.open("rina", "call_active", now=NOW)
    stale = store.open("rafiq", "call_active", now=NOW - interventions.STALE_AFTER - timedelta(seconds=1))
    newest = store.open("rahima", "call_active", now=NOW)
    assert store.get(fresh.intervention_id) is not None
    assert store.get(stale.intervention_id) is None
    assert store.get(newest.intervention_id) is not None


# --- trusted-contact requests ---------------------------------------------------------------------------------------


def _request(
    request_id: str, requester: str, status: actions.Status = "pending", lives: timedelta = timedelta(minutes=10),
) -> actions.ContactRequest:
    return actions.ContactRequest(request_id, "int", requester, "rafiq", NOW + lives, status)


def test_one_requester_cannot_push_another_requesters_pending_request_out():
    store = actions.RequestStore(limit=bounded.PER_OWNER_LIMIT + 4)
    store.add(_request("rina-1", "rina"), NOW)
    for index in range(SPAM):
        store.add(_request(f"spam-{index}", "spammer"), NOW)
    assert store.get("rina-1") is not None
    assert sum(store.get(f"spam-{i}") is not None for i in range(SPAM)) == bounded.PER_OWNER_LIMIT


def test_settled_and_expired_requests_go_before_pending_ones():
    store = actions.RequestStore(limit=3)
    later = NOW + timedelta(minutes=11)
    store.add(_request("pending-old", "rina", lives=timedelta(hours=1)), NOW)
    store.add(_request("settled", "rafiq", "approved"), NOW)
    store.add(_request("lapsed", "rahima"), NOW)  # still pending, but past its expires_at by `later`
    store.add(_request("pending-new", "sumon", lives=timedelta(hours=1)), later)
    store.add(_request("pending-newest", "rina2", lives=timedelta(hours=1)), later)
    assert store.get("pending-old") is not None
    assert store.get("settled") is None and store.get("lapsed") is None
    assert store.get("pending-new") is not None and store.get("pending-newest") is not None
