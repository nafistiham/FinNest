from eval.baselines import bfs2, score_only, shared_entity_components
from eval.metrics import score_case, wilson
from eval.seeds import benign_seeds, ring_seeds

from case_zero.config import DEMO_AS_OF, DEMO_SEED


def test_wilson_known_values():
    lo, hi = wilson(20, 20)
    assert round(lo, 3) == 0.839 and hi == 1.0
    lo, hi = wilson(0, 10)
    assert lo == 0.0 and round(hi, 3) == 0.278


def test_score_case_counts_victims_out():
    m = score_case(pred={"a", "b", "victim"}, truth={"a", "c"}, victims={"victim"})
    assert m == {"tp": 1, "fp": 1, "fn": 1, "precision": 0.5, "recall": 0.5, "recovered": False}


def test_ring_seeds_one_per_ring_without_labels_in_agent_view(world):
    seeds = ring_seeds(world)
    assert len(seeds) == len({l["ring_id"] for l in world.bundle.labels})
    demo = next(s for s in seeds if s["ring_id"] == "ring_demo_otp")
    assert demo["seed"] == DEMO_SEED and demo["truth"] >= {"acct_01070", "acct_01341", "acct_till_AG-0192"}
    assert "acct_rina" in demo["victims"] and "acct_rina" not in demo["truth"]
    assert all(s["as_of"] < "2026-11-11" for s in seeds)


def test_benign_seeds_are_unlabelled(world):
    labelled = {l["acct_id"] for l in world.bundle.labels}
    seeds = benign_seeds(world, n=10)
    assert len(seeds) == 10 and not ({s["seed"] for s in seeds} & labelled)
    assert seeds[0]["seed"] == "acct_09001"  # the new-phone persona, under its alias


def test_baselines_return_account_sets(world):
    near = bfs2(world, DEMO_SEED, DEMO_AS_OF)
    assert DEMO_SEED in near and "acct_01870" in near and "acct_rina" in near
    assert score_only(world, DEMO_SEED, DEMO_AS_OF) <= near
    assert DEMO_SEED in shared_entity_components(world, DEMO_SEED)


def _row(ring, tuning=False, **m):
    return {"ring_id": ring, "tuning": tuning, "methods": {"case_zero": m}}


def test_summary_excludes_tuning_ring_and_skipped_cases():
    from eval.run_eval import summarise
    ok = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, seconds=10.0, cost_usd=0.02, status="done")
    rows = [_row("r1", **ok), _row("ring_demo_otp", True, **{**ok, "recovered": False}), _row(None, skipped="budget"), _row("ring_x", True, skipped="tuning ring"),
            _row(None, **{**ok, "flagged": False, "first_pass_ok": False, "seconds": 30.0, "cost_usd": 0.04})]
    s = summarise(rows, "case_zero")
    assert (s["rings"], s["rings_recovered"], s["benign"], s["benign_false_alarms"]) == (1, 1, 1, 0)
    assert s["skipped_budget"] == 1 and s["skipped_tuning"] == 1 and s["tuning_rows"] == 1
    assert s["validator_first_pass"] == [1, 2] and s["cost_usd_total"] == 0.06 and s["seconds_p50"] == 20.0


def test_budget_gate():
    from eval.run_eval import budget_allows
    assert budget_allows(spent=1.20, cap=1.40, reserve=0.10)
    assert not budget_allows(spent=1.31, cap=1.40, reserve=0.10)


def test_findable_is_the_reachable_part_of_the_truth(world):
    from eval.reach import findable
    seeds = {s["ring_id"]: s for s in ring_seeds(world)}
    demo = seeds["ring_demo_otp"]
    assert findable(world, demo["seed"], demo["as_of"], demo["truth"]) == demo["truth"]
    dormant = [s for r, s in seeds.items() if r.startswith("ring_dormant")]
    assert any(findable(world, s["seed"], s["as_of"], s["truth"]) < s["truth"] for s in dormant)


def test_summary_reports_recall_against_findable_members():
    from eval.run_eval import summarise
    m = dict(recovered=False, precision=1.0, recall=0.5, recall_findable=1.0, flagged=True, first_pass_ok=True, seconds=10.0, cost_usd=0.02, status="done")
    s = summarise([_row("r1", **m)], "case_zero")
    assert s["mean_recall_findable"] == 1.0


def test_merge_rerun_replaces_only_the_named_rings():
    from eval.run_eval import merge_rerun
    old = {"rows": [_row("a", recall=0.1, precision=1.0), _row("b", recall=0.2, precision=1.0)]}
    merged = merge_rerun(old, {"b": {"recall": 0.9, "precision": 0.8}})
    by = {r["ring_id"]: r["methods"]["case_zero"] for r in merged["rows"]}
    assert by["a"]["recall"] == 0.1 and "rerun" not in by["a"]
    assert by["b"]["recall"] == 0.9 and by["b"]["rerun"] is True


def test_agent_methods_score_the_gated_and_ungated_member_lists():
    from eval.run_eval import agent_methods
    seed = {"truth": {"a", "b"}, "victims": {"v"}}
    info = {"action": "freeze", "proposed": ["a", "b", "x"], "members": ["a", "b"], "gate_dropped": ["x"]}
    m = agent_methods({"a", "b"}, info, seed, reach={"a", "b"})
    assert m["case_zero"]["precision"] == 1.0 and m["case_zero"]["recovered"] and m["case_zero"]["gate_dropped"] == ["x"]
    assert round(m["case_zero_ungated"]["precision"], 2) == 0.67 and not m["case_zero_ungated"]["recovered"]
    assert m["case_zero"]["flagged"] and m["case_zero_ungated"]["flagged"]


def test_rerun_replaces_both_agent_rows_and_recomputes_gates():
    from eval.run_eval import apply_rerun
    stale = dict(recovered=False, precision=0.0, recall=0.0, flagged=True, first_pass_ok=False, seconds=26.6, cost_usd=0.03, status="failed", action="freeze")
    good = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, seconds=40.0, cost_usd=0.04, status="done", action="freeze")
    base = {"note": "Base.", "rows": [{"ring_id": "a", "tuning": False, "methods": {"case_zero": good, "case_zero_ungated": good}},
                                      {"ring_id": "b", "tuning": False, "methods": {"case_zero": stale, "case_zero_ungated": stale}}],
            "gates": {"G3_validator": False}}
    fresh = {"spent_usd_ledger": 5.5, "rows": [{"ring_id": "a", "tuning": False, "methods": {}},
                                               {"ring_id": "b", "tuning": False, "methods": {"case_zero": good, "case_zero_ungated": dict(good, precision=0.5)}}]}
    merged = apply_rerun(base, fresh, "b", "Gemini 429 on the first run")
    b = next(r for r in merged["rows"] if r["ring_id"] == "b")["methods"]
    assert b["case_zero"]["rerun"] and b["case_zero"]["status"] == "done" and b["case_zero_ungated"]["precision"] == 0.5
    assert merged["summary"]["case_zero"]["rings_recovered"] == 2 and merged["gates"]["G3_validator"] is True
    assert "Re-run: b (Gemini 429 on the first run)." in merged["note"] and merged["reruns"] == ["b"]
