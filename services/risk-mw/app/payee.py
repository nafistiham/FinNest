"""What /v1/risk/score says about a payee: its mule score before and with this transfer, and why it holds.

The payee of the demo is clean on the evidence before the transfer (0.0002) and looks like a mule once the transfer has
landed (0.9082). So the honest sentence is not "this number is a known mule" but "sending money to this number raises
the risk because ...", naming the part of the risk the transfer itself brings: the feature it moved most. Pure: no
I/O, nothing mutated; app.mule produces the PayeeScreen and app.rules turns it into the DEST_MULE_RISK reason.
"""

from __future__ import annotations

from dataclasses import dataclass

LEAD_BN = "এই নম্বরে টাকা পাঠালে ঝুঁকি বাড়ে কারণ "
LEAD_EN = "Sending money to this number raises the risk because "
SWAP_WINDOW_HOURS = 24  # bhorosha_graph.features.SWAP_RECENCY_HOURS: "received money from an account swapped in the last 24 h"
_BANGLA_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
WINDOW_SUFFIXES = ("_7d", "_30d")

Clause = tuple[str, str]  # (Bangla, English), each completing the lead sentence

SIM_SWAP: Clause = (
    f"এই টাকা গত {str(SWAP_WINDOW_HOURS).translate(_BANGLA_DIGITS)} ঘণ্টার মধ্যে সিম বদলানো একটি অ্যাকাউন্টের সাথে যুক্ত",
    f"this money is linked to an account whose SIM was changed in the last {SWAP_WINDOW_HOURS} hours",
)
PASS_THROUGH: Clause = (
    "এই টাকা পেলে প্রাপকের টাকা আসা-যাওয়ার ধরন এমন অ্যাকাউন্টের মতো হয় যে টাকা পেয়েই সরিয়ে দেয়",
    "with this money the receiver's in-and-out pattern matches an account that passes money straight on",
)
INFLOW: Clause = (
    "প্রাপক অ্যাকাউন্টে এভাবে টাকা আসা তার স্বাভাবিক লেনদেনের সাথে মেলে না",
    "money coming in like this is unusual for the receiving account",
)
DORMANCY: Clause = (
    "প্রাপক অ্যাকাউন্টটি অনেকদিন চুপ থাকার পর হঠাৎ টাকা নিচ্ছে",
    "the receiving account is suddenly taking money after a quiet spell",
)
SALARY: Clause = (
    "প্রাপক অ্যাকাউন্টে আসা টাকার প্রায় কিছুই বেতন নয়",
    "almost none of what the receiving account takes in is salary",
)
KNOWN_FRAUD: Clause = (
    "এই টাকা আগে ধরা পড়া প্রতারণার অ্যাকাউন্টগুলোর খুব কাছে চলে যাবে",
    "the money would sit close to accounts already confirmed as fraud",
)
PATTERN: Clause = (
    "এই লেনদেনসহ প্রাপকের লেনদেনের ধরন চুরি করা টাকা সরানোর ধরনের সাথে মেলে",
    "with this transfer the receiver's activity matches how stolen money is moved on",
)
ALREADY: Clause = (
    "এই লেনদেনের আগেই প্রাপক অ্যাকাউন্টে অস্বাভাবিক লেনদেনের ধরন দেখা গেছে",
    "the receiving account already showed unusual activity before this transfer",
)
# No paying account to send from, so only the score before was computed (app.mule.resolve_payer_account).
UNSCREENED: Clause = (
    "এই লেনদেনের আগেই প্রাপক অ্যাকাউন্টে অস্বাভাবিক লেনদেনের ধরন দেখা গেছে (পাঠানো অ্যাকাউন্টটি চেনা নয়, তাই এই লেনদেনসহ যাচাই করা যায়নি)",
    "the receiving account already showed unusual activity before this transfer (the paying account is not known, so the transfer itself was not screened)",
)
# A hit the demo panel's inbound_mule_score caused while the model was quiet: a number, and nothing more, is known.
SCORE_ONLY: Clause = (
    "প্রাপক অ্যাকাউন্টের ঝুঁকির স্কোর বেশি",
    "the receiving account's risk score is high",
)

# Moved feature (without its _7d/_30d window) -> what it means to the customer.
CLAUSE_BY_FEATURE: dict[str, Clause] = {
    "hops_to_recent_sim_swap": SIM_SWAP, "inbound_from_recent_swap": SIM_SWAP,
    "pass_through_ratio": PASS_THROUGH, "non_salary_pass_through": PASS_THROUGH,
    "in_count": INFLOW, "in_total": INFLOW, "distinct_senders": INFLOW, "max_in_per_hour": INFLOW, "p2p_in_count": INFLOW, "max_txn_amount": INFLOW,
    "days_since_last_txn": DORMANCY, "days_since_first_txn": DORMANCY, "dormant_gap_days": DORMANCY, "active_days": DORMANCY,
    "salary_share_of_in": SALARY, "salary_in_count": SALARY,
    "hops_to_known_fraud": KNOWN_FRAUD, "known_fraud_within_2_hops": KNOWN_FRAUD,
}


@dataclass(frozen=True)
class PayeeScreen:
    """The payee's mule probability at the scenario clock, on the evidence so far and with this transfer landed.

    `with_this_transfer` is None when the money would come from no known account: the transfer cannot be screened,
    and the rule falls back to the score before.
    """

    acct_id: str
    as_of: str
    before: float
    with_this_transfer: float | None
    moved_feature: str | None

    @property
    def rule_score(self) -> float:
        """The number DEST_MULE_RISK fires on."""
        return self.before if self.with_this_transfer is None else self.with_this_transfer


def _base_feature(feature: str) -> str:
    return next((feature.removesuffix(suffix) for suffix in WINDOW_SUFFIXES if feature.endswith(suffix)), feature)


def _clause(payee: PayeeScreen | None, threshold: float) -> Clause:
    if payee is None or payee.rule_score <= threshold:
        return SCORE_ONLY
    if payee.with_this_transfer is None:
        return UNSCREENED
    if payee.before > threshold:
        return ALREADY
    return CLAUSE_BY_FEATURE.get(_base_feature(payee.moved_feature or ""), PATTERN)


def reason_text(payee: PayeeScreen | None, threshold: float) -> tuple[str, str]:
    """Bangla and English text for DEST_MULE_RISK, claiming only what the screen established."""
    text_bn, text_en = _clause(payee, threshold)
    return f"{LEAD_BN}{text_bn}।", f"{LEAD_EN}{text_en}."


def response_fields(payee: PayeeScreen | None) -> dict[str, float | str | None]:
    """The additive ScoreResponse fields; empty when no payee was screened."""
    if payee is None:
        return {}
    return {
        "payee_score_before": payee.before,
        "payee_score_with_this_transfer": payee.with_this_transfer,
        "payee_moved_feature": payee.moved_feature,
        "payee_score_as_of": payee.as_of,
    }
