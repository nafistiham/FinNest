"""Reproducible App Safety Check numbers: classifier metrics, synthetic verdict accuracy, Gemini agreement.

    cd libs/app-safety-check && python eval/appsafety_eval.py                 # offline: rules + classifier
    cd libs/app-safety-check && RISK_MW_GENAI_ENABLED=true RISK_MW_GENAI_BACKEND=vertex \
        RISK_MW_PROJECT_ID=<gcp project> python eval/appsafety_eval.py --gemini   # Gemini triage through the risk-mw engine (Vertex AI, ADC)

Writes eval/results/appsafety.json and appsafety.md at the repository root. The classifier metrics are read from
models/app-safety-check/meta.json (train_lamda.py writes them); this script never retrains.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODULE_DIR = HERE.parent
PROJECT = MODULE_DIR.parents[1]  # the repository root
SERVICE_DIR = PROJECT / "services" / "risk-mw"
for candidate in (MODULE_DIR, SERVICE_DIR):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from bhorosha_app_safety_check import integrity, pipeline, schema as s  # noqa: E402
from bhorosha_app_safety_check.model import AppClassifier  # noqa: E402

CASES = HERE / "appsafety_cases.jsonl"
ARTEFACTS = PROJECT / "models" / "app-safety-check"
RESULTS = PROJECT / "eval" / "results"
DEMO_SECRET = "eval-only-secret"  # the harness signs and verifies its own tokens; the service has no default secret
TARGET_CORRECT = 29  # 18 of the 20 base cases, nine of the ten 2026 cases, both 300-app phones


def load_cases() -> list[dict]:
    return [json.loads(line) for line in CASES.read_text(encoding="utf-8").splitlines() if line.strip()]


def bundle_of(case: dict) -> s.Bundle:
    b = case["bundle"]
    apps = tuple(s.AppRow(a["package"], a.get("label", ""), a.get("installer"), a.get("version", ""), tuple(a.get("permissions", [])), a.get("has_accessibility_service", False), a.get("accessibility_enabled", False), a.get("target_sdk"), a.get("first_install"), a.get("has_notification_listener", False), a.get("has_hce_service", False), a.get("is_default_sms_app", False), a.get("launcher_icon_hidden", False), a.get("installer_declares_install_packages", False)) for a in b["installed_apps"])
    d = b.get("device", {})
    device = s.DeviceRow(tuple(d.get("overlay_holders", [])), tuple(d.get("device_admins", [])), d.get("dev_options", False), d.get("adb", False), d.get("rooted", False), d.get("play_protect", True), d.get("sdk_int"), d.get("default_sms_package"), d.get("nfc_default_payment_package"))
    token = b.get("integrity_token")
    # Every case is a genuine build on a healthy phone unless the case says otherwise: the token is bound to the bundle.
    digest = integrity.bundle_hash(apps, device)
    signed = integrity.sign_demo_verdict(DEMO_SECRET, [token] if token else [], request_hash=digest, app_recognition=b.get("app_recognition", "PLAY_RECOGNIZED"), device_recognition=b.get("device_recognition"))
    verdict = integrity.resolve(signed, demo_secret=DEMO_SECRET, demo_allowed=True, package_name="com.bhorosha.app")
    level = integrity.attestation_level(verdict, digest, expected_package="com.bhorosha.app")
    return s.Bundle(apps, device, verdict, attestation=level)


def percentile(samples: list[float], q: float) -> float:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, max(0, round(q * len(ordered)) - 1))]


def run_cases(cases: list[dict], classifier, gemini) -> dict:
    rows, latencies = [], []
    for case in cases:
        bundle = bundle_of(case)
        started = time.perf_counter()
        report = pipeline.run(bundle, classifier=classifier, gemini=gemini)
        latencies.append((time.perf_counter() - started) * 1000)
        rows.append({
            "id": case["id"], "family": case["family"], "expected": case["expected"], "verdict": report.verdict, "risk": report.risk,
            "correct": report.verdict == case["expected"], "signals": sorted({h.signal for h in report.findings}),
            "agrees_with_classifier": report.agrees_with_classifier, "disagreement_reason": report.disagreement_reason,
            "gemini_used": report.gemini_used, "gemini_error": report.gemini_error, "user_message_bn": report.user_message_bn,
            "prompt_chars": len(report.prompt), "apps": len(bundle.apps),
        })
    correct = sum(r["correct"] for r in rows)
    by_family: dict[str, dict] = {}
    for r in rows:
        f = by_family.setdefault(r["family"], {"cases": 0, "correct": 0})
        f["cases"] += 1
        f["correct"] += int(r["correct"])
    judged = [r for r in rows if r["agrees_with_classifier"] is not None]
    return {
        "cases": len(rows), "correct": correct, "target": TARGET_CORRECT, "passed": correct >= TARGET_CORRECT,
        "by_family": by_family,
        "gemini_calls": sum(r["gemini_used"] for r in rows), "gemini_errors": sum(bool(r["gemini_error"]) for r in rows),
        "agreement_rate": round(sum(r["agrees_with_classifier"] for r in judged) / len(judged), 3) if judged else None,
        "disagreements": [{"id": r["id"], "reason": r["disagreement_reason"]} for r in judged if r["agrees_with_classifier"] is False],
        "latency_ms": {"p50": round(statistics.median(latencies), 1), "p95": round(percentile(latencies, 0.95), 1)},
        # Prompt size of the calls that reached the model (chars; about 4 chars per token of JSON): the whole
        # inventory must not go in, so the two 300-app cases must cost what the 3-app ones do.
        "prompt_chars": {"p50": round(statistics.median(prompts), 1), "max": max(prompts), "largest_bundle_apps": max(r["apps"] for r in rows)} if (prompts := [r["prompt_chars"] for r in rows if r["prompt_chars"]]) else {},
        "rows": rows,
    }


def gemini_call_via_risk_api():
    """The engine's own Gemini call (thread pool, HTTP timeout, thinking level), so the eval measures what ships."""
    from app import appsafety_engine

    return appsafety_engine._gemini


def markdown(summary: dict) -> str:
    m = summary["classifier"]["metrics"]
    lines = [f"# App Safety Check eval — {summary['generated_at']}", "",
             "## Permission classifier (LightGBM)", "", "| Metric | Value |", "|---|---|",
             f"| Dataset | {summary['classifier']['dataset']['name']} ({summary['classifier']['dataset']['rows']} apps, label `{summary['classifier']['dataset']['label_column']}`) |",
             f"| Accuracy | {m['accuracy']} |", f"| Macro-F1 | {m['macro_f1']} |", f"| ROC-AUC | {m['roc_auc']} |",
             f"| Confusion (benign, malicious) | {m['confusion_matrix']['rows']} |", f"| Predict ms/app | {m['predict_ms_per_app']} |",
             f"| Model size | {summary['classifier']['model_bytes'] / 1e6:.2f} MB |", f"| Gates | {'PASS' if summary['classifier']['gates_passed'] else 'FAIL'} |", ""]
    for name in ("offline", "gemini"):
        block = summary.get(name)
        if not block:
            continue
        lines += [f"## Synthetic cases, {name} path", "", f"- {block['correct']}/{block['cases']} verdicts correct (target {block['target']}): {'PASS' if block['passed'] else 'FAIL'}",
                  f"- latency p50 {block['latency_ms']['p50']} ms, p95 {block['latency_ms']['p95']} ms"]
        if block.get("prompt_chars"):
            lines.append(f"- prompt size p50 {block['prompt_chars']['p50']:,} chars, max {block['prompt_chars']['max']:,} chars (largest bundle {block['prompt_chars']['largest_bundle_apps']} apps)")
        if block["agreement_rate"] is not None:
            lines.append(f"- Gemini agrees with the classifier/rules on {block['agreement_rate'] * 100:.0f}% of judged cases; disagreements: {block['disagreements'] or 'none'}")
        if block["gemini_errors"]:
            lines.append(f"- Gemini errors: {block['gemini_errors']} (fell back per FR-4)")
        lines += ["", "| Case | Family | Expected | Got | Signals |", "|---|---|---|---|---|"]
        lines += [f"| {r['id']} | {r['family']} | {r['expected']} | {r['verdict']}{'' if r['correct'] else ' ✗'} | {', '.join(r['signals']) or '—'} |" for r in block["rows"]]
        lines.append("")
    ds = summary["classifier"].get("dataset", {})
    future = summary["classifier"].get("future_metrics") or {}
    future_text = "; ".join(f"unseen {y}: ROC-AUC {fm['roc_auc']}, recall {fm['recall_at_0.8']:.2f} at p≥0.80, {fm['benign_flag_rate_at_0.8'] * 100:.1f}% benign flagged" for y, fm in sorted(future.items())) or "no future-year run recorded"
    lines += [f"Dataset: {ds.get('name', '')}, train years {ds.get('train_years', '')}. {future_text}. VirusTotal labels lag by about a year, so the newest banking-trojan behaviours are enforced by rules; the classifier is one of three signals beside the rules and Gemini. Synthetic cases are hand-written and inflate the picture.", ""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gemini", action="store_true", help="also run the cases through Gemini triage (needs RISK_MW_GENAI_ENABLED=true and a backend)")
    ap.add_argument("--out", type=Path, default=RESULTS / "appsafety.json")
    args = ap.parse_args(argv)
    meta = json.loads((ARTEFACTS / "meta.json").read_text(encoding="utf-8"))
    clf = AppClassifier.load(ARTEFACTS)

    def classifier(perms):
        prediction = clf.predict(perms)
        return prediction.probability, prediction.contributions
    cases = load_cases()
    summary = {"generated_at": datetime.now(UTC).isoformat(), "classifier": {k: meta[k] for k in ("version", "dataset", "features", "metrics", "future_metrics", "gates", "gates_passed", "model_bytes", "top_features") if k in meta}, "offline": run_cases(cases, classifier, None)}
    if args.gemini:
        summary["gemini"] = run_cases(cases, classifier, gemini_call_via_risk_api())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=1, ensure_ascii=False), encoding="utf-8")
    args.out.with_suffix(".md").write_text(markdown(summary), encoding="utf-8")
    off = summary["offline"]
    print(f"classifier: acc {meta['metrics']['accuracy']} auc {meta['metrics']['roc_auc']} | offline cases {off['correct']}/{off['cases']} p95 {off['latency_ms']['p95']} ms", end="")
    if "gemini" in summary:
        g = summary["gemini"]
        print(f" | gemini cases {g['correct']}/{g['cases']} agreement {g['agreement_rate']} errors {g['gemini_errors']} p95 {g['latency_ms']['p95']} ms", end="")
    print(f" -> {args.out}")
    wrong = [r for r in off["rows"] if not r["correct"]]
    for r in wrong:
        print(f"  offline miss: {r['id']} expected {r['expected']} got {r['verdict']} {r['signals']}")
    return 0 if off["passed"] and summary.get("gemini", {"passed": True})["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
