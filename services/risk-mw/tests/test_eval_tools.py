"""Eval tooling: spend cap, labelled dialogue set, metrics."""

from types import SimpleNamespace

import pytest

from eval import budget, dialogues, metrics


def test_spend_ledger_caps_and_persists(tmp_path):
    led = budget.SpendLedger(tmp_path / "s.json", cap_usd=0.10)
    led.check(0.05)
    led.record(0.08)
    with pytest.raises(budget.BudgetExceeded):
        led.check(0.03)
    assert budget.SpendLedger(tmp_path / "s.json", cap_usd=0.10).spent() == pytest.approx(0.08)


def test_gemini_cost_counts_thinking_tokens():
    from app import genai_client
    role = genai_client.ModelRole("x", "m", 1.0, 10.0)
    usage = SimpleNamespace(prompt_token_count=1000, candidates_token_count=100, thoughts_token_count=400)
    assert genai_client.billed_tokens(usage) == (1000, 500)
    assert genai_client.cost_usd(role, 1000, 500) == pytest.approx(0.006)


def test_cached_input_tokens_are_charged_at_a_tenth_of_the_input_price():
    """Implicit caching bills the cached prefix at 10% of the input price; charging it in full overstated the spend."""
    from app import genai_client
    role = genai_client.ModelRole("x", "m", 1.0, 10.0)
    usage = SimpleNamespace(prompt_token_count=3000, cached_content_token_count=2048, candidates_token_count=100, thoughts_token_count=0)
    assert genai_client.cached_tokens(usage) == 2048 and genai_client.billed_tokens(usage) == (3000, 100)
    expected = (952 * 1.0 + 2048 * 0.1 + 100 * 10.0) / 1e6
    assert genai_client.cost_usd(role, 3000, 100, tokens_cached=2048) == pytest.approx(expected, abs=1e-6)  # rounded to 6 places
    assert genai_client.cost_usd(role, 3000, 100) == pytest.approx(0.004)  # nothing cached: the price is unchanged


def test_cached_tokens_are_never_more_than_the_prompt_and_absent_means_none():
    from app import genai_client
    assert genai_client.cached_tokens(SimpleNamespace(prompt_token_count=500)) == 0
    assert genai_client.cached_tokens(SimpleNamespace(prompt_token_count=500, cached_content_token_count=None)) == 0
    assert genai_client.cached_tokens(SimpleNamespace(prompt_token_count=500, cached_content_token_count=900)) == 500
    assert genai_client.cached_tokens(None) == 0


def test_a_call_with_a_cached_prefix_charges_the_ledger_the_cached_price(monkeypatch):
    from app import genai_client
    usage = SimpleNamespace(prompt_token_count=3000, cached_content_token_count=2000, candidates_token_count=100, thoughts_token_count=0)
    response = SimpleNamespace(text="{}", parsed=None, usage_metadata=usage, candidates=[])
    models = SimpleNamespace(generate_content=lambda model, contents, config: response)
    monkeypatch.setattr(genai_client, "_client", lambda: SimpleNamespace(models=models))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    genai_client.LEDGER.reset()
    try:
        result = genai_client.call("t", "volume", "hello")
        role = genai_client.roles()["volume"]
        expected = (1000 * role.input_usd_per_m + 2000 * role.input_usd_per_m * 0.1 + 100 * role.output_usd_per_m) / 1e6
        assert result.tokens_cached == 2000 and result.cost_usd == pytest.approx(expected, abs=1e-6)
        assert genai_client.LEDGER.spent() == pytest.approx(result.cost_usd)
    finally:
        genai_client.LEDGER.reset()


GEN =dialogues.GenBatch(dialogues=[
    dialogues.GenDialogue(requested_secret="otp", first_detectable_turn=2, turns=[
        dialogues.GenTurn(speaker="caller", text="আমি কাস্টমার কেয়ার থেকে বলছি"), dialogues.GenTurn(speaker="user", text="জি"),
        dialogues.GenTurn(speaker="caller", text="কোডটা বলুন")]),
    dialogues.GenDialogue(requested_secret="otp", first_detectable_turn=2, turns=[  # a duplicate up to spacing
        dialogues.GenTurn(speaker="caller", text="আমি কাস্টমার কেয়ার  থেকে বলছি"), dialogues.GenTurn(speaker="user", text="জি"),
        dialogues.GenTurn(speaker="caller", text="কোডটা বলুন")]),
    dialogues.GenDialogue(requested_secret="none", first_detectable_turn=9, turns=[  # detectable turn out of range: clamped to the last caller turn
        dialogues.GenTurn(speaker="caller", text="অন্য কথা"), dialogues.GenTurn(speaker="user", text="হুম")]),
])


def test_generated_batches_become_labelled_dialogues():
    rows = dialogues.to_rows(GEN, archetype="fake_customer_care", channel="bangla", label="scam", batch="b1")
    assert len(rows) == 2  # the near-duplicate is dropped
    first = rows[0]
    assert first["archetype"] == "fake_customer_care" and first["label"] == "scam" and first["channel"] == "bangla"
    assert [t["ts"] for t in first["turns"]] == [0.0, 6.0, 12.0] and first["first_detectable_turn"] == 2
    assert rows[1]["first_detectable_turn"] == 0 and rows[0]["id"] != rows[1]["id"]


def test_benign_rows_have_no_detectable_turn():
    rows = dialogues.to_rows(GEN, archetype="benign_delivery", channel="banglish", label="benign", batch="b2")
    assert all(r["first_detectable_turn"] is None and r["label"] == "benign" for r in rows)


def test_holdout_is_stratified_and_deterministic():
    rows = [{"id": f"s{i}", "label": "scam", "archetype": f"a{i % 6}"} for i in range(180)] + \
           [{"id": f"b{i}", "label": "benign", "archetype": f"k{i % 7}"} for i in range(70)]
    a, b = dialogues.split(rows, held_out=50), dialogues.split(rows, held_out=50)
    held = [r for r in a if r["split"] == "held_out"]
    assert a == b and len(held) == 50
    assert sum(r["label"] == "scam" for r in held) == 30 and len({r["archetype"] for r in held if r["label"] == "scam"}) == 6


def test_metrics_from_outcomes():
    outcomes = [
        {"label": "scam", "detected_turn": 3, "first_detectable_turn": 2, "turns": 6},
        {"label": "scam", "detected_turn": None, "first_detectable_turn": 1, "turns": 4},
        {"label": "benign", "detected_turn": 2, "first_detectable_turn": None, "turns": 5},
        {"label": "benign", "detected_turn": None, "first_detectable_turn": None, "turns": 3},
    ]
    m = metrics.summarise(outcomes)
    assert m["precision"] == 0.5 and m["recall"] == 0.5 and m["benign_false_positive_rate"] == 0.5
    assert m["median_turns_to_detection"] == 3 and m["median_turns_after_first_detectable"] == 1
    assert m["n_scam"] == 2 and m["n_benign"] == 2


def _dialogue(did, label, texts, first=None, archetype="otp_pin_harvest"):
    return {"id": did, "label": label, "archetype": archetype, "channel": "bangla", "first_detectable_turn": first, "split": "held_out",
            "turns": [{"speaker": s, "text": t, "ts": i * 6.0} for i, (s, t) in enumerate(texts)]}


def test_harness_replays_caller_turns_and_scores_gates(monkeypatch):
    from app import scam
    from eval import intervention_eval

    def fake(turns, settings, cards):
        last = [t for t in turns if t.speaker == "caller"][-1].text
        hit = "কোড" in last
        return scam.ScamExtraction(tactics=[{"tactic": "CREDENTIAL_REQUEST", "quote": last}] if hit else [], ask="otp" if hit else "none",
                                   scam_type="otp_pin_harvest" if hit else "none", verdict="SCAM" if hit else "SAFE", confidence=0.95 if hit else 0.1)
    monkeypatch.setattr(scam, "_model_extraction", fake)
    rows = [_dialogue("s1", "scam", [("caller", "হ্যালো"), ("user", "জি"), ("caller", "কোডটা বলুন")], first=2),
            _dialogue("b1", "benign", [("caller", "পার্সেল এসেছে"), ("user", "আসছি")], archetype="benign_delivery")]
    out = intervention_eval.evaluate(rows, ledger=None)
    assert out["outcomes"][0]["detected_turn"] == 2 and out["outcomes"][1]["detected_turn"] is None
    assert out["metrics"]["recall"] == 1.0 and out["metrics"]["benign_false_positive_rate"] == 0.0
    assert out["classifier_calls"] == 3  # caller turns only
    assert set(out["gates"]) == {"precision_0_85", "recall_0_80", "benign_fpr_0_10", "score_p95_under_100ms"}


def test_a_classifier_eval_rerun_keeps_the_speech_smoke_results(tmp_path):
    import json

    from eval import intervention_eval

    path = tmp_path / "intervention.json"
    smoke = {"tts_phone": {"source": "tts_phone", "recognised": 17}}
    path.write_text(json.dumps({"n": 40, "speech_smoke": smoke}), encoding="utf-8")
    assert intervention_eval.keep_speech_smoke({"n": 50}, path) == {"n": 50, "speech_smoke": smoke}
    assert intervention_eval.keep_speech_smoke({"n": 50}, tmp_path / "missing.json") == {"n": 50}


def _saved_run() -> dict:
    return {"n": 3, "split": "held_out", "score_latency": {"p95_ms": 11.5}, "classifier_cost_usd": 0.12,
            "metrics": {"precision": 0.5}, "gates": {"precision_0_85": False}, "false_positives": [{"id": "b1"}], "misses": [],
            "outcomes": [
                {"id": "s1", "label": "scam", "archetype": "otp_pin_harvest", "first_detectable_turn": 1, "detected_turn": 2, "trace": [{"rolling": 0.9, "quote": "x"}]},
                {"id": "b1", "label": "benign", "archetype": "benign_delivery", "first_detectable_turn": None, "detected_turn": 2,
                 "trace": [{"rolling": 0.9, "quote": "কোডটা বলুন"}]},
                {"id": "b2", "label": "benign", "archetype": "benign_relative", "first_detectable_turn": None, "detected_turn": None, "trace": []}]}


def test_relabelling_recomputes_from_saved_outcomes_without_a_classifier_call(monkeypatch):
    import pytest

    from app import genai_client
    from eval import intervention_eval

    monkeypatch.setattr(genai_client, "call", lambda *a, **k: pytest.fail("recompute must not call the classifier"))
    saved = _saved_run()
    rows = [{"id": "s1", "label": "scam", "archetype": "otp_pin_harvest", "first_detectable_turn": 1},
            {"id": "b1", "label": "scam", "archetype": "otp_pin_harvest", "first_detectable_turn": 2, "relabelled_by": "courier-code rule"},
            {"id": "b2", "label": "benign", "archetype": "benign_relative", "first_detectable_turn": None}]
    out = intervention_eval.recompute(saved, rows)
    m = out["metrics"]
    assert (m["n_scam"], m["n_benign"], m["precision"], m["recall"], m["benign_false_positive_rate"]) == (2, 1, 1.0, 1.0, 0.0)
    assert m["median_turns_after_first_detectable"] == 0.5 and out["gates"]["precision_0_85"] and out["false_positives"] == []
    assert out["relabelled"] == ["b1"] and out["before_relabel"]["metrics"] == {"precision": 0.5}
    assert out["score_latency"] == saved["score_latency"] and out["classifier_cost_usd"] == 0.12 and "original run" in out["recomputed_note"]
    again = intervention_eval.recompute(out, rows)  # recomputing a recomputed file keeps the first 'before'
    assert again["before_relabel"] == out["before_relabel"] and again["metrics"] == m


def test_the_saved_numbers_are_what_the_saved_outcomes_and_current_labels_give():
    """intervention.json, when present, must stay a pure function of its outcomes and eval/scam_dialogues.jsonl's labels."""
    import json

    from eval import intervention_eval

    saved = intervention_eval.RESULTS / "intervention.json"
    if not saved.exists():
        pytest.skip("eval/results/intervention.json is not present (run eval/intervention_eval.py to write it)")
    committed = json.loads(saved.read_text(encoding="utf-8"))
    rows = [json.loads(line) for line in intervention_eval.DIALOGUES.read_text(encoding="utf-8").splitlines() if line.strip()]
    redone = intervention_eval.recompute(committed, rows)
    assert redone["metrics"] == committed["metrics"] and redone["gates"] == committed["gates"]
    by_id = {r["id"]: r for r in rows}
    assert all(o["label"] == by_id[o["id"]]["label"] for o in committed["outcomes"])
