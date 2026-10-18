"""The /v1/admin/* routes.

Read-only. The console asks this service three questions - what happened, what is this account, and
which models are behind it - and nothing here writes anything anywhere.

Two decisions worth keeping:

* The overview is served from the committed fixture and recomputed only when asked. Recomputing
  costs a few seconds of SHAP, and a dashboard that stalls on first paint is a dashboard nobody
  opens during a demo.
* The seed world is loaded once, lazily, and kept. It is about 4 MB of JSONL and every account
  drill-down needs it; reading it per request would turn a 5 ms answer into a 400 ms one.
"""

from __future__ import annotations

import json
import logging
import re
import threading
import time
from functools import lru_cache
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, HTTPException, Query, status

from api.auth import Operator

from api import aggregate, architecture, audit, campaigns, cashout, casezero, insight, scenarios
from api.risk_mw import SEED_DIR, get_settings, mule, scenario_now
from api.schemas import (Account, AccountMule, CampaignIncident, CampaignsList, CashoutDayView, CashoutView, Model,
                         Overview)

log = logging.getLogger("admin")
AUDIT_ID = re.compile(r"[A-Za-z0-9_.~@+-]{1,128}")

router = APIRouter(prefix="/v1/admin", tags=["admin"])

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "overview.json"
ROLLUP_FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "payee_rollup.json"
MAX_TXNS = 200

_cache: dict[str, Any] = {"overview": None, "built_at": 0.0}
CACHE_TTL_S = 300


# Two threads arriving at a cold cache would both do the work; lru_cache does not serialise the
# function it wraps. The warm-up thread and the first request are exactly that pair.
_heavy = threading.Lock()


@lru_cache(maxsize=1)
def _world() -> dict[str, Any]:
    with _heavy:
        return aggregate.load_world(SEED_DIR)


def _overview(refresh: bool) -> dict[str, Any]:
    fresh_enough = _cache["overview"] is not None and time.time() - _cache["built_at"] < CACHE_TTL_S
    if refresh or not fresh_enough:
        if refresh or not FIXTURE.exists():
            _cache["overview"] = aggregate.build(SEED_DIR)
            _cache["built_at"] = time.time()
        else:
            _cache["overview"] = json.loads(FIXTURE.read_text())
            # The fixture is a build artefact, not a live computation; let it be re-read when it
            # changes on disk rather than pinning the first read for the life of the process.
            _cache["built_at"] = FIXTURE.stat().st_mtime
    return _cache["overview"]


def warm() -> None:
    """Load the world and the rollup now, so the first operator does not wait for them."""
    started = time.perf_counter()
    try:
        _world()
        _payee_rollup()
        _overview(refresh=False)
    except Exception:  # noqa: BLE001 - a failed warm-up must not stop the service starting
        log.exception("warm-up failed; the first request will pay for it instead")
        return
    log.info("warm-up done in %.1f s", time.perf_counter() - started)


@router.get("/overview", response_model=Overview)
def overview(
    _operator: Operator,
    refresh: Annotated[bool, Query(description="recompute instead of serving the fixture")] = False,
) -> Any:
    """Everything the home screen renders, in one response."""
    return _overview(refresh)


@router.get("/scenarios")
def scenario_runs(_operator: Operator) -> Any:
    """A few payments put through the engine the service actually runs.

    Not scripted outcomes: each one is a real `ScoreRequest` through risk-mw's own `evaluate()`
    and `decide()`, so the codes, weights, band and decision are the engine's answers. Change a
    threshold in `rules.py` and these change with it.
    """
    return {"scenarios": scenarios.all_scenarios(), "badge": "RULE"}


@router.get("/architecture")
def architecture_map(_operator: Operator) -> Any:
    """What is running and how a payment moves through it.

    Most of this is read from risk-mw's own source, which ships inside this image: every router,
    its prefix, every route, every module, and which modules import Gemini, Firestore or a trained
    artefact. The sentences explaining what each piece is *for* are written, and each names the
    file it describes.
    """
    return architecture.snapshot()


@router.get("/models", response_model=list[Model])
def models(_operator: Operator) -> Any:
    """One row per model, read from the eval files the eval harnesses write."""
    return aggregate.models()


@router.get("/account/{acct_id}", response_model=Account)
def account(acct_id: str, _operator: Operator) -> Any:
    """One account: who owns it, what the mule model says, and everything it did.

    The drill-down the fixture cannot hold - every number on the overview has to lead somewhere, and
    for an account-shaped number this is where it leads.
    """
    world = _world()
    record = next((a for a in world["accounts"] if a["acct_id"] == acct_id), None)
    if record is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown account {acct_id}")

    owner = next((c for c in world["customers"] if c["cust_id"] == record["owner_id"]), None)
    # Projected field by field rather than passed through: the seed row carries acct_id too, and a
    # strict response model is the right place to find that out.
    labelled = next((l for l in world["labels"] if l["acct_id"] == acct_id), None)
    label = None if labelled is None else {
        "ring_id": labelled["ring_id"], "role": labelled["role"],
        "typology": labelled["typology"], "first_bad_ts": labelled.get("first_bad_ts"),
    }

    rows = [r for r in world["transactions"] if acct_id in (r["from_acct"], r["to_acct"])]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    txns = [
        {
            "txn_id": r["txn_id"], "ts": r["ts"], "type": r["type"], "amount_bdt": r["amount_bdt"],
            "counterparty": r["to_acct"] if r["from_acct"] == acct_id else r["from_acct"],
            "direction": "out" if r["from_acct"] == acct_id else "in",
            "channel": r["channel"], "ring_id": r["ring_id"],
        }
        for r in rows[:MAX_TXNS]
    ]

    devices = sorted({r["device_id"] for r in rows if r.get("device_id")})
    shared = sorted({
        link["acct_id"] for link in world["device_links"]
        if link.get("device_id") in devices and link.get("acct_id") != acct_id
    })

    model = mule.model()
    scored = model.score_at(acct_id, scenario_now(get_settings())) if model is not None else None  # /v1/mule/score's clock
    mule_block = None
    if scored is not None:
        mule_block = AccountMule(
            known=scored["known"], probability=round(scored["probability"], 4),
            model_version=scored["model_version"], as_of=scored.get("as_of"),
            reasons=[
                {"feature": r["feature"], "value": round(r["value"], 3),
                 "contribution": round(r["contribution"], 3), "direction": r["direction"]}
                for r in scored["reasons"]
            ],
        )

    return {
        "acct_id": acct_id,
        "kind": record["kind"],
        "district": record["district"],
        "opened_at": record["opened_at"],
        "status": record["status"],
        "owner": owner,
        "mule": mule_block,
        "label": label,
        "transactions": txns,
        "transactions_truncated": len(rows) > MAX_TXNS,
        "transaction_count": len(rows),
        "devices": devices,
        "shared_device_accounts": shared,
        "sim_events": [e for e in world["sim_events"] if e.get("acct_id") == acct_id],
        "badge": "MODEL" if mule_block is not None else "SYNTHETIC",
        "synthetic": True,
    }


# --- Case Zero ---------------------------------------------------------------

@lru_cache(maxsize=1)
def _payee_rollup() -> dict[str, dict[str, float]]:
    """How the payment path treated each payee, from the same replay the overview is built on.

    Read from the build artefact when there is one. Computing it instead means replaying 2,330
    payments through the rule engine, which took fifteen seconds on the first request of a fresh
    Cloud Run revision - the kind of first impression a console does not recover from.
    """
    if ROLLUP_FIXTURE.exists():
        with ROLLUP_FIXTURE.open() as fh:
            return json.load(fh)
    with _heavy:
        return aggregate.replay(_world())["payee_rollup"]


@router.get("/casezero/health")
def casezero_health(_operator: Operator) -> Any:
    """Is the investigator up, and how many cases does it hold?"""
    try:
        return {"reachable": True, **casezero.health()}
    except casezero.CaseZeroUnavailable as exc:
        return {"reachable": False, "error": str(exc)}


@router.get("/casezero/seeds")
def casezero_seeds(_operator: Operator) -> Any:
    try:
        return casezero.seeds()
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc


@router.get("/casezero/watchlist")
def casezero_watchlist(_operator: Operator) -> Any:
    """The watch-list, joined to what the payment path actually did about it.

    This is the one place the console computes something Case Zero does not. The gate ladder says
    of G4: "the watch-list exists but is not read at payment time". That is a claim. Joining each
    watch-listed payee to the payments the rule engine scored turns it into a count - how much
    money reached an account an investigation had already implicated, and how little of it the
    payment path stopped on its own.
    """
    try:
        payload = casezero.payee_risk()
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc

    rollup = _payee_rollup()
    rows = []
    for payee in payload.get("payees", []):
        seen = rollup.get(payee["acct_id"], {"payments": 0, "stopped": 0, "amount_bdt": 0.0})
        rows.append({
            **payee,
            "payments_to_this_payee": int(seen["payments"]),
            "stopped_by_rules": int(seen["stopped"]),
            "amount_bdt": round(seen["amount_bdt"]),
        })
    rows.sort(key=lambda row: (-row["payments_to_this_payee"], -row.get("model_score", 0)))

    payments = sum(row["payments_to_this_payee"] for row in rows)
    stopped = sum(row["stopped_by_rules"] for row in rows)
    return {
        "version": payload.get("version"),
        "generated_at": payload.get("generated_at"),
        "payees": rows,
        "gap": {
            "watchlisted_accounts": len(rows),
            "payments_to_watchlisted": payments,
            "stopped_by_rules": stopped,
            "missed": payments - stopped,
            "amount_bdt": round(sum(row["amount_bdt"] for row in rows)),
            "stopped_share": round(stopped / payments, 4) if payments else None,
            "note": "G4 reads the scorer at payment time but not this watch-list. "
                    "Every payment counted here reached an account an investigation had already implicated.",
            "badge": "MODEL",
        },
    }


@router.get("/casezero/case/{case_id}")
def casezero_case(case_id: str, _operator: Operator) -> Any:
    try:
        return casezero.case(case_id)
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc


@router.get("/casezero/case/{case_id}/file")
def casezero_case_file(case_id: str, _operator: Operator) -> Any:
    """The full case file of a live case: decision, members, red flags, timeline, look-alikes, narratives, checks, run."""
    try:
        report = casezero.case(case_id)
    except casezero.CaseNotFound as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Case Zero no longer holds this case: it keeps cases in memory, and a "
                            "redeploy clears them. Open the recorded run, or run the investigation again.") from exc
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc
    try:
        run = casezero.events(case_id)
    except casezero.CaseZeroUnavailable:
        run = []  # the file still reads; cited calls just lose their tool names
    return casezero.case_file(report, run, source="live")


@router.get("/casezero/replay/file")
def casezero_replay_file(_operator: Operator) -> Any:
    """The recorded run's case file, the same shape as a live one: what the console shows when nothing may run on camera."""
    try:
        run = casezero.replay()
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc
    report = next((e.get("report") for e in run if e.get("type") == "report"), None)
    if not report:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "the recorded run has no report")
    return casezero.case_file(report, run, source="recorded")


@router.get("/casezero/graph")
def casezero_graph(_operator: Operator) -> Any:
    """The ring as Case Zero traversed it: its own tool outputs, accumulated, with provenance."""
    try:
        return casezero.graph()
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc


@router.get("/casezero/replay")
def casezero_replay(_operator: Operator) -> Any:
    """A recorded agent run. Costs nobody's Gemini budget, which matters on a judging day."""
    try:
        return casezero.replay()
    except casezero.CaseZeroUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"case zero unavailable: {exc}") from exc


# --- the Incidents view ---------------------------------------------

@router.get("/campaigns", response_model=CampaignsList)
def campaign_list(_operator: Operator) -> Any:
    """Every incident the radar opened on the campaign world, the campaigns it linked, and the eval.

    Served from fixtures/campaigns.json (tools/build_campaigns.py). No radar run, Firestore read or
    Gemini call happens here. A missing or malformed fixture is `available: false`, never a 500.
    """
    try:
        return campaigns.listing()
    except campaigns.Unavailable as exc:
        return {"available": False, "reason": str(exc)}


@router.get("/campaigns/{incident_id}", response_model=CampaignIncident)
def campaign_incident(incident_id: str, _operator: Operator) -> Any:
    """One incident with what its three panels draw: firings, the campaigns holding it, their attempts."""
    try:
        detail = campaigns.incident(incident_id)
    except campaigns.Unavailable as exc:
        return {"available": False, "reason": str(exc)}
    if detail is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown incident {incident_id}")
    return detail


# --- the cash-out view ----------------------------------------------

@router.get("/cashout", response_model=CashoutView)
def cashout_view(_operator: Operator) -> Any:
    """The common point of cash-out on the campaign world: tills, daily runs, flags, clusters, candidates, the eval.

    Served from fixtures/cashout.json (tools/build_cashout.py). No rule replay, Firestore read or Gemini call happens
    here. A missing or malformed fixture is `available: false`, never a 500.
    """
    try:
        return cashout.whole()
    except cashout.Unavailable as exc:
        return {"available": False, "reason": str(exc)}


@router.get("/cashout/day/{day}", response_model=CashoutDayView)
def cashout_day(day: str, _operator: Operator) -> Any:
    """One daily run (YYYY-MM-DD, as of 00:00): its tills, flags, clusters, candidates and the cash-outs its map draws."""
    if not cashout.is_day(day):
        # 422 as a number: Starlette renamed its constant, and requirements.txt allows versions either side of that.
        raise HTTPException(422, f"{day!r} is not a date (YYYY-MM-DD)")
    try:
        detail = cashout.day(day)
    except cashout.Unavailable as exc:
        return {"available": False, "reason": str(exc)}
    if detail is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"no daily run on {day}")
    return detail


# --- the live audit trail ----------------------------------------------------

@router.get("/audit")
def audit_log(
    _operator: Operator,
    limit: Annotated[int, Query(ge=1, le=1000, description="documents to read, newest first")] = 50,
    before: Annotated[str | None, Query(description="the `at` of the last row shown: the page below")] = None,
    since: Annotated[str | None, Query(description="the `at` of the newest row shown: a poll")] = None,
) -> Any:
    """Every call risk-mw actually answered, newest first.

    This is the other half of the console. Everything else is the replay - what the engine would
    decide about the seed world. This is what happened: who called, with which flags, and what came
    back, including the rule codes the seed can never make fire.

    `since` makes a poll cheap: it reads only what arrived after the newest row the caller already
    has, which is usually nothing. Without it a console polling every five seconds would re-read
    the whole page to learn that.
    """
    try:
        rows = audit.recent(limit=limit, before=before, since=since)
    except audit.AuditUnavailable as exc:
        return {"available": False, "error": str(exc), "rows": [], "facets": {}, "window": None}
    return {
        "available": True,
        "rows": rows,
        "facets": audit.facets(rows),
        "window": {
            "returned": len(rows),
            "newest": rows[0]["at"] if rows else None,
            "oldest": rows[-1]["at"] if rows else None,
            "note": "facet counts are over the documents returned, not the whole collection",
        },
        # Only a full page can have more below it. A short page is the end of the collection, and
        # a `since` poll has no "below" at all.
        "next_before": rows[-1]["at"] if len(rows) == limit and not since else None,
        "since": since,
        # Not RULE: this stream carries Gemini scam turns and the LAMDA app classifier alongside
        # the rule engine. One badge over all of them would claim something untrue about two of
        # them, so the badge says only what the whole stream is - what the service actually did.
        "badge": "LIVE",
    }


@router.get("/audit/{doc_id}")
def audit_document(
    doc_id: str,
    _operator: Operator,
    full: Annotated[bool, Query(description="the stored document whole, transcripts included")] = False,
) -> Any:
    # A document id is opaque, but it is not arbitrary: anything with a slash would address a
    # different collection, and anything long is not one of ours. Checked here so a malformed id
    # is a 404 rather than a round trip.
    """One audit document, redacted for display. The console never recomputes a stored decision.

    Redacted, not rewritten: a caller's number keeps its last three digits, a transcript its first
    forty characters, an installed-app list its length. The reasons the customer was shown are
    untouched, because reproducing those exactly is the whole point of the drawer. `?full=1`
    returns the document whole for the case that needs it.
    """
    if not AUDIT_ID.fullmatch(doc_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown audit document {doc_id}")
    try:
        doc = audit.one(doc_id, full=full)
    except audit.AuditUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - a read failure is the upstream's, not a 500 here
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"{type(exc).__name__}: {exc}") from exc
    if doc is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown audit document {doc_id}")
    return doc


@router.get("/audit/{doc_id}/insight")
def audit_insight(doc_id: str, _operator: Operator) -> Any:
    """Gemini's reading of one stored score, for the analyst: why this decision and this score, and what to check.

    Beside the customer's reasons, never instead of them: those stay verbatim in the drawer. Built from the
    redacted document, checked against it before it is returned (api/insight.py), and cached per document.
    No reading is a 200 with a fixed `reason` (`genai_disabled`, `spend_cap`, `timeout`, `genai_error`,
    `invalid`, `not_a_score`, `nothing_fired`), so the drawer can say why instead of showing an error.
    """
    if not AUDIT_ID.fullmatch(doc_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown audit document {doc_id}")
    try:
        doc = audit.one(doc_id)
    except audit.AuditUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - a read failure is the upstream's, not a 500 here
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"{type(exc).__name__}: {exc}") from exc
    if doc is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown audit document {doc_id}")
    try:
        return {"available": True, **insight.explain(doc_id, doc)}
    except insight.InsightUnavailable as exc:
        return {"available": False, "reason": exc.code}
