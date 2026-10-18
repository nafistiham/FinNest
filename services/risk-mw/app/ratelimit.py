"""Per-caller request limits.

The service URL is public and some routes spend Gemini money, so each caller gets a sliding-window
quota. Callers are told apart by the address Cloud Run's front end saw, never by a header they
chose: the front end appends the real client to X-Forwarded-For, so only the last hop is trusted.
"""

from __future__ import annotations

import logging
import math
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping, Sequence

from fastapi import HTTPException, Request, status

log = logging.getLogger(__name__)
MAX_TRACKED_CALLERS = 10_000
SHARED_KEY = "*"  # every caller counts against the same quota
LOGGED_HEADER_CHARS = 200  # X-Forwarded-For is the caller's own text; only this much of it reaches the log
# Held while several buckets are checked and then counted, so two calls cannot both pass the check
# for the last slot. The buckets taken together are only ever spent through enforce_all.
_SPEND_ALL_LOCK = threading.Lock()


class SlidingWindowLimiter:
    """At most `limit` admitted calls per `window_s` seconds for each key."""

    def __init__(self, limit: int, window_s: float, clock: Callable[[], float] = time.monotonic, max_keys: int = MAX_TRACKED_CALLERS) -> None:
        self._limit = limit
        self._window = window_s
        self._clock = clock
        self._max_keys = max_keys
        self._hits: dict[str, deque[float]] = {}
        self._logged: dict[str, float] = {}
        self._lock = threading.Lock()

    def check(self, key: str) -> float:
        """0.0 when the call is admitted and counted; otherwise the seconds until a slot frees up.

        A rejected call is not counted, so hammering a closed gate does not push the opening back.
        """
        now = self._clock()
        with self._lock:
            wait = self._wait(key, now)
            if not wait:
                self._count(key, now)
            return wait

    def would_admit(self, key: str) -> float:
        """What check() would answer now, without counting the call. Pair with record()."""
        now = self._clock()
        with self._lock:
            return self._wait(key, now)

    def record(self, key: str) -> None:
        """Count one call for `key` now, after would_admit() said it fits."""
        now = self._clock()
        with self._lock:
            self._count(key, now)

    def rejection_log_due(self, key: str) -> bool:
        """True for the first rejection of `key` in a window, False for the rest, so a flood logs one line per caller."""
        now = self._clock()
        with self._lock:
            last = self._logged.get(key)
            if last is not None and now - last < self._window:
                return False
            self._logged.pop(key, None)
            if len(self._logged) >= self._max_keys:
                self._evict_logged(now)
            self._logged[key] = now  # appended last, so the table stays oldest-first for _evict_logged
            return True

    def tracked_keys(self) -> int:
        with self._lock:
            return len(self._hits)

    def logged_keys(self) -> int:
        with self._lock:
            return len(self._logged)

    def _wait(self, key: str, now: float) -> float:
        hits = self._hits.get(key)
        while hits and now - hits[0] >= self._window:
            hits.popleft()
        if len(hits or ()) < self._limit:
            return 0.0
        return max(self._window - (now - hits[0]), 0.001) if hits else self._window

    def _count(self, key: str, now: float) -> None:
        if key not in self._hits and len(self._hits) >= self._max_keys:
            self._evict(now)
        self._hits.setdefault(key, deque()).append(now)

    def _evict(self, now: float) -> None:
        """Drop callers whose window has emptied; if the table is still full, drop the oldest half."""
        self._hits = {k: v for k, v in self._hits.items() if v and now - v[-1] < self._window}
        if len(self._hits) >= self._max_keys:
            keep = list(self._hits.items())[len(self._hits) // 2 :]
            self._hits = dict(keep)

    def _evict_logged(self, now: float) -> None:
        """Forget keys last logged a window or more ago; if the table is still full, forget the oldest half."""
        recent = {k: t for k, t in self._logged.items() if now - t < self._window}
        self._logged = recent if len(recent) < self._max_keys else dict(list(recent.items())[len(recent) // 2 :])


def client_ip(headers: Mapping[str, str], peer: str) -> str:
    hops = [h.strip() for h in (headers.get("x-forwarded-for") or "").split(",") if h.strip()]
    return hops[-1] if hops else peer


def _peer(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _key(request: Request, per_caller: bool) -> str:
    return client_ip(request.headers, _peer(request)) if per_caller else SHARED_KEY


def _too_many(request: Request, rejected: Sequence[tuple[str, SlidingWindowLimiter, str, float]]) -> HTTPException:
    """The 429 for a call one or more buckets turned away, logged at most once per bucket and key per window."""
    forwarded = (request.headers.get("x-forwarded-for") or "")[:LOGGED_HEADER_CHARS]
    for bucket, limiter, key, _ in rejected:
        if limiter.rejection_log_due(key):
            log.info("rate limited bucket=%s key=%s x-forwarded-for=%r peer=%s", bucket, key, forwarded, _peer(request))
    wait = max(w for *_, w in rejected)
    return HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "too many requests, slow down", headers={"Retry-After": str(math.ceil(wait))})


def enforce(bucket: str, *, per_caller: bool = True) -> Callable[[Request], None]:
    """A route dependency that spends one call from the named bucket or answers 429."""

    def dependency(request: Request) -> None:
        limiters: Mapping[str, SlidingWindowLimiter] = getattr(request.app.state, "limiters", {})
        limiter = limiters.get(bucket)
        if limiter is None:
            return
        key = _key(request, per_caller)
        wait = limiter.check(key)
        if wait:
            raise _too_many(request, [(bucket, limiter, key, wait)])

    return dependency


Rejected = list[tuple[str, SlidingWindowLimiter, str, float]]


def spend_all(request: Request, buckets: Sequence[tuple[str, bool]]) -> Rejected:
    """Spend one call from every named bucket, or from none of them; returns the buckets that refused (empty = admitted).

    Each bucket is a (name, per_caller) pair. Every bucket is checked before any is counted, so a call
    one bucket rejects is not counted in another: a caller whose call the shared bucket turns away keeps
    their own quota. A shared bucket (per_caller False) is the floor under a per-caller one on routes
    that spend money: a per-caller quota depends on telling callers apart, and once a parallel burst
    from one client passed it for reasons the logs did not settle, so it is not treated as a ceiling.
    """
    limiters: Mapping[str, SlidingWindowLimiter] = getattr(request.app.state, "limiters", {})
    targets = [(name, limiters[name], _key(request, per_caller)) for name, per_caller in buckets if name in limiters]
    if not targets:
        return []
    with _SPEND_ALL_LOCK:
        waits = [(name, limiter, key, limiter.would_admit(key)) for name, limiter, key in targets]
        rejected = [w for w in waits if w[3]]
        if not rejected:
            for _name, limiter, key in targets:
                limiter.record(key)
    return rejected


def enforce_all(*buckets: tuple[str, bool]) -> Callable[[Request], None]:
    """A route dependency that spends one call from every named bucket, or answers 429 (see spend_all)."""

    def dependency(request: Request) -> None:
        rejected = spend_all(request, buckets)
        if rejected:
            raise _too_many(request, rejected)

    return dependency


def admit(request: Request, buckets: Sequence[tuple[str, bool]]) -> bool:
    """Spend the buckets at the point of use, inside a handler, instead of at the route.

    For routes that only sometimes call the model: the handler decides it needs Gemini, asks here, and on False
    answers from its deterministic path instead of spending (the caller never sees a 429 for a call that was not
    made). Logged once per bucket and caller per window, like a 429 would be.
    """
    rejected = spend_all(request, buckets)
    if rejected:
        _too_many(request, rejected)  # builds the (unraised) 429 for the sake of its one-per-window log line
        return False
    return True


# The Gemini buckets: one call from the caller's own quota and one from the quota every caller shares, or neither.
GENAI_BUCKETS: tuple[tuple[str, bool], ...] = (("genai", True), ("genai_all", False))
# Routes that always spend (/v1/scam/turn, /v1/investigate) take this at the route; /v1/appsafety/check spends through
# admit() only when a check has something for the model (review finding 2026-10-16: a clean phone used to cost a slot).
GENAI_QUOTA = enforce_all(*GENAI_BUCKETS)
