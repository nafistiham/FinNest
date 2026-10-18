"""Making room in the in-process stores (sessions, interventions, trusted-contact requests).

Each store is an OrderedDict, oldest first, changed only under that store's own lock; this module is called from
inside it, right after an insert, and drops entries from that private dict in this order so one busy caller cannot
push another caller's live entry out:

1. the inserting owner's own entries past PER_OWNER_LIMIT, her stale ones first, then her oldest;
2. stale entries (settled or expired) of anyone, oldest first;
3. the oldest entries left.

The entry just inserted is never dropped.
"""

from __future__ import annotations

from collections import OrderedDict
from collections.abc import Callable, Hashable, Sequence
from typing import TypeVar

K = TypeVar("K", bound=Hashable)
V = TypeVar("V")

PER_OWNER_LIMIT = 16  # entries one uid may hold in a store at once


def _drop(items: OrderedDict[K, V], candidates: Sequence[K], excess: int, is_stale: Callable[[V], bool]) -> None:
    if excess <= 0:
        return
    stale_first = [k for k in candidates if is_stale(items[k])] + [k for k in candidates if not is_stale(items[k])]
    for key in stale_first[:excess]:
        del items[key]


def make_room(
    items: OrderedDict[K, V],
    keep: K,
    *,
    owner_of: Callable[[K, V], str],
    is_stale: Callable[[V], bool],
    limit: int,
    per_owner: int = PER_OWNER_LIMIT,
) -> None:
    """Bring the store back under `per_owner` for keep's owner and under `limit` overall (see the module order)."""
    owner = owner_of(keep, items[keep])
    owned = [k for k, v in items.items() if k != keep and owner_of(k, v) == owner]
    _drop(items, owned, len(owned) + 1 - per_owner, is_stale)
    others = [k for k in items if k != keep]
    _drop(items, others, len(items) - limit, is_stale)
