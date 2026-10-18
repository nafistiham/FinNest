"""Case Zero service: same-origin console, streaming investigations, cases and the payee watch-list."""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import time
from collections import OrderedDict, deque
from collections.abc import Callable
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import AliasChoices, BaseModel, Field, field_validator

from case_zero import PROJECT_DIR
from case_zero.config import DEMO_AS_OF, DEMO_SEED, WORLD_END, WORLD_START, Settings
from case_zero.export import decision, payee_risk
from case_zero.ids import new_case_id
from case_zero.llm import GeminiLLM, select_backend
from case_zero.orchestrator import run_investigation
from case_zero.schemas import exported_status, to_contract
from case_zero.world import World

STATIC = Path(__file__).resolve().parent.parent / "static"
MAX_CONCURRENT = 3
PER_IP_LIMIT = 6          # investigations per IP per window
PER_IP_WINDOW_S = 600.0
MAX_CASES = 200           # display history; decisions are kept apart and never evicted
PING_S = 10.0
TRUSTED_HOPS = 1          # proxies that append to X-Forwarded-For: run.app's front end is one (CASE_ZERO_TRUSTED_HOPS)
SEEDS = (
    {"seed": DEMO_SEED, "as_of": DEMO_AS_OF, "label": "Flagged wallet during Rina's theft (demo)"},
    {"seed": "acct_rina", "as_of": DEMO_AS_OF, "label": "Rina's own account"},
    {"seed": "acct_09001", "as_of": DEMO_AS_OF, "label": "Customer with a new phone"},
    {"seed": "acct_till_AG-0192", "as_of": "2026-11-10T16:00:00", "label": "Agent till AG-0192 after the cash-outs"},
)


class InvestigateIn(BaseModel):
    seed: str = Field(max_length=64, pattern=r"^acct_[A-Za-z0-9_-]{1,48}$", validation_alias=AliasChoices("seed", "acct_id"))  # acct_id: risk-mw's name
    as_of: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")
    fault_inject: bool = False

    @field_validator("as_of")
    @classmethod
    def within_world(cls, v: str | None) -> str | None:
        if v is not None and not (WORLD_START <= v < WORLD_END):
            raise ValueError(f"as_of must fall inside the synthetic world, {WORLD_START} to {WORLD_END}")
        return v


FINAL = ("done", "degraded", "failed")


class _Run:
    """One investigation, from either POST route: its events so far, status, report and task."""

    def __init__(self, case_id: str) -> None:
        self.case_id, self.status, self.events, self.report, self.task = case_id, "queued", [], None, None
        self.new = asyncio.Event()

    async def add(self, event: dict) -> None:
        self.events.append(event)
        self.new.set()
        self.new = asyncio.Event()


def _sse(i: int, event: dict) -> str:
    return f"id: {i}\nevent: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False, default=str)}\n\n"


def client_ip(headers, peer: str, trusted_hops: int = TRUSTED_HOPS) -> str:
    """The caller's address. Each trusted proxy appends the address it saw to X-Forwarded-For after
    whatever the caller sent, so the client is the trusted_hops-th hop from the right; anything to its
    left can be forged. On run.app that is the last hop (1). With no proxy (0), or fewer hops than
    proxies, the header is not trusted and the peer address is used."""
    hops = [h.strip() for h in (headers.get("x-forwarded-for") or "").split(",") if h.strip()]
    return hops[-trusted_hops] if 0 < trusted_hops <= len(hops) else peer


def _llm_from_env(settings: Settings):
    if select_backend(os.environ)[0] == "none":
        return None
    return GeminiLLM.from_env(settings.models_yaml, settings.model_role, settings.thinking_level)


def create_app(world: World | None = None, llm=None, settings: Settings = Settings(), admin_token: str | None = None,
               max_concurrent: int = MAX_CONCURRENT, per_ip_limit: int = PER_IP_LIMIT, max_cases: int = MAX_CASES, clock=time.monotonic,
               trusted_hops: int | None = None, case_ids: Callable[[], str] = new_case_id) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if app.state.world is None:
            app.state.world = World.load(PROJECT_DIR)
        if app.state.llm is None:  # built at startup, not at import
            app.state.llm = _llm_from_env(settings)
        yield

    app = FastAPI(title="Case Zero", lifespan=lifespan)
    app.state.world = world
    app.state.llm = llm
    app.state.cases, app.state.approved, app.state.tasks, app.state.runs = OrderedDict(), set(), set(), OrderedDict()
    app.state.decisions = {}   # every decided case's members, roles and action; in memory (no Firestore client yet)
    token = admin_token if admin_token is not None else os.environ.get("CASE_ZERO_ADMIN_TOKEN")
    hops = trusted_hops if trusted_hops is not None else int((os.environ.get("CASE_ZERO_TRUSTED_HOPS") or "").strip() or TRUSTED_HOPS)
    gate = asyncio.Semaphore(max_concurrent)
    recent: dict[str, deque] = {}

    def rate_limited(ip: str) -> bool:
        now = clock()
        for idle in [k for k, q in recent.items() if not q or now - q[-1] > PER_IP_WINDOW_S]:
            del recent[idle]
        q = recent.setdefault(ip, deque())
        while q and now - q[0] > PER_IP_WINDOW_S:
            q.popleft()
        if len(q) >= per_ip_limit:
            return True
        q.append(now)
        return False

    app.state.rate_keys = lambda: len(recent)

    def store(case_id: str, report) -> None:
        """Two stores: `cases` is the display history, bounded; `decisions` feeds the watch-list and is not, so
        a burst of investigations of unknown accounts cannot evict a real ring from /api/payee-risk."""
        app.state.cases[case_id] = report
        while len(app.state.cases) > max_cases:
            app.state.cases.popitem(last=False)
        if (decided := decision(case_id, report)) is not None:
            app.state.decisions[case_id] = decided

    def fresh_case_id() -> str:
        """A new random id. A collision is about 1 in 10^15 at our volumes; the loop is a guard, not a feature."""
        case_id = case_ids()
        while case_id in app.state.runs or case_id in app.state.cases or case_id in app.state.decisions:
            case_id = case_ids()
        return case_id

    def admit(request: Request) -> None:
        if app.state.llm is None:
            raise HTTPException(503, "Gemini is not configured: set CASE_ZERO_PROJECT_ID (Vertex AI)")
        if gate.locked():  # before the per-IP count: a busy rejection must not use up the caller's quota
            raise HTTPException(429, "busy: too many investigations running; try the replay")
        if rate_limited(client_ip(request.headers, request.client.host if request.client else "unknown", hops)):
            raise HTTPException(429, "too many investigations from this address; try the replay")

    def run_or_404(case_id: str) -> _Run:
        run = app.state.runs.get(case_id)
        if run is None:
            raise HTTPException(404, "unknown investigation")
        return run

    def case_or_404(case_id: str):
        report = app.state.cases.get(case_id)
        if report is None:
            raise HTTPException(404, "unknown case")
        return report

    @app.get("/health")  # not /healthz: Cloud Run reserves paths ending in "z"
    def health() -> dict:
        llm_ = app.state.llm
        return {"ok": True, "llm_ready": llm_ is not None, "model": llm_.role.id if llm_ else None, "cases": len(app.state.cases)}

    @app.get("/api/seeds")
    def seeds() -> list[dict]:
        return list(SEEDS)

    async def launch(body: InvestigateIn, request: Request) -> _Run:
        """Admit, take a slot and start the run in the background; both POST routes go through here."""
        admit(request)
        await gate.acquire()  # taken before any other request runs, so a burst cannot slip past the check
        case_id = fresh_case_id()
        run = _Run(case_id)
        app.state.runs[case_id] = run
        while len(app.state.runs) > max_cases:
            oldest = next(iter(app.state.runs))
            if app.state.runs[oldest].status not in FINAL:
                break
            app.state.runs.pop(oldest)

        async def go() -> None:
            run.status = "running"
            try:
                report = await run_investigation(app.state.world, app.state.llm, body.seed, body.as_of or DEMO_AS_OF, run.add, case_id, body.fault_inject, settings)
                store(case_id, report)  # unknown seeds too: the done event promises a fetchable case
                run.report, run.status = report, exported_status(report.status)
            except asyncio.CancelledError:  # only at shutdown: a viewer leaving never cancels a run
                run.status = "failed"
                await run.add({"type": "error", "message": "cancelled: the service is shutting down"})
                await run.add({"type": "done", "case_id": case_id, "status": "failed"})
                raise
            except Exception as exc:  # the stream and the status must always reach a final state
                run.status = "failed"
                await run.add({"type": "error", "message": f"{type(exc).__name__}: {exc}"})
                await run.add({"type": "done", "case_id": case_id, "status": "failed"})
            finally:
                gate.release()
                run.new.set()  # wake listeners that are waiting for the final status

        run.task = asyncio.create_task(go())
        app.state.tasks.add(run.task)
        run.task.add_done_callback(app.state.tasks.discard)
        return run

    async def events(run: _Run, start: int = 0):
        """The run's events as server-sent events from `start`, until it is final."""
        i = start
        while True:
            waiter = run.new
            while i < len(run.events):
                yield _sse(i, run.events[i])
                i += 1
            if run.status in FINAL and i >= len(run.events):
                return
            try:
                await asyncio.wait_for(waiter.wait(), PING_S)
            except asyncio.TimeoutError:
                yield ": ping\n\n"

    def sse_response(stream) -> StreamingResponse:
        return StreamingResponse(stream, media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    @app.post("/api/investigations", status_code=202)
    async def start_investigation(body: InvestigateIn, request: Request) -> dict:
        """Start a case and return where to watch it: an EventSource stream, or a status URL to poll.
        It keeps running if the viewer leaves, so a poller can still collect it."""
        run = await launch(body, request)
        return {"case_id": run.case_id, "status": run.status, "stream_url": f"/api/investigations/{run.case_id}/events", "status_url": f"/api/investigations/{run.case_id}"}

    @app.get("/api/investigations/{case_id}/events")
    async def investigation_events(case_id: str, last_event_id: str | None = Header(default=None)) -> StreamingResponse:
        """Server-sent events for EventSource; a reconnect resumes after Last-Event-ID."""
        run = run_or_404(case_id)
        return sse_response(events(run, int(last_event_id) + 1 if last_event_id and last_event_id.isdigit() else 0))

    @app.get("/api/investigations/{case_id}")
    def investigation_status(case_id: str, since: int = 0) -> dict:
        """For polling when SSE cannot get through: status, the events after `since`, and the report once final."""
        run = run_or_404(case_id)
        since = max(0, min(since, len(run.events)))
        return {"case_id": case_id, "status": run.status, "events": run.events[since:], "next": len(run.events),
                "report": run.report.model_dump() if run.report is not None else None}

    @app.post("/api/investigate")
    async def investigate(body: InvestigateIn, request: Request) -> StreamingResponse:
        """One-request stream (POST) of the same run the two-step routes above serve, so it can be polled
        too. Leaving this stream does not stop the run: a Gemini call already sent may still be billed, so
        the case finishes, is stored, and /api/investigations/{id}/events replays it to a returning viewer."""
        run = await launch(body, request)
        return sse_response(events(run))

    @app.get("/api/cases/{case_id}")
    def get_case(case_id: str) -> dict:
        return case_or_404(case_id).model_dump()

    @app.get("/api/cases/{case_id}/contract")
    def get_contract(case_id: str) -> dict:
        report = case_or_404(case_id)
        return to_contract(report, report._ledger)

    @app.post("/api/cases/{case_id}/approve")
    def approve(case_id: str, x_admin_token: str | None = Header(default=None)) -> dict:
        if not token or not x_admin_token or not hmac.compare_digest(token, x_admin_token):
            raise HTTPException(403, "analyst approval needs the admin token")
        if case_id not in app.state.decisions:  # a decided case stays approvable after the display history drops it
            case_or_404(case_id)
        app.state.approved.add(case_id)
        return {"case_id": case_id, "approved": True}

    @app.get("/api/decisions/{case_id}")
    def get_decision(case_id: str) -> dict:
        """The stored decision behind the watch-list (members, roles, action); it outlives /api/cases/{id}."""
        stored = app.state.decisions.get(case_id)
        if stored is None:
            raise HTTPException(404, "no decision for this case")
        return stored

    @app.get("/api/payee-risk")
    def get_payee_risk() -> dict:
        return payee_risk(app.state.decisions, app.state.approved, app.state.world)

    @app.get("/api/replay")
    def replay() -> FileResponse:
        path = STATIC / "replay" / "demo.jsonl"
        if not path.exists():
            raise HTTPException(404, "no recorded replay yet")
        return FileResponse(path, media_type="application/x-ndjson")

    @app.get("/")
    def console() -> FileResponse:
        return FileResponse(STATIC / "index.html")

    return app


app = create_app()
