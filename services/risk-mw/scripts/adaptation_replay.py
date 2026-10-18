"""The "dynamic knowledge" replay. A PAID check: Gemini scores every caller turn, twice.

    python scripts/adaptation_replay.py --dry-run          # the plan, the card versions and the most it could cost; no model call
    RISK_MW_GENAI_ENABLED=true RISK_MW_PROJECT_ID=... RISK_MW_GENAI_BACKEND=vertex python scripts/adaptation_replay.py

One stipend-OTP call, which never says "OTP" or "code", goes turn by turn through scam.score_turn (the code /v1/scam/turn
runs): first with the active card set minus the stipend card and its two examples (the knowledge before that card was
added; or --before-version to name a card file), then with the active set. For each run it records the turn of detection,
the card the verdict names and the cards version, and writes eval/results/adaptation_replay.json. One synthetic call is a
demonstration, not a measurement. Spend goes on eval/budget.py's SpendLedger: the reserve is checked before each model call
and the cost recorded after.
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from app import genai_client, scam, tactic_cards  # noqa: E402
from app.contracts import ScamTurnRequest, Turn  # noqa: E402
from app.settings import Settings, get_settings  # noqa: E402
from app.tactic_cards import Cards  # noqa: E402
from eval.budget import BudgetExceeded, SpendLedger  # noqa: E402

CARD = "stipend_benefit_otp"
OUT = HERE / "eval" / "results" / "adaptation_replay.json"
# About 8k prefix tokens and a short transcript in, a few hundred out, on gemini-3.5-flash-lite ($0.30 / $2.50 per million).
RESERVE_PER_CALL = 0.006
SECRET_TURN = 4
# Non-native draft, native_check: pending. Unlike the example bank's stipend call, it says neither "OTP" nor "code".
CALL = (
    {"speaker": "caller", "text": "আসসালামু আলাইকুম, আমি জেলা শিক্ষা অফিস থেকে বলছি। আপনার ছেলের উপবৃত্তির টাকা এই মাসে আসেনি, জানেন তো?",
     "native_check": "pending"},
    {"speaker": "user", "text": "জি, এখনও আসেনি। কেন?", "native_check": "pending"},
    {"speaker": "caller", "text": "আপনার নম্বরটা এখনও যাচাই হয়নি। এখনই একটা মেসেজ যাবে, ওটা খুলে রাখুন।", "native_check": "pending"},
    {"speaker": "user", "text": "হ্যাঁ, একটা মেসেজ এসেছে।", "native_check": "pending"},
    {"speaker": "caller", "text": "মেসেজের ভেতরের সংখ্যাগুলো আমাকে পড়ে শোনান, তাহলে আজই টাকা ঢুকে যাবে।", "native_check": "pending"},
    {"speaker": "user", "text": "এক মিনিট, দেখছি।", "native_check": "pending"},
    {"speaker": "caller", "text": "তাড়াতাড়ি করেন, অফিস বন্ধ হয়ে যাবে।", "native_check": "pending"},
)


def turns() -> tuple[Turn, ...]:
    return tuple(Turn(speaker=t["speaker"], text=t["text"], ts=i * 6.0) for i, t in enumerate(CALL))


def caller_indices() -> list[int]:
    return [i for i, t in enumerate(CALL) if t["speaker"] == "caller"]


def card_sets(settings: Settings, before_version: str | None = None) -> tuple[Cards, Cards]:
    active = tactic_cards.load(settings)
    before = tactic_cards.load(settings, version=before_version) if before_version else active.without(CARD)
    return before, active


def replay(cards: Cards, label: str, settings: Settings, ledger: SpendLedger | None = None) -> dict:
    """Score the call turn by turn with this card set; the first turn at or above the alert is the turn of detection."""
    calls: list = []
    original = genai_client.call

    def counting(*args, **kwargs):
        result = original(*args, **kwargs)
        calls.append(result)
        return result

    session, call, trace, detected, stopped = f"adapt-{label}-{uuid.uuid4().hex[:8]}", turns(), [], None, None
    genai_client.call = counting
    try:
        for i in caller_indices():
            if ledger is not None:
                ledger.check(RESERVE_PER_CALL)
            before = len(calls)
            out = scam.score_turn(ScamTurnRequest(session_id=session, turns=call[: i + 1]), settings, cards=cards)
            spent = sum(c.cost_usd for c in calls[before:])
            if ledger is not None:
                ledger.record(spent)
            trace.append({"turn": i, "verdict": out.verdict, "rolling": out.rolling_score, "rule_hits": list(out.rule_hits),
                          "matched_card": out.matched_card, "tactics": list(out.tactics), "ask": out.ask, "model": len(calls) > before,
                          "cached_tokens": sum(c.tokens_cached for c in calls[before:]), "cost_usd": round(spent, 6)})
            if detected is None and out.rolling_score >= scam.ALERT_PAIR:
                detected = i
    except BudgetExceeded as exc:
        stopped = str(exc)
    finally:
        genai_client.call = original
    at = next((t for t in trace if t["turn"] == detected), trace[-1] if trace else {})
    return {"label": label, "cards_version": cards.version, "has_card": cards.card(CARD) is not None, "detected_turn": detected,
            "matched_card": at.get("matched_card"), "model_calls": len(calls), "cost_usd": round(sum(c.cost_usd for c in calls), 6),
            "stopped": stopped, "trace": trace}


def run(settings: Settings, ledger: SpendLedger | None, before_version: str | None = None) -> dict:
    before, active = card_sets(settings, before_version)
    runs = [replay(before, "before", settings, ledger), replay(active, "after", settings, ledger)]
    return {"call": "stipend_otp_without_trigger_words", "card": CARD, "secret_turn": SECRET_TURN, "turns": len(CALL), "runs": runs,
            "note": "one synthetic call, non-native Bangla (native_check: pending); a demonstration of a card edit, not a measurement"}


def dry_run(settings: Settings, before_version: str | None = None) -> str:
    before, active = card_sets(settings, before_version)
    calls = 2 * len(caller_indices())
    return "\n".join([
        f"adaptation replay: one {len(CALL)}-turn stipend-OTP call, the code asked at turn {SECRET_TURN}, scored at caller turns {caller_indices()}",
        f"  before: cards {before.version} ({len(before.archetypes)} cards, {len(before.examples)} examples, has {CARD}: {before.card(CARD) is not None})",
        f"  after:  cards {active.version} ({len(active.archetypes)} cards, {len(active.examples)} examples, has {CARD}: {active.card(CARD) is not None})",
        f"  {calls} model calls on role volume, reserve ${RESERVE_PER_CALL:.3f} each: at most ${calls * RESERVE_PER_CALL:.3f}",
        f"  would write {OUT}",
        "dry run: no model call, nothing written"])


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print the plan and the most it could cost; no model call, nothing written")
    parser.add_argument("--before-version", help=f"a card file version for the first run (default: the active set without {CARD})")
    parser.add_argument("--out", type=Path, default=OUT, help="where to write the result JSON")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    settings = get_settings()
    if args.dry_run:
        print(dry_run(settings, args.before_version))
        return
    try:
        genai_client.select_backend(settings)
    except genai_client.GenAIDisabled as exc:
        raise SystemExit(f"Gemini is off ({exc}); run with --dry-run, or set RISK_MW_GENAI_ENABLED=true and a backend") from exc
    ledger = SpendLedger()
    result = {**run(settings, ledger, args.before_version), "spent_usd_ledger": ledger.spent()}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({r["label"]: {k: r[k] for k in ("cards_version", "detected_turn", "matched_card")} for r in result["runs"]}, indent=2))


if __name__ == "__main__":
    main()
