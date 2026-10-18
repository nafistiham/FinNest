"""Document state: demo_state, users, interventions, transactions, scam sessions.

One small interface over Firestore (when RISK_MW_FIRESTORE_ENABLED=true) or an in-process dict
(tests, local runs, the single-instance demo). Documents are plain dicts keyed by collection and id.
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
from typing import Any, Protocol, TypeVar

from app.settings import get_settings

# Room for Cloud Run's 20 concurrent requests reading a few documents each; a read waits on the network, not the CPU.
READ_WORKERS = 32
_READERS = ThreadPoolExecutor(max_workers=READ_WORKERS, thread_name_prefix="store-read")
T = TypeVar("T")


class Tx(Protocol):
    """What a transaction body may do: every read before the first write (Firestore's rule)."""

    def get(self, collection: str, doc_id: str) -> dict[str, Any]: ...
    def where(self, collection: str, field: str, value: Any) -> list[dict[str, Any]]: ...
    def set(self, collection: str, doc_id: str, data: dict[str, Any]) -> None: ...
    def merge(self, collection: str, doc_id: str, data: dict[str, Any]) -> None: ...


class Store(Protocol):
    def get(self, collection: str, doc_id: str) -> dict[str, Any]: ...
    def set(self, collection: str, doc_id: str, data: dict[str, Any]) -> None: ...
    def merge(self, collection: str, doc_id: str, data: dict[str, Any]) -> None: ...
    def delete(self, collection: str, doc_id: str) -> None: ...
    def where(self, collection: str, field: str, value: Any) -> list[dict[str, Any]]: ...
    def run(self, fn: Callable[[Tx], T]) -> T: ...


class MemoryStore:
    def __init__(self) -> None:
        self._docs: dict[tuple[str, str], dict[str, Any]] = {}
        self._lock = threading.RLock()  # re-entrant: run() holds it while the body reads and writes

    def get(self, collection: str, doc_id: str) -> dict[str, Any]:
        with self._lock:
            return dict(self._docs.get((collection, doc_id), {}))

    def set(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        with self._lock:
            self._docs = {**self._docs, (collection, doc_id): dict(data)}

    def merge(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        with self._lock:
            self._docs = {**self._docs, (collection, doc_id): {**self._docs.get((collection, doc_id), {}), **data}}

    def delete(self, collection: str, doc_id: str) -> None:
        with self._lock:
            self._docs = {k: v for k, v in self._docs.items() if k != (collection, doc_id)}

    def where(self, collection: str, field: str, value: Any) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(v) for (c, _), v in self._docs.items() if c == collection and v.get(field) == value]

    def run(self, fn: Callable[[Tx], T]) -> T:
        with self._lock:
            return fn(self)


class _FirestoreTx:
    def __init__(self, db, transaction) -> None:
        self._db, self._t = db, transaction

    def get(self, collection: str, doc_id: str) -> dict[str, Any]:
        snap = self._db.collection(collection).document(doc_id).get(transaction=self._t)
        return dict(snap.to_dict() or {}) if snap.exists else {}

    def where(self, collection: str, field: str, value: Any) -> list[dict[str, Any]]:
        from google.cloud.firestore import FieldFilter

        query = self._db.collection(collection).where(filter=FieldFilter(field, "==", value))
        return [dict(s.to_dict() or {}) for s in self._t.get(query)]

    def set(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        self._t.set(self._db.collection(collection).document(doc_id), data)

    def merge(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        self._t.set(self._db.collection(collection).document(doc_id), data, merge=True)


class FirestoreStore:
    def __init__(self, client) -> None:
        self._db = client

    def get(self, collection: str, doc_id: str) -> dict[str, Any]:
        snap = self._db.collection(collection).document(doc_id).get()
        return dict(snap.to_dict() or {}) if snap.exists else {}

    def set(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        self._db.collection(collection).document(doc_id).set(data)

    def merge(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        self._db.collection(collection).document(doc_id).set(data, merge=True)

    def delete(self, collection: str, doc_id: str) -> None:
        self._db.collection(collection).document(doc_id).delete()

    def where(self, collection: str, field: str, value: Any) -> list[dict[str, Any]]:
        from google.cloud.firestore import FieldFilter

        return [dict(s.to_dict() or {}) for s in self._db.collection(collection).where(filter=FieldFilter(field, "==", value)).stream()]

    def run(self, fn: Callable[[Tx], T]) -> T:
        from google.cloud import firestore

        @firestore.transactional
        def body(transaction):
            return fn(_FirestoreTx(self._db, transaction))

        return body(self._db.transaction())


_MEMORY = MemoryStore()


@lru_cache(maxsize=1)
def _firestore() -> FirestoreStore:
    from google.cloud import firestore

    return FirestoreStore(firestore.Client(project=get_settings().project_id or None))


def store() -> Store:
    return _firestore() if get_settings().firestore_enabled else _MEMORY


def transaction(fn: Callable[[Tx], T]) -> T:
    """fn's reads and writes as one atomic update: a Firestore transaction, or the memory store's lock. Firestore retries fn on
    contention, so it reads everything before its first write and has no side effects (no push, no audit) of its own."""
    return store().run(fn)


def get_many(keys: Sequence[tuple[str, str]]) -> list[dict[str, Any]]:
    """Read several (collection, id) documents at once, in the order asked: one round trip instead of one per document.

    The Firestore client is thread-safe, so the reads share it; spec section 6 asks for the score's reads in parallel.
    """
    db = store()
    return list(_READERS.map(lambda key: db.get(*key), keys))


def reset_memory() -> None:
    """Tests only: forget every in-memory document."""
    global _MEMORY
    _MEMORY = MemoryStore()
