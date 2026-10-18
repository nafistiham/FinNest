"""The payment-attempt stream of the campaign world: every send_money in the ledger as an allowed attempt,
plus the synthetic refusals (held attempts) that never became transactions.

Truth is carried by one column, `truth_campaign`: the `ring_id` of the labelled ring an attempt belongs to (any
typology), None when benign. Cash-outs are outcomes, not attempts; they stay in `transactions.jsonl`.
"""

from __future__ import annotations

import zlib

import numpy as np

from bhorosha_synth import schema as s

Rows = tuple[dict, ...]

RETRY_RING_SHARE = 0.25  # a quarter of rings show a held first attempt, then the retry that went through
RETRY_LEAD_MIN = (3, 8)  # the held attempt comes this many minutes before the retry (inclusive)


def attempt_row(ts: str, from_acct: str, to_acct: str, amount_bdt: float, type: str, channel: str, decision: str,
                txn_id: str | None, truth_campaign: str | None) -> dict:
    """An attempt without its stream position: build_attempts adds attempt_id and is_new_payee."""
    if decision not in s.DECISIONS:
        raise ValueError(f"unsupported decision {decision!r}")
    return {"ts": ts, "from_acct": from_acct, "to_acct": to_acct, "amount_bdt": amount_bdt, "type": type,
            "channel": channel, "decision": decision, "txn_id": txn_id, "truth_campaign": truth_campaign}


def _victim_payments(txns: Rows, labels: Rows) -> dict[str, dict]:
    """ring_id -> the ring's first victim-originated send_money."""
    victims = {(l["ring_id"], l["acct_id"]) for l in labels if l["role"] == "victim"}
    first: dict[str, dict] = {}
    for t in sorted(txns, key=lambda t: (t["ts"], t["txn_id"])):
        ring = t.get("ring_id")
        if ring and t["type"] in s.ATTEMPT_TYPES and (ring, t["from_acct"]) in victims and ring not in first:
            first = {**first, ring: t}
    return first


def held_retries(seed: int, txns: Rows, labels: Rows, share: float = RETRY_RING_SHARE) -> Rows:
    """For a share of rings, a held attempt RETRY_LEAD_MIN minutes before the ring's first victim payment, same
    payer, payee, amount and channel. The demo ring is left alone (the demo script depends on it) and the call-centre
    rings carry their own holds. Each ring draws on its own stream, so adding a ring never changes another's draw."""
    skip = {l["ring_id"] for l in labels if l["typology"] == s.CAMPAIGN_TYPOLOGY} | {s.DEMO_RING_ID}
    rows = []
    for ring_id, first in sorted(_victim_payments(txns, labels).items()):
        if ring_id in skip:
            continue
        rng = np.random.default_rng([seed, s.RETRY_STREAM, zlib.crc32(ring_id.encode())])
        if rng.random() >= share:
            continue
        lead = int(rng.integers(RETRY_LEAD_MIN[0], RETRY_LEAD_MIN[1] + 1))
        rows.append(attempt_row(s.add_minutes(first["ts"], -lead), first["from_acct"], first["to_acct"], first["amount_bdt"],
                                first["type"], first["channel"], "hold", None, ring_id))
    return tuple(rows)


def build_attempts(txns: Rows, extra: Rows) -> Rows:
    """One allowed attempt per ledger payment plus the `extra` (held) rows, time-ordered, with ids and is_new_payee.
    A payee is new to a payer until an earlier allowed payment on that pair; a held attempt establishes nothing."""
    allowed = tuple(attempt_row(t["ts"], t["from_acct"], t["to_acct"], t["amount_bdt"], t["type"], t["channel"], "allow",
                                t["txn_id"], t.get("ring_id")) for t in txns if t["type"] in s.ATTEMPT_TYPES)
    ordered = sorted(allowed + tuple(extra), key=lambda a: (a["ts"], a["from_acct"], a["to_acct"], a["amount_bdt"], a["decision"]))
    paid: frozenset[tuple[str, str]] = frozenset()
    rows = []
    for i, a in enumerate(ordered):
        pair = (a["from_acct"], a["to_acct"])
        row = {"attempt_id": f"att_{i:07d}", **a, "is_new_payee": pair not in paid}
        rows.append({field: row[field] for field in s.ATTEMPT_FIELDS})
        if a["decision"] == "allow":
            paid = paid | {pair}
    return tuple(rows)
