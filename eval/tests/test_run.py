"""Unit tests for eval/run.py."""

from __future__ import annotations

import json
import sys
import urllib.error
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import run  # noqa: E402


def test_percentile_is_nearest_rank_not_max():
    samples = [100.0] * 19 + [1300.0]
    assert run.percentile(samples, 0.95) == 100.0
    assert run.percentile(samples, 1.0) == 1300.0
    assert run.percentile([5.0], 0.95) == 5.0


def test_percentile_rejects_empty():
    with pytest.raises(ValueError):
        run.percentile([], 0.5)


def test_interpreter_is_the_running_python():
    assert run.interpreter() == sys.executable


def test_pytest_summary_recognises_collection_errors():
    out = "ERROR tests/conftest.py\n!!!! Interrupted: 1 error during collection !!!!\n1 error in 0.05s\n"
    assert run.pytest_summary_line(out) == "1 error in 0.05s"
    assert run.pytest_summary_line("....\n33 passed, 1 warning in 0.40s\n") == "33 passed, 1 warning in 0.40s"


def test_mule_eval_does_not_report_stale_metrics_on_failure(monkeypatch, tmp_path):
    stale = tmp_path / "mule.json"
    stale.write_text(json.dumps({"test": {"auc_pr": 0.9}}), encoding="utf-8")
    monkeypatch.setattr(run, "_run", lambda cmd, cwd: (1, "Traceback: boom"))
    result = run.mule_eval(results_path=stale)
    assert result["status"] == "failed"
    assert result["test"] is None
    assert "boom" in result["log_tail"]


def test_mule_eval_reads_metrics_on_success(monkeypatch, tmp_path):
    path = tmp_path / "mule.json"
    path.write_text(json.dumps({"test": {"auc_pr": 0.84}, "split": {"train_cutoffs": []}}), encoding="utf-8")
    monkeypatch.setattr(run, "_run", lambda cmd, cwd: (0, "ok"))
    result = run.mule_eval(results_path=path)
    assert result["status"] == "ok" and result["test"]["auc_pr"] == 0.84


def test_mule_eval_command_does_not_write_artefacts(monkeypatch, tmp_path):
    seen: list[list[str]] = []
    path = tmp_path / "mule.json"
    path.write_text(json.dumps({"test": {}, "split": {}}), encoding="utf-8")
    monkeypatch.setattr(run, "_run", lambda cmd, cwd: seen.append(cmd) or (0, ""))
    run.mule_eval(results_path=path)
    assert "--artefacts" not in seen[0]


def test_deployed_records_probe_failure_instead_of_crashing(monkeypatch):
    monkeypatch.setattr(run, "_run", lambda cmd, cwd: (0, "smoke: x\n  ok health"))

    def boom(url, body, headers):
        raise urllib.error.HTTPError(url, 401, "unauthorized", None, None)

    monkeypatch.setattr(run, "_post", boom)
    result = run.deployed("https://example.test")
    assert result["status"] == "failed"
    assert "401" in result["error"]
    assert result["risk_score_latency_ms"] is None


def test_deployed_ignores_samples_without_timing_header(monkeypatch):
    monkeypatch.setattr(run, "_run", lambda cmd, cwd: (0, "smoke: x"))
    answers = iter([(None, 300.0, 200), (20.0, 250.0, 200), (30.0, 260.0, 200)])
    monkeypatch.setattr(run, "_post", lambda url, body, headers: next(answers))
    monkeypatch.setattr(run, "LATENCY_SAMPLES", 3)
    lat = run.deployed("https://example.test")["risk_score_latency_ms"]
    assert lat["server_samples"] == 2 and lat["server_p50"] == 25.0
    assert lat["end_to_end_p50"] == 260.0


def test_deployed_sends_an_eval_identity_header(monkeypatch):
    monkeypatch.setattr(run, "_run", lambda cmd, cwd: (0, "smoke: x"))
    captured: dict = {}
    monkeypatch.setattr(run, "_post", lambda url, body, headers: captured.update(headers) or (10.0, 100.0, 200))
    monkeypatch.setattr(run, "LATENCY_SAMPLES", 1)
    run.deployed("https://example.test")
    assert captured.get("X-Demo-User") == run.EVAL_USER


def test_markdown_renders_both_suites_and_pending(tmp_path):
    summary = {
        "generated_at": "2026-10-16T07:00:00+00:00",
        "modules": {
            "mule_scorer": {"status": "ok", "test": {"auc_pr": 0.84, "precision_at_50": 0.9, "recall_at_precision_0.9": 0.6, "ring_level_recall": 0.9, "recall_by_typology": {"fan_in_fan_out": 0.3}}, "split": {"train_cutoffs": ["2026-10-14T00:00:00"], "train_positives": 59, "test_cutoffs": ["2026-11-04T00:00:00"], "test_positives": 164}},
            "risk_mw_tests": {"status": "ok", "summary": "33 passed"},
            "synth_tests": {"status": "failed", "summary": "1 failed, 29 passed"},
            "deployed": {"status": "failed", "url": "https://x", "error": "HTTP 401", "smoke": [], "risk_score_latency_ms": None},
        },
        "pending": ["intervention"],
    }
    md = run.markdown(summary)
    assert "33 passed" in md and "1 failed, 29 passed" in md
    assert "HTTP 401" in md
    assert "intervention" in md
    assert "| AUC-PR | 0.84 |" in md


def test_deployed_latency_line_says_end_to_end_includes_the_runners_network():
    dep = {"status": "ok", "url": "https://x", "error": None, "smoke": [],
           "risk_score_latency_ms": {"samples": 20, "server_samples": 20, "server_p50": 26.6, "server_p95": 38.2, "end_to_end_p50": 290.7, "end_to_end_p95": 6556.4}}
    line = run._deployed_section(dep)[1]
    assert "p95 38.2 ms" in line and "p95 6556.4 ms" in line
    assert line.endswith(" (end-to-end is measured from the runner's network and includes connection setup)")


# --- ATO and investigator results, Gemini table ----------------------------------------------------


def _ato_results(train_sessions=4):
    return {
        "dataset": "hmog",
        "source": "MEASURED on HMOG writing sessions",
        "users": 2,
        "table": "/Users/someone/data/hmog_features.jsonl",
        "split": {"train_sessions_per_user": 5, "holdout_sessions_per_user": 3},
        "metrics": {
            "identity_eer_mean": {"value": 0.1618, "target": "0.03-0.1", "status": "fail", "source": "MEASURED on HMOG writing sessions"},
            "coached_detection_rate": {"value": 1.0, "target": ">= 0.9", "status": "pass", "source": "GENERATED coached counterparts"},
            "judge_faithfulness": {"value": None, "target": ">= 4.0 / 5", "status": "not run", "source": "needs Gemini"},
        },
        "per_user": [{"user": "u1", "train_sessions": train_sessions}, {"user": "u2", "train_sessions": train_sessions}, {"user": "u3", "train_sessions": 5}],
        "caveat": "coached sessions are generated",
    }


def _case_zero_results():
    return {
        "model": "gemini-3.8-flash",
        "judge_model": "gemini-3.8-flash",
        "gates": {"G1_recovery": True, "G4_latency_cost": False},
        "summary": {
            "case_zero": {"rings": 17, "rings_recovered": 16, "mean_precision": 0.98, "benign": 10, "benign_false_alarms": 0, "seconds_p50": 43.3, "seconds_p95": 64.7,
                          "cost_usd_per_case": 0.043, "cost_usd_total": 1.1599, "judge_cost_usd_total": 0.1578, "judge_n": 27},
            "score_only_0.5": {"rings": 17, "rings_recovered": 1, "mean_precision": 0.586, "benign": 10, "benign_false_alarms": 0},
        },
        "rows": [{"case": "ring_fan_1", "trace": "long"}],
        "note": "synthetic data",
    }


def _entry(data, source="x.json"):
    return {"status": "ok", "source": source, "data": data}


def _write(tmp_path, name, data):
    path = tmp_path / name
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def test_load_results_is_none_for_a_missing_file_and_flags_a_corrupt_one(tmp_path):
    assert run.load_results(tmp_path / "nope.json", run.project_investigator) is None
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    loaded = run.load_results(bad, run.project_investigator)
    assert loaded["status"] == "failed" and loaded["error"]


def test_load_results_flags_a_file_that_is_not_an_object(tmp_path):
    loaded = run.load_results(_write(tmp_path, "list.json", [1, 2]), run.project_ato)
    assert loaded["status"] == "failed" and "object" in loaded["error"]


def test_load_results_projects_the_file_and_names_its_source_without_an_absolute_path(tmp_path):
    loaded = run.load_results(_write(tmp_path, "ok.json", {"model": "m", "rows": [1]}), run.project_investigator)
    assert loaded["status"] == "ok" and loaded["data"] == {"model": "m"}
    assert loaded["source"] == "ok.json"


def test_loading_keeps_only_what_the_summary_renders(tmp_path):
    ato = run.load_results(_write(tmp_path, "ato.json", _ato_results(train_sessions=4)), run.project_ato)
    cz = run.load_results(_write(tmp_path, "cz.json", _case_zero_results()), run.project_investigator)
    assert set(ato["data"]) == {"source", "users", "metrics", "split", "caveat", "realised_train_sessions"}
    assert ato["data"]["realised_train_sessions"] == [4, 5]
    assert set(cz["data"]) == {"model", "judge_model", "gates", "summary", "note"}
    for entry in (ato, cz):
        assert not {"per_user", "rows", "table"} & set(entry["data"])
        assert "/Users/" not in json.dumps(entry)


def test_ato_section_reports_the_realised_enrolment_not_the_configured_one():
    text = "\n".join(run._ato_section(_entry(run.project_ato(_ato_results(train_sessions=4)))))
    assert "0.1618" in text and "fail" in text.lower()
    assert "4, 5 enrolment sessions" in text and "configured 5" in text


def test_ato_section_keeps_generated_numbers_labelled_and_unrun_ones_visible():
    text = "\n".join(run._ato_section(_entry(run.project_ato(_ato_results()))))
    assert "GENERATED" in text and "not run" in text.lower()


def test_the_pooled_eer_row_says_it_is_the_free_text_figure():  # the product figure lives in the ato README
    pooled = {"value": 0.0797, "target": "0.03-0.1", "status": "within band", "source": "MEASURED on HMOG writing sessions"}
    results = _ato_results()
    data = {**results, "metrics": {"identity_eer_pooled": pooled, **results["metrics"]}}
    rows = run._ato_section(_entry(run.project_ato(data)))
    pooled_row = next(r for r in rows if r.startswith("| identity_eer_pooled |"))
    assert run.ATO_POOLED_NOTE in pooled_row and "0.0797" in pooled_row
    assert "free text" in run.ATO_POOLED_NOTE and "libs/ato/README.md" in run.ATO_POOLED_NOTE
    assert not any(ch.isdigit() for ch in run.ATO_POOLED_NOTE)
    assert sum(run.ATO_POOLED_NOTE in r for r in rows) == 1


def test_investigator_section_shows_gates_baseline_and_cost():
    text = "\n".join(run._investigator_section(_entry(run.project_investigator(_case_zero_results()), "c.json")))
    assert "16/17" in text and "G4_latency_cost" in text and "FAIL" in text
    assert "score_only_0.5" in text and "$0.043" in text


def test_investigator_gate_g3_is_labelled_a_citation_check():  # it checks that cited facts exist, not that they follow
    results = {**_case_zero_results(), "gates": {"G3_validator": True}}
    text = "\n".join(run._investigator_section(_entry(run.project_investigator(results), "c.json")))
    assert "G3_citation_check pass" in text and "validator" not in text


def _models_yaml(tmp_path):
    models = tmp_path / "models.yaml"
    models.write_text("roles:\n  workhorse:\n    id: gemini-3.8-flash\n    input_usd_per_m: 0.75\n    output_usd_per_m: 3.75\n    use: explanations\n  volume:\n    id: gemini-3.5-flash-lite\n    input_usd_per_m: 0.3\n    output_usd_per_m: 2.5\n    use: scam turns\n")
    return models


def test_gemini_section_lists_every_pinned_role_and_the_measured_spend(tmp_path):
    gemini = run.gemini_usage(_models_yaml(tmp_path), _entry(run.project_investigator(_case_zero_results()), "c.json"))
    assert gemini["roles"][0] == {"role": "workhorse", "id": "gemini-3.8-flash", "input_usd_per_m": 0.75, "output_usd_per_m": 3.75, "use": "explanations"}
    assert gemini["measured"] == {"cost_usd_per_case": 0.043, "cost_usd_total": 1.1599, "judge_cost_usd_total": 0.1578, "judge_n": 27}
    assert json.loads(json.dumps(gemini)) == gemini  # data, not rendered lines
    text = "\n".join(run._gemini_section(gemini))
    assert "gemini-3.8-flash" in text and "gemini-3.5-flash-lite" in text and "0.75" in text
    assert "$0.043 per case" in text


def test_gemini_usage_has_no_measured_spend_without_investigator_results(tmp_path):
    gemini = run.gemini_usage(_models_yaml(tmp_path), None)
    assert gemini["measured"] is None
    assert "Measured" not in "\n".join(run._gemini_section(gemini))


def test_modules_that_have_results_are_not_listed_as_pending():
    assert run.pending_modules({"ato_behaviour", "investigator"}) == (
        "app_safety", "intervention", "campaign_radar", "common_point_of_cashout")
    assert len(run.pending_modules(set())) == 6


def _summary_with(modules, gemini=None):
    base = {
        "mule_scorer": {"status": "ok"},
        "risk_mw_tests": {"status": "ok", "summary": "1 passed"},
        "synth_tests": {"status": "ok", "summary": "1 passed"},
    }
    return {"generated_at": "t", "pending": list(run.pending_modules(set(modules))), "modules": {**base, **modules}, "gemini": gemini}


def test_markdown_includes_the_new_sections_when_results_exist(tmp_path):
    investigator = _entry(run.project_investigator(_case_zero_results()), "c.json")
    summary = _summary_with(
        {"ato_behaviour": _entry(run.project_ato(_ato_results()), "a.json"), "investigator": investigator},
        gemini=run.gemini_usage(_models_yaml(tmp_path), investigator),
    )
    out = run.markdown(summary)
    assert "Behaviour model" in out and "Investigator" in out
    assert "## Gemini usage" in out and "| volume | gemini-3.5-flash-lite | 0.3 / 2.5 | scam turns |" in out and "$0.043 per case" in out
    assert "ato_behaviour: not run yet" not in out and "app_safety: not run yet" in out


def test_a_results_file_with_a_renamed_key_degrades_to_one_line_and_the_run_continues():
    ato = {k: v for k, v in run.project_ato(_ato_results()).items() if k != "metrics"}
    cz = run.project_investigator(_case_zero_results())
    broken_row = {**cz["summary"]["score_only_0.5"]}
    del broken_row["rings_recovered"]
    cz_broken = {**cz, "summary": {**cz["summary"], "score_only_0.5": broken_row}}
    summary = _summary_with({"ato_behaviour": _entry(ato, "a.json"), "investigator": _entry(cz_broken, "c.json")})
    out = run.markdown(summary)
    assert "could not render ato_behaviour from `a.json`: missing key 'metrics'" in out
    assert "could not render investigator from `c.json`: missing key 'rings_recovered'" in out
    assert "## risk-mw deployment" in out and "## Not run yet" in out


def test_a_section_whose_data_has_the_wrong_shape_degrades_too():
    ato = {**run.project_ato(_ato_results()), "metrics": ["identity_eer_mean"]}
    text = "\n".join(run._ato_section(_entry(ato, "a.json")))
    assert "could not render ato_behaviour from `a.json`" in text


def test_project_app_safety_keeps_the_card_and_runs_only():
    raw = {"generated_at": "t", "classifier": {"version": "v", "dataset": {"name": "d"}, "metrics": {"accuracy": 1}, "future_metrics": {"2023": {}}, "gates_passed": True, "model_bytes": 1, "top_features": [1, 2]},
           "offline": {"cases": 30, "correct": 30, "target": 27, "passed": True, "agreement_rate": None, "gemini_errors": 0, "latency_ms": {"p50": 1, "p95": 2}, "rows": [1, 2, 3]}}
    out = run.project_app_safety(raw)
    assert "top_features" not in out["classifier"] and "rows" not in out["offline"] and "gemini" not in out
    assert out["classifier"]["future_metrics"] == {"2023": {}} and out["offline"]["correct"] == 30


def test_app_safety_section_renders_future_years_and_runs():
    entry = {"status": "ok", "source": "x.json", "data": {"generated_at": "t", "classifier": {"version": "v", "model_bytes": 4_000_000, "gates_passed": True, "dataset": {"name": "LAMDA", "train_years": [2019]}, "metrics": {"accuracy": 0.9, "macro_f1": 0.9, "roc_auc": 0.96},
             "future_metrics": {"2023": {"roc_auc": 0.93, "recall_at_0.8": 0.58, "benign_flag_rate_at_0.8": 0.007}}}, "offline": {"cases": 30, "correct": 30, "target": 27, "latency_ms": {"p95": 90}}}}
    text = "\n".join(run._app_safety_section(entry))
    assert "Unseen 2023" in text and "30/30 correct" in text and "gates pass" in text


def test_the_gemini_usage_table_says_what_runs():  # nothing imports ADK; Case Zero runs on the workhorse role
    roles = run.gemini_usage(run.MODELS_CONFIG, None)["roles"]
    uses = {r["role"]: r["use"] for r in roles}
    assert all(uses.values())
    assert all("ADK" not in use.replace("not ADK", "") for use in uses.values())
    assert "Case Zero" in uses["workhorse"] and "google-genai" in uses["workhorse"]
    assert "explanation" not in uses["workhorse"]  # app/ato.py passes call=None: no service asks Gemini to explain
    assert "investigator" not in uses["reasoning"]
    assert "apa_judge" in uses["reasoning"]  # risk-mw's eval/apa_judge.py judges on it by default
