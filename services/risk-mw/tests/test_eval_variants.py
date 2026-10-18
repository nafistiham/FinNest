"""Wilson intervals, the adversarial set, the variant re-measure and the comparison table. No paid call."""

import json
import re
from pathlib import Path
from types import SimpleNamespace
from typing import Literal

import pytest
from pydantic import BaseModel

from eval import metrics

SERVICE_DIR = Path(__file__).resolve().parent.parent


# --- intervals ------------------------------------------------------------------------------------


def test_wilson_intervals_match_the_reports_numbers():
    """The report's own figures: 30 of 33 scams caught is 0.76-0.97; 1 of 17 benign calls flagged is 1-27%."""
    lo, hi = metrics.wilson(30, 33)
    assert (round(lo, 2), round(hi, 2)) == (0.76, 0.97)
    lo, hi = metrics.wilson(1, 17)
    assert (round(lo, 2), round(hi, 2)) == (0.01, 0.27)
    assert metrics.wilson(0, 0) is None
    assert metrics.wilson(0, 10)[0] == 0.0 and metrics.wilson(10, 10)[1] == 1.0


def test_intervals_and_pass_rate_from_outcomes():
    outcomes = [{"label": "scam", "detected_turn": 2, "first_detectable_turn": 1}, {"label": "scam", "detected_turn": None, "first_detectable_turn": 1},
                {"label": "benign", "detected_turn": None, "first_detectable_turn": None}]
    ci = metrics.intervals(outcomes)
    assert ci["recall"] == metrics.wilson(1, 2) and ci["precision"] == metrics.wilson(1, 1) and ci["benign_false_positive_rate"] == metrics.wilson(0, 1)
    rate = metrics.pass_rate(outcomes[:2])
    assert rate == {"n": 2, "passed": 1, "rate": 0.5, "ci": metrics.wilson(1, 2), "median_turns_after_first_detectable": 1}


# --- the adversarial set --------------------------------------------------------------------------

ADVERSARIAL = SERVICE_DIR / "eval" / "adversarial_dialogues.jsonl"
TRIGGER_WORDS = re.compile(r"otp|ওটিপি|কোড|code|পিন|\bpin\b|password|পাসওয়ার্ড|ভেরিফিকেশন|verification", re.IGNORECASE)


def _adversarial() -> list[dict]:
    return [json.loads(line) for line in ADVERSARIAL.read_text(encoding="utf-8").splitlines() if line.strip()]


def test_the_adversarial_set_has_the_held_out_shape():
    rows, held = _adversarial(), json.loads((SERVICE_DIR / "eval" / "scam_dialogues.jsonl").read_text(encoding="utf-8").splitlines()[0])
    assert len(rows) == 10 and len({r["id"] for r in rows}) == 10
    for r in rows:
        assert set(held) <= set(r), r["id"]
        assert r["label"] == "scam" and r["split"] == "adversarial" and r["native_check"] == "pending" and r["channel"] in ("bangla", "banglish")
        assert all(set(t) == {"speaker", "text", "ts"} and t["speaker"] in ("caller", "user") and t["text"].strip() for t in r["turns"])
        ts = [t["ts"] for t in r["turns"]]
        assert ts == sorted(ts) and ts[0] == 0.0
        assert r["turns"][r["first_detectable_turn"]]["speaker"] == "caller"
        assert sum(t["speaker"] == "caller" for t in r["turns"]) >= 5, f"{r['id']}: the request must be spread over five caller turns"


def test_the_adversarial_set_covers_the_moves_scammers_use_against_a_window_and_a_keyword_list():
    rows = _adversarial()
    moves = {m for r in rows for m in r["adversarial"]}
    assert {"split_request", "no_trigger_words", "injection", "silent_scammer", "courier_code", "stipend_otp"} <= moves
    for r in rows:
        caller = " ".join(t["text"] for t in r["turns"] if t["speaker"] == "caller")
        if "no_trigger_words" in r["adversarial"]:
            assert not TRIGGER_WORDS.search(caller), f"{r['id']}: {TRIGGER_WORDS.search(caller).group(0)}"
        if "injection" in r["adversarial"]:
            assert re.search(r"ভরসা|bhorosha", caller, re.IGNORECASE) and re.search(r"নির্দেশ|instruction", caller, re.IGNORECASE)
    silent = next(r for r in rows if "silent_scammer" in r["adversarial"])
    tail = [t for t in silent["turns"][silent["first_detectable_turn"] + 1:] if t["speaker"] == "caller"]
    assert len(tail) >= 2 and all(len(t["text"].split()) <= 4 for t in tail[-2:])  # the caller has gone quiet while the victim acts


# --- the variant re-measure (eval/intervention_eval.py --variant) ----------------------------------


class _Extraction(BaseModel):
    verdict: Literal["SAFE", "UNCERTAIN", "SCAM"]
    confidence: float


class FakeClock:
    """A clock per thread that only the fake model moves: dialogues replay in parallel, each turn on its own time."""

    def __init__(self):
        import threading

        self.local = threading.local()

    @property
    def now(self):
        return getattr(self.local, "now", 0.0)

    @now.setter
    def now(self, value):
        self.local.now = value

    def __call__(self):
        return self.now


def _row(did, label, texts, first=None, archetype="otp_pin_harvest", split="held_out"):
    return {"id": did, "label": label, "archetype": archetype, "channel": "bangla", "first_detectable_turn": first, "split": split,
            "turns": [{"speaker": s, "text": t, "ts": i * 6.0} for i, (s, t) in enumerate(texts)]}


ROWS = [_row("s1", "scam", [("caller", "হ্যালো"), ("user", "জি"), ("caller", "কোডটা বলুন")], first=2),
        _row("s2", "scam", [("caller", "শুনুন"), ("user", "জি"), ("caller", "একটু কথা ছিল")], first=2),
        _row("b1", "benign", [("caller", "পার্সেল এসেছে"), ("user", "আসছি")], archetype="benign_delivery")]
BASELINE = {"outcomes": [{"id": "s1", "detected_turn": 2}, {"id": "s2", "detected_turn": None}, {"id": "b1", "detected_turn": 0}]}


def _verdict(contents: str, workhorse: bool) -> tuple[str, float]:
    if "কোড" in contents:
        return "SCAM", 0.95
    if "কথা" in contents:
        return ("SCAM", 0.92) if workhorse else ("UNCERTAIN", 0.6)
    return "SAFE", 0.1


@pytest.fixture
def detector(monkeypatch):
    """The detector as it will be after merge: score_turn reads settings.scam_variant and makes its one read through
    scam_variants.extract, whose default calls are genai_client.call and scam_variants.call_with_thoughts (both faked)."""
    from app import genai_client, scam, scam_variants
    from app.contracts import ScamTurnResponse
    from eval import intervention_eval

    clock, seen, calls = FakeClock(), [], []
    monkeypatch.setattr(intervention_eval, "clock", clock)

    def model(task, role_name, contents, schema=None, **kwargs):
        calls.append((task, role_name))
        workhorse = role_name == "workhorse"
        clock.now += 2.5 if workhorse else 0.8
        verdict, conf = _verdict(contents, workhorse)
        return SimpleNamespace(text=json.dumps({"verdict": verdict, "confidence": conf}), parsed=None, latency_ms=2500.0 if workhorse else 800.0,
                               cost_usd=0.004 if workhorse else 0.001, thoughts="claims an office, asks to talk")

    def score_turn(req, settings, uid=None):
        seen.append(settings.scam_variant)
        last = [t for t in req.turns if t.speaker == "caller"][-1].text
        v = scam_variants.extract(settings.scam_variant, prefix="P", transcript_part=last, schema=_Extraction, settings=settings).extraction
        rolling = v["confidence"] if v["verdict"] == "SCAM" else min(v["confidence"], 0.69)
        return ScamTurnResponse(scam_type="otp_pin_harvest", urgency="none", requested_secret="none", confidence=v["confidence"],
                                evidence_quote=last, recommended_action="none", rolling_score=rolling)

    monkeypatch.setattr(scam, "score_turn", score_turn)
    monkeypatch.setattr(genai_client, "call", model)
    monkeypatch.setattr(scam_variants, "call_with_thoughts", model)
    return SimpleNamespace(seen=seen, calls=calls, clock=clock)


def test_each_variant_replays_every_caller_turn_through_score_turn_with_its_own_setting(detector):
    from eval import intervention_eval

    v1, v4 = intervention_eval.run_variants(("v1", "v4"), ROWS, ledger=None, per_role=2, baseline=BASELINE, sets=("held_out",))
    assert sorted(set(detector.seen)) == ["v1", "v4"] and detector.seen.count("v1") == 5  # caller turns only
    assert {o["id"]: o["detected_turn"] for o in v1["outcomes"]} == {"s1": 2, "s2": None, "b1": None}
    assert {o["id"]: o["detected_turn"] for o in v4["outcomes"]} == {"s1": 2, "s2": 2, "b1": None}  # the second read caught s2
    assert v1["metrics"]["recall"] == 0.5 and v4["metrics"]["recall"] == 1.0 and v4["metrics"]["benign_false_positive_rate"] == 0.0
    assert tuple(v4["intervals"]["recall"]) == metrics.wilson(2, 2)
    assert v1["median_turns_to_detection"] == 2


def test_the_variant_report_has_latency_cost_flips_and_escalation(detector):
    from eval import intervention_eval

    v1, v4 = intervention_eval.run_variants(("v1", "v4"), ROWS, ledger=None, per_role=2, baseline=BASELINE, sets=("held_out",))
    assert v1["turn_ms"]["p50"] == 800.0 and v1["turn_ms"]["p95"] == 800.0
    assert v4["turn_ms"]["p95"] == 800.0 and v4["turn_wall_ms"]["p95"] == 3300.0  # the background second read is not on the turn's path
    assert v1["cost"]["total_usd"] == pytest.approx(0.005) and v1["cost"]["per_call_usd"] == pytest.approx(0.005 / 3, abs=1e-6)
    assert v4["cost"]["total_usd"] == pytest.approx(0.009) and v4["cost"]["model_calls"] == 6
    assert v1["flip_vs_v0"] == {"n": 3, "flips": 1, "rate": 0.333, "now_flagged": [], "now_clear": ["b1"]}
    assert v4["flip_vs_v0"]["now_flagged"] == ["s2"] and v4["flip_vs_v0"]["flips"] == 2
    esc = v4["escalation"]
    assert esc["escalated"] == 1 and esc["share"] == 0.2 and esc["lands_after_ms"]["p50"] == 2500.0 and esc["changed_share"] == 1.0
    assert v1["escalation"]["escalated"] == 0 and v1["escalation"]["lands_after_ms"] is None


def test_a_production_callback_is_measured_and_its_verdict_counts_from_the_next_turn(detector, monkeypatch):
    """When score_turn hands v4's second read to a callback (production), the eval runs that callback before the turn returns:
    the turn answers with the first read, and the landed verdict raises the call's risk from the next caller turn on."""
    from app import scam, scam_variants
    from app.contracts import ScamTurnResponse
    from eval import intervention_eval

    landed: dict[str, float] = {}

    def score_turn(req, settings, uid=None):
        last = [t for t in req.turns if t.speaker == "caller"][-1].text

        def on_escalation(esc):
            if esc["extraction"] and esc["verdict"] == "SCAM":
                landed[req.session_id] = esc["extraction"]["confidence"]
        v = scam_variants.extract(settings.scam_variant, prefix="P", transcript_part=last, schema=_Extraction, settings=settings,
                                  on_escalation=on_escalation).extraction
        now = v["confidence"] if v["verdict"] == "SCAM" else min(v["confidence"], 0.69)
        rolling = max(now, landed.get(req.session_id, 0.0))
        return ScamTurnResponse(scam_type="x", urgency="none", requested_secret="none", confidence=v["confidence"], evidence_quote=last,
                                recommended_action="none", rolling_score=rolling)
    monkeypatch.setattr(scam, "score_turn", score_turn)
    rows = [_row("late", "scam", [("caller", "একটু কথা ছিল"), ("user", "জি"), ("caller", "শুনুন")], first=0),
            _row("last", "scam", [("caller", "শুনুন"), ("user", "জি"), ("caller", "একটু কথা ছিল")], first=2)]
    (v4,) = intervention_eval.run_variants(("v4",), rows, ledger=None, per_role=2, baseline=None, sets=("held_out",))
    assert {o["id"]: o["detected_turn"] for o in v4["outcomes"]} == {"late": 2, "last": None}
    assert v4["escalation"]["escalated"] == 2 and v4["escalation"]["lands_after_ms"]["p50"] == 2500.0
    assert v4["escalation"]["lands_before_next_caller_turn"] == 1.0  # 0.8 s + 2.5 s lands well inside the 12 s to the next caller turn


def test_adversarial_dialogues_are_reported_as_a_pass_rate_apart_from_the_held_out_metrics(detector):
    from eval import intervention_eval

    rows = ROWS + [_row("a1", "scam", [("caller", "শুনুন"), ("user", "জি"), ("caller", "কোডটা বলুন")], first=2, split="adversarial"),
                   _row("a2", "scam", [("caller", "শুনুন"), ("user", "জি"), ("caller", "এখনই")], first=2, split="adversarial")]
    (v1,) = intervention_eval.run_variants(("v1",), rows, ledger=None, per_role=2, baseline=None, sets=("held_out", "adversarial"))
    assert v1["n"] == {"held_out": 3, "adversarial": 2} and v1["metrics"]["n_scam"] == 2
    assert v1["adversarial"]["passed"] == 1 and v1["adversarial"]["rate"] == 0.5 and v1["adversarial"]["missed"] == ["a2"]
    assert v1["flip_vs_v0"] is None


def _quota_error():
    from google.genai import errors

    return errors.APIError(429, {"error": {"message": "quota"}})


def test_a_rate_limited_read_backs_off_and_is_retried_instead_of_scoring_uncertain():
    from eval import intervention_eval

    slept, attempts = [], []

    def flaky(task, role_name, *a, **k):
        attempts.append(role_name)
        if len(attempts) < 3:
            raise _quota_error()
        return SimpleNamespace(cost_usd=0.001)
    limits = intervention_eval.RoleLimits(per_role=2, retries=5, backoff_s=1.0, sleep=slept.append)
    meter = intervention_eval.TurnMeter()
    token = intervention_eval.METER.set(meter)
    try:
        assert limits.wrap(flaky)("scam_turn", "volume", "x").cost_usd == 0.001
    finally:
        intervention_eval.METER.reset(token)
    assert len(attempts) == 3 and limits.rate_limited == 2 and meter.rate_limited == 2 and meter.cost_usd == 0.001
    assert len(slept) == 2 and slept[1] > slept[0] * 1.5  # exponential back-off

    def other(*a, **k):
        raise ValueError("not a quota error")
    with pytest.raises(ValueError):
        limits.wrap(other)("scam_turn", "volume", "x")


def test_the_back_off_gives_up_after_its_retries():
    from google.genai import errors

    from eval import intervention_eval

    limits = intervention_eval.RoleLimits(per_role=1, retries=2, backoff_s=0.0, sleep=lambda s: None)

    def always(*a, **k):
        raise _quota_error()
    with pytest.raises(errors.APIError):
        limits.wrap(always)("scam_turn", "volume", "x")
    assert limits.rate_limited == 2


def test_a_semaphore_per_role_bounds_concurrent_reads():
    import threading
    import time

    from eval import intervention_eval

    limits = intervention_eval.RoleLimits(per_role=2)
    active, peak, lock = {"volume": 0, "workhorse": 0}, {"volume": 0, "workhorse": 0}, threading.Lock()

    def read(task, role_name, *a, **k):
        with lock:
            active[role_name] += 1
            peak[role_name] = max(peak[role_name], active[role_name])
        time.sleep(0.02)
        with lock:
            active[role_name] -= 1
        return SimpleNamespace(cost_usd=0.0)
    guarded = limits.wrap(read)
    threads = [threading.Thread(target=guarded, args=("t", role, "x")) for role in ["volume"] * 8 + ["workhorse"] * 4]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert peak == {"volume": 2, "workhorse": 2}


def test_the_spend_cap_stops_a_variant_run_and_says_what_it_skipped(detector, tmp_path):
    from eval import budget, intervention_eval

    ledger = budget.SpendLedger(tmp_path / "spend.json", cap_usd=0.0035)
    (v1,) = intervention_eval.run_variants(("v1",), ROWS, ledger=ledger, per_role=1, baseline=None, sets=("held_out",))
    assert ledger.spent() <= 0.0035 and v1["incomplete"]["skipped"] and v1["incomplete"]["reason"]
    assert len(v1["outcomes"]) + len(v1["incomplete"]["skipped"]) == 3


def test_a_dialogue_that_breaks_is_named_and_the_rest_of_the_paid_run_is_kept(detector, monkeypatch):
    from app import scam
    from eval import intervention_eval

    real = scam.score_turn

    def flaky(req, settings, uid=None):
        if req.session_id.endswith("b1"):
            raise RuntimeError("store down")
        return real(req, settings, uid)
    monkeypatch.setattr(scam, "score_turn", flaky)
    (v1,) = intervention_eval.run_variants(("v1",), ROWS, ledger=None, per_role=2, baseline=None, sets=("held_out",))
    assert v1["incomplete"]["skipped"] == ["b1 (RuntimeError)"] and [o["id"] for o in v1["outcomes"]] == ["s1", "s2"]


def test_dry_run_lists_the_calls_and_the_reserve_and_calls_nothing(monkeypatch, tmp_path, capsys):
    from app import scam
    from eval import intervention_eval

    monkeypatch.setattr(scam, "score_turn", lambda *a, **k: pytest.fail("a dry run must not score"))
    monkeypatch.setattr(intervention_eval, "RESULTS", tmp_path)
    intervention_eval.main(["--variant", "v4", "v5", "--set", "adversarial", "--dry-run", "--spend-file", str(tmp_path / "s.json")])
    out = capsys.readouterr().out
    turns = sum(t["speaker"] == "caller" for r in _adversarial() for t in r["turns"])
    assert "v4" in out and "v5" in out and f"{turns} caller turns" in out and "reserve" in out and "intervention.json" in out
    assert list(tmp_path.iterdir()) == []  # nothing written, not even the spend file


def test_the_v0_baseline_is_never_overwritten(monkeypatch, tmp_path, detector):
    from eval import intervention_eval

    (tmp_path / "intervention.json").write_text('{"n": 50}', encoding="utf-8")
    dialogues = tmp_path / "d.jsonl"
    dialogues.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in ROWS), encoding="utf-8")
    monkeypatch.setattr(intervention_eval, "RESULTS", tmp_path)
    monkeypatch.setattr(intervention_eval, "DIALOGUES", dialogues)
    monkeypatch.setattr(intervention_eval, "require_gemini", lambda: None)
    with pytest.raises(SystemExit) as stop:
        intervention_eval.main(["--split", "held_out"])  # a plain classifier run would rewrite V0
    assert stop.value.code == 2
    intervention_eval.main(["--variant", "v1", "--set", "held_out", "--spend-file", str(tmp_path / "s.json")])
    assert (tmp_path / "intervention.json").read_text(encoding="utf-8") == '{"n": 50}'
    saved = json.loads((tmp_path / "variants" / "v1.json").read_text(encoding="utf-8"))
    assert saved["variant"] == "v1" and saved["n"]["held_out"] == 3 and (tmp_path / "variants" / "v1.md").exists()
    assert "Wilson" in (tmp_path / "variants" / "v1.md").read_text(encoding="utf-8")


def _variant_result(v, recall, fpr, p95, *, adversarial=0.7, cost=0.002, escalation=None, incomplete=None):
    return {"variant": v, "reads": f"reads of {v}", "n": {"held_out": 50, "adversarial": 10},
            "metrics": {"precision": 0.95, "recall": recall, "benign_false_positive_rate": fpr, "median_turns_to_detection": 4.0,
                        "median_turns_after_first_detectable": 1.0, "n_scam": 33, "n_benign": 17},
            "intervals": {"precision": [0.85, 0.99], "recall": [round(recall - 0.12, 2), min(1.0, round(recall + 0.05, 2))],
                          "benign_false_positive_rate": [0.01, 0.27]},
            "adversarial": {"n": 10, "passed": int(adversarial * 10), "rate": adversarial, "ci": [0.4, 0.9], "missed": []},
            "median_turns_to_detection": 4.0, "turn_ms": {"p50": p95 * 0.7, "p95": p95, "n": 232, "path": "synchronous"},
            "cost": {"per_call_usd": cost, "per_turn_usd": cost / 4, "total_usd": cost * 60, "model_calls": 232},
            "flip_vs_v0": {"n": 50, "flips": 3, "rate": 0.06, "now_flagged": [], "now_clear": []},
            "escalation": escalation or {"turns": 232, "escalated": 0, "share": 0.0, "lands_after_ms": None, "changed_share": None},
            "rate_limited": 0, "incomplete": incomplete}


V0_SAVED = {"n": 50, "model": "gemini-3.5-flash-lite", "classifier_cost_usd": 0.1151, "classifier_turn_ms": {"p50": 1123.3, "p95": 1612.2},
            "metrics": {"precision": 0.968, "recall": 0.909, "benign_false_positive_rate": 0.059, "median_turns_to_detection": 4.0},
            "outcomes": [{"id": f"s{i}", "label": "scam", "detected_turn": 2 if i < 30 else None} for i in range(33)]
            + [{"id": f"b{i}", "label": "benign", "detected_turn": 1 if i == 0 else None} for i in range(17)]}


def _results():
    lands = {"turns": 232, "escalated": 40, "share": 0.172, "lands_after_ms": {"p50": 2600.0, "p95": 3900.0}, "changed_share": 0.4,
             "lands_before_next_caller_turn": 0.9}
    return [_variant_result("v1", 0.90, 0.06, 1500), _variant_result("v2", 0.95, 0.06, 1700), _variant_result("v3", 0.97, 0.06, 3000),
            _variant_result("v4", 0.96, 0.12, 1600, escalation=lands), _variant_result("v5", 0.95, 0.03, 2400, cost=0.005)]


def test_the_selection_rule_is_best_recall_within_the_fpr_and_latency_limits():
    from eval import variant_table

    rows = [variant_table.variant_row(r) for r in _results()]
    sel = variant_table.select(rows)
    assert sel["winner"] == "v5"  # ties v2 on recall, wins on the lower benign FPR
    assert set(sel["eligible"]) == {"v1", "v2", "v5"}
    assert "p95" in sel["excluded"]["v3"] and "FPR" in sel["excluded"]["v4"]
    assert "v2" in sel["recall_overlaps_winner"]  # the intervals overlap: not a significant difference at this size


def test_no_eligible_variant_means_no_winner_and_v1_stays():
    from eval import variant_table

    rows = [variant_table.variant_row(_variant_result("v1", 0.9, 0.2, 1500)), variant_table.variant_row(_variant_result("v2", 0.9, 0.05, 2600)),
            variant_table.variant_row(_variant_result("v3", 0.99, 0.0, 900, incomplete={"skipped": ["x"], "reason": "cap"}))]
    sel = variant_table.select(rows)
    assert sel["winner"] is None and "incomplete" in sel["excluded"]["v3"] and "v1" in sel["note"]


def test_the_table_reads_the_variant_files_and_v0_and_writes_the_comparison(tmp_path):
    from eval import variant_table

    (tmp_path / "variants").mkdir()
    for r in _results()[:4] + [_results()[4]]:
        (tmp_path / "variants" / f"{r['variant']}.json").write_text(json.dumps(r), encoding="utf-8")
    (tmp_path / "variants" / "v2.json").unlink()
    (tmp_path / "intervention.json").write_text(json.dumps(V0_SAVED), encoding="utf-8")
    table = variant_table.main(["--results-dir", str(tmp_path)])
    assert table["missing"] == ["v2"] and table["selection"]["winner"] == "v5"
    v0 = next(r for r in table["rows"] if r["name"] == "V0")
    assert v0["recall"] == 0.909 and v0["p95_ms"] == 1612.2 and v0["recall_ci"] == list(metrics.wilson(30, 33))
    assert v0["cost_per_call_usd"] == pytest.approx(0.1151 / 50, abs=1e-6)
    saved = json.loads((tmp_path / "variant_comparison.json").read_text(encoding="utf-8"))
    assert saved["selection"]["winner"] == "v5"
    md = (tmp_path / "variant_comparison.md").read_text(encoding="utf-8")
    assert "Selection rule" in md and "RISK_MW_SCAM_VARIANT=v5" in md and "2600.0" in md  # v4's background verdict, reported apart


def test_the_comparison_answers_help_by_its_path():
    import os
    import subprocess
    import sys

    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    run = subprocess.run([sys.executable, "eval/variant_table.py", "--help"], cwd=SERVICE_DIR, env=env, text=True, capture_output=True, timeout=60)
    assert run.returncode == 0 and "usage" in run.stdout, run.stderr[-400:]


def test_sets_load_the_held_out_and_the_adversarial_dialogues():
    from eval import intervention_eval

    held, adversarial, both = (intervention_eval.load_rows(s) for s in ("held_out", "adversarial", "both"))
    assert {r["split"] for r in held} == {"held_out"} and len(held) == 50
    assert {r["split"] for r in adversarial} == {"adversarial"} and len(adversarial) == 10 and len(both) == 60


# --- review findings (H) and the parent's run rules: resumable output, an early cache check, honest latency -------------


def test_a_restarted_run_skips_the_dialogues_it_already_paid_for(detector, tmp_path):
    from eval import intervention_eval

    progress = tmp_path / "progress.jsonl"
    intervention_eval.run_variants(("v1",), ROWS[:2], per_role=2, progress=progress)
    paid = len(detector.calls)
    assert len(progress.read_text(encoding="utf-8").splitlines()) == 2 and paid == 4  # two dialogues, two caller turns each
    (again,) = intervention_eval.run_variants(("v1",), ROWS, per_role=2, progress=progress)
    assert len(detector.calls) == paid + 1  # only b1's one caller turn is read again
    assert [o["id"] for o in again["outcomes"]] == ["s1", "s2", "b1"] and again["incomplete"] is None


def test_a_run_stops_early_when_its_first_reads_cost_more_than_twice_the_cached_price(detector):
    from eval import intervention_eval

    assert intervention_eval.ReadCostGuard().threshold_usd == pytest.approx(2 * 0.0007)
    guard = intervention_eval.ReadCostGuard(threshold_usd=0.0005, after=2)  # the fake volume read costs $0.001
    (out,) = intervention_eval.run_variants(("v1",), ROWS, per_role=1, guard=guard)
    assert guard.tripped and out["incomplete"] and "per-read cost" in out["incomplete"]["reason"]
    assert len(detector.calls) < 5  # it stopped instead of reading every turn


def test_a_429_is_backed_off_and_metered_by_the_role_limits_not_slept_inside_the_client(monkeypatch):
    from google.genai import errors

    from app import genai_client
    from app.settings import Settings
    from eval import intervention_eval

    usage = SimpleNamespace(prompt_token_count=100, candidates_token_count=10, thoughts_token_count=0, cached_content_token_count=0)
    answers = [errors.ClientError(429, {"error": {"code": 429, "message": "Resource exhausted", "status": "RESOURCE_EXHAUSTED"}})]

    def generate_content(model, contents, config):
        if answers:
            raise answers.pop(0)
        return SimpleNamespace(text="{}", parsed=None, usage_metadata=usage, candidates=[])
    client = SimpleNamespace(models=SimpleNamespace(generate_content=generate_content), caches=None)
    monkeypatch.setattr(genai_client, "_client", lambda location=None: client)
    monkeypatch.setattr(genai_client, "select_backend", lambda s: "vertex")
    monkeypatch.setattr(genai_client, "get_settings", lambda: Settings(genai_enabled=True, project_id="p"))
    slept = []
    monkeypatch.setattr(genai_client.time, "sleep", lambda s: slept.append(s))
    limits = intervention_eval.RoleLimits(per_role=1, backoff_s=0.01, sleep=lambda s: None)
    meter = intervention_eval.TurnMeter()
    token = intervention_eval.METER.set(meter)
    try:
        limits.wrap(genai_client.call)("scam_turn", "volume", "x", timeout_s=4.0)
    finally:
        intervention_eval.METER.reset(token)
    assert meter.rate_limited == 1 and limits.rate_limited == 1 and slept == []  # no 0.4 s sleep hidden in the turn's latency


def test_v5s_synchronous_path_is_the_first_read_and_the_slowest_sample_not_the_queueing():
    from eval import intervention_eval

    meter = intervention_eval.TurnMeter()
    esc = {"kind": "self_consistency", "background": False, "latency_ms": 1000.0, "wall_ms": 1217.0}
    assert intervention_eval.sync_ms(1.2667, meter, home=1, esc=esc) == pytest.approx(1049.7, abs=0.5)
    assert intervention_eval.sync_ms(1.0, meter, home=1, esc=None) == pytest.approx(1000.0)


def test_a_failed_background_read_is_not_counted_on_the_synchronous_path():
    from app import scam_variants
    from eval import intervention_eval

    clock = {"t": 0.0}
    limits = intervention_eval.RoleLimits(per_role=1)

    def failing(task, role_name, *a, **k):
        clock["t"] += 2.0
        raise TimeoutError("slow")
    meter = intervention_eval.TurnMeter()
    token = intervention_eval.METER.set(meter)
    old = intervention_eval.clock
    intervention_eval.clock = lambda: clock["t"]
    try:
        with pytest.raises(TimeoutError):
            limits.wrap(failing)(scam_variants.ESCALATION_TASK, "workhorse", "x")
    finally:
        intervention_eval.METER.reset(token)
        intervention_eval.clock = old
    assert meter.background_s == pytest.approx(2.0)


def test_a_variant_run_on_fewer_rows_is_not_compared_with_full_runs():
    from eval import variant_table

    def row(name, n, recall=0.9):
        return {"name": name, "n_held_out": n, "recall": recall, "fpr": 0.05, "p95_ms": 1000.0, "incomplete": False, "recall_ci": [0.8, 0.95],
                "adversarial_rate": 1.0, "cost_per_call_usd": 0.003}
    sel = variant_table.select([row("v1", 50), row("v2", 40, recall=1.0), row("v3", 50)])
    assert "v2" in sel["excluded"] and "rows" in sel["excluded"]["v2"] and sel["winner"] in ("v1", "v3")


def test_turn_reserves_cover_an_uncached_read():
    from eval import intervention_eval

    uncached = 0.0031  # measured under parallel load before the prefix cache
    assert all(intervention_eval.TURN_RESERVE[v] >= uncached * intervention_eval.CALLS_PER_TURN[v] for v in ("v1", "v2", "v3", "v5"))


def test_a_tripped_guard_abandons_the_dialogue_even_though_the_detector_swallows_the_error(monkeypatch):
    """score_turn turns any failed read into 'uncertain'; the guard's stop must not become a run of made-up verdicts."""
    from app import scam
    from app.contracts import ScamTurnResponse
    from eval import intervention_eval

    guard = intervention_eval.ReadCostGuard()
    guard.tripped = 0.003

    def swallowing(req, settings, uid=None):
        return ScamTurnResponse(scam_type="uncertain", urgency="none", requested_secret="none", confidence=0.4, evidence_quote="",
                                recommended_action="none", rolling_score=0.4)
    monkeypatch.setattr(scam, "score_turn", swallowing)
    with pytest.raises(intervention_eval.CostTooHigh):
        intervention_eval.replay_dialogue(ROWS[0], "v1", intervention_eval.get_settings(), guard=guard)
