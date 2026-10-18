"""What /v1/risk/signals leaves for /v1/risk/score.

/score carries neither the behaviour features nor the device signals; they arrive at /signals and the two calls are
joined by session id. The last SignalsRequest is held per (caller uid, session id), so another caller posting to
the same session id starts a session of his own instead of overwriting hers. Entries expire RISK_MW_SESSION_TTL_S
after the last post and the store is bounded by RISK_MW_SESSION_LIMIT: expired sessions are dropped first, and no
uid holds more than app.bounded.PER_OWNER_LIMIT sessions, so one caller cannot push another's live session out.

In-process on purpose, which is honest only because the service runs as one instance (README "One instance, on
purpose"). The production home is users/{uid}/sessions/{sessionId} in Firestore.
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime

from app import bounded
from app.contracts import SignalsRequest
from app.settings import Settings

SessionKey = tuple[str, str]  # (caller uid, session id)


@dataclass(frozen=True)
class SessionState:
    signals: SignalsRequest
    received_at: datetime  # server clock when /signals stored it

    @property
    def features(self) -> tuple[float, ...]:
        return self.signals.behaviour.features


def _uid_of(key: SessionKey, _state: SessionState) -> str:
    return key[0]


def _expired(state: SessionState, now: datetime, ttl_s: float) -> bool:
    return (now - state.received_at).total_seconds() > ttl_s


class SessionStore:
    """Bounded, thread-safe, expiring map of (uid, session id) to the last state posted for it."""

    def __init__(self) -> None:
        self._items: OrderedDict[SessionKey, SessionState] = OrderedDict()
        self._lock = threading.Lock()

    def put(self, key: SessionKey, state: SessionState, limit: int, ttl_s: float) -> SessionState:
        """Store `state`; past `limit`, expired sessions go first and no uid keeps more than PER_OWNER_LIMIT."""
        with self._lock:
            self._items[key] = state
            self._items.move_to_end(key)
            bounded.make_room(
                self._items, key, owner_of=_uid_of, limit=limit,
                is_stale=lambda other: _expired(other, state.received_at, ttl_s),
            )
        return state

    def get(self, key: SessionKey, now: datetime, ttl_s: float) -> SessionState | None:
        with self._lock:
            state = self._items.get(key)
            if state is None:
                return None
            if _expired(state, now, ttl_s):
                del self._items[key]
                return None
            return state

    def clear(self) -> None:
        with self._lock:
            self._items.clear()


STORE = SessionStore()


def remember(uid: str, body: SignalsRequest, now: datetime, settings: Settings) -> SessionState:
    """Hold this caller's latest signals for the session until its score request arrives."""
    return STORE.put((uid, body.session_id), SessionState(body, now), settings.session_limit, settings.session_ttl_s)


def recall(uid: str, session_id: str, now: datetime, settings: Settings) -> SessionState | None:
    """This caller's live state for the session, or None if none was posted or it has expired."""
    return STORE.get((uid, session_id), now, settings.session_ttl_s)


def forget() -> None:
    """Drop the store. For tests and for an artefacts redeploy."""
    STORE.clear()
