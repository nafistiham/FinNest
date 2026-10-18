"""/v1/investigate fronts Case Zero. The stub stays as the fallback so the demo never breaks."""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from app import contracts as c
from app.investigator import CaseZeroClient, InvestigatorUnavailable, UnknownCase, sse_events
from app.routers import investigate

BASE = "http://case-zero.test"

CONTRACT = {
    "case_id": "CZ-0001",
    "acct_id": "acct_01288",
    "status": "done",
    "summary_en": "Funds passed through three accounts to one till.",
    "summary_bn": "টাকা তিনটি অ্যাকাউন্ট হয়ে একটি টিলে গেছে।",
    "evidence": [{"row_id": "txn_000421", "claim": "Tk 4,900 received 11 minutes after the PIN reset"}],
    "ring": ["acct_09001", "acct_01070"],
    "confidence": 0.91,
    "recommended_action": "freeze",
    "model_version": "mule-lgbm-0.1+gemini-3.8-flash",
}

STREAM = [
    {"type": "run_started", "case_id": "CZ-0001", "seed": "acct_01288", "as_of": "2026-11-10T14:35:00", "model": "gemini-3.8-flash"},
    {"type": "score", "call_id": "tc_00", "data": {"probability": 0.91}},
    {"type": "tool_call", "name": "neighbours", "args": {"acct_id": "acct_01288", "hops": 2}},
    {"type": "tool_result", "call_id": "tc_01", "ok": True, "data": {}},
    {"type": "validator", "attempt": 1, "pass": True, "violations": []},
    {"type": "report", "report": {"model_score": 0.91, "draft": {"red_flags": []}}},
    {"type": "done", "case_id": "CZ-0001"},
]


def _sse_body(events) -> bytes:
    return "".join(f"id: {i}\nevent: {e['type']}\ndata: {json.dumps(e)}\n\n" for i, e in enumerate(events)).encode()


def _transport(routes: dict[tuple[str, str], httpx.Response | Exception]) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        outcome = routes.get((request.method, request.url.path))
        if outcome is None:
            return httpx.Response(404, json={"detail": "not found"})
        if isinstance(outcome, Exception):
            raise outcome
        # A fresh copy per call: httpx rebinds a response's stream to the client that read it, so one canned response
        # could not otherwise be read by both the sync client (a case read) and the async one (its events) in one test.
        return httpx.Response(outcome.status_code, headers=outcome.headers, content=outcome.content)

    return httpx.MockTransport(handler)


def _client(routes) -> CaseZeroClient:
    return CaseZeroClient(BASE, transport=_transport(routes))


# --- SSE parsing --------------------------------------------------------------------------------


def _parse(text: str) -> list[dict]:
    async def lines():
        for line in text.split("\n"):
            yield line

    async def collect():
        return [event async for event in sse_events(lines())]

    return asyncio.run(collect())


def test_sse_parser_reads_data_lines_and_ignores_pings_ids_and_event_names():
    text = ": ping\n\nid: 0\nevent: score\ndata: {\"type\": \"score\", \"x\": 1}\n\nid: 1\ndata: {\"type\": \"done\"}\n\n"
    assert _parse(text) == [{"type": "score", "x": 1}, {"type": "done"}]


def test_sse_parser_skips_a_malformed_frame_instead_of_ending_the_stream():
    assert _parse("data: {not json\n\ndata: {\"type\": \"done\"}\n\n") == [{"type": "done"}]


# --- the client ---------------------------------------------------------------------------------


def test_start_returns_the_case_id():
    client = _client({("POST", "/api/investigations"): httpx.Response(202, json={"case_id": "CZ-0007", "status": "queued"})})
    assert client.start("acct_01288") == "CZ-0007"


@pytest.mark.parametrize("outcome", [httpx.Response(429, json={}), httpx.Response(503, json={}), httpx.ConnectError("down")])
def test_start_reports_an_unavailable_investigator(outcome):
    with pytest.raises(InvestigatorUnavailable):
        _client({("POST", "/api/investigations"): outcome}).start("acct_01288")


def test_contract_is_none_while_the_case_is_still_running():
    assert _client({}).contract("CZ-9999") is None


def test_status_of_an_unknown_case_raises():
    with pytest.raises(UnknownCase):
        _client({}).status("CZ-9999")


def test_steps_translate_case_zero_events_into_the_step_vocabulary():
    client = _client({
        ("GET", "/api/investigations/CZ-0001/events"): httpx.Response(200, content=_sse_body(STREAM), headers={"content-type": "text/event-stream"}),
        ("GET", "/api/cases/CZ-0001/contract"): httpx.Response(200, json=CONTRACT),
    })
    steps = asyncio.run(_collect(client.steps("CZ-0001")))
    assert [s["step"] for s in steps] == ["plan", "tool", "tool", "evidence", "done"]
    assert steps[1] == {"step": "tool", "name": "score", "args": {"acct_id": "acct_01288"}}
    assert steps[2]["name"] == "neighbours"
    assert steps[3] == {"step": "evidence", "row_id": "txn_000421", "text": "Tk 4,900 received 11 minutes after the PIN reset"}
    assert steps[4] == {"step": "done", "confidence": 0.91}


def test_steps_still_finish_with_done_when_the_contract_is_missing():
    client = _client({("GET", "/api/investigations/CZ-0001/events"): httpx.Response(200, content=_sse_body(STREAM))})
    steps = asyncio.run(_collect(client.steps("CZ-0001")))
    assert steps[-1] == {"step": "done", "confidence": 0.91}


def test_steps_surface_an_investigator_error_and_a_cut_stream():
    errored = [STREAM[0], {"type": "error", "message": "TimeoutError: tool loop"}, {"type": "done", "case_id": "CZ-0001"}]
    client = _client({("GET", "/api/investigations/CZ-0001/events"): httpx.Response(200, content=_sse_body(errored))})
    steps = asyncio.run(_collect(client.steps("CZ-0001")))
    assert {"step": "error", "text": "TimeoutError: tool loop"} in steps

    cut = _client({("GET", "/api/investigations/CZ-0001/events"): httpx.Response(200, content=_sse_body(STREAM[:3]))})
    cut_steps = asyncio.run(_collect(cut.steps("CZ-0001")))
    assert cut_steps[-1]["step"] == "error"


async def _collect(stream):
    return [step async for step in stream]


# --- the routes ---------------------------------------------------------------------------------


@pytest.fixture
def wired(monkeypatch, client):
    """/v1/investigate pointed at a fake Case Zero; returns the fake's route table so tests can edit it."""
    investigate.STORE.clear()
    investigate.RECENT.clear()
    investigate.OWNERS.clear()
    routes = {
        ("POST", "/api/investigations"): httpx.Response(202, json={"case_id": "CZ-0001", "status": "queued"}),
        ("GET", "/api/investigations/CZ-0001"): httpx.Response(200, json={"case_id": "CZ-0001", "status": "running", "events": [STREAM[0]], "next": 1, "report": None}),
        ("GET", "/api/investigations/CZ-0001/events"): httpx.Response(200, content=_sse_body(STREAM)),
        ("GET", "/api/cases/CZ-0001/contract"): httpx.Response(200, json=CONTRACT),
    }
    fake = _client(routes)
    monkeypatch.setattr(investigate, "client_for", lambda url: fake if url else None)
    monkeypatch.setenv("RISK_MW_INVESTIGATOR_URL", BASE)
    from app.settings import get_settings

    get_settings.cache_clear()
    yield routes
    investigate.STORE.clear()
    investigate.RECENT.clear()
    investigate.OWNERS.clear()
    monkeypatch.undo()
    get_settings.cache_clear()


def test_investigate_hands_back_case_zeros_case_id(client, wired):
    created = c.InvestigateResponse(**client.post("/v1/investigate", json={"acct_id": "acct_01288"}).json())
    assert created.case_id == "CZ-0001"
    assert created.stream_url == "/v1/investigations/CZ-0001/events"


def test_a_finished_case_is_returned_in_the_frozen_report_shape(client, wired):
    report = c.CaseReport(**client.get("/v1/investigations/CZ-0001").json())
    assert report.status == "done" and report.confidence == 0.91 and report.evidence[0].row_id == "txn_000421"


def test_a_running_case_is_a_valid_pending_report(client, wired):
    wired[("GET", "/api/cases/CZ-0001/contract")] = httpx.Response(404, json={})
    report = c.CaseReport(**client.get("/v1/investigations/CZ-0001").json())
    assert report.status == "running" and report.acct_id == "acct_01288" and report.evidence == ()


def test_an_unknown_case_is_a_404(client, wired):
    assert client.get("/v1/investigations/CZ-4242").status_code == 404
    assert client.get("/v1/investigations/CZ-4242/events").status_code == 404


def test_events_stream_in_the_step_vocabulary(client, wired):
    response = client.get("/v1/investigations/CZ-0001/events")
    assert response.headers["content-type"].startswith("text/event-stream")
    steps = [json.loads(line[5:]) for line in response.text.splitlines() if line.startswith("data:")]
    assert [s["step"] for s in steps] == ["plan", "tool", "tool", "evidence", "done"]


def test_the_same_account_reuses_its_case_instead_of_spending_quota(client, wired):
    first = client.post("/v1/investigate", json={"acct_id": "acct_01288"}).json()
    wired[("POST", "/api/investigations")] = httpx.Response(202, json={"case_id": "CZ-0002", "status": "queued"})
    wired[("GET", "/api/investigations/CZ-0001")] = httpx.Response(200, json={"case_id": "CZ-0001", "status": "done", "events": [], "next": 0, "report": {}})
    second = client.post("/v1/investigate", json={"acct_id": "acct_01288"}).json()
    assert second["case_id"] == first["case_id"] == "CZ-0001"


def test_a_failed_case_is_not_reused(client, wired):
    client.post("/v1/investigate", json={"acct_id": "acct_01288"})
    wired[("POST", "/api/investigations")] = httpx.Response(202, json={"case_id": "CZ-0002", "status": "queued"})
    wired[("GET", "/api/investigations/CZ-0001")] = httpx.Response(200, json={"case_id": "CZ-0001", "status": "failed", "events": [], "next": 0, "report": None})
    assert client.post("/v1/investigate", json={"acct_id": "acct_01288"}).json()["case_id"] == "CZ-0002"


@pytest.mark.parametrize("outcome", [httpx.Response(429, json={}), httpx.Response(500, json={}), httpx.ConnectError("down")])
def test_when_case_zero_is_down_the_stub_answers_and_says_so(client, wired, outcome):
    wired[("POST", "/api/investigations")] = outcome
    created = c.InvestigateResponse(**client.post("/v1/investigate", json={"acct_id": "acct_01288"}).json())
    report = c.CaseReport(**client.get(f"/v1/investigations/{created.case_id}").json())
    assert report.model_version == "stub-fallback"
    assert "data:" in client.get(created.stream_url).text


def test_the_stub_store_is_bounded(client):
    investigate.STORE.clear()
    for i in range(investigate.MAX_STUB_CASES + 20):
        investigate.STORE.add(investigate._stub_report(f"id{i}", "acct_x", "stub"))
    assert len(investigate.STORE) <= investigate.MAX_STUB_CASES
    assert investigate.STORE.get("id0") is None and investigate.STORE.get(f"id{investigate.MAX_STUB_CASES + 19}") is not None


def test_a_case_id_that_could_alter_the_upstream_path_is_rejected_before_any_upstream_call(client, wired):
    for bad in ("..", "CZ-1%3Fx%3D1", "a" * 200, "CZ 1"):
        assert client.get(f"/v1/investigations/{bad}").status_code in (404, 422)
        assert client.get(f"/v1/investigations/{bad}/events").status_code in (404, 422)


def test_the_recent_case_table_is_bounded():
    investigate.RECENT.clear()
    for i in range(investigate.MAX_RECENT_CASES + 50):
        investigate.RECENT.put(f"acct_{i}", f"CZ-{i:04d}")
    assert investigate.RECENT.size() <= investigate.MAX_RECENT_CASES
    assert investigate.RECENT.get(f"acct_{investigate.MAX_RECENT_CASES + 49}", 60) is not None
    investigate.RECENT.clear()


# --- a case that failed Case Zero's citation check after its retry is "degraded", never "done" -------


DEGRADED = {**CONTRACT, "status": "degraded", "redacted": True, "limitations": "1 unsupported statement(s) removed after a failed retry.",
            "validation_errors": ["en_bn_mismatch in narrative_bn: ids ['acct_01870'] amounts [1850]"]}


def test_a_degraded_case_passes_through_with_its_errors(client, wired):
    wired[("GET", "/api/cases/CZ-0001/contract")] = httpx.Response(200, json=DEGRADED)
    response = client.get("/v1/investigations/CZ-0001")
    assert response.status_code == 200
    report = c.CaseReport(**response.json())
    assert (report.status, report.redacted) == ("degraded", True)
    assert report.validation_errors[0].startswith("en_bn_mismatch") and "removed" in report.limitations


def test_a_contract_without_the_degraded_fields_still_validates():
    report = c.CaseReport(**CONTRACT)   # no validation_errors or limitations
    assert report.validation_errors == () and report.limitations == ""


# --- with auth on, a case reads only to the caller who started it ----------------------------


ALICE = {"Authorization": "Bearer alice"}   # auth_on fakes the Firebase check: the bearer token is the uid
BOB = {"Authorization": "Bearer bob"}
NEW_ID = "CZ-7K3MQX2PLA"                   # Case Zero's id shape: CZ- plus ten base32 characters
SECOND_ID = "CZ-Q4ZB6WNE2D"


def _start(client, headers, acct_id="acct_01288") -> str:
    response = client.post("/v1/investigate", json={"acct_id": acct_id}, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()["case_id"]


def _route_case(routes, case_id: str, state: str = "running") -> None:
    """Point the fake Case Zero's next POST at case_id and serve that case's status, events and contract."""
    routes[("POST", "/api/investigations")] = httpx.Response(202, json={"case_id": case_id, "status": "queued"})
    routes[("GET", f"/api/investigations/{case_id}")] = httpx.Response(200, json={"case_id": case_id, "status": state, "events": [STREAM[0]], "next": 1, "report": None})
    routes[("GET", f"/api/investigations/{case_id}/events")] = httpx.Response(200, content=_sse_body(STREAM))
    routes[("GET", f"/api/cases/{case_id}/contract")] = httpx.Response(200, json={**CONTRACT, "case_id": case_id})


def test_with_auth_on_only_the_caller_who_started_a_case_can_read_it(client, wired, auth_on):
    case_id = _start(client, ALICE)
    assert client.get(f"/v1/investigations/{case_id}", headers=ALICE).status_code == 200
    assert client.get(f"/v1/investigations/{case_id}/events", headers=ALICE).status_code == 200
    assert client.get(f"/v1/investigations/{case_id}", headers=BOB).status_code == 404       # 404, not 403: no hint the id exists
    assert client.get(f"/v1/investigations/{case_id}/events", headers=BOB).status_code == 404
    assert client.get(f"/v1/investigations/{case_id}").status_code == 401
    assert client.get(f"/v1/investigations/{case_id}/events").status_code == 401


def test_with_auth_on_another_callers_case_looks_like_an_unknown_one(client, wired, auth_on):
    case_id = _start(client, ALICE)
    theirs = client.get(f"/v1/investigations/{case_id}", headers=BOB)
    unknown = client.get("/v1/investigations/CZ-4242", headers=BOB)
    assert (theirs.status_code, theirs.json()) == (unknown.status_code, unknown.json()) == (404, {"detail": "unknown case"})


def test_in_demo_mode_anyone_may_read_any_case(client, wired):
    case_id = _start(client, {"X-Demo-User": "alice"})
    for who in ({"X-Demo-User": "bob"}, {"X-Demo-User": "alice"}, {}):
        assert client.get(f"/v1/investigations/{case_id}", headers=who).status_code == 200
        assert client.get(f"/v1/investigations/{case_id}/events", headers=who).status_code == 200


def test_with_auth_on_a_repeat_request_reuses_only_the_callers_own_case(client, wired, auth_on):
    alices = _start(client, ALICE)
    wired[("GET", f"/api/investigations/{alices}")] = httpx.Response(200, json={"case_id": alices, "status": "done", "events": [], "next": 0, "report": {}})
    _route_case(wired, SECOND_ID)
    assert _start(client, ALICE) == alices                       # her own case, still reusable: no second Case Zero run
    bobs = _start(client, BOB)
    assert bobs == SECOND_ID != alices                            # Case Zero was asked again, for bob
    assert client.get(f"/v1/investigations/{alices}", headers=BOB).status_code == 404
    assert client.get(f"/v1/investigations/{bobs}", headers=BOB).status_code == 200
    assert client.get(f"/v1/investigations/{bobs}", headers=ALICE).status_code == 404


def test_in_demo_mode_a_repeat_request_by_anyone_reuses_the_accounts_case(client, wired):
    first = _start(client, {"X-Demo-User": "alice"})
    wired[("GET", f"/api/investigations/{first}")] = httpx.Response(200, json={"case_id": first, "status": "done", "events": [], "next": 0, "report": {}})
    _route_case(wired, SECOND_ID)
    assert _start(client, {"X-Demo-User": "bob"}) == first


@pytest.mark.parametrize("outcome", [httpx.Response(500, json={}), httpx.ConnectError("down")])
def test_with_auth_on_a_stub_case_reads_only_to_its_starter(client, wired, auth_on, outcome):
    wired[("POST", "/api/investigations")] = outcome
    case_id = _start(client, ALICE)
    assert investigate.STORE.get(case_id) is not None             # the stub answered
    assert client.get(f"/v1/investigations/{case_id}", headers=ALICE).json()["model_version"] == "stub-fallback"
    assert client.get(f"/v1/investigations/{case_id}", headers=BOB).status_code == 404
    assert client.get(f"/v1/investigations/{case_id}/events", headers=BOB).status_code == 404


def test_a_new_format_case_zero_id_passes_the_path_pattern(client, wired):
    _route_case(wired, NEW_ID, state="done")
    created = c.InvestigateResponse(**client.post("/v1/investigate", json={"acct_id": "acct_09001"}).json())
    assert (created.case_id, created.stream_url) == (NEW_ID, f"/v1/investigations/{NEW_ID}/events")
    assert c.CaseReport(**client.get(f"/v1/investigations/{NEW_ID}").json()).case_id == NEW_ID
    steps = [json.loads(line[5:]) for line in client.get(f"/v1/investigations/{NEW_ID}/events").text.splitlines() if line.startswith("data:")]
    assert steps[-1]["step"] == "done"


def test_with_auth_on_a_case_whose_owner_record_is_gone_fails_closed(client, wired, auth_on):
    case_id = _start(client, ALICE)
    investigate.OWNERS.clear()                                    # a restart, or the bound reached
    assert client.get(f"/v1/investigations/{case_id}", headers=ALICE).status_code == 404


def test_the_owner_table_is_bounded_and_keeps_the_newest():
    owners = investigate.CaseOwners(limit=5)
    for i in range(8):
        owners.put(f"CZ-{i:010d}", f"uid{i}")
    assert owners.size() == 5
    assert owners.owner("CZ-0000000000") is None and owners.owner("CZ-0000000007") == "uid7"
    owners.put("CZ-0000000003", "uid3")                           # a re-put moves a case to the newest end
    owners.put("CZ-NEW0000000", "uidN")
    assert owners.owner("CZ-0000000003") == "uid3" and owners.owner("CZ-0000000004") is None
    assert investigate.OWNERS.limit == investigate.MAX_RECENT_CASES + investigate.MAX_STUB_CASES


def test_one_caller_cannot_push_another_callers_owner_record_out():
    owners = investigate.CaseOwners()
    owners.put("CZ-ALICE00000", "alice")
    flood = owners.limit * 2
    for i in range(flood):
        owners.put(f"CZ-M{i:09d}", "mallory")
    assert owners.owner("CZ-ALICE00000") == "alice"                # her case still reads to her
    assert owners.owner(f"CZ-M{flood - 1:09d}") == "mallory"       # the flooder keeps only her own newest
    assert owners.size() <= owners.limit


def test_with_auth_on_one_caller_cannot_push_another_callers_reusable_case_out():
    investigate.RECENT.clear()
    investigate.RECENT.put(("alice", "acct_01288"), "CZ-ALICE00000")
    flood = investigate.MAX_RECENT_CASES * 2
    for i in range(flood):
        investigate.RECENT.put(("mallory", f"acct_{i}"), f"CZ-M{i:09d}")
    assert investigate.RECENT.get(("alice", "acct_01288"), 60) == "CZ-ALICE00000"
    assert investigate.RECENT.get(("mallory", f"acct_{flood - 1}"), 60) == f"CZ-M{flood - 1:09d}"
    assert investigate.RECENT.size() <= investigate.MAX_RECENT_CASES
    investigate.RECENT.clear()


def test_with_auth_on_a_refused_read_writes_an_audit_row(client, wired, auth_on, monkeypatch):
    rows = []
    monkeypatch.setattr(investigate.audit, "record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid, inputs, outputs)) or "a1")
    case_id = _start(client, ALICE)
    assert client.get(f"/v1/investigations/{case_id}", headers=ALICE).status_code == 200
    assert rows == []                                             # the owner's own read is not a refusal
    assert client.get(f"/v1/investigations/{case_id}", headers=BOB).status_code == 404
    assert client.get(f"/v1/investigations/{case_id}/events", headers=BOB).status_code == 404
    refused = ("investigation_read_refused", "bob", {"case_id": case_id}, {"status_code": 404, "detail": "unknown case"})
    assert rows == [refused, refused]
