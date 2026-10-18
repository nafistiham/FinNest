"""Transcript-first demo path (spec: built first; the live-speech path is a bonus).

A scripted dialogue goes turn by turn through /v1/scam/turn, then the pending transaction through
/v1/risk/score and /v1/intervene (Apa's warning, generated for the call from its evidence ledger), exactly
as the app would call them. With Gemini off no line validates and the hold is the floor: earcon,
vibration and the card, no words. `post(path, body) -> dict` is a TestClient in-process or HTTP against a
deployed risk-mw (scripts/replay_demo.py).
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

SCRIPTS_FILE = Path(__file__).resolve().parent.parent / "seed" / "scam_scripts.jsonl"
ALERT = 0.7
Post = Callable[[str, dict], dict]


def load_scripts(path: Path = SCRIPTS_FILE) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def replay(post: Post, script: dict, flags: dict | None = None, user_id: str = "rina", amount_bdt: float = 4800.0) -> dict:
    session = f"demo-{script['id']}"
    turns, timeline, detected = script["turns"], [], None
    for i in range(len(turns)):
        pending = script["pending_action"] if script.get("pending_turn") is not None and i >= script["pending_turn"] else None
        out = post("/v1/scam/turn", {"session_id": session, "turns": turns[: i + 1], "caller_number": script.get("caller_number"), "pending_action": pending})
        timeline.append({"turn": i, "speaker": turns[i]["speaker"], "text": turns[i]["text"], **{k: out[k] for k in (
            "scam_type", "confidence", "requested_secret", "rolling_score", "recommended_action", "evidence_quote")}})
        if detected is None and out["rolling_score"] >= ALERT:
            detected = i
    result = {"script": script["id"], "label": script["label"], "secret_turn": script.get("secret_turn"), "detected_turn": detected,
              "timeline": timeline, "decision": None, "reasons": [], "apa": None}
    if not script.get("pending_action"):
        return result
    action = script["pending_action"]
    txn = {"type": action, "amount_bdt": amount_bdt if action == "send_money" else 0.0, "is_new_payee": action == "send_money",
           "to_account": "acct_demo_payee" if action == "send_money" else None, "txn_id": f"demo-{script['id']}"}
    score = post("/v1/risk/score", {"user_id": user_id, "session_id": session, "txn": txn, "demo_flags": flags or {}})
    reasons = sorted(score["reasons"], key=lambda r: -r["weight"])
    result.update(decision=score["decision"], reasons=[r["code"] for r in reasons], risk_score=score["risk_score"])
    if score["decision"] != "allow":
        last_caller = next((t["text"] for t in reversed(turns) if t["speaker"] == "caller"), "")
        trigger = reasons[0]["code"] if reasons else "generic"
        apa = post("/v1/intervene", {"user_id": user_id, "trigger": trigger, "txn": txn, "transcript_snippet": last_caller,
                                     "session_id": session})
        result["apa"] = {k: apa.get(k) for k in ("script_bn", "script_en", "ui", "lines", "earcon", "vibrate", "speak_on_device",
                                                 "warning_id", "ledger_hash", "audio_asset_id")}
    return result
