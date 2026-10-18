"""Permission vectoriser: the phone's `requestedPermissions` into the classifier's training column order (FR-3).

`columns.json` (written by the trainer) is the single source of the order. Phone permission names
("android.permission.READ_SMS") and dataset column spellings ("READ_SMS", "android.permission.READ_SMS",
"Permission.READ_SMS") meet through `canonical_permission`; permissions the training set never saw are
dropped, columns the phone did not declare are 0.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from pathlib import Path

import numpy as np

from bhorosha_app_safety_check.schema import canonical_permission

COLUMNS_FILE = "columns.json"


class Vectoriser:
    def __init__(self, columns: Sequence[str]):
        if not columns:
            raise ValueError("a vectoriser needs at least one column")
        self.columns: tuple[str, ...] = tuple(columns)
        self._index: dict[str, int] = {}
        for i, column in enumerate(self.columns):
            self._index.setdefault(canonical_permission(column), i)  # first spelling wins on a duplicate

    @classmethod
    def load(cls, artefacts: Path) -> Vectoriser:
        return cls(json.loads((artefacts / COLUMNS_FILE).read_text(encoding="utf-8"))["columns"])

    def save(self, artefacts: Path) -> None:
        artefacts.mkdir(parents=True, exist_ok=True)
        (artefacts / COLUMNS_FILE).write_text(json.dumps({"columns": list(self.columns)}, indent=0), encoding="utf-8")

    def __len__(self) -> int:
        return len(self.columns)

    def known(self, permission: str) -> bool:
        return canonical_permission(permission) in self._index

    def transform(self, permissions: Iterable[str]) -> np.ndarray:
        row = np.zeros(len(self.columns), dtype=np.float32)
        for permission in permissions:
            i = self._index.get(canonical_permission(permission))
            if i is not None:
                row[i] = 1.0
        return row

    def transform_many(self, rows: Sequence[Iterable[str]]) -> np.ndarray:
        if not rows:
            return np.zeros((0, len(self.columns)), dtype=np.float32)
        return np.vstack([self.transform(r) for r in rows])
