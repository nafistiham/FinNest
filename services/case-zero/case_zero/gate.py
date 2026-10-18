"""Membership gate: the writer proposes ring members, code decides which ones count.

Starting from the seed, a proposed account joins the ring only when code can link it to an account
already in the ring, using events in the WINDOW_DAYS before `as_of`:

- it is in the seed's dormant cohort or common-point-of-compromise result;
- it passed on, within HOURS, money a member sent it; or it received a member's fresh inflow;
- it sent a member money it had itself received (transfer or cash deposit) within HOURS before;
- it shares a device, SIM, NID or phone with a member and received transfers in the window;
- a till: cash deposits to 2+ members and cash-outs from 2+ members (round-tripping), or 2+ members
  cashed out fresh money there and TILL_CONFIRMED_MIN analyst-confirmed fraud accounts (3-day lag)
  had cashed out there before.

Links through tills never count for customers: a till serves everyone. Victims are never gated.
Thresholds were chosen on the seed-7 and seed-11 dev worlds, never on the scored seed-42 world.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import timedelta

from bhorosha_graph import tools as gt
from bhorosha_synth import schema as s

from case_zero import patterns
from case_zero.schemas import CaseDraft, Excluded
from case_zero.validator import ACCT_RE, AGENT_RE
from case_zero.world import World, alias_id, real_id

HOURS = 24
WINDOW_DAYS = 7
PASS_THROUGH = 0.8
TILL_CONFIRMED_MIN = 3
IDENTITY = ("device:", "sim:", "nid:", "phone:")
NO_LINK = "no money, identity or pattern link to the ring"
INFLOW = ("send_money", "cash_in")
# A sentence ends at . ! ? before whitespace (so 7.5 stays whole) or at the Bangla danda, never at an abbreviation
# such as "Tk. 7,900". The group keeps the whitespace, so paragraph breaks survive a removed sentence.
SENTENCE_SPLIT = re.compile(r"((?<=[.!?])(?<!\btk\.)(?<!\brs\.)(?<!\bno\.)(?<!\bapprox\.)(?<!\be\.g\.)(?<!\bi\.e\.)(?<!\bvs\.)\s+|(?<=।)\s*)", re.IGNORECASE)


@dataclass
class GateResult:
    kept: dict[str, str] = field(default_factory=dict)     # acct -> why it is in the ring
    dropped: dict[str, str] = field(default_factory=dict)  # acct -> why it is not


def _shift(ts: str, **delta) -> str:
    return s.format_ts(s.parse_ts(ts) + timedelta(**delta))


class _Linker:
    def __init__(self, world: World, seed: str, as_of: str):
        self.world, self.seed, self.as_of = world, seed, as_of
        self.lo = _shift(as_of, days=-WINDOW_DAYS)
        self.cohort = {c["acct_id"] for c in patterns.dormant_cohort(world, as_of, seed)["cohort"]}
        self.cpc = {a["acct_id"] for a in patterns.common_point_of_compromise(world, as_of, seed)["linked_accounts"]}
        confirmed_before = _shift(as_of, days=-world.lag_days)
        self.confirmed = {l["acct_id"] for l in world.bundle.labels if l["role"] in gt.FRAUD_ROLES and l["first_bad_ts"] < confirmed_before}
        self._tx: dict[str, list[dict]] = {}

    def tx(self, acct: str) -> list[dict]:
        if acct not in self._tx:
            self._tx[acct] = [t for t in self.world.bundle.txns_by_acct.get(acct, ()) if self.lo <= t["ts"] <= self.as_of]
        return self._tx[acct]

    def kind(self, acct: str) -> str | None:
        return self.world.bundle.accounts.get(acct, {}).get("kind")

    def _fresh_inflow(self, acct: str, ts: str) -> float:
        return sum(x["amount_bdt"] for x in self.tx(acct) if x["to_acct"] == acct and x["type"] in INFLOW and _shift(ts, hours=-HOURS) <= x["ts"] <= ts)

    def _till(self, till: str, members: set[str]) -> str | None:
        tx = self.tx(till)
        outs = {t["from_acct"] for t in tx if t["to_acct"] == till and t["type"] == "cash_out" and t["from_acct"] in members and self._fresh_inflow(t["from_acct"], t["ts"]) > 0}
        ins = {t["to_acct"] for t in tx if t["from_acct"] == till and t["type"] == "cash_in" and t["to_acct"] in members}
        if len(outs) >= 2 and len(ins) >= 2:
            return "round-trip till"
        history = {t["from_acct"] for t in self.world.bundle.txns_by_acct.get(till, ()) if t["to_acct"] == till and t["type"] == "cash_out" and t["ts"] <= self.as_of and t["from_acct"] in self.confirmed}
        if len(outs) >= 2 and len(history) >= TILL_CONFIRMED_MIN:
            return f"till where {len(outs)} members cashed out, used by {len(history)} confirmed fraud accounts"
        return None

    def evidence(self, acct: str, kept: set[str]) -> str | None:
        members = {k for k in kept if k != acct and self.kind(k) == "customer"}
        kind = self.kind(acct)
        if kind == "agent_till":
            return self._till(acct, members)
        if kind != "customer":
            return None
        if acct in self.cohort:
            return "woke from dormancy with the seed"
        if acct in self.cpc:
            return "fed by the same compromised customers as the seed"
        tx = self.tx(acct)
        for t in tx:
            if t["type"] != "send_money":
                continue
            if t["to_acct"] == acct and t["from_acct"] in members:
                out = sum(x["amount_bdt"] for x in tx if x["from_acct"] == acct and t["ts"] <= x["ts"] <= _shift(t["ts"], hours=HOURS))
                if out >= PASS_THROUGH * t["amount_bdt"]:
                    return f"passed on money from {alias_id(t['from_acct'])}"
                if self._fresh_inflow(t["from_acct"], t["ts"]) >= t["amount_bdt"]:
                    return f"received fresh inflow forwarded by {alias_id(t['from_acct'])}"
            if t["from_acct"] == acct and t["to_acct"] in members and self._fresh_inflow(acct, t["ts"]) >= PASS_THROUGH * t["amount_bdt"]:
                return f"forwarded fresh money to {alias_id(t['to_acct'])}"
        ids = {e for e in self.world.entity_links(acct, self.as_of) if e.startswith(IDENTITY)}
        sharers = [k for k in members if ids & self.world.entity_links(k, self.as_of)]
        if sharers and any(t["to_acct"] == acct and t["type"] == "send_money" for t in tx):
            return f"shares an identity with {alias_id(sorted(sharers)[0])}"
        return None


def check_members(world: World, seed: str, as_of: str, proposed) -> GateResult:
    """Grow the ring from the seed through proposed accounts that code can link to it."""
    seed = real_id(seed)
    linker = _Linker(world, seed, as_of)
    kept, todo = {seed: "seed"}, {real_id(a) for a in proposed} - {seed}
    changed = True
    while changed:
        changed = False
        for acct in sorted(todo):
            why = linker.evidence(acct, set(kept))
            if why:
                kept[acct], changed = why, True
                todo.discard(acct)
    return GateResult(kept={alias_id(a): w for a, w in kept.items()}, dropped={alias_id(a): NO_LINK for a in sorted(todo)})


def apply_gate(world: World, seed: str, as_of: str, draft: CaseDraft) -> tuple[CaseDraft, dict]:
    """Move writer-listed members that code cannot link to the ring into `excluded`, with the reason."""
    proposed = [m.acct_id for m in draft.members if m.role != "victim"]
    result = check_members(world, seed, as_of, proposed)
    keep = [m for m in draft.members if m.role == "victim" or m.acct_id in result.kept]
    moved = [Excluded(acct_id=m.acct_id, reason=f"Code check: listed as {m.role}, but {NO_LINK} was found before {as_of}.", evidence=m.evidence)
             for m in draft.members if m.role != "victim" and m.acct_id in result.dropped]
    update = {"members": keep, "excluded": [*draft.excluded, *moved]}
    if moved:
        note = f"Code check moved {len(moved)} writer-listed account(s) to excluded: {', '.join(e.acct_id for e in moved)}."
        update["limitations"] = " ".join(x for x in (draft.limitations, note) if x)
    return draft.model_copy(update=update), {"kept": {a: w for a, w in result.kept.items() if a in proposed or a == alias_id(real_id(seed))}, "dropped": result.dropped}


def _names(acct: str, text: str) -> bool:
    """The text names the account: by its id, or an agent's till as "till AG-0192". Never by the bare agent id,
    which is also how the writer names an onboarding agent ("onboarded by agent AG-0014")."""
    if acct in ACCT_RE.findall(text):
        return True
    agent = AGENT_RE.search(acct) if acct.startswith("acct_till_") else None
    return bool(agent and re.search(rf"\btill\s+{agent.group(0)}\b", text, re.IGNORECASE))


def _drop_sentences(text: str, keep) -> str:
    """The text without the sentences keep() turns down; the text itself when it keeps them all. A removed
    sentence's paragraph break moves to the sentence before it."""
    parts = SENTENCE_SPLIT.split(text)
    kept: list[list[str]] = []
    removed = False
    for sentence, gap in zip(parts[0::2], parts[1::2] + [""]):
        if not sentence.strip() or keep(sentence):
            kept.append([sentence, gap])
        else:
            removed = True
            if kept and gap.count("\n") > kept[-1][1].count("\n"):
                kept[-1][1] = gap
    if not removed:
        return text
    return "".join(sentence + gap for sentence, gap in kept).rstrip() + text[len(text.rstrip()):]


def strip_accusations(draft: CaseDraft, excluded) -> tuple[CaseDraft, list[str]]:
    """Remove every red flag, timeline entry and narrative sentence that names an account the code check
    excluded, with one limitations line per removal. The writer's own excluded look-alikes are not passed here:
    what it says about them is why they are not in the ring, not an accusation. Nothing to remove: the same
    draft, untouched."""
    notes: list[str] = []

    def keep(text: str, what: str) -> bool:
        if who := " and ".join(sorted(a for a in excluded if _names(a, text))):
            notes.append(f"{what} removed: it names {who}, which the code check excluded.")
        return not who

    flags = [f for f in draft.red_flags if keep(f.text, f"Red flag {f.code}")]
    timeline = [t for t in draft.timeline if keep(t.text, "A timeline entry")]
    narrative_en = _drop_sentences(draft.narrative_en, lambda x: keep(x, "An English narrative sentence"))
    narrative_bn = _drop_sentences(draft.narrative_bn, lambda x: keep(x, "A Bangla narrative sentence"))
    if not notes:
        return draft, []
    return draft.model_copy(update={"red_flags": flags, "timeline": timeline, "narrative_en": narrative_en, "narrative_bn": narrative_bn,
                                    "limitations": " ".join(x for x in (draft.limitations, *notes) if x)}), notes
