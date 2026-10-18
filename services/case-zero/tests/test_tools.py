import json

from case_zero.config import DEMO_AS_OF, DEMO_SEED
from case_zero.ledger import Ledger
from case_zero.tools import TOOL_SPECS

AFTER_DRAIN = "2026-11-10T16:00:00"


def test_tool_specs_cover_thirteen_tools_without_as_of():
    names = [t["name"] for t in TOOL_SPECS]
    assert names == ["get_account", "score", "score_neighbours", "neighbours", "path_between", "shared_entities", "velocity_stats", "agent_till_stats", "kyc_dupe_check", "known_fraud_proximity", "dormant_cohort", "device_safety", "common_point_of_compromise"]
    assert all("as_of" not in t["parameters"]["properties"] for t in TOOL_SPECS)


def test_call_ids_are_sequential(world):
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    assert led.prefetch_score()["call_id"] == "tc_00"
    assert led.call("get_account", acct_id=DEMO_SEED)["call_id"] == "tc_01"
    assert led.call("velocity_stats", acct_id=DEMO_SEED)["call_id"] == "tc_02"


def test_as_of_is_injected(world):
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    out = led.call("neighbours", acct_id=DEMO_SEED, hops=2)
    assert out["ok"]
    assert all(n["first_ts"] <= DEMO_AS_OF for n in out["data"]["neighbours"])
    till = led.call("agent_till_stats", agent_id="AG-0192")["data"]
    assert till["as_of"] == DEMO_AS_OF


def test_budget_exhausted(world):
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF, max_calls=10)
    for _ in range(10):
        assert led.call("get_account", acct_id=DEMO_SEED)["ok"]
    out = led.call("get_account", acct_id=DEMO_SEED)
    assert out["ok"] is False and out["error"] == "tool budget exhausted"
    assert led.budget_left == 0


def test_unknown_tool_and_bad_args_do_not_raise(world):
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    assert led.call("transfer_money", acct_id=DEMO_SEED)["ok"] is False
    assert led.call("velocity_stats", acct="x")["ok"] is False


def test_ledger_records_ids_and_amounts(world):
    led = Ledger(world, DEMO_SEED, AFTER_DRAIN)
    out = led.call("path_between", source="acct_rina", target="acct_till_AG-0192")
    assert out["data"]["found"]
    assert 7900 in led.amounts_bdt and 1850 in led.amounts_bdt
    assert any(i.startswith("txn_") for i in led.ids)
    assert {"acct_rina", "acct_01070", "acct_till_AG-0192"} <= led.ids
    assert "2026-11-10T14:13:00" in led.times
    assert {"source": "acct_rina", "target": "acct_01070"}.items() <= out["graph_delta"]["edges"][0].items()


def test_no_labels_leak(world):
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    calls = [("get_account", {"acct_id": "acct_rina"}), ("score", {"acct_id": DEMO_SEED}), ("neighbours", {"acct_id": DEMO_SEED, "hops": 2}),
             ("path_between", {"source": "acct_rina", "target": "acct_00036"}), ("shared_entities", {"acct_ids": [DEMO_SEED, "acct_00036", "acct_01341"]}),
             ("velocity_stats", {"acct_id": DEMO_SEED}), ("agent_till_stats", {"agent_id": "AG-0192"}), ("kyc_dupe_check", {"acct_id": DEMO_SEED}),
             ("known_fraud_proximity", {"acct_id": DEMO_SEED})]
    for name, kw in calls:
        text = json.dumps(led.call(name, **kw))
        assert "ring_demo_otp" not in text, name
        assert "persona" not in text, name
        if name != "known_fraud_proximity":
            assert "ring_id" not in text, name


def test_ledgers_are_isolated(world):
    a, b = Ledger(world, DEMO_SEED, DEMO_AS_OF), Ledger(world, "acct_rina", AFTER_DRAIN)
    a.call("get_account", acct_id=DEMO_SEED)
    assert b.call("get_account", acct_id="acct_rina")["call_id"] == "tc_01"
    assert DEMO_SEED in a.ids and DEMO_SEED not in b.ids


def test_score_neighbours_returns_model_scored_candidates(world):
    led = Ledger(world, DEMO_SEED, AFTER_DRAIN)
    out = led.call("score_neighbours", acct_id=DEMO_SEED, hops=3, min_score=0.5)
    cands = out["data"]["candidates"]
    assert out["ok"] and cands, out
    assert all(c["probability"] >= 0.5 and c["hops"] <= 3 and c["via"] in ("money", "identity") for c in cands)
    assert [c["probability"] for c in cands] == sorted((c["probability"] for c in cands), reverse=True)
    top = cands[0]
    assert abs(top["probability"] - world.score_at(top["acct_id"], AFTER_DRAIN)["probability"]) < 1e-3
    assert "acct_till_AG-0192" in {c["acct_id"] for c in cands}  # the colluding till, cashed out by 16:00


def test_prefetch_carries_model_candidates(world):
    led = Ledger(world, DEMO_SEED, AFTER_DRAIN)
    data = led.prefetch_score()["data"]
    assert "probability" in data and isinstance(data["model_candidates"], list)


def test_device_safety_degrades_without_risk_api_and_reads_the_standing_verdict(world, monkeypatch):
    import io
    import json as _json

    from case_zero import tools

    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    out = led.call("device_safety", acct_id=DEMO_SEED)
    assert out["ok"] and out["data"]["known"] is False and "not configured" in out["data"]["note"]

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    payload = {"uid": DEMO_SEED, "known": True, "verdict": "BLOCK", "risk_score": 0.95, "flagged_packages": ["com.demo.takanow"], "attestation": "none", "checked_at": "2026-10-16T16:30:37.512885+00:00", "valid_until": "2026-10-17T16:30:37.512885+00:00"}
    monkeypatch.setattr(tools, "RISK_MW_URL", "https://risk-mw.example")
    monkeypatch.setattr(tools.urllib.request, "urlopen", lambda req, timeout: _Resp(_json.dumps(payload).encode()))
    out = led.call("device_safety", acct_id=DEMO_SEED)["data"]
    assert out["known"] is True and out["verdict"] == "BLOCK" and out["flagged_packages"] == ["com.demo.takanow"] and "note" not in out
    assert "checked_at" not in out and "valid_until" not in out  # timestamps outside the world's format never reach the writer
    monkeypatch.setattr(tools.urllib.request, "urlopen", lambda req, timeout: _Resp(b"[1, 2]"))
    assert led.call("device_safety", acct_id=DEMO_SEED)["data"]["known"] is False

    def boom(req, timeout):
        raise tools.urllib.error.URLError("down")

    monkeypatch.setattr(tools.urllib.request, "urlopen", boom)
    out = led.call("device_safety", acct_id=DEMO_SEED)["data"]
    assert out["known"] is False and "unreachable" in out["note"]


def test_device_safety_asks_for_the_phones_report_and_says_whose_it_is(world, monkeypatch):
    """risk-mw answers from its own checks only unless asked, and a BLOCK the phone reported with a
    payment read as known=false. The tool asks for the phone's report too and passes on where the verdict came from
    and its closed-set facts (no package names), so the writer can say "the phone reported" rather than "the bank checked"."""
    import io
    import json as _json

    from case_zero import tools

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    seen = {}
    payload = {"uid": "acct_rina", "known": True, "verdict": "BLOCK", "risk_score": 0.9, "flagged_packages": [], "attestation": "none",
               "checked_at": "", "valid_until": "2026-10-19T10:00:00+00:00", "source": "phone", "facts": ["READS_MESSAGES"]}

    def fake(req, timeout):
        seen["url"] = req.full_url
        return _Resp(_json.dumps(payload).encode())

    monkeypatch.setattr(tools, "RISK_MW_URL", "https://risk-mw.example")
    monkeypatch.setattr(tools.urllib.request, "urlopen", fake)
    out = Ledger(world, DEMO_SEED, DEMO_AS_OF).call("device_safety", acct_id="acct_rina")["data"]
    assert seen["url"].endswith("/v1/appsafety/latest/acct_rina?include_phone=true")
    assert (out["known"], out["verdict"], out["source"], out["facts"]) == (True, "BLOCK", "phone", ["READS_MESSAGES"])
    assert "valid_until" not in out


def test_the_investigator_is_told_how_to_weigh_a_phone_reported_verdict():
    from case_zero import prompts, tools

    spec = next(t for t in tools.TOOL_SPECS if t["name"] == "device_safety")
    assert "source" in spec["description"] and "facts" in spec["description"]
    assert "reported by the customer's phone" in spec["description"]
    assert "source \"phone\"" in prompts.INVESTIGATOR_SYSTEM
