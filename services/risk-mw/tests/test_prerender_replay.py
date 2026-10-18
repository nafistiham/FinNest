"""The pre-render hit rate replay, with fakes for score_turn, the pre-render and TTS. No paid call."""

import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts import prerender_replay as replay

SERVICE_DIR = Path(__file__).resolve().parent.parent


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class FakeLedger:
    def __init__(self, key):
        self.key = key

    def hash(self, pending_action=None, band=None):
        return f"{self.key}|{pending_action}|{band}"


def _call(did, archetype="otp_pin_harvest", caller_turns=4):
    turns = []
    for k in range(caller_turns * 2 - 1):
        turns.append({"speaker": "caller" if k % 2 == 0 else "user", "text": f"turn {k}", "ts": k * 6.0})
    return {"id": did, "label": "scam", "archetype": archetype, "split": "held_out", "first_detectable_turn": 2, "turns": turns}


def _band(risk):
    return "almost_certain" if risk >= 0.9 else "likely" if risk >= 0.7 else "possible"


def deps_for(clock, script, *, c0_ms=3200.0, c0=True, gen_ms=1800.0, render=(900.0, 700.0, 800.0, 600.0), score_s=1.0, banded=False):
    """script: per call id, a list per caller turn of (risk, evidence key). Holds at risk >= 0.7 with a pending action."""
    seen = {"prearm": [], "c0": [], "score": []}
    last_hash = {}

    def score_turn(req, settings, uid=None):
        clock.now += score_s
        i = sum(t.speaker == "caller" for t in req.turns) - 1
        steps = script[req.session_id.removeprefix("replay-")]
        risk, key = steps[min(i, len(steps) - 1)]  # past the script, the call stays where it ended
        seen["score"].append((req.session_id, req.pending_action))
        return SimpleNamespace(rolling_score=risk, recommended_action="hold_and_warn" if risk >= 0.7 and req.pending_action else "none",
                               _key=key)

    def state_of(session_id, uid, response):  # one band throughout (so only the evidence moves the hash), or the detector's bands
        band = _band(response.rolling_score) if banded else "likely"
        return SimpleNamespace(ledger=FakeLedger(response._key), risk=response.rolling_score, band=band)

    def maybe_prearm(session_id, uid, state, pending_action, settings, now=None):
        seen["prearm"].append((session_id, now))
        h = state.ledger.hash(pending_action, state.band)
        if state.risk < 0.5 or last_hash.get(session_id) == h:
            return None
        last_hash[session_id] = h
        clock.now += (gen_ms + sum(render)) / 1000
        return SimpleNamespace(stage="C1", ledger_hash=h, gen_ms=gen_ms, render_ms=dict(zip("ATRX", render)), warning_id="w",
                               lines=tuple(SimpleNamespace(role=r) for r in "ATRX"))

    def call_start_pair(session_id, uid, settings, address=None, now=None):
        seen["c0"].append((session_id, now))
        if not c0:
            return None
        clock.now += c0_ms / 1000
        return SimpleNamespace(stage="C0", ledger_hash="c0", gen_ms=1500.0, render_ms={"A": 900.0, "X": 800.0}, warning_id="c",
                               lines=(SimpleNamespace(role="A"), SimpleNamespace(role="X")))

    return replay.Deps(score_turn=score_turn, state_of=state_of, maybe_prearm=maybe_prearm, call_start_pair=call_start_pair), seen


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr(replay, "clock", c)
    monkeypatch.setattr(replay, "wall", lambda: 1_000.0)  # the call starts at 1,000 s; the pre-render sees 1,000 s plus the call's ts
    return c


SETTINGS = SimpleNamespace(prearm_max_per_call=4)


def test_a_pre_render_whose_hash_matches_and_that_finished_before_the_hold_is_fresh(clock):
    script = {"f": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "b")]}
    deps, seen = deps_for(clock, script)
    out = replay.replay_call(_call("f"), deps, SETTINGS, pending_action="send_money", uid="replay")
    assert out["status"] == "fresh" and out["hold"]["turn"] == 6 and out["hold"]["ts"] == 36.0
    (p,) = out["prepared"]
    assert p["started_at"] == pytest.approx(13.0) and p["ready_at"] == pytest.approx(13.0 + 4.8)  # turn 12 s + 1 s scoring + 4.8 s measured
    assert seen["c0"] == [("replay-f", 1_000.0)] and all(a == "send_money" for _, a in seen["score"])
    assert [now for _, now in seen["prearm"]] == pytest.approx([1_001.0, 1_013.0, 1_025.0, 1_037.0])  # turn ts plus its scoring, the crossing too


def test_an_older_pre_render_with_a_different_hash_is_stale(clock):
    deps, _ = deps_for(clock, {"s": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "c")]})
    assert replay.replay_call(_call("s"), deps, SETTINGS, pending_action="send_money", uid="replay")["status"] == "stale"


def test_with_no_refresh_ready_the_call_start_pair_plays(clock):
    deps, _ = deps_for(clock, {"c": [(0.3, "a"), (0.95, "b")]})
    out = replay.replay_call(_call("c"), deps, SETTINGS, pending_action="send_money", uid="replay")
    assert out["status"] == "call_start" and out["c0"]["ready_at"] == pytest.approx(3.2)


def test_a_pre_render_still_rendering_at_the_hold_does_not_count(clock):
    deps, _ = deps_for(clock, {"n": [(0.6, "a"), (0.95, "a")]}, c0=False, gen_ms=9000.0, render=(1000.0, 1000.0, 1000.0, 1000.0))
    out = replay.replay_call(_call("n"), deps, SETTINGS, pending_action="send_money", uid="replay")
    assert out["status"] == "none" and out["prepared"][0]["ready_at"] > out["hold"]["ts"]


def test_a_call_that_never_holds_is_left_out_of_the_hit_rate(clock):
    deps, _ = deps_for(clock, {"q": [(0.3, "a"), (0.4, "a"), (0.5, "a"), (0.6, "a")]})
    out = replay.replay_call(_call("q"), deps, SETTINGS, pending_action="send_money", uid="replay")
    assert out["status"] == "no_hold" and out["hold"] is None


def test_a_submit_one_caller_turn_after_the_crossing_finds_the_warning_armed_on_the_crossing_turn(clock):
    """Review finding (H): the hold fired the moment the risk crossed 0.7, before any pre-render at that band could exist, so
    'fresh' was impossible. The replay now pre-arms on the crossing turn too and reports two submit moments."""
    deps, seen = deps_for(clock, {"b": [(0.3, "a"), (0.6, "b"), (0.9, "b"), (0.9, "b")]}, banded=True)
    out = replay.replay_call(_call("b"), deps, SETTINGS, pending_action="send_money", uid="replay")
    assert out["hold"]["turn"] == 4 and out["status"] == "stale" and out["stale_reason"] == "band"  # submitted at the crossing
    assert out["next"]["turn"] == 6 and out["status_next"] == "fresh"  # submitted at the next caller turn
    assert len(out["prepared"]) == 2 and out["prepared"][-1]["band"] == "almost_certain"


def test_a_call_that_ends_at_the_crossing_reports_the_crossing_for_both_moments(clock):
    deps, _ = deps_for(clock, {"e": [(0.3, "a"), (0.6, "b"), (0.9, "b")]}, banded=True)
    out = replay.replay_call(_call("e", caller_turns=3), deps, SETTINGS, pending_action="send_money", uid="replay")
    assert out["next"] is None and out["status_next"] == out["status"]


def test_readiness_is_judged_when_the_hold_can_fire_after_its_turn_is_scored(clock):
    deps, _ = deps_for(clock, {"r": [(0.6, "a"), (0.95, "a")]}, c0=False, gen_ms=9000.0, render=(700.0, 700.0, 700.0, 700.0), score_s=1.5)
    out = replay.replay_call(_call("r", caller_turns=2), deps, SETTINGS, pending_action="send_money", uid="replay")
    p = out["prepared"][0]
    assert out["hold"]["ts"] < p["ready_at"] <= out["hold"]["at"] and out["status"] == "fresh"


def test_the_replay_reports_hit_rates_timings_and_a_cold_path_estimate(clock, tmp_path):
    rows = [_call("f"), _call("s"), _call("c"), _call("q")]
    script = {"f": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "b")], "s": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "c")],
              "c": [(0.3, "a"), (0.95, "b")], "q": [(0.3, "a"), (0.4, "a"), (0.5, "a"), (0.6, "a")]}
    deps, _ = deps_for(clock, script)
    result = replay.run(rows, deps, SETTINGS, pending_action="send_money", uid="replay")
    assert result["held"] == 3 and result["no_hold"] == ["q"]
    assert result["counts"] == {"fresh": 1, "stale": 1, "call_start": 1, "none": 0}
    assert result["hit_rate"] == {"fresh": 0.333, "stale": 0.333, "call_start": 0.333, "none": 0.0}
    gen = result["generation_ms"]
    assert gen["n"] == 4 + 5 and gen["p50"] == 1800.0 and gen["p95"] == 1800.0  # C0 for four calls; C1 for f, s (two), c and q
    assert result["render_ms_per_line"]["n"] == 4 * 2 + 5 * 4 and result["render_source"] == "prerender"
    assert result["counts_next_turn"] == {"fresh": 2, "stale": 1, "call_start": 0, "none": 0}  # c: armed on its crossing turn
    assert result["stale_reasons"]["at_crossing"] == {"band": 0, "evidence": 1}
    cold = result["cold_path_estimate_ms"]
    assert cold["p50"] == pytest.approx(result["generation_ms"]["p50"] + result["render_ms_per_line"]["p50"] + replay.DELIVERY_MS)
    path = tmp_path / "prerender_replay.json"
    replay.write(result, path)
    assert json.loads(path.read_text(encoding="utf-8"))["counts"]["fresh"] == 1


def test_spend_is_checked_before_each_step_and_recorded_after(clock, tmp_path, monkeypatch):
    from eval import budget

    spent = iter([0.0, 0.001, 0.001, 0.004, 0.004, 0.0045, 0.0045, 0.03, 0.03, 0.031, 0.031, 0.032, 0.032, 0.033] + [0.033] * 50)
    monkeypatch.setattr(replay, "_spent_now", lambda: next(spent))
    ledger = budget.SpendLedger(tmp_path / "s.json", cap_usd=5.0)
    deps, _ = deps_for(clock, {"f": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "b")]})
    replay.replay_call(_call("f"), deps, SETTINGS, pending_action="send_money", uid="replay", ledger=ledger)
    assert ledger.spent() == pytest.approx(0.033)
    tight = budget.SpendLedger(tmp_path / "t.json", cap_usd=0.01)
    with pytest.raises(budget.BudgetExceeded):
        replay.replay_call(_call("f"), deps, SETTINGS, pending_action="send_money", uid="replay", ledger=tight)


def test_twenty_held_out_scam_calls_across_the_archetypes_deterministically():
    rows = [json.loads(line) for line in (SERVICE_DIR / "eval" / "scam_dialogues.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    picked = replay.pick_calls(rows, 20)
    assert len(picked) == 20 and picked == replay.pick_calls(rows, 20)
    assert all(r["split"] == "held_out" and r["label"] == "scam" for r in picked) and len({r["archetype"] for r in picked}) == 6


# --- spreading renders over the two TTS engines ------------------------------------------------------


class RateLimited(Exception):
    pass


def test_renders_alternate_between_the_two_engines_and_are_timed(clock):
    roles = []

    def speak(text_bn, settings, role="tts"):
        roles.append(role)
        clock.now += 0.9
        return b"pcm"
    spreader = replay.EngineSpreader(speak, ("tts", "tts_fallback"))
    assert [spreader("লাইন", None) for _ in range(4)] == [b"pcm"] * 4
    assert roles == ["tts", "tts_fallback", "tts", "tts_fallback"] and spreader.routed
    assert [r["engine"] for r in spreader.renders] == roles and all(r["ms"] == pytest.approx(900.0) and r["ok"] for r in spreader.renders)


def test_a_rate_limited_engine_hands_the_line_to_the_other(clock):
    roles = []

    def speak(text_bn, settings, role="tts"):
        roles.append(role)
        if role == "tts":
            raise RateLimited("429")
        return b"pcm"
    spreader = replay.EngineSpreader(speak, ("tts", "tts_fallback"))
    assert spreader("লাইন", None) == b"pcm" and roles == ["tts", "tts_fallback"]
    assert [(r["engine"], r["ok"]) for r in spreader.renders] == [("tts", False), ("tts_fallback", True)]


def test_a_streaming_speak_is_timed_to_its_last_chunk_and_a_lazy_429_moves_engines(clock):
    def speak(text_bn, settings, role="tts"):
        if role == "tts":
            raise RateLimited("429")
            yield b""  # a generator: the error arrives on the first next()
        for _ in range(3):
            clock.now += 0.2
            yield b"x"
    spreader = replay.EngineSpreader(speak, ("tts", "tts_fallback"))
    assert b"".join(spreader("লাইন", None)) == b"xxx"
    assert spreader.renders[-1]["engine"] == "tts_fallback" and spreader.renders[-1]["ms"] == pytest.approx(600.0)


def test_an_engine_that_is_not_there_is_dropped_for_the_rest_of_the_replay(clock):
    roles = []

    def speak(text_bn, settings, role="tts"):
        roles.append(role)
        if role == "tts_fallback":
            raise RuntimeError("404 model not found")
        return b"pcm"
    spreader = replay.EngineSpreader(speak, ("tts", "tts_fallback"))
    for _ in range(4):
        spreader("লাইন", None)
    assert roles == ["tts", "tts_fallback", "tts", "tts", "tts"] and spreader.engines == ("tts",)


def test_a_speak_that_cannot_be_told_the_engine_is_passed_through(clock):
    spreader = replay.EngineSpreader(lambda text_bn, settings: b"pcm", ("tts", "tts_fallback"))
    assert spreader("লাইন", None) == b"pcm" and spreader.routed is False and spreader.renders[0]["engine"] is None


def test_the_spreader_is_installed_on_app_tts_for_the_replay_and_removed_after():
    from app import tts

    original = tts.speak
    with replay.spreading(("tts", "tts_fallback")) as spreader:
        assert tts.speak is spreader
    assert tts.speak is original


# --- the command line --------------------------------------------------------------------------------


def test_dry_run_lists_the_calls_and_the_reserve_and_calls_nothing(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(replay, "real_deps", lambda: pytest.fail("a dry run must not build the paid pipeline"))
    replay.main(["--dry-run", "--spend-file", str(tmp_path / "s.json"), "--out", str(tmp_path / "out.json")])
    out = capsys.readouterr().out
    assert "20 held-out scam calls" in out and "reserve" in out and "tts_fallback" in out
    assert list(tmp_path.iterdir()) == []


def test_answers_help_by_its_path():
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    run = subprocess.run([sys.executable, "scripts/prerender_replay.py", "--help"], cwd=SERVICE_DIR, env=env, text=True, capture_output=True,
                         timeout=60)
    assert run.returncode == 0 and "usage" in run.stdout, run.stderr[-400:]


def test_a_restarted_replay_skips_the_calls_it_already_paid_for(clock, tmp_path):
    script = {"f": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "b")], "s": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "c")],
              "c": [(0.3, "a"), (0.95, "b")]}
    deps, seen = deps_for(clock, script)
    progress = tmp_path / "replay.progress.jsonl"
    replay.run([_call("f"), _call("s")], deps, SETTINGS, pending_action="send_money", uid="replay", progress=progress)
    scored = len(seen["score"])
    result = replay.run([_call("f"), _call("s"), _call("c")], deps, SETTINGS, pending_action="send_money", uid="replay", progress=progress)
    assert [c["id"] for c in result["calls"]] == ["f", "s", "c"] and len(progress.read_text(encoding="utf-8").splitlines()) == 3
    assert {sid for sid, _ in seen["score"][scored:]} == {"replay-c"}


def test_a_tripped_guard_stops_the_replay_and_keeps_what_it_paid_for(clock, tmp_path):
    from eval import intervention_eval

    deps, _ = deps_for(clock, {"f": [(0.3, "a"), (0.6, "b"), (0.6, "b"), (0.9, "b")], "s": [(0.3, "a"), (0.95, "b")]})
    guard = intervention_eval.ReadCostGuard()
    progress = tmp_path / "replay.progress.jsonl"
    real = deps.score_turn

    def tripping(req, settings, uid=None):
        out = real(req, settings, uid)
        if req.session_id == "replay-s":
            guard.tripped = 0.003
        return out
    deps = replay.Deps(score_turn=tripping, state_of=deps.state_of, maybe_prearm=deps.maybe_prearm, call_start_pair=deps.call_start_pair)
    result = replay.run([_call("f"), _call("s")], deps, SETTINGS, pending_action="send_money", uid="replay", progress=progress, guard=guard)
    assert [c["id"] for c in result["calls"]] == ["f"] and "per-read cost" in result["stopped"]


def test_the_paid_replay_starts_no_real_timers(monkeypatch):
    """It runs each call on its own ts timeline: a real trailing timer would refresh outside it, and outside the eval ledger."""
    from app import prerender

    monkeypatch.setattr(prerender, "TRAILING", prerender.Trailing())
    replay.real_deps()
    assert prerender.TRAILING.schedule(("apa_warnings", "k"), 0.01, lambda: None) is False
