"""risk-mw: the FinNest risk backend on Cloud Run.

Run locally:  uvicorn main:app --reload --port 8080
Tests:        pytest
Deploy:       gcloud run deploy risk-mw --source . --region asia-southeast1
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from app import appsafety_engine, ato, genai_client, mule, scam, session_model
from app.ratelimit import SlidingWindowLimiter, enforce
from app.routers import actions, appsafety, demo, intervene, investigate, mule as mule_router, risk, speech
from app.routers import warnings as warning_routes
from app.settings import get_settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
# One OpenMP thread per prediction. Every model here scores a single row, which a thread team only slows down
# (predict_proba 4.7 ms instead of 0.3), and each request thread's first prediction paid up to 45 ms to build
# its team. Set before any model is loaded (they load lazily, in the lifespan); a deploy's own value wins.
os.environ.setdefault("OMP_NUM_THREADS", "1")

PROCESSING_HEADER = "X-Processing-Time-Ms"


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # Warm every model at start-up so the first score call is not the slow one (about 170 ms cold).
    mule.model()
    session_model.warm_up()
    ato.models()  # None, and cached, when RISK_MW_ATO_ARTEFACTS_DIR is unset
    genai_client.warm_up()  # the Gemini client and its first token, no model call; skipped when Gemini is off
    # The detector's card cache, off the lifespan: the first live scam turn then reads it instead of making it (about 3 s).
    threading.Thread(target=lambda: scam.warm_prefix(), name="detector-card-cache", daemon=True).start()
    appsafety_engine.warm_up()  # classifier + one Gemini call; best-effort, see the function
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="FinNest risk-mw", version=settings.model_version, lifespan=lifespan)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    app.state.limiters = (
        {
            "default": SlidingWindowLimiter(settings.rate_limit_default_per_min, 60),
            "genai": SlidingWindowLimiter(settings.rate_limit_genai_per_min, 60),
            "genai_all": SlidingWindowLimiter(settings.rate_limit_genai_all_per_min, 60),
        }
        if settings.rate_limit_enabled
        else {}
    )

    @app.middleware("http")
    async def add_processing_time(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        started = time.perf_counter()
        response = await call_next(request)
        response.headers[PROCESSING_HEADER] = f"{(time.perf_counter() - started) * 1000:.1f}"
        return response

    # Cloud Run's front end answers /healthz itself with a 404, so the real health route is /health.
    @app.get("/health", tags=["ops"])
    @app.get("/healthz", tags=["ops"], include_in_schema=False)
    def health() -> dict[str, str | bool]:
        return {"status": "ok", "service": settings.service_name, "model_version": settings.model_version, "demo_mode": settings.demo_mode}

    for router in (risk.router, mule_router.router, appsafety.router, intervene.router, actions.router, investigate.router, demo.router,
                   warning_routes.router):
        app.include_router(router, dependencies=[Depends(enforce("default"))])
    # The speech router carries a WebSocket route, which an HTTP rate-limit dependency cannot serve; its paid HTTP route
    # (/v1/scam/transcribe) carries the Gemini quota itself, and the live bridge is bounded by its own switch and limits.
    app.include_router(speech.router)
    return app


app = create_app()
