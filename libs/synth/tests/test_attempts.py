"""The payment-attempt stream built from the ledger plus synthetic refusals (unit level)."""

from __future__ import annotations

from bhorosha_synth import schema as s
from bhorosha_synth.attempts import RETRY_LEAD_MIN, attempt_row, build_attempts, held_retries


def _send(txn_id: str, ts: str, a: str, b: str, amount: float = 1000.0, ring_id: str | None = None, kind: str = "send_money") -> dict:
    return {"txn_id": txn_id, "ts": ts, "type": kind, "amount_bdt": amount, "from_acct": a, "to_acct": b, "channel": "app",
            "status": "ok", "agent_id": None, "device_id": None, "ring_id": ring_id}


def test_attempt_rows_carry_exactly_the_attempt_fields_in_order():
    rows = build_attempts((_send("t0", "2026-10-07T10:00:00", "A", "B"),), ())
    assert tuple(rows[0]) == s.ATTEMPT_FIELDS
    assert rows[0]["attempt_id"] == "att_0000000" and rows[0]["decision"] == "allow" and rows[0]["txn_id"] == "t0"


def test_only_payment_types_become_attempts():
    txns = (_send("t0", "2026-10-07T10:00:00", "A", "B"), _send("t1", "2026-10-07T10:05:00", "A", "till", kind="cash_out"),
            _send("t2", "2026-10-07T10:06:00", "pay", "A", kind="salary"))
    rows = build_attempts(txns, ())
    assert [r["txn_id"] for r in rows] == ["t0"]
    assert {r["type"] for r in rows} <= set(s.ATTEMPT_TYPES)


def test_is_new_payee_counts_only_earlier_allowed_payments_on_the_pair():
    txns = (_send("t0", "2026-10-07T10:00:00", "A", "B"), _send("t1", "2026-10-07T11:00:00", "A", "B"),
            _send("t2", "2026-10-07T12:10:00", "A", "C"))
    held = (attempt_row("2026-10-07T12:00:00", "A", "C", 1000.0, "send_money", "app", "hold", None, None),)
    rows = build_attempts(txns, held)
    flags = [(r["to_acct"], r["decision"], r["is_new_payee"]) for r in rows]
    assert flags == [("B", "allow", True), ("B", "allow", False), ("C", "hold", True), ("C", "allow", True)]


def test_attempts_are_time_ordered_with_unique_ids_and_truth_from_the_ring():
    txns = (_send("t1", "2026-10-07T11:00:00", "A", "B", ring_id="ring_x"), _send("t0", "2026-10-07T10:00:00", "C", "D"))
    rows = build_attempts(txns, ())
    assert [r["ts"] for r in rows] == sorted(r["ts"] for r in rows)
    assert len({r["attempt_id"] for r in rows}) == len(rows)
    assert {r["txn_id"]: r["truth_campaign"] for r in rows} == {"t0": None, "t1": "ring_x"}


def _labels(ring_id: str, victims: tuple[str, ...], typology: str = "fan_in_fan_out") -> tuple[dict, ...]:
    return tuple({"acct_id": v, "ring_id": ring_id, "role": "victim", "typology": typology, "first_bad_ts": "2026-10-07T09:00:00"} for v in victims)


def test_held_retry_precedes_the_rings_first_victim_payment_by_three_to_eight_minutes():
    txns = (_send("t0", "2026-10-09T10:00:00", "v1", "hub", 2500.0, ring_id="ring_fan_9"),
            _send("t1", "2026-10-09T10:30:00", "v2", "hub", 1500.0, ring_id="ring_fan_9"))
    held = held_retries(42, txns, _labels("ring_fan_9", ("v1", "v2")), share=1.0)
    assert len(held) == 1
    row = held[0]
    assert (row["from_acct"], row["to_acct"], row["amount_bdt"], row["decision"], row["txn_id"]) == ("v1", "hub", 2500.0, "hold", None)
    lead = (s.parse_ts("2026-10-09T10:00:00") - s.parse_ts(row["ts"])).total_seconds() / 60
    assert RETRY_LEAD_MIN[0] <= lead <= RETRY_LEAD_MIN[1]
    assert row["truth_campaign"] == "ring_fan_9"


def test_held_retries_skip_the_demo_ring_and_the_callcentre_rings_and_are_per_ring_deterministic():
    txns = (_send("t0", "2026-10-09T10:00:00", "rina", "l1", ring_id=s.DEMO_RING_ID),
            _send("t1", "2026-10-10T10:00:00", "v", "p", ring_id="ring_callcentre_0"),
            _send("t2", "2026-10-11T10:00:00", "w", "hub", ring_id="ring_fan_1"))
    labels = (_labels(s.DEMO_RING_ID, ("rina",), "otp_takeover_cashout") + _labels("ring_callcentre_0", ("v",), s.CAMPAIGN_TYPOLOGY)
              + _labels("ring_fan_1", ("w",)))
    held = held_retries(42, txns, labels, share=1.0)
    assert {r["truth_campaign"] for r in held} == {"ring_fan_1"}
    alone = held_retries(42, txns[2:], labels[2:], share=1.0)
    assert alone == held  # adding a ring never changes another ring's draw
