"""Deterministic case ids for the few tests whose meaning depends on which case came first (display eviction).

Production ids are random (case_zero/ids.py); pass sequential_ids() as create_app(case_ids=...) only where order matters."""

from __future__ import annotations

import itertools
from collections.abc import Callable


def sequential_ids() -> Callable[[], str]:
    numbers = itertools.count(1)
    return lambda: "CZ-%04d" % next(numbers)
