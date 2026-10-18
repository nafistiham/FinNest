"""Which transaction row the risk-mw contract cites for a red flag.

A flag cites tool calls, and one call can return many transfers: a `neighbours` call lists up to 25
counterparties, most of them unrelated to the flag. So the row is chosen, never just the first id:

1. A step of a cited `path_between` call, since the model traced that money on purpose. The step must
   agree with the flag: touch an account the flag names (if it names any) and carry a Taka amount the
   flag names (if it names any). A step that matches the flag outright (rule 2) is taken first.
2. Otherwise a transfer from any cited call that matches the flag outright. That means both its sender
   and receiver are accounts the flag names, or one of them is and it carries a Taka amount the flag
   names. A named amount must always match.
3. Otherwise none: no evidence is better than wrong evidence.

Amounts count only when written as money (Tk, ৳, টাকা, k, lakh), so "within 120 minutes" does not
constrain the row. Accounts are compared in the ids the model saw (persona aliases).
"""

from __future__ import annotations

from case_zero.schemas import RedFlag
from case_zero.validator import ACCT_RE, amount_mentions
from case_zero.world import alias_id, real_id


def evidence_txn(flag: RedFlag, ledger) -> str | None:
    """The txn id the contract cites for this flag, or None when no cited transfer is clearly about it."""
    accounts = set(ACCT_RE.findall(flag.text))
    amounts = {value for value, as_money in amount_mentions(flag.text) if as_money}
    cited = [e for e in (ledger.entry(c) for c in dict.fromkeys(flag.evidence)) if e is not None and e["ok"]]
    transfers = _transfers(ledger.world, cited)

    def amount_ok(t: tuple) -> bool:
        return not amounts or round(t[2]) in amounts

    def agrees(t: tuple) -> bool:
        return amount_ok(t) and (not accounts or bool({t[0], t[1]} & accounts))

    def matches(t: tuple) -> bool:
        return amount_ok(t) and ({t[0], t[1]} <= accounts or bool(amounts and {t[0], t[1]} & accounts))

    steps = [st["txn_id"] for e in cited if e["name"] == "path_between" for st in (e["data"] or {}).get("steps", [])]
    returned = [i for e in cited for i in e["ids"] if i.startswith("txn_")]
    for ids, fits in ((steps, matches), (steps, agrees), (returned, matches)):
        for txn in ids:
            if txn in transfers and fits(transfers[txn]):
                return txn
    return None


def _transfers(world, cited: list[dict]) -> dict[str, tuple[str, str, float]]:
    """txn id -> (sender, receiver, amount) for every transfer the cited calls returned. Each one touches
    an account the same output names, so only those accounts' transfers are read."""
    wanted = {i for e in cited for i in e["ids"] if i.startswith("txn_")}
    found = {}
    for acct in {real_id(i) for e in cited for i in e["ids"] if i.startswith("acct_")}:
        for t in world.bundle.txns_by_acct.get(acct, ()):
            if t["txn_id"] in wanted:
                found[t["txn_id"]] = (alias_id(t["from_acct"]), alias_id(t["to_acct"]), t["amount_bdt"])
    return found
