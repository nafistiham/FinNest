"""Turn the seed world into the one object the console renders.

Every figure the operator console shows is produced here, once, from `data/seed/` replayed
through risk-mw's own rule engine and the trained mule scorer. The console computes no fraud
metric of its own; it renders what this module returns.

Three properties are structural rather than remembered, because these functional
requirements are easy to agree with and easy to forget:

* every section carries a `badge` saying whether a model, a rule, a stub or nothing stands behind it;
* every rate is emitted next to its denominator, by the same function;
* `catch_rate` and `false_positive_rate` are built together, so neither can ship without the other.

The replay is deterministic: the same seed, artefacts and thresholds give the same numbers, which is
what lets `tests/test_fixture_is_current.py` fail on a stale fixture instead of shipping one.
"""

from __future__ import annotations

import collections
import json
import random
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from api.risk_mw import (
    REPO,
    SEED_DIR,
    DemoFlags,
    ScoreRequest,
    Txn,
    decide,
    evaluate,
    get_settings,
    mule,
    scenario_now,
)

DHAKA = ZoneInfo("Asia/Dhaka")

# Every code the rule engine and the behaviour adapter can emit. The seed world can only make a
# couple of them fire, and naming the ones that cannot is the difference between an honest chart and
# one that reads as "the other rules never catch anything". Which list is which is computed from the
# replay, never typed in, so this tuple only has to be complete.
#
# It was not: MODEL_RISK (rules.py:101) and MONEY_LOCK_ACTIVE (rules.py:111) are emitted by the rule
# engine, and app/ato.py:323 appends _COLD_START to the behaviour code when the verdict is not
# personalised. A code missing here is a code that silently appears in neither column.
# APP_SAFETY_CAUTION went missing the same way when it was added, so tests/test_codes.py now reads the codes out
# of risk-mw's source and fails on the next one.
ALL_CODES: tuple[str, ...] = (
    "CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H", "NEW_PAYEE_ABOVE_P95", "APP_SAFETY_BLOCK",
    "APP_SAFETY_CAUTION", "DEST_MULE_RISK", "SCREEN_SHARE_ACTIVE", "SCAM_CONVERSATION",
    "ATO_BEHAVIOUR_MISMATCH", "ATO_BEHAVIOUR_MISMATCH_COLD_START", "COACHING_SUSPECTED",
    "MODEL_RISK", "MONEY_LOCK_ACTIVE",
)
CANNOT_FIRE_REASON = (
    "the seed world carries no call state, SIM change, screen share, app-safety verdict, scam score "
    "or behaviour vector, so only the two ledger-side rules can fire"
)
CANNOT_FIRE_REASON_BN = (
    "seed জগতে কল স্টেট, সিম বদল, স্ক্রিন শেয়ার, অ্যাপ-সেফটি রায়, স্ক্যাম স্কোর বা বিহেভিয়ার ভেক্টর "
    "কিছুই নেই, তাই লেজার-ভিত্তিক দুটো রুলই কেবল জ্বলতে পারে"
)
DECISIONS: tuple[str, ...] = ("allow", "step_up", "delay", "hold", "block")
BANDS: tuple[str, ...] = ("low", "medium", "high", "critical")
STOPPING: frozenset[str] = frozenset({"hold", "block"})

SAMPLE_SEED = 7          # the random sample of unlabelled accounts, fixed so the board never shuffles
SAMPLE_ACCOUNTS = 250
BOARD_SIZE = 25
HISTOGRAM_BUCKETS = 10


# --- loading ----------------------------------------------------------------

def _rows(seed_dir: Path, name: str) -> list[dict[str, Any]]:
    with (seed_dir / f"{name}.jsonl").open() as fh:
        return [json.loads(line) for line in fh]


def load_world(seed_dir: Path = SEED_DIR) -> dict[str, Any]:
    """Every seed table we touch, read once."""
    tables = ("transactions", "customers", "accounts", "labels", "agents", "merchants",
              "devices", "sims", "sim_events", "device_links")
    world = {name: _rows(seed_dir, name) for name in tables}
    world["transactions"].sort(key=lambda r: r["ts"])
    return world


def world_counts(world: dict[str, Any]) -> dict[str, Any]:
    tx = world["transactions"]
    days = sorted({r["ts"][:10] for r in tx})
    return {
        "customers": len(world["customers"]),
        "accounts": len(world["accounts"]),
        "transactions": len(tx),
        "agents": len(world["agents"]),
        "merchants": len(world["merchants"]),
        "devices": len(world["devices"]),
        "sims": len(world["sims"]),
        "sim_events": len(world["sim_events"]),
        "device_links": len(world["device_links"]),
        "labelled_accounts": len(world["labels"]),
        "rings": len({r["ring_id"] for r in world["labels"]}),
        "first_day": days[0],
        "last_day": days[-1],
        "days": len(days),
        "badge": "SYNTHETIC",
    }


# --- the replay -------------------------------------------------------------

def replay(world: dict[str, Any]) -> dict[str, Any]:
    """Score every send_money row the way the live service would, and count what happened.

    `is_new_payee` is derived rather than read: the seed has no such column, and the first time a
    (sender, payee) pair appears in time order is exactly what the app would report.
    """
    settings = get_settings()
    p95 = settings.default_p95_amount_bdt
    # Every payee is scored on the evidence before the server's scenario clock, the moment the live service scores at
    # (app.clock), never on the whole world: one clock, so one score per payee.
    as_of = scenario_now(settings)
    payee_score: dict[str, float] = {}

    seen_pairs: set[tuple[str, str]] = set()
    mix = collections.Counter({d: 0 for d in DECISIONS})
    bands = collections.Counter({b: 0 for b in BANDS})
    codes: collections.Counter[str] = collections.Counter()
    cooccurrence: collections.Counter[str] = collections.Counter()
    confusion = collections.Counter({"catch": 0, "miss": 0, "false_positive": 0, "true_negative": 0})
    value = collections.Counter({"protected": 0.0, "friction": 0.0})
    histogram = [0] * HISTOGRAM_BUCKETS
    daily: dict[str, dict[str, int]] = {}
    # Per payee, so §G4's "the watch-list is not read at payment time" can be a number rather than
    # a sentence. Dropped before the fixture is written - it is a thousand rows nobody renders.
    payees: dict[str, dict[str, float]] = {}

    for row in world["transactions"]:
        if row["type"] != "send_money":
            continue
        pair = (row["from_acct"], row["to_acct"])
        is_new_payee = pair not in seen_pairs
        seen_pairs.add(pair)

        if row["to_acct"] not in payee_score:
            payee_score[row["to_acct"]] = mule.inbound_mule_score(row["to_acct"], as_of) or 0.0
        inbound = payee_score[row["to_acct"]]
        request = ScoreRequest(
            user_id=row["from_acct"],
            session_id=row["txn_id"],
            txn=Txn(type="send_money", amount_bdt=row["amount_bdt"],
                    to_account=row["to_acct"], is_new_payee=is_new_payee),
            demo_flags=DemoFlags(inbound_mule_score=round(min(max(inbound, 0.0), 1.0), 4)),
        )
        result = decide(request, evaluate(request, p95, settings), 0.0, settings.model_version, settings)

        mix[result.decision] += 1
        bands[result.band] += 1
        histogram[min(int(result.risk_score * HISTOGRAM_BUCKETS), HISTOGRAM_BUCKETS - 1)] += 1

        fired = sorted(reason.code for reason in result.reasons)
        for code in fired:
            codes[code] += 1
        for i, left in enumerate(fired):
            for right in fired[i + 1:]:
                cooccurrence[f"{left} + {right}"] += 1

        stopped = result.decision in STOPPING
        fraudulent = row["ring_id"] is not None
        if fraudulent:
            confusion["catch" if stopped else "miss"] += 1
        else:
            confusion["false_positive" if stopped else "true_negative"] += 1
        if stopped:
            value["protected" if fraudulent else "friction"] += row["amount_bdt"]

        day = daily.setdefault(row["ts"][:10], {"scored": 0, "stopped": 0})
        day["scored"] += 1
        day["stopped"] += 1 if stopped else 0

        payee = payees.setdefault(row["to_acct"], {"payments": 0, "stopped": 0, "amount_bdt": 0.0})
        payee["payments"] += 1
        payee["stopped"] += 1 if stopped else 0
        payee["amount_bdt"] += row["amount_bdt"]

    return {
        "denominator": sum(mix.values()),
        "denominator_label": "send_money transactions",
        "mix": dict(mix),
        "bands": dict(bands),
        "codes": dict(codes.most_common()),
        "cooccurrence": dict(cooccurrence.most_common()),
        "codes_that_cannot_fire": [c for c in ALL_CODES if c not in codes],
        "codes_that_cannot_fire_reason": CANNOT_FIRE_REASON,
        "codes_that_cannot_fire_reason_bn": CANNOT_FIRE_REASON_BN,
        "confusion": dict(confusion),
        "rates": _rates(confusion, mix),
        "value": {"protected_bdt": round(value["protected"]), "friction_bdt": round(value["friction"]),
                  "currency": "BDT"},
        "histogram": histogram,
        "histogram_edges": [round(i / HISTOGRAM_BUCKETS, 1) for i in range(HISTOGRAM_BUCKETS + 1)],
        "daily": [{"day": d, **v} for d, v in sorted(daily.items())],
        "payee_rollup": payees,
        "badge": "RULE",
    }


def _rates(confusion: collections.Counter, mix: collections.Counter) -> dict[str, Any]:
    """Catch rate and false-positive rate, built together so neither can be served alone.

    Each rate ships with the denominator it was divided by. A rate without its denominator is how a
    dashboard starts lying without anybody deciding to.
    """
    fraudulent = confusion["catch"] + confusion["miss"]
    genuine = confusion["false_positive"] + confusion["true_negative"]
    stopped = mix["hold"] + mix["block"]
    return {
        "catch_rate": round(confusion["catch"] / fraudulent, 4) if fraudulent else None,
        "catch_rate_denominator": fraudulent,
        "false_positive_rate": round(confusion["false_positive"] / genuine, 4) if genuine else None,
        "false_positive_rate_denominator": genuine,
        "stop_precision": round(confusion["catch"] / stopped, 4) if stopped else None,
        "stop_precision_denominator": stopped,
        "stopped": stopped,
    }


# --- the mule board ---------------------------------------------------------

def mule_board(world: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """The riskiest accounts with the reasons the model gives for them.

    Scored over the labelled accounts plus a fixed random sample of the rest, because every call is
    a SHAP pass and this is the slow half of the build. The sample seed is pinned so the board does
    not reshuffle between runs.
    """
    model = mule.model()
    labels = {row["acct_id"]: row for row in world["labels"]}
    rng = random.Random(SAMPLE_SEED)
    sample = rng.sample(world["accounts"], min(SAMPLE_ACCOUNTS, len(world["accounts"])))
    candidates = sorted(set(labels) | {a["acct_id"] for a in sample})

    board: list[dict[str, Any]] = []
    model_version = None
    if model is not None:
        as_of = scenario_now(get_settings())  # the clock /v1/mule/score answers at
        for acct in candidates:
            scored = model.score_at(acct, as_of)
            if not scored["known"]:
                continue
            model_version = scored["model_version"]
            label = labels.get(acct)
            board.append({
                "acct": acct,
                "probability": round(scored["probability"], 4),
                "role": label["role"] if label else None,
                "typology": label["typology"] if label else None,
                "ring": label["ring_id"] if label else None,
                "shap": [
                    {"feature": r["feature"], "value": round(r["value"], 3),
                     "contribution": round(r["contribution"], 3), "direction": r["direction"]}
                    for r in scored["reasons"][:3]
                ],
            })
        board.sort(key=lambda b: -b["probability"])

    threshold = get_settings().mule_hold_threshold
    meta = {
        "scored": len(board),
        "at_or_above_hold_threshold": sum(1 for b in board if b["probability"] >= threshold),
        "hold_threshold": threshold,
        "sample_seed": SAMPLE_SEED,
        "model_version": model_version,
        "badge": "MODEL" if model is not None else "OFF",
    }
    return board[:BOARD_SIZE], meta


# --- the gate ladder --------------------------------------------------------

# The FinNest defence-in-depth plan is the vocabulary the team argues in, so the console uses it
# rather than inventing its own. Each gate's static half - what it is, which component owns it, what
# it sees - comes from that plan; the live half is filled from the
# replay below. G7 reads "not built", and that is the point: the ladder shows what we have not done
# as plainly as what we have.
GATES: tuple[dict[str, Any], ...] = (
    {"id": "G0", "title": "The server decides and executes",
     "title_bn": "সার্ভারই সিদ্ধান্ত নেয় এবং কার্যকর করে",
     "sees": "server", "owner_ticket": "risk-mw", "status": "planned", "badge": "NONE",
     "note": "Today a hold is a response body; an attacker who controls the phone can ignore it. "
             "Until the server writes the transaction, every gate below is advice.",
     "note_bn": "আজ একটা হোল্ড মানে শুধু রেসপন্সের একটা ফিল্ড; ফোনের দখল নেওয়া আক্রমণকারী সেটা "
                "উপেক্ষা করতে পারে। সার্ভার নিজে লেনদেনটা না লেখা পর্যন্ত নিচের প্রতিটা গেট কেবল পরামর্শ।"},
    {"id": "G1", "title": "Takeover: freeze credential changes after a SIM change or new device",
     "title_bn": "টেকওভার: সিম বদল বা নতুন ডিভাইসের পর ক্রেডেনশিয়াল বদল আটকে দেওয়া",
     "sees": "server", "owner_ticket": "risk-mw", "status": "rule on client flags", "badge": "RULE",
     "note": "CALL_ACTIVE_NON_CONTACT and SIM_CHANGED_24H exist; the server-event path is planned.",
     "note_bn": "CALL_ACTIVE_NON_CONTACT আর SIM_CHANGED_24H আছে; সার্ভার-ইভেন্টের পথটা এখনো পরিকল্পনায়।"},
    {"id": "G2", "title": "Scam call: call state, screen share, the assistant, the turn classifier, app safety",
     "title_bn": "স্ক্যাম কল: কল স্টেট, স্ক্রিন শেয়ার, সহকারী, টার্ন ক্লাসিফায়ার, অ্যাপ সেফটি",
     "sees": "phone, raise-only", "owner_ticket": "mobile / ato / app-safety", "status": "built",
     "badge": "MODEL",
     "note": "The behaviour model went live on risk-mw on 2026-10-16: a coached session returns "
             "ATO_BEHAVIOUR_MISMATCH and COACHING_SUSPECTED. App safety is still a deterministic stub.",
     "note_bn": "বিহেভিয়ার মডেল ২০২৬-১০-১৬ থেকে risk-mw-তে চালু: শেখানো সেশনে "
                "ATO_BEHAVIOUR_MISMATCH আর COACHING_SUSPECTED ফেরত আসে। অ্যাপ সেফটি এখনো একটা স্টাব।"},
    {"id": "G3", "title": "Sender anomaly: amount against this person, drained balance, a never-paid payee",
     "title_bn": "প্রেরকের অস্বাভাবিকতা: তার নিজের ইতিহাসের তুলনায় অঙ্ক, ব্যালেন্স খালি, অচেনা প্রাপক",
     "sees": "server ledger", "owner_ticket": "risk-mw", "status": "fixed threshold", "badge": "RULE",
     "note": "A fixed p95 stands in for a per-person baseline; geography is not read at all yet.",
     "note_bn": "প্রতি-ব্যক্তির বেসলাইনের বদলে একটা স্থির p95 বসানো আছে; ভূগোল এখনো পড়াই হয় না।"},
    {"id": "G4", "title": "Payee: mule score, Case Zero watch-list, till risk",
     "title_bn": "প্রাপক: মিউল স্কোর, Case Zero ওয়াচ-লিস্ট, এজেন্ট টিলের ঝুঁকি",
     "sees": "server ledger, nightly", "owner_ticket": "mule model", "status": "built", "badge": "MODEL",
     "note": "The scorer is live in the payment path. The watch-list exists but is not read at "
             "payment time.",
     "note_bn": "স্কোরারটি পেমেন্টের পথে চালু আছে। ওয়াচ-লিস্ট আছে, কিন্তু পেমেন্টের সময় পড়া হয় না।"},
    {"id": "G5", "title": "Cash-out: a cooling window on inbound funds that carried takeover signals",
     "title_bn": "ক্যাশ-আউট: টেকওভারের চিহ্ন বহন করা টাকার উপর একটা অপেক্ষার সময়",
     "sees": "server ledger", "owner_ticket": "risk-mw", "status": "planned", "badge": "NONE",
     "note": "Needs a cash-out transaction type. This is the gate that keeps stolen money inside "
             "the system long enough to return it.",
     "note_bn": "এর জন্য একটা ক্যাশ-আউট লেনদেনের ধরন দরকার। এই গেটটাই চুরি হওয়া টাকা সিস্টেমের "
                "ভেতরে এত সময় ধরে রাখে যে ফেরত দেওয়া যায়।"},
    {"id": "G6", "title": "After the fact: nightly scoring, Case Zero, freeze what is still inside",
     "title_bn": "ঘটনার পরে: রাতের স্কোরিং, Case Zero, ভেতরে যা আছে তা ফ্রিজ করা",
     "sees": "server ledger, Gemini", "owner_ticket": "case-zero", "status": "built", "badge": "MODEL",
     "note": "Case Zero recovers the ring and writes the case. Freeze and claw-back actions are not built.",
     "note_bn": "Case Zero রিংটা খুঁজে বের করে কেস লেখে। ফ্রিজ আর টাকা ফেরানোর ব্যবস্থা এখনো বানানো হয়নি।"},
    {"id": "G7", "title": "Feedback and sharing: confirmed mules into G4, hashed identifiers across providers",
     "title_bn": "ফিডব্যাক ও শেয়ারিং: নিশ্চিত মিউল G4-তে ফেরত, প্রোভাইডারদের মধ্যে হ্যাশ করা শনাক্তকারী",
     "sees": "confirmed cases", "owner_ticket": None, "status": "not built", "badge": "NONE",
     "note": "No national sharing exists in Bangladesh yet. A ring that moves provider escapes.",
     "note_bn": "বাংলাদেশে এখনো জাতীয় পর্যায়ে কোনো শেয়ারিং নেই। প্রোভাইডার বদলে ফেললে রিং পালিয়ে যায়।"},
)



def gates(replay_: dict[str, Any], board_meta: dict[str, Any]) -> list[dict[str, Any]]:
    """The ladder, with whatever live numbers each gate actually has.

    A gate with no measurement says so. Filling an empty gate with a zero would read as "this gate
    caught nothing", which is a different and false claim.
    """
    codes = replay_["codes"]
    live: dict[str, dict[str, Any]] = {
        "G3": {"volume": replay_["denominator"], "volume_label": "payments scored",
               "volume_label_bn": "স্কোর করা পেমেন্ট",
               "caught": codes.get("NEW_PAYEE_ABOVE_P95", 0), "caught_label": "delayed on amount",
               "caught_label_bn": "অঙ্কের কারণে দেরি"},
        "G4": {"volume": board_meta["scored"], "volume_label": "accounts scored",
               "volume_label_bn": "স্কোর করা অ্যাকাউন্ট",
               "caught": codes.get("DEST_MULE_RISK", 0), "caught_label": "payments held",
               "caught_label_bn": "আটকানো পেমেন্ট"},
    }
    return [{**gate, **live.get(gate["id"], {"volume": None, "caught": None})} for gate in GATES]


# --- the pilot targets ------------------------------------------------------

def targets(replay_: dict[str, Any]) -> list[dict[str, Any]]:
    """The five targets the team set itself, including the four we cannot measure yet.

    Showing a target with NO DATA is the point. A target nobody can see is a target nobody hits, and
    three of these need a release path that does not exist, so hiding them would hide the gap.
    """
    rates = replay_["rates"]
    return [
        {"id": "false_delays", "label": "False delays per 1,000 customers per month",
         "label_bn": "প্রতি ১,০০০ গ্রাহকে মাসে ভুল দেরি",
         "target": "< 1", "target_bn": "< ১", "value": None, "unit": None, "badge": "NO DATA",
         "why": "needs a release path and a month of operation; today we can only count false holds "
                "in the replay, which is a different denominator",
         "why_bn": "এর জন্য ছেড়ে দেওয়ার একটা পথ আর এক মাসের চলা দরকার; আজ কেবল রিপ্লেতে ভুল হোল্ড "
                   "গোনা যায়, যার হর আলাদা"},
        {"id": "minutes_to_release", "label": "Median minutes to release",
         "label_bn": "ছেড়ে দিতে মধ্যমা কত মিনিট",
         "target": "< 5", "target_bn": "< ৫", "value": None, "unit": "minutes", "badge": "NO DATA",
         "why": "no release path exists; trusted-contact approve/decline is the nearest thing",
         "why_bn": "ছেড়ে দেওয়ার কোনো পথই নেই; বিশ্বস্ত মানুষের approve/decline-ই সবচেয়ে কাছের জিনিস"},
        {"id": "self_release", "label": "Delays ended by the customer or a relative, not staff",
         "label_bn": "যত দেরি গ্রাহক বা তার আপনজন নিজে শেষ করেছেন, কর্মী নয়",
         "target": "> 90%", "target_bn": "> ৯০%", "value": None, "unit": "%", "badge": "NO DATA",
         "why": "same: nothing to end yet",
         "why_bn": "একই কথা: শেষ করার মতো কিছুই এখনো নেই"},
        {"id": "money_inside", "label": "Stolen money still inside the system when the alarm sounds",
         "label_bn": "অ্যালার্ম বাজার সময় চুরি হওয়া টাকার কতটা এখনো সিস্টেমের ভেতরে",
         "target": "> 50%", "target_bn": "> ৫০%", "value": None, "unit": "%", "badge": "NO DATA",
         "why": "needs G5, the cash-out cooling window",
         "why_bn": "এর জন্য G5 দরকার, ক্যাশ-আউটের অপেক্ষার সময়"},
        {"id": "friction_cost", "label": "Friction imposed on genuine payments",
         "label_bn": "নির্দোষ পেমেন্টের উপর চাপানো ঘর্ষণ",
         "target": "as low as the catch allows", "target_bn": "ধরার হার যতটা অনুমতি দেয়, তত কম",
         "value": replay_["value"]["friction_bdt"],
         "unit": "BDT", "badge": "RULE",
         "why": f"{replay_['confusion']['false_positive']} genuine payments held out of "
                f"{rates['false_positive_rate_denominator']}",
         "why_bn": f"{rates['false_positive_rate_denominator']}টির মধ্যে "
                   f"{replay_['confusion']['false_positive']}টি নির্দোষ পেমেন্ট আটকানো হয়েছে"},
    ]


# --- model health -----------------------------------------------------------

EVAL_FILES: tuple[tuple[str, str, str], ...] = (
    ("mule-lgbm", "eval/results/mule.json", "MODEL"),
    ("ato-identity", "libs/ato/eval/results/ato_hmog.json", "MODEL"),
    ("case-zero", "services/case-zero/eval/results/case_zero.json", "MODEL"),
)


def _read_eval(path: Path) -> dict[str, Any] | None:
    try:
        with path.open() as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


# The eval files say whether a target was met in words, not in booleans, and they do not all use
# the same words. "within band" is how a two-sided target reports success - the ATO pooled EER has
# to land inside 0.03-0.1, where lower is not automatically better - so reading only for "pass"
# called a passing model failed. "not run" is a third answer and belongs in neither column: a gate
# nobody measured is not a gate nobody met.
_GATE_MET = frozenset({"pass", "passed", "within band", "in band", "ok", "met"})
_GATE_UNRUN = frozenset({"not run", "unrun", "not measured", "skipped", "n/a", "pending"})


def _gate(status: Any) -> bool | None:
    """True if the target was met, False if it was missed, None if it was never measured."""
    if not isinstance(status, str):
        return None
    key = status.strip().lower()
    if key in _GATE_UNRUN:
        return None
    return key in _GATE_MET


def _ato_gates(metrics: dict[str, Any]) -> tuple[dict[str, bool], list[str]]:
    """Every ATO metric that carries a real target, split into measured gates and unrun ones.

    One boolean on the pooled EER threw away the other eight rows the eval file had already
    measured, which is the same table the case-zero row builds from its own gates block.
    """
    measured: dict[str, bool] = {}
    unrun: list[str] = []
    for name, metric in metrics.items():
        if not isinstance(metric, dict):
            continue
        target = metric.get("target")
        if not target or target == "-":          # no target means nothing to pass or miss
            continue
        # The gate is named by the threshold it checks, not by the metric alone: "score_p95_ms
        # <= 50.0" tells the operator what passing meant, and a bare metric name whose value is a
        # boolean reads as a rate that lost its denominator - which the aggregate's own test
        # correctly refuses.
        label = f"{name} {target}"
        met = _gate(metric.get("status"))
        if met is None:
            unrun.append(label)
        else:
            measured[label] = met
    return measured, unrun


def models() -> list[dict[str, Any]]:
    """One row per model, read from the eval files the harnesses write (eval/run.py and the per-component evals).

    Nothing here is typed in by hand - including whether a gate passed. A missing file becomes
    NO DATA rather than a stale number, and a failed gate is reported as failed, because a
    model-health page that only shows passes is decoration. The converse matters just as much: a
    gate that was met must not read as missed, and a gate that was never run must not read as
    either.
    """
    rows: list[dict[str, Any]] = []

    mule_eval = _read_eval(REPO / "eval/results/mule.json")
    if mule_eval:
        test = mule_eval["test"]
        rows.append({
            "id": "mule-lgbm", "version": mule_eval["model_version"], "badge": "MODEL",
            "headline": f"AUC-PR {test['auc_pr']}, precision@50 {test['precision_at_50']}",
            "gates_passed": None,
            "per_segment": test["recall_by_typology"],
            "per_segment_label": "ring-level recall @50 by typology",
            "eval": "eval/results/mule.json",
            "generated_at": mule_eval.get("generated_at"),
        })
    else:
        rows.append({"id": "mule-lgbm", "badge": "NO DATA", "eval": "eval/results/mule.json"})

    ato = _read_eval(REPO / "libs/ato/eval/results/ato_hmog.json")
    if ato:
        metrics_ = ato.get("metrics", {})
        pooled = metrics_.get("identity_eer_pooled", {})
        measured, unrun = _ato_gates(metrics_)
        # The caveat is the model's own, and it outlives any particular number: HMOG is American
        # handsets, and the coached rows have no public dataset behind them at all.
        note = "measured on HMOG, not on Bangladeshi handsets"
        if unrun:
            note += f"; {len(unrun)} gate{'s' if len(unrun) > 1 else ''} not run ({', '.join(sorted(unrun))})"
        rows.append({
            "id": "ato-identity", "version": f"hmog, {ato.get('users')} users", "badge": "MODEL",
            "headline": f"pooled EER {pooled.get('value')} (target {pooled.get('target')})",
            "gates_passed": all(measured.values()) if measured else None,
            "gates_detail": measured or None,
            "per_segment": None,
            "eval": "libs/ato/eval/results/ato_hmog.json",
            "note": note,
        })

    cz = _read_eval(REPO / "services/case-zero/eval/results/case_zero.json")
    if cz:
        summary = cz["summary"].get("case_zero", {})
        cz_gates = {
            name: value if isinstance(value, bool) else bool(_gate(value))
            for name, value in (cz.get("gates") or {}).items()
            if isinstance(value, bool) or _gate(value) is not None
        }
        rows.append({
            "id": "case-zero", "version": cz.get("model"), "badge": "MODEL",
            "headline": (f"{summary.get('rings_recovered')}/{summary.get('rings')} rings, "
                         f"precision {summary.get('mean_precision')}"),
            "gates_passed": all(cz_gates.values()) if cz_gates else None,
            "gates_detail": cz_gates or None,
            "per_segment": None,
            "eval": "services/case-zero/eval/results/case_zero.json",
            "cost_usd": cz.get("spent_usd_ledger"),
        })

    rows.append({"id": "app-safety", "version": None, "badge": "STUB", "headline": "deterministic severity ladder",
                 "gates_passed": None, "per_segment": None, "eval": None,
                 "note": "the app classifier has not landed; every verdict is a rule"})
    rows.append({"id": "fna-intervention", "version": None, "badge": "STUB",
                 "headline": "three scripted triggers, always intervenes",
                 "gates_passed": None, "per_segment": None, "eval": None})
    return rows


# --- policy checks ----------------------------------------------------------

def policy(replay_: dict[str, Any]) -> list[dict[str, Any]]:
    """The team's own stated rules, checked against what the engine actually did.

    `block = 0` is otherwise just an empty bar on a chart. Stated as a policy and checked, it becomes
    the thing it is: evidence that no model reached a decision only an analyst may reach.
    """
    blocks = replay_["mix"].get("block", 0)
    return [
        # One sentence in the plan, two claims, and they do not have the same answer. Checking them
        # together let the true half carry the false one: `block = 0` in the replay was reported as
        # the whole policy holding, while live traffic was already blocking payments for a device
        # reason with no analyst and no payee anywhere in the decision.
        {"id": "no_model_block",
         "statement": "No payment-scoring model may reach block.",
         "statement_bn": "পেমেন্ট স্কোর করা কোনো মডেল block পর্যন্ত যেতে পারবে না।",
         "ok": blocks == 0,
         "evidence": f"block = {blocks} over {replay_['denominator']} scored payments. The engine has "
                     "exactly one path to block and it is not a payment score: APP_SAFETY_BLOCK, on "
                     "a device verdict (rules.py:69).",
         "evidence_bn": f"{replay_['denominator']}টি স্কোর করা পেমেন্টে block = {blocks}। ইঞ্জিনে block-এ "
                        "যাওয়ার পথ একটাই, আর সেটা পেমেন্ট স্কোর নয় — APP_SAFETY_BLOCK, ডিভাইসের রায়ে "
                        "(rules.py:69)।",
         "source": "defence-in-depth plan, section 5"},
        {"id": "decline_needs_an_analyst",
         "statement": "A decline exists only for a payee an analyst has confirmed as a mule.",
         "statement_bn": "অ্যানালিস্ট যে প্রাপককে মিউল বলে নিশ্চিত করেছেন, কেবল তার জন্যই decline আছে।",
         # Not a measurement of today's traffic - a fact about the engine, which is stronger. The one
         # rule that can block reads a device verdict. There is no analyst in that path and no payee
         # in it either, so the claim is already false whether or not anyone has tripped it yet.
         "ok": False,
         "evidence": "False by construction. APP_SAFETY_BLOCK (rules.py:69) declines on a device "
                     "verdict: no analyst, no payee, no mule confirmation. That verdict is not "
                     "model-free either - two LAMDA CLASSIFIER_HIGH hits on sideloaded apps combine "
                     "above the 0.80 threshold (app-safety-check pipeline.py:131); only Gemini is "
                     "capped at CAUTION. The audit log shows it has already happened in live traffic.",
         "evidence_bn": "গঠনগতভাবেই ভুল। APP_SAFETY_BLOCK (rules.py:69) ডিভাইসের রায়ে decline করে: কোনো "
                        "অ্যানালিস্ট নেই, কোনো প্রাপক নেই, মিউল নিশ্চিতকরণ নেই। সেই রায়ও মডেল-মুক্ত নয় — "
                        "সাইডলোড করা অ্যাপে দুটো LAMDA CLASSIFIER_HIGH মিলে 0.80 থ্রেশহোল্ড ছাড়িয়ে যায় "
                        "(app-safety-check pipeline.py:131); কেবল Gemini-কেই CAUTION-এ আটকানো আছে। "
                        "অডিট লগ বলছে লাইভ ট্রাফিকে এটা ইতিমধ্যেই ঘটেছে।",
         "source": "defence-in-depth plan, section 5"},
        {"id": "holds_are_delays",
         "statement": "Holds are delays with a customer-controlled release, never a model's block.",
         "statement_bn": "হোল্ড মানে দেরি, যা গ্রাহক নিজেই শেষ করতে পারেন — কখনোই মডেলের ব্লক নয়।",
         "ok": False,
         "evidence": "No release path exists. A hold today ends when the trusted contact approves, "
                     "when it expires, or not at all - the customer cannot end it themselves.",
         "evidence_bn": "ছেড়ে দেওয়ার কোনো পথ নেই। আজ একটা হোল্ড শেষ হয় বিশ্বস্ত মানুষ অনুমোদন দিলে, "
                        "মেয়াদ ফুরালে, নয়তো কখনোই না — গ্রাহক নিজে সেটা শেষ করতে পারেন না।",
         "source": "defence-in-depth plan, section 6"},
        {"id": "client_signals_raise_only",
         "statement": "Client signals only raise risk; the ledger decides.",
         "statement_bn": "ক্লায়েন্টের সিগন্যাল কেবল ঝুঁকি বাড়াতে পারে; সিদ্ধান্ত নেয় লেজার।",
         "ok": True,
         "evidence": "Every demo_flag enters through a rule that can only add a hit; no flag can "
                     "lower a score or clear another rule.",
         "evidence_bn": "প্রতিটা demo_flag এমন একটা রুলের ভেতর দিয়ে ঢোকে যা কেবল হিট যোগ করতে পারে; "
                        "কোনো ফ্ল্যাগ স্কোর কমাতে বা অন্য রুল বাতিল করতে পারে না।",
         "source": "app/rules.py"},
    ]


def weakest_link(models_: list[dict[str, Any]], replay_: dict[str, Any]) -> dict[str, Any]:
    """Name the worst thing on the page, so a reader does not have to go looking for it."""
    worst_typology, worst_recall = None, None
    for row in models_:
        segments = row.get("per_segment") or {}
        for name, value in segments.items():
            if worst_recall is None or value < worst_recall:
                worst_typology, worst_recall = name, value
    stubs = [row["id"] for row in models_ if row["badge"] == "STUB"]
    unbuilt = [g["id"] for g in GATES if g["badge"] == "NONE"]
    return {
        "typology": worst_typology,
        "ring_recall": worst_recall,
        "stubs": stubs,
        "gates_not_built": unbuilt,
        # Without eval results (they are not committed) there is no ring recall to rank; say so.
        "sentence": (
            (f"Weakest detector: {worst_typology} at ring recall {worst_recall}. " if worst_typology is not None
             else "Weakest detector: not measured (no eval results in this build). ")
            + f"Gates not built: {', '.join(unbuilt)}. Stubs still answering: {', '.join(stubs)}."
        ),
        "sentence_bn": (
            (f"সবচেয়ে দুর্বল ডিটেক্টর: {worst_typology}, ring recall {worst_recall}। " if worst_typology is not None
             else "সবচেয়ে দুর্বল ডিটেক্টর: মাপা হয়নি (এই বিল্ডে ইভ্যাল ফলাফল নেই)। ")
            + f"যে গেটগুলো বানানো হয়নি: {', '.join(unbuilt)}। যেগুলো এখনো স্টাব: {', '.join(stubs)}।"
        ),
    }


# --- the whole thing --------------------------------------------------------

def build(
    seed_dir: Path = SEED_DIR,
    now: datetime | None = None,
    world: dict[str, Any] | None = None,
    replayed: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """The overview object, exactly as `/v1/admin/overview` and `fixtures/overview.json` carry it.

    `world` and `replayed` let a caller that has already paid for those pass them in - the build CLI
    needs the replay's payee rollup as well, and replaying twice would double the slowest step.
    """
    settings = get_settings()
    world = world if world is not None else load_world(seed_dir)
    replay_ = replayed if replayed is not None else replay(world)
    # The rollup is for the watch-list join, not for the console; keeping it out of the fixture
    # keeps that file readable and about a third of its size.
    replay_ = {k: v for k, v in replay_.items() if k != "payee_rollup"}
    board, board_meta = mule_board(world)
    models_ = models()
    counts = world_counts(world)
    checksum = (seed_dir / "CHECKSUM").read_text().strip() if (seed_dir / "CHECKSUM").exists() else None
    stamp = (now or datetime.now(DHAKA)).isoformat()

    return {
        "generated_at": stamp,
        "window": {"from": counts["first_day"], "to": counts["last_day"],
                   "tz": "Asia/Dhaka", "days": counts["days"]},
        "source": {
            "seed_dir": str(seed_dir.relative_to(REPO)),
            "checksum": checksum,
            "service": settings.service_name,
            "model_version": settings.model_version,
            "mule_model_version": board_meta["model_version"],
            "thresholds": {
                "band_medium": settings.band_medium, "band_high": settings.band_high,
                "band_critical": settings.band_critical,
                "mule_hold_threshold": settings.mule_hold_threshold,
                "default_p95_amount_bdt": settings.default_p95_amount_bdt,
            },
            "synthetic": True,
        },
        "world": counts,
        "replay": replay_,
        "gates": gates(replay_, board_meta),
        "targets": targets(replay_),
        "mule_board": board,
        "mule_board_meta": board_meta,
        "models": models_,
        "policy": policy(replay_),
        "weakest_link": weakest_link(models_, replay_),
    }
