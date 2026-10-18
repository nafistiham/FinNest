"""Regenerate every measured number with one command.

    python eval/run.py                      # mule scorer eval + risk-mw and synth test suites
    python eval/run.py --url https://...    # also smoke + latency against a deployed risk-mw

Writes eval/results/summary.json and eval/results/summary.md (eval/results/ is not committed). The mule eval is
evaluate-only: it never rewrites the shipped artefacts in models/mule (use libs/synth/eval/mule_eval.py
--artefacts for that). The behaviour model, investigator, App Safety Check, Campaign Radar and cash-out sections are
read from the result files their own harnesses wrote, never re-run here: the investigator's harness spends Gemini
money, and the behaviour model's reads a 6 GB dataset. Modules with no results file are listed as "not run yet".
summary.json keeps only the fields of those files that summary.md renders, never the per-user or per-case rows.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path

import yaml

PROJECT = Path(__file__).resolve().parent.parent  # the repository root
RESULTS = PROJECT / "eval" / "results"
MULE_RESULTS = RESULTS / "mule.json"
ATO_RESULTS = PROJECT / "libs" / "ato" / "eval" / "results" / "ato_hmog.json"  # written by libs/ato/eval/ato_eval.py
INVESTIGATOR_RESULTS = PROJECT / "services" / "case-zero" / "eval" / "results" / "case_zero.json"  # written by its eval/run_eval.py
MODELS_CONFIG = PROJECT / "services" / "risk-mw" / "config" / "models.yaml"
ATO_MODULE, INVESTIGATOR_MODULE, APP_SAFETY_MODULE = "ato_behaviour", "investigator", "app_safety"
APP_SAFETY_RESULTS = RESULTS / "appsafety.json"  # written by libs/app-safety-check/eval/appsafety_eval.py
CAMPAIGN_MODULE = "campaign_radar"  # written by libs/radar/eval/radar_eval.py
CAMPAIGN_RESULTS = RESULTS / "campaign.json"
CASHOUT_MODULE = "common_point_of_cashout"
CASHOUT_RESULTS = RESULTS / "cashout.json"  # written by libs/radar/eval/cashout_eval.py
MULE_MODULE, RISK_MW_TESTS, SYNTH_TESTS, DEPLOYED = "mule_scorer", "risk_mw_tests", "synth_tests", "deployed"
ALL_MODULES = (ATO_MODULE, APP_SAFETY_MODULE, "intervention", INVESTIGATOR_MODULE, CAMPAIGN_MODULE, CASHOUT_MODULE)
LATENCY_SAMPLES = 20
EVAL_USER = "eval-runner"  # audit rows written by the latency probe carry this uid, so they are never mistaken for demo traffic
PROBE_TIMEOUT_S = 30
LOG_TAIL_CHARS = 4000
SCORE_BODY = json.dumps({"user_id": "rina", "session_id": "eval", "txn": {"type": "pin_reset"}, "demo_flags": {"call_active": True}}).encode()
TIMING_HEADER = "X-Processing-Time-Ms"
ATO_FIELDS = ("source", "users", "metrics", "split", "caveat")
INVESTIGATOR_FIELDS = ("model", "judge_model", "gates", "summary", "note")
APP_SAFETY_CLASSIFIER_FIELDS = ("version", "dataset", "metrics", "future_metrics", "gates_passed", "model_bytes")
APP_SAFETY_RUN_FIELDS = ("cases", "correct", "target", "passed", "agreement_rate", "gemini_errors", "latency_ms")
# Gate keys stay as the harnesses write them; the summary names what a gate really checks. G3 checks that every
# id, amount and time a case cites exists in a tool output, not that the sentence follows from it.
GATE_LABELS = {"G3_validator": "G3_citation_check"}
MEASURED_SPEND_FIELDS = ("cost_usd_per_case", "cost_usd_total", "judge_cost_usd_total", "judge_n")
E2E_CAVEAT = " (end-to-end is measured from the runner's network and includes connection setup)"


def interpreter() -> str:
    """The interpreter running this script: run eval/run.py from the environment that has the requirements."""
    return sys.executable


def percentile(samples: list[float], q: float) -> float:
    """Nearest-rank percentile: the ceil(q*n)-th smallest sample."""
    if not samples:
        raise ValueError("percentile of an empty sample")
    ordered = sorted(samples)
    rank = max(1, math.ceil(q * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def pytest_summary_line(output: str) -> str:
    markers = ("passed", "failed", "error")
    return next((line.strip() for line in reversed(output.splitlines()) if any(m in line for m in markers)), "")


def _run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    except OSError as exc:  # interpreter or script missing
        return 127, f"{cmd[0]}: {exc}"
    return proc.returncode, (proc.stdout + proc.stderr)[-LOG_TAIL_CHARS:]


def mule_eval(results_path: Path = MULE_RESULTS) -> dict:
    cmd = [interpreter(), "eval/mule_eval.py", "--seed-dir", str(PROJECT / "data" / "seed"), "--out", str(results_path)]
    code, out = _run(cmd, PROJECT / "libs" / "synth")
    if code != 0:
        return {"status": "failed", "test": None, "split": None, "log_tail": out[-600:]}
    metrics = json.loads(results_path.read_text(encoding="utf-8"))
    return {"status": "ok", "test": metrics.get("test"), "split": metrics.get("split"), "log_tail": ""}


def pytest_suite(path: Path) -> dict:
    code, out = _run([interpreter(), "-m", "pytest", "-q", "-p", "no:cacheprovider"], path)
    return {"status": "ok" if code == 0 else "failed", "summary": pytest_summary_line(out), "log_tail": "" if code == 0 else out[-600:]}


def _post(url: str, body: bytes, headers: dict[str, str]) -> tuple[float | None, float, int]:
    """Return (server-side ms from the timing header or None, end-to-end ms, HTTP status)."""
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as resp:  # noqa: S310 - our own service URL
        total = (time.perf_counter() - started) * 1000
        header = resp.headers.get(TIMING_HEADER)
        return (float(header) if header else None), total, resp.status


def _latency(url: str) -> dict:
    headers = {"Content-Type": "application/json", "X-Demo-User": EVAL_USER}
    server: list[float] = []
    end_to_end: list[float] = []
    for _ in range(LATENCY_SAMPLES):
        s_ms, e_ms, _status = _post(f"{url}/v1/risk/score", SCORE_BODY, headers)
        end_to_end.append(e_ms)
        if s_ms is not None:
            server.append(s_ms)
    return {
        "samples": LATENCY_SAMPLES, "server_samples": len(server),
        "server_p50": round(statistics.median(server), 1) if server else None, "server_p95": round(percentile(server, 0.95), 1) if server else None,
        "end_to_end_p50": round(statistics.median(end_to_end), 1), "end_to_end_p95": round(percentile(end_to_end, 0.95), 1),
    }


def deployed(url: str) -> dict:
    code, out = _run(["scripts/smoke.sh", url], PROJECT / "services" / "risk-mw")
    result = {"status": "ok" if code == 0 else "failed", "url": url, "smoke": out.strip().splitlines(), "error": None, "risk_score_latency_ms": None}
    try:
        return {**result, "risk_score_latency_ms": _latency(url)}
    except urllib.error.HTTPError as exc:
        return {**result, "status": "failed", "error": f"HTTP {exc.code} from {exc.url}"}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {**result, "status": "failed", "error": f"probe failed: {exc}"}


def _mule_section(mule: dict) -> list[str]:
    if not mule.get("test"):
        return ["## Mule scorer", "", f"- status: {mule['status']}" + (f" — {mule['log_tail'][-200:]}" if mule.get("log_tail") else ""), ""]
    t, split = mule["test"], mule["split"]
    rows = ["## Mule scorer", "", "| Metric | Value |", "|---|---|",
            f"| AUC-PR | {t['auc_pr']} |", f"| Precision @ 50 | {t['precision_at_50']} |", f"| Recall @ precision 0.9 | {t['recall_at_precision_0.9']} |", f"| Ring-level recall @ 50 | {t['ring_level_recall']} |"]
    rows += [f"| Recall @ 50 · {k} | {v} |" for k, v in t["recall_by_typology"].items()]
    rows += ["", f"Split: train {', '.join(c[:10] for c in split['train_cutoffs'])} ({split['train_positives']} positives); test {', '.join(c[:10] for c in split['test_cutoffs'])} ({split['test_positives']} positives). Synthetic data inflates scores.", ""]
    return rows


def _deployed_section(dep: dict | None) -> list[str]:
    if dep is None:
        return []
    lines = [f"- Deployed smoke ({dep['url']}): {dep['status']}" + (f" — {dep['error']}" if dep.get("error") else "")]
    lat = dep.get("risk_score_latency_ms")
    if lat:
        lines.append(f"- `/v1/risk/score` latency, n={lat['samples']}: server p50 {lat['server_p50']} ms, p95 {lat['server_p95']} ms ({lat['server_samples']} timed); end-to-end p50 {lat['end_to_end_p50']} ms, p95 {lat['end_to_end_p95']} ms{E2E_CAVEAT}")
    return lines


def pending_modules(landed: set[str]) -> tuple[str, ...]:
    return tuple(m for m in ALL_MODULES if m not in landed)


def _relative(path: Path) -> str:
    """Project-relative, or just the file name: no absolute path reaches the committed summary."""
    return str(path.relative_to(PROJECT)) if path.is_relative_to(PROJECT) else path.name


def _pick(data: dict, fields: tuple[str, ...]) -> dict:
    return {k: data[k] for k in fields if k in data}


def project_ato(data: dict) -> dict:
    """The behaviour-model fields the summary renders. The per-user rows, and the local dataset path that
    harness records, stay in its own file; only the distinct enrolment counts actually used are kept."""
    rows = data.get("per_user") if isinstance(data.get("per_user"), list) else []
    realised = {u.get("train_sessions") for u in rows if isinstance(u, dict)}
    return {**_pick(data, ATO_FIELDS), "realised_train_sessions": sorted(n for n in realised if isinstance(n, int | float))}


def project_investigator(data: dict) -> dict:
    """The investigator fields the summary renders; the per-case rows stay in Case Zero's own file."""
    return _pick(data, INVESTIGATOR_FIELDS)


def project_app_safety(data: dict) -> dict:
    """The App Safety Check fields the summary renders: the classifier card and the synthetic-case runs (offline, and
    through Gemini when the harness ran with --gemini); the 30 per-case rows stay in its own file."""
    classifier = data.get("classifier")
    out = {"generated_at": data.get("generated_at"), "classifier": _pick(classifier if isinstance(classifier, dict) else {}, APP_SAFETY_CLASSIFIER_FIELDS)}
    for run in ("offline", "gemini"):
        if isinstance(data.get(run), dict):
            out[run] = _pick(data[run], APP_SAFETY_RUN_FIELDS)
    return out


def project_campaign(data: dict) -> dict:
    """Acceptance and campaign summaries only; run-level artifacts stay in the radar outputs."""
    return _pick(data, ("mode", "live", "generated_at", "config", "measures", "campaigns", "payee_note", "benign", "incident_classes",
                        "false_incidents_per_week", "missing", "caveat"))


def load_results(path: Path, project: Callable[[dict], dict]) -> dict | None:
    """A module's own results file cut down by `project` to what the summary renders, or None if the module has
    not written one. A corrupt file is reported, not hidden."""
    if not path.exists():
        return None
    source = _relative(path)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return {"status": "failed", "source": source, "error": f"unreadable: {exc}"}
    except OSError as exc:  # strerror only: the full message would carry the absolute path
        return {"status": "failed", "source": source, "error": f"unreadable: {exc.strerror or type(exc).__name__}"}
    if not isinstance(raw, dict):
        return {"status": "failed", "source": source, "error": f"expected a JSON object, got {type(raw).__name__}"}
    return {"status": "ok", "source": source, "data": project(raw)}


def project_cashout(data: dict) -> dict:
    """Each world's summary and status; the per-day rows, candidate accounts and clusters stay in cashout.json."""
    worlds = data.get("worlds") if isinstance(data.get("worlds"), list) else []
    return {**_pick(data, ("generated_at", "config", "caveat")),
            "worlds": [_pick(w, ("world", "status", "missing", "seed_checksum", "summary")) for w in worlds if isinstance(w, dict)]}


RESULT_FILES = ((ATO_MODULE, ATO_RESULTS, project_ato), (APP_SAFETY_MODULE, APP_SAFETY_RESULTS, project_app_safety), (INVESTIGATOR_MODULE, INVESTIGATOR_RESULTS, project_investigator), (CAMPAIGN_MODULE, CAMPAIGN_RESULTS, project_campaign), (CASHOUT_MODULE, CASHOUT_RESULTS, project_cashout))


def result_files() -> dict[str, dict]:
    """Every module that has written a results file, projected."""
    loaded = ((name, load_results(path, project)) for name, path, project in RESULT_FILES)
    return {name: entry for name, entry in loaded if entry is not None}


def _value(metric: dict) -> str:
    return "n/a" if metric.get("value") is None else str(metric["value"])


def _what_failed(exc: Exception) -> str:
    return f"missing key {exc.args[0]!r}" if isinstance(exc, KeyError) else f"{type(exc).__name__}: {exc}"


def _section(title: str, module: str, entry: dict, body: Callable[[dict, str], list[str]]) -> list[str]:
    """A section rendered from a file another harness wrote. A renamed key costs that section one line, not the run."""
    head = [f"## {title}", ""]
    source = entry.get("source", "?")
    if entry.get("status") != "ok":
        return head + [f"- {source}: {entry.get('error')}", ""]
    try:
        return head + body(entry["data"], source)
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        return head + [f"- could not render {module} from `{source}`: {_what_failed(exc)}", ""]


# The HMOG file's pooled EER uses the keyrank_* block, which needs prose typing; the app's typing surface is digits. The
# product figure (without the block) is in libs/ato/README.md, so the summary never shows the better one unqualified.
ATO_POOLED_METRIC = "identity_eer_pooled"
ATO_POOLED_NOTE = "HMOG free text, with `keyrank_*`; the product figure is in `libs/ato/README.md`"


def _ato_value(name: str, metric: dict) -> str:
    return f"{_value(metric)} ({ATO_POOLED_NOTE})" if name == ATO_POOLED_METRIC else _value(metric)


def _ato_body(data: dict, source: str) -> list[str]:
    rows = ["| Metric | Value | Target | Status | Source |", "|---|---|---|---|---|"]
    rows += [f"| {name} | {_ato_value(name, m)} | {m.get('target', '-')} | {m.get('status', '-')} | {m.get('source', '-')} |" for name, m in data["metrics"].items()]
    realised = data.get("realised_train_sessions") or []
    configured = (data.get("split") or {}).get("train_sessions_per_user")
    enrolment = f"Enrolment actually used: {', '.join(map(str, realised))} enrolment sessions per user (configured {configured})." if realised else ""
    return rows + ["", f"{data['source']}, {data['users']} users, from `{source}`. {enrolment}", "", data.get("caveat", ""), ""]


def _ato_section(entry: dict) -> list[str]:
    return _section("Behaviour model", ATO_MODULE, entry, _ato_body)


def _investigator_body(data: dict, source: str) -> list[str]:
    rows = ["| Method | Rings recovered | Mean precision | Benign false alarms |", "|---|---|---|---|"]
    rows += [f"| {name} | {r['rings_recovered']}/{r['rings']} | {r['mean_precision']} | {r['benign_false_alarms']}/{r['benign']} |" for name, r in data["summary"].items()]
    cz = data["summary"].get("case_zero", {})
    gates = ", ".join(f"{GATE_LABELS.get(g, g)} {'pass' if ok else 'FAIL'}" for g, ok in data["gates"].items())
    detail = f"Case Zero ({data['model']}): p50 {cz.get('seconds_p50')} s, p95 {cz.get('seconds_p95')} s, ${cz.get('cost_usd_per_case')} per case." if cz else ""
    return rows + ["", f"Spec gates: {gates}. {detail} From `{source}`.", ""]


def _investigator_section(entry: dict) -> list[str]:
    return _section("Investigator", INVESTIGATOR_MODULE, entry, _investigator_body)


def _app_safety_body(data: dict, source: str) -> list[str]:
    c = data["classifier"]
    m = c["metrics"]
    rows = ["| Metric | Value |", "|---|---|",
            f"| Model | `{c['version']}` ({c['model_bytes'] / 1e6:.2f} MB), gates {'pass' if c.get('gates_passed') else 'FAIL'} |",
            f"| Dataset | {c['dataset'].get('name', '?')}, train years {c['dataset'].get('train_years', '?')} |",
            f"| In-distribution accuracy / macro-F1 / ROC-AUC | {m['accuracy']} / {m['macro_f1']} / {m['roc_auc']} |"]
    for year, fm in sorted((c.get("future_metrics") or {}).items()):
        rows.append(f"| Unseen {year}: ROC-AUC, recall at p≥0.80, benign flagged | {fm['roc_auc']}, {fm['recall_at_0.8']:.2f}, {fm['benign_flag_rate_at_0.8'] * 100:.1f}% |")
    for run, label in (("offline", "Synthetic phones, rules + classifier"), ("gemini", "Synthetic phones, through Gemini triage")):
        r = data.get(run)
        if r:
            extra = f", Gemini agreement {r['agreement_rate']}" if r.get("agreement_rate") is not None else ""
            rows.append(f"| {label} | {r['correct']}/{r['cases']} correct (target {r['target']}), p95 {r['latency_ms']['p95']} ms{extra} |")
    return rows + ["", f"From `{source}`, generated {data.get('generated_at', '?')}. Synthetic cases are hand-written and inflate the picture; the future-year rows are the honest number.", ""]


def _app_safety_section(entry: dict) -> list[str]:
    return _section("App Safety Check", APP_SAFETY_MODULE, entry, _app_safety_body)


CAMPAIGN_COLUMNS = ("flag_ts", "time_to_flag_min", "allowed_by_flag", "cashed_out_by_flag", "retained_by_flag", "retained_fraction",
                    "future_allowed_after_flag", "precision", "recall", "victim_coverage")
INCIDENT_CLASSES = ("benign_only", "mixed", "fraud_dominant")


def _cell(value: object) -> str:
    """None is n/a (nothing credited by the flag, a burst not evaluated); whole floats print as integers."""
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else f"{value:.4g}"
    return str(value)


def _campaign_tables(data: dict) -> list[str]:
    rows = ["| Campaign | Flag | Minutes after tenth | Allowed by flag BDT | Cashed out by flag BDT | Retained by flag BDT | Retained fraction | "
            "Future allowed after flag BDT | Precision | Recall | Victim coverage |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    rows += [f"| {r['campaign_id']} | " + " | ".join(_cell(r.get(c)) for c in CAMPAIGN_COLUMNS) + " |" for r in data.get("campaigns", [])]
    rows += ["", "| Burst | Kind | Attempts | Incidents | Status |", "|---|---|---|---|---|"]
    rows += [f"| {b['burst_id']} | {b['kind']} | {b.get('observed_attempts')} | {_cell(b.get('incidents'))} | {b.get('status', '-')} |" for b in data.get("benign", [])]
    return rows


def _route_line(world: str, fipw: dict) -> str | None:
    """Measured benign-only incidents per route over the world's exposure, beside the nominal p-branch figure."""
    summary = fipw.get("summary")
    if not summary:
        return None
    routes = ", ".join(f"{route} {r['benign_only_incidents']} in {r['exposure_weeks']:.2f} weeks" for route, r in summary.items())
    return f"- {world}: {routes} (nominal p-branch {_cell((fipw.get('nominal') or {}).get('p_branch_only'))} a week)"


def _flag_line(row: dict) -> str | None:
    f = row.get("flag_firing")
    if not f:
        return None
    return (f"- {row['campaign_id']}: opened at sender {row.get('senders_before_flag')}, {_cell(row.get('minutes_from_first_to_flag'))} min after "
            f"the first attempt, by {f['key']} ({f['window_min']} min, {f['reason']}); payees {row.get('payees_found')} of {row.get('payees_total')} "
            f"({row.get('payees_named')} named), till {'found' if row.get('till_found') else 'not found'}")


def _campaign_incident_lines(data: dict) -> list[str]:
    classes = data.get("incident_classes") or {}
    fipw = data.get("false_incidents_per_week") or {}
    nominal = fipw.get("nominal") or {}
    replay = fipw.get("campaign_free_replay") or {}
    benign = (data.get("measures") or {}).get("benign_burst_incidents") or {}
    lines = [line for line in (_flag_line(r) for r in data.get("campaigns", [])) if line]
    lines = (["How each campaign was flagged:"] + lines + [""]) if lines else []
    if data.get("payee_note"):  # written by radar_eval.py from the matched components; rendered verbatim
        lines += [data["payee_note"], ""]
    if benign.get("evaluated") is not None:
        lines += [f"Benign bursts counted: {', '.join(benign['evaluated'])}; outside the payment stream: {', '.join(benign['outside_stream']) or 'none'}.", ""]
    lines += ["Incident classes: " + ", ".join(f"{name} {classes.get(name, 0)}" for name in INCIDENT_CLASSES) + ".", "",
              f"False incidents per week, nominal (p-branch union bound; not a measured rate and not a guarantee): "
              f"{_cell(nominal.get('p_branch_only'))} against a budget of {_cell(nominal.get('budget'))}."]
    measured = [line for line in (_route_line("this world", fipw), _route_line("campaign-free replay", replay)) if line]
    lines += (["", "Measured benign-only incidents, by route:"] + measured) if measured else []
    if replay.get("status") and replay.get("status") != "run":
        lines += ["", f"Campaign-free replay: {replay['status']}" + (f" ({replay['reason']})" if replay.get("reason") else "") + "."]
    return lines


def _campaign_body(data: dict, source: str) -> list[str]:
    if data.get("mode") == "audit_reader":
        live = data.get("live", {})
        return [f"Audit reader: {live.get('status', 'missing')}; {live.get('scope', 'reader sanity only')}. From `{source}`.", "", data.get("caveat", ""), ""]
    rows = ["| Measure | Value | Target | Status |", "|---|---|---|---|"]
    rows += [f"| {name} | {_value(m)} | {m.get('target', '-')} | {m.get('status', '-')} |" for name, m in data["measures"].items()]
    rows += [""] + _campaign_tables(data) + [""] + _campaign_incident_lines(data)
    rows += [""] + [f"- {item}" for item in data.get("missing", [])]
    return rows + ["", f"From `{source}`, generated {data.get('generated_at', '?')}.", "", data.get("caveat", ""), ""]


def _campaign_section(entry: dict) -> list[str]:
    return _section("Campaign Radar", CAMPAIGN_MODULE, entry, _campaign_body)


CASHOUT_HEADER = ("| World | Filter | Daily runs | Till flags per day | Till-flag precision, next 7 days | Candidates | Candidate precision | "
                  "False candidates per week | Lead days, median (mean) | Recall of the lead | Live clusters | Replayed clusters (events) |")


def _cashout_row(world: str, s: dict, name: str, f: dict) -> str:
    """One world under one candidate filter: the till-flag and cluster columns repeat, the candidate columns are the filter's."""
    flags, cands, recall, replayed = s["till_flags"], f["candidates"], f["recall_of_the_lead"], s["replayed_clusters"]
    lead = cands.get("lead_days") or {}
    lead_cell = f"{_cell(lead['median'])} ({_cell(lead['mean'])})" if lead else "n/a"
    return (f"| {world} | {name} | {s['days_run']} | {_cell(flags['per_day'])} | {flags['right']}/{flags['scored_till_days']} = "
            f"{_cell(flags['precision'])} (base rate {_cell(flags['base_rate'])}) | {cands['total']} | {_cell(cands['precision'])} | "
            f"{_cell(cands['false_per_week'])} | {lead_cell} | {recall['caught']}/{recall['future_confirmed_mules']} = "
            f"{_cell(recall['recall'])} ({recall['caught']}/{recall['cashed_out_before_confirmation']} reachable) | "
            f"{s['live_clusters']} | {replayed['clusters']} ({replayed['events']}) |")


def _cashout_body(data: dict, source: str) -> list[str]:
    worlds = data["worlds"]
    ran = [w for w in worlds if w.get("status") == "run"]
    pairs = [(w["world"], w["summary"], name, f) for w in ran for name, f in w["summary"]["filters"].items()]
    rows = [CASHOUT_HEADER, "|---|---|---|---|---|---|---|---|---|---|---|---|"] + [_cashout_row(*pair) for pair in pairs]
    held = [(world, name, f["held_back"]) for world, _s, name, f in pairs if not f["candidates"]["total"]]
    rows += [""] + [f"- {world}, {name}: no candidate; {h['accounts']} accounts held back by the filter, {h['mules']} of them mules"
                    for world, name, h in held] if held else []
    rows += [f"- {w['world']}: missing ({'; '.join(w.get('missing', []))})" for w in worlds if w.get("status") != "run"]
    return rows + ["", f"From `{source}`, generated {data.get('generated_at', '?')}.", "", data.get("caveat", ""), ""]


def _cashout_section(entry: dict) -> list[str]:
    return _section("Common point of cash-out", CASHOUT_MODULE, entry, _cashout_body)


def _measured_spend(investigator: dict | None) -> dict | None:
    """Case Zero's measured Gemini spend from its projected results, or None when there is none to show."""
    data = (investigator or {}).get("data")
    summary = data.get("summary") if isinstance(data, dict) else None
    cz = summary.get("case_zero") if isinstance(summary, dict) else None
    if not isinstance(cz, dict) or cz.get("cost_usd_per_case") is None:
        return None
    return {k: cz.get(k) for k in MEASURED_SPEND_FIELDS}


def gemini_usage(models_path: Path, investigator: dict | None) -> dict:
    """Where Gemini is used: the pinned model and price per role, and the spend a harness measured for it."""
    roles = yaml.safe_load(models_path.read_text(encoding="utf-8"))["roles"]
    return {
        "roles": [{"role": name, "id": r["id"], "input_usd_per_m": r["input_usd_per_m"], "output_usd_per_m": r["output_usd_per_m"], "use": r.get("use", "")} for name, r in roles.items()],
        "measured": _measured_spend(investigator),
    }


def _gemini_section(gemini: dict) -> list[str]:
    lines = ["## Gemini usage", "", "| Role | Model | USD per 1M in / out | Used for |", "|---|---|---|---|"]
    lines += [f"| {r['role']} | {r['id']} | {r['input_usd_per_m']} / {r['output_usd_per_m']} | {r['use']} |" for r in gemini["roles"]]
    m = gemini.get("measured")
    if m:
        lines += ["", f"Measured: Case Zero ${m['cost_usd_per_case']} per case (${m['cost_usd_total']} for the run); judge ${m['judge_cost_usd_total']} for {m['judge_n']} cases."]
    return lines + [""]


def markdown(summary: dict) -> str:
    modules = summary["modules"]
    lines = [f"# Eval summary — {summary['generated_at']}", ""]
    lines += _mule_section(modules[MULE_MODULE])
    lines += ["## Test suites", "", f"- risk-mw: {modules[RISK_MW_TESTS]['summary']} [{modules[RISK_MW_TESTS]['status']}]",
              f"- synth: {modules[SYNTH_TESTS]['summary']} [{modules[SYNTH_TESTS]['status']}]", ""]
    if ATO_MODULE in modules:
        lines += _ato_section(modules[ATO_MODULE])
    if APP_SAFETY_MODULE in modules:
        lines += _app_safety_section(modules[APP_SAFETY_MODULE])
    if INVESTIGATOR_MODULE in modules:
        lines += _investigator_section(modules[INVESTIGATOR_MODULE])
    if CAMPAIGN_MODULE in modules:
        lines += _campaign_section(modules[CAMPAIGN_MODULE])
    if CASHOUT_MODULE in modules:
        lines += _cashout_section(modules[CASHOUT_MODULE])
    if summary.get("gemini"):
        lines += _gemini_section(summary["gemini"])
    lines += ["## risk-mw deployment", ""] + (_deployed_section(modules.get(DEPLOYED)) or ["- not checked (pass --url)"])
    lines += ["", "## Not run yet", ""] + [f"- {m}: not run yet" for m in summary["pending"]]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=None, help="deployed risk-mw base URL for smoke + latency")
    args = parser.parse_args(argv)
    RESULTS.mkdir(parents=True, exist_ok=True)
    modules = {
        MULE_MODULE: mule_eval(),
        RISK_MW_TESTS: pytest_suite(PROJECT / "services" / "risk-mw"),
        SYNTH_TESTS: pytest_suite(PROJECT / "libs" / "synth"),
        **result_files(),
        **({DEPLOYED: deployed(args.url.rstrip("/"))} if args.url else {}),
    }
    summary = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "modules": modules,
        "pending": list(pending_modules(set(modules))),
        "gemini": gemini_usage(MODELS_CONFIG, modules.get(INVESTIGATOR_MODULE)),
    }
    (RESULTS / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    report = markdown(summary)
    (RESULTS / "summary.md").write_text(report, encoding="utf-8")
    sys.stdout.write(report)  # the CLI's report; stdout is the intended output channel
    return 0 if all(m["status"] == "ok" for m in modules.values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
