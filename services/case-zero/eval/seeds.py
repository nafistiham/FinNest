"""Evaluation seeds from the labels: one per ring at the end of its drain, plus benign look-alikes.

Labels are used only here, to score results; nothing in this file reaches the agent.
"""

from __future__ import annotations

from datetime import timedelta

from bhorosha_synth import schema as s

from case_zero.world import World, alias_id

SEED_ROLE_ORDER = ("mule_L1", "purchased_mule", "mule_L2", "controller", "cashout_agent")
BENIGN_AS_OF = "2026-11-10T16:00:00"


def ring_seeds(world: World) -> list[dict]:
    rings: dict[str, list[dict]] = {}
    for label in world.bundle.labels:
        rings.setdefault(label["ring_id"], []).append(label)
    ring_txns: dict[str, list[str]] = {}
    for txns in world.bundle.txns_by_acct.values():
        for t in txns:
            if t.get("ring_id"):
                ring_txns.setdefault(t["ring_id"], []).append(t["ts"])
    out = []
    for ring_id, labels in sorted(rings.items()):
        members = [l for l in labels if l["role"] != "victim"]
        seed = min(members, key=lambda l: (SEED_ROLE_ORDER.index(l["role"]) if l["role"] in SEED_ROLE_ORDER else 99, l["acct_id"]))
        last = s.parse_ts(max(ring_txns.get(ring_id, [seed["first_bad_ts"]]))) + timedelta(minutes=1)
        # before any member of this ring could count as analyst-confirmed (3-day lag), so the agent cannot be handed the answer
        unconfirmed = s.parse_ts(min(l["first_bad_ts"] for l in members)) + timedelta(days=world.lag_days) - timedelta(minutes=1)
        as_of = s.format_ts(min(last, unconfirmed))
        visible = {l["acct_id"] for l in members if world.has_activity(l["acct_id"], as_of)}
        if seed["acct_id"] not in visible and visible:
            seed = next(l for l in sorted(members, key=lambda l: (SEED_ROLE_ORDER.index(l["role"]) if l["role"] in SEED_ROLE_ORDER else 99, l["acct_id"])) if l["acct_id"] in visible)
        out.append({"ring_id": ring_id, "typology": seed["typology"], "seed": seed["acct_id"], "as_of": as_of,
                    "truth": visible, "victims": {l["acct_id"] for l in labels if l["role"] == "victim"}})
    return out


def benign_seeds(world: World, n: int = 10) -> list[dict]:
    labelled = {l["acct_id"] for l in world.bundle.labels}
    week_start = s.format_ts(s.parse_ts(BENIGN_AS_OF) - timedelta(days=7))
    busy = sorted(
        (a for a, acct in world.bundle.accounts.items() if acct.get("kind") == "customer" and a not in labelled and a != "acct_newphone_benign"),
        key=lambda a: (-sum(1 for t in world.bundle.txns_by_acct.get(a, ()) if week_start <= t["ts"] <= BENIGN_AS_OF), a),
    )
    picks = [alias_id("acct_newphone_benign")] + busy[: n - 1]
    return [{"ring_id": None, "typology": "none", "seed": a, "as_of": BENIGN_AS_OF, "truth": set(), "victims": set()} for a in picks]
