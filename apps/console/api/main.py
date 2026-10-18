"""FinNest Admin: the operator console's own service. Cloud Run service `finnest-admin` by default.

A separate service, not a router inside risk-mw. risk-mw is pinned to a single
instance because four things live in its process memory; an analyst console that recomputes a SHAP
pass has no business sharing that instance. Keeping them apart also means this can be redeployed
during judging without touching the service the demo runs on.

What it serves: the /v1/admin/* API, and the built console at /. The console calls risk-mw directly
for anything live (health, mule score, investigations) - this service never proxies it, so there is
one less place for a stale copy of someone else's contract to live.

Run locally:  uvicorn api.main:app --reload --port 8099
Tests:        pytest
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field

from api import auth
from api import insight
from api.router import FIXTURE, router, warm

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

SERVICE = os.environ.get("K_SERVICE") or "finnest-admin"
VERSION = "0.1.0"
# The risk-mw base URL the console's browser half calls; reported on /health. Empty when unset.
UPSTREAM = os.environ.get("RISK_MW_URL", "").rstrip("/")
PROCESSING_HEADER = "X-Processing-Time-Ms"
WEB_DIST = Path(__file__).resolve().parents[1] / "web" / "dist"


class Credentials(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Warm the seed world and the payee rollup off the request path.

    Measured on the first deploy: an unwarmed account drill-down took 8.6 s and the Case Zero
    watch-list 16.2 s, because the first caller paid for loading 12,122 transactions and replaying
    the rules. Both answer in about 0.26 s once warm. risk-mw warms its scorer at start-up for the
    same reason; a daemon thread keeps the health check answering while it happens.

    Gemini gets its own thread: the first reading after a deploy timed out cold, and it should not wait behind
    the seed world either. See insight.warm_up.
    """
    threading.Thread(target=warm, name="warm", daemon=True).start()
    threading.Thread(target=insight.warm_up_from_env, name="warm-gemini", daemon=True).start()
    yield


class CachedConsole(StaticFiles):
    """Static files with the two cache rules a hashed-asset build needs.

    `StaticFiles` sends an ETag and a Last-Modified and no `Cache-Control` at all, and a browser
    given no instruction caches heuristically - roughly a tenth of the file's age - without
    revalidating. So `index.html` was served from the viewer's own cache, pointing at the previous
    build's assets, which were in that cache too. A deploy landed and nobody saw it: the console
    looked unchanged while the API underneath it was new.

    The fix is the standard pair, and it only works because Vite fingerprints filenames:

    * `index.html` must revalidate every time. `no-cache` does not mean "do not store", it means
      "ask first", so the ETag still saves the download when nothing changed.
    * everything under `assets/` carries a content hash in its name, so a changed file is a
      different URL and the old one can be kept for a year. `immutable` tells the browser not to
      revalidate it even on a reload.
    """

    def file_response(self, *args: Any, **kwargs: Any) -> Response:
        response = super().file_response(*args, **kwargs)
        path = str(getattr(response, "path", ""))
        if "/assets/" in path:
            response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        else:
            response.headers["Cache-Control"] = "no-cache"
        return response


def create_app() -> FastAPI:
    app = FastAPI(title="FinNest Admin", version=VERSION, lifespan=lifespan)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    @app.middleware("http")
    async def add_processing_time(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        started = time.perf_counter()
        response = await call_next(request)
        response.headers[PROCESSING_HEADER] = f"{(time.perf_counter() - started) * 1000:.1f}"
        return response

    @app.get("/health", tags=["ops"])
    def health() -> dict[str, object]:
        stamp = None
        if FIXTURE.exists():
            try:
                stamp = json.loads(FIXTURE.read_text())["generated_at"]
            except (OSError, json.JSONDecodeError, KeyError):
                stamp = None
        return {"status": "ok", "service": SERVICE, "version": VERSION, "upstream": UPSTREAM,
                "fixture_generated_at": stamp, "synthetic": True}

    @app.post("/v1/auth/login", tags=["auth"])
    def login(body: Credentials) -> dict[str, object]:
        """One operator account, checked server-side. See api/auth.py for what this is not."""
        if not auth.check_password(body.username, body.password):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "wrong username or password")
        return auth.issue(body.username.strip())

    @app.get("/v1/auth/me", tags=["auth"])
    def me(operator: auth.Operator) -> dict[str, str]:
        return {"username": operator}

    app.include_router(router)

    # The built console, when there is one. Mounted last so it never shadows an API route.
    if WEB_DIST.is_dir():
        app.mount("/", CachedConsole(directory=WEB_DIST, html=True), name="console")

    return app


app = create_app()
