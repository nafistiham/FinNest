"""Three payments, run through the real rule engine, with the path each one took.

This is the animated half of the system picture: press play and watch one payment leave a phone,
collect an answer from each service, and have those answers merge into a decision.

**Nothing here is a scripted outcome.** Every scenario is a real `ScoreRequest` put through
risk-mw's own `evaluate()` and `decide()` - the same two functions the deployed service calls, and
the same two the replay in the overview uses. The reason codes, the weights, the band and the
decision are whatever the engine says they are. If someone changes a threshold in `rules.py`,
these scenarios change with it, and if that makes a scenario stop demonstrating what its name
claims, the test says so rather than the page quietly lying.

What is written: the scenario's name, the one-line situation, and which box on the map each input
comes from. The inputs themselves are the flags a phone would actually post.
"""

from __future__ import annotations

from typing import Any

import json
import os
from pathlib import Path
from functools import lru_cache

from api.risk_mw import REPO, DemoFlags, ScoreRequest, Txn, decide, evaluate, get_settings
import random

from app import ato
from bhorosha_ato import synth
from app import rules as rules_module

# Where each input on a ScoreRequest comes from, so the animation can light the right edge. These
# are the node ids from `architecture.SYSTEMS`.
SOURCE: dict[str, str] = {
    "call_active": "app",
    "sim_swap": "app",
    "screen_share": "app",
    "caller_in_contacts": "app",
    "app_safety_verdict": "risk-mw",
    "scam_score": "risk-mw",
    "inbound_mule_score": "risk-mw",
    "amount_bdt": "app",
    "is_new_payee": "app",
}

# The code each input can make fire. Used only to report whether an input was *read* - an input
# posted that no rule looks at is worth seeing, and is why the coached scenario below does not
# claim the call did anything to a payment.
FIRES: dict[str, str] = {
    "call_active": "CALL_ACTIVE_NON_CONTACT",
    "sim_swap": "SIM_CHANGED_24H",
    "screen_share": "SCREEN_SHARE_ACTIVE",
    "app_safety_verdict": "APP_SAFETY_BLOCK",
    "scam_score": "SCAM_CONVERSATION",
    "inbound_mule_score": "DEST_MULE_RISK",
    "is_new_payee": "NEW_PAYEE_ABOVE_P95",
    "amount_bdt": "NEW_PAYEE_ABOVE_P95",
}

# Which part answers each one. Written, and checked against the module that owns it.
ANSWERED_BY: dict[str, str] = {
    "call_active": "device_signals",
    "sim_swap": "device_signals",
    "screen_share": "device_signals",
    "caller_in_contacts": "device_signals",
    "app_safety_verdict": "app-safety",
    "scam_score": "scam",
    "inbound_mule_score": "mule-lgbm",
    "amount_bdt": "ledger",
    "is_new_payee": "ledger",
}

SCENARIOS: tuple[dict[str, Any], ...] = (
    {
        "id": "ordinary",
        "name": "An ordinary payment",
        "name_bn": "সাধারণ একটা পেমেন্ট",
        "story": "Rina pays someone she has paid before. Nothing else is happening.",
        "story_bn": "রিনা এমন কাউকে টাকা পাঠাচ্ছেন যাকে আগেও পাঠিয়েছেন। আর কিছুই ঘটছে না।",
        "txn": {"type": "send_money", "amount_bdt": 1200.0, "to_account": "acct_rahima", "is_new_payee": False},
        "flags": {},
    },
    {
        "id": "mule",
        "name": "The payee is a mule",
        "name_bn": "প্রাপক একজন মিউল",
        "story": "A first payment, larger than usual, to an account money has reached this way before.",
        "story_bn": "প্রথমবার পাঠানো, স্বাভাবিকের চেয়ে বড়, এমন অ্যাকাউন্টে যেখানে আগেও এভাবে টাকা গেছে।",
        "txn": {"type": "send_money", "amount_bdt": 24000.0, "to_account": "acct_01070", "is_new_payee": True},
        "flags": {"inbound_mule_score": 0.87},
    },
    {
        "id": "coached",
        "name": "She is being talked through it",
        "name_bn": "কেউ বলে বলে করাচ্ছে",
        "story": "Her own hand, her screen shared, and a voice telling her what to tap.",
        "story_bn": "তাঁর নিজেরই হাত, স্ক্রিন শেয়ার করা, আর একটা কণ্ঠ বলে দিচ্ছে কোথায় চাপতে হবে।",
        "txn": {"type": "send_money", "amount_bdt": 18000.0, "to_account": "acct_00036", "is_new_payee": True},
        "flags": {"screen_share": True, "scam_score": 0.8},
        "behaviour_coached": True,
    },
    {
        "id": "stranger-hand",
        "name": "A hand the phone does not know",
        "name_bn": "ফোনের অচেনা হাত",
        "story": "The same phone, but the account has no enrolled profile, so the population model judges it.",
        "story_bn": "একই ফোন, কিন্তু অ্যাকাউন্টটির কোনো এনরোল করা প্রোফাইল নেই, তাই পপুলেশন মডেল বিচার করে।",
        "txn": {"type": "send_money", "amount_bdt": 9000.0, "to_account": "acct_01288", "is_new_payee": True},
        "flags": {},
        # No enrolled profile for this id, so `behaviour_hits` falls back to the cold-start model -
        # which is exactly the situation the _COLD_START suffix exists to mark.
        "behaviour_user": "u_not_enrolled",
    },
    {
        "id": "watchlisted",
        "name": "Already on the watch-list",
        "name_bn": "আগেই ওয়াচ-লিস্টে",
        "story": "Case Zero named this payee in CZ-0001. The payment path does not read that list.",
        "story_bn": "কেস জিরো এই প্রাপককে CZ-0001-এ চিহ্নিত করেছে। পেমেন্টের পথ ওই লিস্টটা পড়ে না।",
        "txn": {"type": "send_money", "amount_bdt": 3400.0, "to_account": "acct_01870", "is_new_payee": False},
        # acct_01870 is mule_L2 on the live watch-list and the mule model scores it 0.0001 - which
        # is the whole of gate G4 in one payment.
        "flags": {"inbound_mule_score": 0.0001},
        "watchlisted": "CZ-0001",
    },
    {
        "id": "pin-reset",
        "name": "A PIN reset, mid-call",
        "name_bn": "কলের মাঝে পিন রিসেট",
        "story": "Not a payment at all. She is changing her PIN while on a call she did not expect.",
        "story_bn": "পেমেন্টই নয়। অপ্রত্যাশিত একটা কলে থাকা অবস্থায় তিনি পিন বদলাচ্ছেন।",
        "txn": {"type": "pin_reset", "amount_bdt": 0.0, "to_account": "self", "is_new_payee": False},
        "flags": {"call_active": True},
    },
)


# One row per check, in the order a payment meets them. `code` is what that check can make fire;
# `reads` is the request field it looks at. The behaviour check is listed with no code because it
# cannot reach one here - see `_verdict`.
CHECKS: tuple[dict[str, Any], ...] = (
    {"id": "device_signals", "label": "device signals", "reads": "sim_swap, screen_share, call_active",
     "codes": ("SIM_CHANGED_24H", "SCREEN_SHARE_ACTIVE", "CALL_ACTIVE_NON_CONTACT")},
    {"id": "ato-identity", "label": "behaviour", "reads": "behaviour vector",
     "codes": ("ATO_BEHAVIOUR_MISMATCH", "COACHING_SUSPECTED")},
    {"id": "app-safety", "label": "app check", "reads": "app_safety_verdict",
     "codes": ("APP_SAFETY_BLOCK", "APP_SAFETY_CAUTION")},
    {"id": "scam", "label": "call", "reads": "scam_score", "codes": ("SCAM_CONVERSATION",)},
    {"id": "mule-lgbm", "label": "payee", "reads": "inbound_mule_score", "codes": ("DEST_MULE_RISK",)},
    {"id": "ledger", "label": "her history", "reads": "amount_bdt, is_new_payee",
     "codes": ("NEW_PAYEE_ABOVE_P95",)},
)


# Enrolment sessions captured on a real handset are personal data and are not part of the public
# repo. Point CONSOLE_ATO_SESSIONS at a JSONL file of your own captures to turn the behaviour step on;
# without it the step reports "off" and every other check still runs.
SESSIONS = Path(os.environ.get("CONSOLE_ATO_SESSIONS")
                or REPO / "models" / "ato" / "enrolment" / "rina_phone_sessions.jsonl")


@lru_cache(maxsize=1)
def _session_vector() -> tuple[float, ...] | None:
    """One real behaviour vector, captured from the demo phone during enrolment.

    Fifty-five features measured off a handset - how it was held, how the keys were pressed. Not
    generated here: a made-up vector would score as whatever I chose, which is the opposite of the
    point.
    """
    try:
        with SESSIONS.open() as fh:
            row = json.loads(fh.readline())
        return tuple(float(x) for x in row["features"])
    except (OSError, ValueError, KeyError):
        return None


def _behaviour(user_id: str, in_call: bool, coached: bool = False) -> dict[str, Any]:
    """What the behaviour model says about this hand on this phone.

    Run for real when the behaviour artefacts are present: `api/risk_mw.py` points the service at them.
    An enrolled user scored against their own session comes back clean; a user with no profile is
    judged by the population model and says so in the code it returns.
    """
    vector = _session_vector()
    if vector is not None and coached:
        # The project's own generator, the one the ATO eval uses: it keeps the grip and moves the
        # tempo, because a coached payment is her hand being talked through a payment, not someone
        # else's hand. No public dataset records that, which is why this tool exists.
        vector = synth.coach(vector, random.Random(7))
    if vector is None:
        return {"verdict": "off", "code": None, "weight": None,
                "test": "enrolment sessions not in this build"}
    hits = ato.behaviour_hits(user_id, vector, in_call=in_call)
    if not hits:
        return {"verdict": "clear", "code": None, "weight": None,
                "test": "matches the enrolled hand"}
    hit = hits[0]
    code = hit.reason.code
    weight = round(hit.reason.weight, 3)
    if code.startswith("COACHING"):
        # The identity model still recognises her; it is the tempo that changed.
        test = f"{weight} — her hand, someone else's tempo"
    elif code.endswith("_COLD_START"):
        test = f"{weight} against the population model"
    else:
        test = f"{weight} against the enrolled hand"
    return {"verdict": "raised", "code": code, "weight": weight, "test": test}


def _verdict(check: dict[str, Any], txn: dict[str, Any], flags: dict[str, Any],
             hits: dict[str, float], settings: Any) -> dict[str, Any]:
    """What one check concluded about this payment, and the comparison it concluded it from.

    Every check reports, including the ones that found nothing - "no rule fired" told a reader
    nothing about whether the check ran and was satisfied, or never ran at all. Three verdicts:
    `raised` when it made a code fire, `clear` when it looked and was satisfied, and `off` when it
    could not look. Nothing here decides anything; `evaluate()` already did, and `hits` is its
    answer.
    """
    fired = [c for c in check["codes"] if c in hits]
    if fired:
        code = fired[0]
        return {"verdict": "raised", "code": code, "weight": hits[code],
                "test": _test_for(code, txn, flags, settings)}

    return {"verdict": "clear", "code": None, "weight": None,
            "test": _clear_text(check["id"], txn, flags, settings)}


def _test_for(code: str, txn: dict[str, Any], flags: dict[str, Any], settings: Any) -> str:
    """The comparison that made this code fire, with the threshold the engine is using."""
    if code == "DEST_MULE_RISK":
        return f"{flags['inbound_mule_score']} > {settings.mule_hold_threshold}"
    if code == "SCAM_CONVERSATION":
        return f"{flags['scam_score']} >= {rules_module.SCAM_SCORE_HOLD_THRESHOLD}"
    if code == "NEW_PAYEE_ABOVE_P95":
        return f"new payee and ৳{txn['amount_bdt']:,.0f} > ৳{settings.default_p95_amount_bdt:,.0f}"
    if code == "APP_SAFETY_BLOCK":
        return f'verdict is "{flags.get("app_safety_verdict")}"'
    if code == "APP_SAFETY_CAUTION":
        # rules.py weighs it by the source(s) that said CAUTION and caps it below band_high: a warning, never a hold.
        return f'verdict is "{flags.get("app_safety_verdict")}", weighed ≤ {settings.app_safety_caution_weight_cap}'
    if code == "SCREEN_SHARE_ACTIVE":
        return "screen is shared"
    if code == "SIM_CHANGED_24H":
        return f"SIM changed within {settings.sim_change_hold_hours}h"
    if code == "CALL_ACTIVE_NON_CONTACT":
        return "on a call, and this is a PIN reset"
    return code


def _clear_text(check_id: str, txn: dict[str, Any], flags: dict[str, Any], settings: Any) -> str:
    """Why a check was satisfied - the same comparison, landing the other way."""
    if check_id == "mule-lgbm":
        return f"{flags.get('inbound_mule_score', 0.0)} ≤ {settings.mule_hold_threshold}"
    if check_id == "scam":
        score = flags.get("scam_score", 0.0)
        if txn["type"] not in rules_module.SCAM_HOLD_TXN_TYPES:
            return f"{txn['type']} is not held on a call"
        return f"{score} < {rules_module.SCAM_SCORE_HOLD_THRESHOLD}"
    if check_id == "app-safety":
        return f'verdict is "{flags.get("app_safety_verdict", "SAFE")}"'
    if check_id == "device_signals":
        on = [k for k in ("sim_swap", "screen_share", "call_active") if flags.get(k)]
        if not on:
            return "nothing raised on the handset"
        return f"{', '.join(on)} on, but not enough on its own"
    if check_id == "ledger":
        if not txn["is_new_payee"]:
            return "a payee she has paid before"
        return f"৳{txn['amount_bdt']:,.0f} ≤ ৳{settings.default_p95_amount_bdt:,.0f}"
    return "satisfied"


def _behaviour_raw(scenario: dict[str, Any]) -> tuple[Any, ...]:
    """The behaviour hits for this scenario, as the service would collect them."""
    vector = _session_vector()
    if vector is None:
        return ()
    if scenario.get("behaviour_coached"):
        vector = synth.coach(vector, random.Random(7))
    return ato.behaviour_hits(
        scenario.get("behaviour_user", "rina"),
        vector,
        in_call=bool(scenario["flags"].get("call_active")),
    )


def run(scenario: dict[str, Any]) -> dict[str, Any]:
    """Score one scenario with the engine the service runs, and report what it said."""
    settings = get_settings()
    request = ScoreRequest(
        user_id="rina",
        session_id=f"scenario-{scenario['id']}",
        txn=Txn(**scenario["txn"]),
        demo_flags=DemoFlags(**scenario["flags"]),
    )
    hits = evaluate(request, settings.default_p95_amount_bdt, settings)
    # The behaviour model returns rule hits, not a score, and `risk.py` appends them before
    # deciding - so this does too. Without it the picture showed a behaviour hit at 0.856 and a sum
    # of 0.6, which is a fair thing for a reader to call a lie.
    hits = (*hits, *_behaviour_raw(scenario))
    result = decide(request, hits, 0.0, settings.model_version, settings)
    return {
        "id": scenario["id"],
        "name": scenario["name"],
        "name_bn": scenario["name_bn"],
        "story": scenario["story"],
        "story_bn": scenario["story_bn"],
        "txn": scenario["txn"],
        "checks": [
            {**{k: c[k] for k in ("id", "label", "reads")},
             **(_behaviour(scenario.get("behaviour_user", "rina"),
                           bool(scenario["flags"].get("call_active")),
                           coached=bool(scenario.get("behaviour_coached")))
                if c["id"] == "ato-identity"
                else _verdict(c, scenario["txn"], scenario["flags"],
                              {h.reason.code: h.reason.weight for h in hits}, settings))}
            for c in CHECKS
        ],
        # Straight from the engine. Every field below is its answer, not ours.
        "hits": [
            {
                "code": h.reason.code,
                "weight": h.reason.weight,
                "decision": h.decision,
                "text_bn": h.reason.text_bn,
                "text_en": h.reason.text_en,
            }
            for h in hits
        ],
        "decision": result.decision,
        "band": result.band,
        "risk_score": result.risk_score,
        "model_version": result.model_version,
        "watchlisted": scenario.get("watchlisted"),
    }


def all_scenarios() -> list[dict[str, Any]]:
    return [run(s) for s in SCENARIOS]
