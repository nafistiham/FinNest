"""/v1/investigate, /v1/investigations/{case_id}, /v1/investigations/{case_id}/events.

With RISK_MW_INVESTIGATOR_URL set these front Case Zero: start a case there, hand back
its id, and translate its report and live events into the frozen contract. If Case Zero is unset,
busy or down, the scripted stub answers instead, marked model_version "stub-fallback", so the
console and the video still run.
"""

from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from collections import OrderedDict
from collections.abc import AsyncIterator, Iterator
from functools import lru_cache
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Path, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse

from app import audit, bounded
from app.auth import require_user
from app.contracts import CaseReport, Evidence, InvestigateRequest, InvestigateResponse
from app.investigator import CaseZeroClient, InvestigatorUnavailable, UnknownCase
from app.ratelimit import GENAI_QUOTA
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)
router = APIRouter(prefix="/v1", tags=["investigate"])

MAX_STUB_CASES = 256
MAX_RECENT_CASES = 1024
# Both id styles in use: uuid4 for stub cases, "CZ-" plus ten base32 characters for Case Zero. Anything else never
# reaches upstream.
CASE_ID_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"
CaseId = Annotated[str, Path(pattern=CASE_ID_PATTERN)]
STUB_FALLBACK_VERSION = "stub-fallback"
SSE_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}

STUB_RING = ("acct_mule_1", "acct_mule_2", "acct_mule_3", "agent_till_colluding")
STUB_EVENTS = (
    {"step": "plan", "text": "Hypotheses: cash-out mule fan-out; legitimate salary disbursement; takeover after SIM swap."},
    {"step": "tool", "name": "neighbours", "args": {"acct_id": "acct_mule_1", "hops": 2}},
    {"step": "tool", "name": "shared_entities", "args": {"acct_ids": list(STUB_RING[:3])}},
    {"step": "evidence", "row_id": "txn_000421", "text": "Tk 4,900 received 11 minutes after the victim's PIN reset."},
    {"step": "done", "confidence": 0.82},
)


class CaseStore:
    """The stub's cases, newest last. Bounded, because the URL is public."""

    def __init__(self, limit: int = MAX_STUB_CASES) -> None:
        self._limit = limit
        self._cases: OrderedDict[str, CaseReport] = OrderedDict()
        self._lock = threading.Lock()

    def add(self, report: CaseReport) -> CaseReport:
        with self._lock:
            self._cases[report.case_id] = report
            while len(self._cases) > self._limit:
                self._cases.popitem(last=False)
        return report

    def get(self, case_id: str) -> CaseReport | None:
        with self._lock:
            return self._cases.get(case_id)

    def clear(self) -> None:
        with self._lock:
            self._cases.clear()

    def __len__(self) -> int:
        with self._lock:
            return len(self._cases)


STORE = CaseStore()


def _stub_report(case_id: str, acct_id: str, model_version: str) -> CaseReport:
    return CaseReport(
        case_id=case_id,
        acct_id=acct_id,
        status="done",
        summary_en="Account received funds within minutes of a victim's PIN reset and forwarded them through three accounts sharing a device to a single agent till. Pattern is consistent with a cash-out mule ring; requires human review.",
        summary_bn="পিন রিসেটের কয়েক মিনিটের মধ্যে অ্যাকাউন্টটি টাকা পেয়েছে এবং একই ডিভাইস ব্যবহারকারী তিনটি অ্যাকাউন্টের মাধ্যমে একটি এজেন্ট টিলে পাঠিয়েছে। ধরনটি ক্যাশ-আউট মিউল রিংয়ের সাথে মিলে যায়; মানব পর্যালোচনা প্রয়োজন।",
        evidence=(
            Evidence(row_id="txn_000421", claim="Tk 4,900 received 11 minutes after the victim's PIN reset"),
            Evidence(row_id="device_link_077", claim="Three accounts share device hash d7f3…"),
            Evidence(row_id="txn_000433", claim="Cash-out at agent till AG-0192 within 40 minutes"),
        ),
        ring=STUB_RING,
        confidence=0.82,
        recommended_action="route_to_risk_reviewer",
        model_version=model_version,
    )


def _stub_stream() -> Iterator[str]:
    for event in STUB_EVENTS:
        yield f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


# What a repeat request may reuse: the account alone in demo mode, (uid, account) with auth on (see _recent_key).
RecentKey = str | tuple[str, str]


def _recent_owner(key: RecentKey, _value: object) -> str:
    """With auth on a key is (uid, acct_id) and the uid owns it, so bounded.make_room caps each caller's share. In demo
    mode each account is its own owner, so the table stays the oldest-first FIFO it always was."""
    return key[0] if isinstance(key, tuple) else key


class RecentCases:
    """The newest Case Zero case for each account (each caller's account, with auth on), so a repeat request reuses it."""

    def __init__(self, limit: int = MAX_RECENT_CASES) -> None:
        self.limit = limit
        self._by_acct: OrderedDict[RecentKey, tuple[str, float]] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: RecentKey, ttl_s: float) -> str | None:
        with self._lock:
            found = self._by_acct.get(key)
        if found is None or time.monotonic() - found[1] > ttl_s:
            return None
        return found[0]

    def put(self, key: RecentKey, case_id: str) -> None:
        with self._lock:
            self._by_acct.pop(key, None)   # a re-put moves the key to the newest end
            self._by_acct[key] = (case_id, time.monotonic())
            bounded.make_room(self._by_acct, key, owner_of=_recent_owner, is_stale=lambda _v: False, limit=self.limit)

    def size(self) -> int:
        with self._lock:
            return len(self._by_acct)

    def forget(self, key: RecentKey) -> None:
        with self._lock:
            self._by_acct.pop(key, None)

    def clear(self) -> None:
        with self._lock:
            self._by_acct.clear()


RECENT = RecentCases()


class CaseOwners:
    """Who started each case (Case Zero's and the stub's), so with auth on a case reads only to that caller.

    In memory like the rest of the service's state, and bounded by app/bounded.py: one caller holds at most
    bounded.PER_OWNER_LIMIT records (her oldest go first), so a busy caller cannot push another's out; past the overall
    limit the oldest go. A case whose record is gone (those bounds, or a restart) reads as 404 under auth: fail closed."""

    def __init__(self, limit: int = MAX_RECENT_CASES + MAX_STUB_CASES) -> None:
        self.limit = limit
        self._by_case: OrderedDict[str, str] = OrderedDict()
        self._lock = threading.Lock()

    def put(self, case_id: str, uid: str) -> None:
        with self._lock:
            self._by_case.pop(case_id, None)   # a re-put moves the case to the newest end
            self._by_case[case_id] = uid
            bounded.make_room(self._by_case, case_id, owner_of=lambda _k, owner: owner, is_stale=lambda _v: False, limit=self.limit)

    def owner(self, case_id: str) -> str | None:
        with self._lock:
            return self._by_case.get(case_id)

    def size(self) -> int:
        with self._lock:
            return len(self._by_case)

    def clear(self) -> None:
        with self._lock:
            self._by_case.clear()


OWNERS = CaseOwners()


def _require_owner(case_id: str, uid: str, settings: Settings, started: float) -> None:
    """With auth on, only the caller who started a case may read it. Anyone else gets the same 404 as an unknown id
    (not a 403), so a caller cannot learn which ids exist, and the refusal is audited. Demo mode: no check."""
    if settings.auth_required and OWNERS.owner(case_id) != uid:
        detail = "unknown case"
        audit.record("investigation_read_refused", uid, {"case_id": case_id}, {"status_code": status.HTTP_404_NOT_FOUND, "detail": detail},
                     (time.perf_counter() - started) * 1000)
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail)


@lru_cache(maxsize=4)
def _build_client(url: str) -> CaseZeroClient:
    return CaseZeroClient(url)


def client_for(url: str) -> CaseZeroClient | None:
    return _build_client(url) if url else None


def _recent_key(acct_id: str, uid: str, settings: Settings) -> RecentKey:
    """With auth on a caller reuses only a case they started, which they can read; in demo mode the console and the
    portal share one case per account, as before."""
    return (uid, acct_id) if settings.auth_required else acct_id


def _reusable(client: CaseZeroClient, acct_id: str, uid: str, settings: Settings) -> str | None:
    key = _recent_key(acct_id, uid, settings)
    case_id = RECENT.get(key, settings.investigator_reuse_s)
    if case_id is None:
        return None
    try:
        if client.status(case_id)["status"] != "failed":
            return case_id
    except (UnknownCase, InvestigatorUnavailable):
        pass
    RECENT.forget(key)
    return None


def _start_remote(client: CaseZeroClient, acct_id: str, uid: str, settings: Settings) -> str | None:
    """A Case Zero case id for this account, or None when the stub must answer."""
    reused = _reusable(client, acct_id, uid, settings)
    if reused is not None:
        return reused
    try:
        case_id = client.start(acct_id)
    except InvestigatorUnavailable as exc:
        log.warning("case zero unavailable, answering from the stub: %s", exc)
        return None
    RECENT.put(_recent_key(acct_id, uid, settings), case_id)
    return case_id


@router.post("/investigate", response_model=InvestigateResponse, dependencies=[Depends(GENAI_QUOTA)])
def investigate(
    body: InvestigateRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> InvestigateResponse:
    client = client_for(settings.investigator_url)
    case_id = _start_remote(client, body.acct_id, uid, settings) if client else None
    if case_id is None:
        case_id = str(uuid.uuid4())
        STORE.add(_stub_report(case_id, body.acct_id, STUB_FALLBACK_VERSION if client else settings.model_version))
    OWNERS.put(case_id, uid)
    return InvestigateResponse(case_id=case_id, stream_url=f"/v1/investigations/{case_id}/events")


def _pending_report(case_id: str, status_payload: dict[str, Any]) -> CaseReport:
    """A schema-valid CaseReport for a case Case Zero has not finished (or lost before it finished)."""
    state = status_payload.get("status")
    events = status_payload.get("events") or ()
    seed = next((e.get("seed") for e in events if e.get("type") == "run_started"), None)
    failed = state == "failed"
    error = next((e.get("message") for e in events if e.get("type") == "error"), None)
    return CaseReport(
        case_id=case_id,
        acct_id=seed or "unknown",
        status="failed" if failed else ("running" if state == "running" else "queued"),
        summary_en=f"Investigation failed: {error or 'no report was produced'}." if failed else "Investigation in progress.",
        summary_bn="তদন্ত ব্যর্থ হয়েছে।" if failed else "তদন্ত চলছে।",
        evidence=(),
        ring=(),
        confidence=0.0,
        recommended_action="pending",
        model_version="case-zero",
    )


@router.get("/investigations/{case_id}", response_model=CaseReport)
def get_case(
    case_id: CaseId,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> CaseReport:
    _require_owner(case_id, uid, settings, time.perf_counter())
    stub = STORE.get(case_id)
    if stub is not None:
        return stub
    client = client_for(settings.investigator_url)
    if client is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown case")
    try:
        contract = client.contract(case_id)
        if contract is not None:
            return CaseReport(**contract)
        return _pending_report(case_id, client.status(case_id))
    except UnknownCase as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown case") from exc
    except InvestigatorUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "the investigator is unavailable") from exc


async def _as_sse(steps: AsyncIterator[dict[str, Any]]) -> AsyncIterator[str]:
    async for step in steps:
        yield f"data: {json.dumps(step, ensure_ascii=False)}\n\n"


@router.get("/investigations/{case_id}/events")
async def case_events(
    case_id: CaseId,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> StreamingResponse:
    _require_owner(case_id, uid, settings, time.perf_counter())
    if STORE.get(case_id) is not None:
        return StreamingResponse(_stub_stream(), media_type="text/event-stream", headers=SSE_HEADERS)
    client = client_for(settings.investigator_url)
    if client is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown case")
    try:
        await run_in_threadpool(client.status, case_id)  # a 404 here, before the stream starts
    except UnknownCase as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown case") from exc
    except InvestigatorUnavailable as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "the investigator is unavailable") from exc
    return StreamingResponse(_as_sse(client.steps(case_id)), media_type="text/event-stream", headers=SSE_HEADERS)
