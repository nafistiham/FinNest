"""The replay /api/replay serves: what the console's Case Zero view and ring need from it (2026-10-17).

The console plays this file instead of running Gemini on camera, and builds its ring from each tool result's graph_delta
(apps/console/api/casezero.py `graph`). A re-recording must keep all of this true.
"""

import json
import os
import re
from pathlib import Path

REPLAY = Path(os.environ.get("CASE_ZERO_REPLAY_UNDER_TEST", Path(__file__).resolve().parents[1] / "static" / "replay" / "demo.jsonl"))


def _events() -> list[dict]:
    return [json.loads(line) for line in REPLAY.read_text(encoding="utf-8").splitlines() if line.strip()]


def test_the_replay_starts_on_the_demo_seed_with_a_random_case_id():
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    start = _events()[0]
    assert start["type"] == "run_started"
    assert (start["seed"], start["as_of"]) == (DEMO_SEED, DEMO_AS_OF)
    assert start["model"].startswith("gemini-")
    assert re.fullmatch(r"CZ-[A-Z2-7]{10}", start["case_id"])   # Ids, not the old counter


def test_the_replay_is_a_complete_case_whose_citation_check_passed_first_time():
    events = _events()
    assert events[-1]["type"] == "done"
    validators = [e for e in events if e["type"] == "validator"]
    assert validators and validators[0]["attempt"] == 1 and validators[0]["pass"] is True
    report = next(e for e in events if e["type"] == "report")["report"]
    assert report["status"] == "done" and report["action"] in {"freeze", "watch", "close"}
    assert report["case_id"] == events[0]["case_id"]


def test_every_tool_result_carries_the_graph_the_console_draws():
    events = _events()
    calls = {e["call_id"] for e in events if e["type"] == "tool_call"}
    results = [e for e in events if e["type"] == "tool_result"]
    assert calls and {e["call_id"] for e in results} == calls
    assert all(isinstance(e.get("graph_delta"), dict) for e in results)
    assert all(isinstance(e.get("_t"), (int, float)) for e in events)   # the console's at_s


def test_every_red_flag_cites_a_call_in_the_recording():
    events = _events()
    known = {e["call_id"] for e in events if e["type"] in {"tool_call", "score"}}
    flags = next(e for e in events if e["type"] == "report")["report"]["draft"]["red_flags"]
    assert flags and all(f["evidence"] and set(f["evidence"]) <= known for f in flags)
