"""Mule scorer adapter: the mule scorer and graph bundle inside risk-mw.

Loaded once at start-up from RISK_MW_MULE_ARTEFACTS_DIR. If the directory or the packages are
missing the API still runs: scores are 0.0 / unknown and the demo flags drive the rules.

Every score here is time-aware: it is computed on the events before an `as_of` the caller
takes from app.clock, never at the artefact's end-of-world cutoff, which would see the ring after
it has finished.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from app import personas
from app.contracts import Txn
from app.payee import PayeeScreen
from app.settings import get_settings

log = logging.getLogger(__name__)
FRAUD_ROLES = ("mule_L1", "mule_L2", "cashout_agent", "purchased_mule", "controller")
MONEY_MOVING_TXN = "send_money"  # the only txn type that lands money on the payee; the others screen it as it stands


@dataclass(frozen=True)
class MuleModel:
    scorer: Any  # bhorosha_graph.scorer.MuleScorer
    bundle: Any  # bhorosha_graph.bundle.GraphBundle, the world the scores are read from
    labels: tuple[dict, ...]
    loaded_ms: float

    def score_at(self, acct_id: str, as_of: str) -> dict:
        """The account's score and ten reasons on the events before `as_of`.

        The same answer as MuleScorer.score_at (pinned in libs/synth/tests), built from this one account's features
        instead of the whole table: milliseconds at any as_of, so the wall clock in production costs no table rebuild.
        """
        return self.scorer.screen_transfer(self.bundle, acct_id, as_of)["before"]

    def screen_transfer(self, acct_id: str, as_of: str, from_acct: str | None = None, amount_bdt: float | None = None) -> dict:
        """Before and with the pending transfer, at `as_of`; the bundle is not changed (MuleScorer.screen_transfer)."""
        return self.scorer.screen_transfer(self.bundle, acct_id, as_of, from_acct, amount_bdt)

    def demo_ring(self) -> dict[str, list[str]]:
        from bhorosha_synth import schema as s

        by_role: dict[str, list[str]] = {}
        for label in self.labels:
            if label["ring_id"] == s.DEMO_RING_ID:
                by_role = {**by_role, label["role"]: by_role.get(label["role"], []) + [label["acct_id"]]}
        return by_role


def _load(artefacts: Path) -> MuleModel | None:
    try:
        from bhorosha_graph.bundle import load_bundle
        from bhorosha_graph.scorer import load_scorer
    except ImportError as exc:
        log.warning("mule scorer packages unavailable (%s); inbound mule score is off", exc)
        return None
    started = time.perf_counter()
    try:
        scorer = load_scorer(artefacts)
        bundle = load_bundle(artefacts / "graph.pkl")
    except (OSError, ValueError, TypeError) as exc:
        log.error("mule artefacts at %s could not be loaded: %s", artefacts, exc)
        return None
    loaded_ms = (time.perf_counter() - started) * 1000
    log.info("mule scorer loaded from %s in %.0f ms (%s)", artefacts, loaded_ms, scorer.version)
    return MuleModel(scorer, bundle, bundle.labels, round(loaded_ms, 1))


@lru_cache(maxsize=1)
def model() -> MuleModel | None:
    artefacts = get_settings().mule_artefacts_dir
    if artefacts is None or not Path(artefacts).is_dir():
        log.info("RISK_MW_MULE_ARTEFACTS_DIR not set or missing; inbound mule score is off")
        return None
    return _load(Path(artefacts))


def inbound_mule_score(acct_id: str | None, as_of: str) -> float:
    """Probability that the receiving account is a mule on the evidence before `as_of`, without any pending transfer;
    0.0 when unknown or the model is off. No route needs it (they screen with the transfer); kept because
    external probe scripts patch it at start-up."""
    loaded = model()
    if not acct_id or loaded is None:
        return 0.0
    return float(loaded.score_at(acct_id, as_of)["probability"])


def resolve_payer_account(user_id: str) -> str | None:
    """The account a payer's money leaves from: `user_id` (the bound identity, app.identity) itself when it is an
    account in the world, else the account its persona row names in config/personas.json (the app and the test portal
    send "rina"; app.personas.account_for, the table reads p95 amounts from), else None.
    """
    loaded = model()
    if loaded is None or not user_id:
        return None
    if user_id in loaded.bundle.accounts:
        return user_id
    account = personas.account_for(user_id, get_settings())
    return account if account in loaded.bundle.accounts else None


def _as_screen(out: dict, screened: bool) -> PayeeScreen:
    moved = out["moved"]
    return PayeeScreen(
        acct_id=out["acct_id"],
        as_of=out["as_of"],
        before=float(out["before"]["probability"]),
        with_this_transfer=float(out["with_this_transfer"]["probability"]) if screened else None,
        moved_feature=moved["feature"] if moved else None,
    )


def screen_payee(txn: Txn, user_id: str, as_of: str) -> PayeeScreen | None:
    """The payee of `txn` scored at `as_of`, before and with this transfer from the payer's account; None when there is
    no known payee. A send_money from no known account is scored before only (with_this_transfer None): there is no
    account to put the money in motion from, and inventing one would invent the evidence.

    A scoring failure is logged and answered with None, so the rules still decide on everything else: a broken
    model must not stop a payment screen from answering.
    """
    loaded = model()
    if loaded is None or not txn.to_account:
        return None
    payer = resolve_payer_account(user_id)
    moves_money = txn.type == MONEY_MOVING_TXN
    amount = txn.amount_bdt if moves_money and payer else None
    try:
        out = loaded.screen_transfer(txn.to_account, as_of, payer, amount)
    except Exception:  # noqa: BLE001 - degrade to no model signal, never 500 the payment screen
        log.exception("payee screen failed for %s as of %s; no mule signal for this request", txn.to_account, as_of)
        return None
    if not out["known"]:
        return None
    if moves_money and payer is None:
        log.info("payer %r is no known account; %s scored before the transfer only", user_id, txn.to_account)
    return _as_screen(out, screened=payer is not None or not moves_money)
