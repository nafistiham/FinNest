"""Case ids are CZ- plus ten random base32 characters, not a counter anyone can walk."""

import json
import re

from fake_llm import FakeLLM, draft
from fastapi.testclient import TestClient
from test_app import SCRIPT, events_of
from test_orchestrator import NO_MIN, good_draft

from case_zero.app import create_app
from case_zero.config import DEMO_SEED
from case_zero.ids import CASE_ID_ALPHABET, CASE_ID_LENGTH, new_case_id

CASE_ID_RE = re.compile(r"^CZ-[A-Z2-7]{10}$")
# risk-mw's path pattern for a case id, copied from services/risk-mw/app/routers/investigate.py (CASE_ID_PATTERN):
# a Case Zero id that did not match it would 422 at risk-mw's /v1/investigations/{case_id}.
RISK_MW_CASE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
DRAWS = 10_000


def test_alphabet_is_base32_and_ids_carry_fifty_bits():
    assert CASE_ID_ALPHABET == "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    assert CASE_ID_LENGTH == 10


def test_new_case_id_has_the_cz_prefix_and_ten_base32_characters():
    for _ in range(200):
        case_id = new_case_id()
        assert CASE_ID_RE.match(case_id), case_id
        assert RISK_MW_CASE_ID_PATTERN.match(case_id), case_id


def test_ten_thousand_ids_are_distinct_and_use_the_whole_alphabet():
    ids = [new_case_id() for _ in range(DRAWS)]
    assert len(set(ids)) == DRAWS
    seen = set("".join(i[3:] for i in ids))
    assert seen == set(CASE_ID_ALPHABET)   # a smoke check that no character is excluded, not a statistics test


def _client(world, llm=None, **kw) -> TestClient:
    llm = llm or FakeLLM(SCRIPT + [draft(good_draft())])
    return TestClient(create_app(settings=NO_MIN, world=world, llm=llm, admin_token="t", **kw))


def test_two_started_investigations_get_different_random_ids(world):
    c = _client(world)
    first = c.post("/api/investigations", json={"seed": DEMO_SEED})
    second = c.post("/api/investigations", json={"seed": "acct_99991"})
    assert first.status_code == second.status_code == 202
    ids = [first.json()["case_id"], second.json()["case_id"]]
    assert ids[0] != ids[1]
    assert all(CASE_ID_RE.match(i) for i in ids), ids
    assert "CZ-0001" not in ids
    assert first.json()["stream_url"] == f"/api/investigations/{ids[0]}/events"


def test_the_case_id_never_reaches_gemini(world):
    """The validator's AMOUNT_RE could read an id's digits as a Taka amount, so the id stays out of every prompt."""
    llm = FakeLLM(SCRIPT + [draft(good_draft())])
    c = _client(world, llm=llm)
    events = events_of(c.post("/api/investigate", json={"seed": DEMO_SEED}).text)
    case_id = events[0]["case_id"]
    assert CASE_ID_RE.match(case_id) and events[-1]["type"] == "done"
    assert llm.calls, "the fake LLM was never called"
    assert case_id not in json.dumps(llm.calls, default=str)
    assert c.get(f"/api/cases/{case_id}").status_code == 200


def test_a_colliding_draw_is_redrawn(world):
    ids = iter(["CZ-AAAAAAAAAA", "CZ-AAAAAAAAAA", "CZ-BBBBBBBBBB"])
    c = _client(world, case_ids=ids.__next__)
    first = c.post("/api/investigations", json={"seed": DEMO_SEED}).json()["case_id"]
    second = c.post("/api/investigations", json={"seed": "acct_99991"}).json()["case_id"]
    assert (first, second) == ("CZ-AAAAAAAAAA", "CZ-BBBBBBBBBB")
