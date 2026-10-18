"""Case Zero money and durability: spend and viewer disconnects, money arrows,
and decided cases that outlive the display history."""

import asyncio
from types import SimpleNamespace

import pytest

from case_zero.budget import SpendLedger
from case_zero.llm import MAX_OUTPUT_TOKENS, GeminiLLM, ModelRole, cost_usd, estimate_tokens

ROLE = ModelRole(name="workhorse", id="gemini-3.8-flash", input_usd_per_m=0.75, output_usd_per_m=3.75)


def _client(generate):
    return SimpleNamespace(aio=SimpleNamespace(models=SimpleNamespace(generate_content=generate)))


# A cancelled call is charged its reservation ----------------------------------------------------
def test_a_call_cancelled_after_dispatch_is_charged_its_reservation(tmp_path):
    sent = asyncio.Event()

    async def slow(model, contents, config):
        sent.set()
        await asyncio.sleep(5)
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    llm = GeminiLLM(_client(slow), ROLE, budget=budget)

    async def go():
        task = asyncio.create_task(llm.chat("s", [], None, None, 30))
        await sent.wait()   # the request is out: Gemini may finish and bill it whatever we do now
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(go())
    worst = cost_usd(estimate_tokens("s", [], None), MAX_OUTPUT_TOKENS, ROLE)
    assert budget.held() == 0 and budget.calls() == 1 and budget.spent() == pytest.approx(worst)


# A viewer leaving the one-request stream does not drop the case -----------------------------------
def test_leaving_the_one_request_stream_lets_the_case_finish_and_keeps_it(world):
    import httpx
    from fake_llm import FakeLLM, draft
    from test_orchestrator import NO_MIN, SCRIPT, good_draft
    from test_judge_and_tool_concurrency import _post_and_leave_after_first_event, _until_final

    from case_zero.app import create_app
    from case_zero.config import DEMO_SEED

    async def go():
        llm = FakeLLM(SCRIPT + [draft(good_draft())], delay_s=0.2)
        app = create_app(settings=NO_MIN, world=world, llm=llm, max_concurrent=1)
        await asyncio.wait_for(_post_and_leave_after_first_event(app, {"seed": DEMO_SEED}), 10)
        (case_id,) = app.state.runs   # the one run this test started
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            status = await _until_final(c, case_id)
            case = await c.get(f"/api/cases/{case_id}")
            replay = await c.get(f"/api/investigations/{case_id}/events")
            payees = (await c.get("/api/payee-risk")).json()["payees"]
            again = await c.post("/api/investigations", json={"seed": "acct_99999"})
            return status, case, replay.text, payees, again.status_code
    status, case, replay, payees, again = asyncio.run(go())
    assert status["status"] == "done" and status["report"]["action"] == "freeze"
    assert case.status_code == 200 and case.json()["status"] == "done"   # stored, not dropped
    assert "event: report" in replay and "cancelled" not in replay      # a viewer who comes back gets the whole run
    assert {p["acct_id"] for p in payees} == {"acct_01070", "acct_01870"}
    assert again == 202                                                  # the slot is freed once the run ends


# Money arrows point the way the money went ------------------------------------------------------
def _neighbour_edges(world, seed: str) -> list[dict]:
    from case_zero.config import DEMO_AS_OF
    from case_zero.ledger import Ledger
    out = Ledger(world, seed, DEMO_AS_OF, 15).call("neighbours", acct_id=seed, hops=1)
    return [e for e in out["graph_delta"]["edges"] if e["kind"] == "money"]


def _transfers(world) -> dict[str, dict]:
    return {t["txn_id"]: t for touching in world.bundle.txns_by_acct.values() for t in touching}


def test_rinas_demo_transfer_is_drawn_from_rina_to_the_mule(world):
    edge = next(e for e in _neighbour_edges(world, "acct_rina") if "acct_01070" in (e["source"], e["target"]))
    assert (edge["source"], edge["target"], edge["txn_id"]) == ("acct_rina", "acct_01070", "txn_011308")


def test_an_inbound_transfer_to_the_seed_points_at_the_seed(world):
    from case_zero.config import DEMO_SEED
    from case_zero.world import real_id
    edges, txns = _neighbour_edges(world, DEMO_SEED), _transfers(world)
    rina = next(e for e in edges if "acct_rina" in (e["source"], e["target"]))
    assert (rina["source"], rina["target"]) == ("acct_rina", DEMO_SEED)
    assert any(e["source"] == DEMO_SEED for e in edges)   # its own payments still point away from it
    for e in edges:   # every arrow is the real transfer's
        t = txns[e["txn_id"]]
        assert (real_id(e["source"]), real_id(e["target"]), e["amount_bdt"], e["ts"]) == (t["from_acct"], t["to_acct"], round(t["amount_bdt"]), t["ts"])


def test_the_neighbours_tool_passes_the_transfer_through_with_aliased_ids(world):
    from case_zero.config import DEMO_AS_OF
    from case_zero.tools import run_tool
    from case_zero.world import ALIASES
    persona, alias = next(iter(ALIASES.items()))
    rows = run_tool(world, "neighbours", DEMO_AS_OF, {"acct_id": alias, "hops": 1})["neighbours"]
    assert rows and all({"txn_id", "from_acct", "to_acct", "via"} <= r.keys() for r in rows)
    assert all(alias in (r["from_acct"], r["to_acct"]) for r in rows) and persona not in str(rows)


def test_identity_links_are_drawn_without_an_arrow(world):
    import re
    from pathlib import Path
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from case_zero.ledger import Ledger
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF, 15)
    out = led.call("shared_entities", acct_ids=[DEMO_SEED, "acct_01635"])
    assert out["graph_delta"]["edges"] and all(e["kind"] == "link" and "txn_id" not in e for e in out["graph_delta"]["edges"])
    html = (Path(__file__).resolve().parent.parent / "static" / "index.html").read_text(encoding="utf-8")
    link_style = re.search(r"edge\[kind = 'link'\]\", style: \{([^}]*)\}", html)
    assert link_style and '"target-arrow-shape": "none"' in link_style[1]


def test_the_recorded_replay_draws_every_transfer_the_way_it_went(world):
    import json
    from pathlib import Path
    from case_zero.world import real_id
    replay = Path(__file__).resolve().parent.parent / "static" / "replay" / "demo.jsonl"
    txns = _transfers(world)
    edges = [e for line in replay.read_text(encoding="utf-8").splitlines() for ev in [json.loads(line)] if ev["type"] == "tool_result"
             for e in (ev.get("graph_delta") or {}).get("edges", []) if e["kind"] == "money"]
    assert edges
    for e in edges:
        t = txns[e.get("txn_id")] if e.get("txn_id") in txns else None
        assert t is not None and (real_id(e["source"]), real_id(e["target"])) == (t["from_acct"], t["to_acct"]), e
    assert any((e["source"], e["target"]) == ("acct_rina", "acct_01070") for e in edges)
    assert not any((e["source"], e["target"]) == ("acct_01070", "acct_rina") for e in edges)


# Decided cases and the watch-list outlive the display history --------------------------------------
def _evicting_client(world):
    from fake_llm import FakeLLM, draft
    from fastapi.testclient import TestClient
    from ids import sequential_ids
    from test_orchestrator import NO_MIN, SCRIPT, good_draft

    from case_zero.app import create_app
    from case_zero.config import DEMO_SEED
    c = TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM(SCRIPT + [draft(good_draft())]), admin_token="t", max_cases=2,
                              case_ids=sequential_ids()))   # these tests need to know which case was evicted first
    c.post("/api/investigate", json={"seed": DEMO_SEED})                 # CZ-0001: a valid report with two payees
    for unknown in ("acct_99991", "acct_99992", "acct_99993"):           # CZ-0002..4: nothing to find, no Gemini call
        c.post("/api/investigate", json={"seed": unknown})
    return c


def test_a_decided_case_keeps_its_payees_after_display_eviction(world):
    c = _evicting_client(world)
    assert c.get("/api/cases/CZ-0001").status_code == 404                # gone from the display history
    payees = {p["acct_id"]: p for p in c.get("/api/payee-risk").json()["payees"]}
    assert set(payees) == {"acct_01070", "acct_01870"}
    assert all(p["status"] == "suspected" and p["case_id"] == "CZ-0001" for p in payees.values())


def test_an_evicted_decided_case_can_still_be_approved(world):
    c = _evicting_client(world)
    assert c.post("/api/cases/CZ-0001/approve", headers={"X-Admin-Token": "t"}).status_code == 200
    assert c.post("/api/cases/CZ-9999/approve", headers={"X-Admin-Token": "t"}).status_code == 404
    payees = {p["acct_id"]: p["status"] for p in c.get("/api/payee-risk").json()["payees"]}
    assert payees == {"acct_01070": "confirmed", "acct_01870": "suspected"}


def _report(status: str):
    from test_orchestrator import good_draft

    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    return SimpleNamespace(status=status, seed=DEMO_SEED, as_of=DEMO_AS_OF, action="freeze", draft=good_draft())


def test_the_decided_statuses_are_done_and_degraded():
    from case_zero.export import DECIDED, decision
    assert DECIDED == {"done", "degraded"}
    assert decision("CZ-0001", _report("done"))["action"] == "freeze"
    assert decision("CZ-0001", _report("degraded"))["members"][1] == {"acct_id": "acct_01070", "role": "mule_L1", "facts": ["acct_01070 fanned Tk 7,900 out within minutes"]}
    assert decision("CZ-0001", _report("failed")) is None


def test_a_report_that_failed_validation_after_the_retry_is_a_degraded_decision():
    """The orchestrator's own status for a case that did not pass the citation check after the retry is
    failed_after_retry (exports it as degraded): it is decided, held, and never confirmed."""
    from case_zero.export import decision, payee_risk
    from test_judge_and_tool_concurrency import _FixedScores
    d = decision("CZ-0001", _report("failed_after_retry"))
    assert d["status"] == "degraded" and [m["acct_id"] for m in d["members"]][1:] == ["acct_01070", "acct_01870"]
    out = payee_risk({"CZ-0001": d}, {"CZ-0001"}, _FixedScores({"acct_01070": 0.99, "acct_01870": 0.99}))   # approved, critical band
    assert {p["acct_id"]: p["status"] for p in out["payees"]} == {"acct_01070": "suspected", "acct_01870": "suspected"}


def test_a_degraded_case_holds_its_payees_but_never_confirms_them():
    from case_zero.export import decision, payee_risk
    from test_judge_and_tool_concurrency import _FixedScores
    scores = _FixedScores({"acct_01070": 0.99, "acct_01870": 0.99})
    out = payee_risk({"CZ-0001": decision("CZ-0001", _report("degraded"))}, {"CZ-0001"}, scores)   # approved, critical band
    assert {p["acct_id"]: p["status"] for p in out["payees"]} == {"acct_01070": "suspected", "acct_01870": "suspected"}


# 1. The contract cites the transfer a flag is about, never an arbitrary neighbours row --
def _replayed_demo(world):
    """The 2026-10-16 recorded demo case and a ledger rebuilt by re-running its recorded calls on the same world.

    The served replay was re-recorded on 2026-10-17; this case's RF01 (neighbours, then path_between) is what the test is about."""
    import json
    from pathlib import Path
    from case_zero.ledger import Ledger
    from case_zero.schemas import CaseReport
    events = [json.loads(line) for line in (Path(__file__).resolve().parent / "fixtures" / "replay_2026-10-16.jsonl").read_text(encoding="utf-8").splitlines()]
    start = events[0]
    ledger = Ledger(world, start["seed"], start["as_of"], start["max_tool_calls"])
    ledger.prefetch_score()
    for e in events:
        if e["type"] == "tool_call":
            ledger.call(e["name"], **e["args"])
    report = CaseReport.model_validate(next(e for e in events if e["type"] == "report")["report"])
    return report, ledger


def test_the_recorded_demo_cites_rinas_transfer_not_a_neighbours_row(world):
    from case_zero.schemas import to_contract
    report, ledger = _replayed_demo(world)
    rf01 = next(f for f in report.draft.red_flags if f.code == "RF01")
    assert ledger.entry(rf01.evidence[0])["name"] == "neighbours"   # its first citation lists 25 transfers
    # RF01 also cites path_between acct_rina -> acct_01070; RF02 cites only the neighbours and velocity calls, so it has no row
    assert to_contract(report, ledger)["evidence"] == [{"row_id": "txn_011308", "claim": rf01.text}]


def _neighbours_only(world, text: str):
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from case_zero.ledger import Ledger
    from case_zero.schemas import RedFlag
    from case_zero.evidence import evidence_txn
    ledger = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    ledger.prefetch_score()
    ledger.call("neighbours", acct_id=DEMO_SEED, hops=1)   # tc_01
    return evidence_txn(RedFlag(code="RF02", text=text, evidence=["tc_01"]), ledger)


def test_a_neighbours_only_flag_gets_no_row_unless_one_matches_it(world):
    assert _neighbours_only(world, "Funds dispersed rapidly within minutes of receipt.") is None              # names nothing
    assert _neighbours_only(world, "acct_rafiq paid Tk 5,000 to acct_00999 the same day.") is None            # rows do not involve them
    assert _neighbours_only(world, "acct_01070 received Tk 1,234 within minutes.") is None                    # its account, not its amount
    assert _neighbours_only(world, "acct_rina sent Tk 7,900 to acct_01070 at 14:13.") == "txn_011308"         # both ends and the amount
    assert _neighbours_only(world, "acct_01070 received Tk 7,900 and passed it on.") == "txn_011308"          # one end and the amount


# 2. Cloud Run keeps the CPU on, so a run whose viewer left does not stall ----------------
def test_deploy_keeps_cpu_on_between_requests():
    from pathlib import Path
    script = (Path(__file__).resolve().parent.parent / "deploy.sh").read_text(encoding="utf-8")
    deploy = script[script.index("gcloud run deploy case-zero"):script.index("--quiet")]
    assert "--no-cpu-throttling" in deploy


# 3 and 4. Only decisions that name someone are kept, and they can be read back ------------
def test_a_case_that_names_nobody_leaves_no_decision(world):
    from case_zero.export import decision
    from test_orchestrator import good_draft
    empty, victim_only = _report("done"), _report("done")
    empty.draft = good_draft(members=[])                                                   # an unknown or idle account
    victim_only.draft = good_draft(members=[{"acct_id": "acct_rina", "role": "victim", "evidence": ["tc_01"]}])
    assert decision("CZ-0002", empty) is None and decision("CZ-0003", victim_only) is None
    assert list(_evicting_client(world).app.state.decisions) == ["CZ-0001"]               # the three unknown accounts left nothing


def test_an_evicted_decision_can_be_read_before_it_is_approved(world):
    c = _evicting_client(world)
    stored = c.get("/api/decisions/CZ-0001")
    assert stored.status_code == 200
    assert stored.json()["action"] == "freeze" and stored.json()["status"] == "done"
    assert [(m["acct_id"], m["role"]) for m in stored.json()["members"]] == [("acct_rina", "victim"), ("acct_01070", "mule_L1"), ("acct_01870", "mule_L2")]
    assert c.get("/api/decisions/CZ-0004").status_code == 404   # an unknown account decided nothing
    assert c.get("/api/decisions/CZ-9999").status_code == 404


# 6. The agent is told what a neighbours row is ---------------------------------------
def test_the_neighbours_description_says_which_transfer_a_row_is():
    from case_zero.tools import TOOL_SPECS
    text = next(t["description"] for t in TOOL_SPECS if t["name"] == "neighbours")
    assert all(field in text for field in ("from_acct", "to_acct", "txn_id", "via"))
    assert "earliest" in text and "first amount and time per counterparty" not in text
