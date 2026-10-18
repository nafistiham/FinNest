"""One-time pass: a raw dataset archive -> a compact feature table on disk .

    python -m bhorosha_ato.extract --dataset hmog --data-dir "$FINNEST_ATO_DATA_DIR" \
        --out ../../models/ato/hmog_features.jsonl

Why this is its own pass rather than something `eval/ato_eval.py` does on the way in: HMOG is a
~6 GB archive carrying accelerometer, gyroscope and magnetometer at 100 Hz next to raw touch and
keystroke logs, so parsing it costs minutes. Parse once, write a table small enough to read in
seconds (100 users x 24 sessions x 30 floats), and let every later eval, sweep or demo read the
table instead of the archive. `models/mule/features.parquet` is the same move for the mule
scorer.

JSONL plus a sibling manifest, not parquet: the table is tiny, and a line-oriented text file can
be diffed, grepped and checked for truncation without a reader library.

Two things each record carries that a bare feature matrix would lose.

* The session's TASK type. HMOG's 24 sessions per user are 8 reading, 8 writing and 8
  map-navigation, and they are not interchangeable: a reading session has no typing at all and a
  writing session has little swiping, while one 30-feature row assumes a session carries swipes
  AND PIN entry AND motion. So the task has to travel with the row, and the eval measures
  identity (morphology) on the reading+map sessions and coaching (tempo) on the writing ones -
  the same split `schema.Signal` already forces on the features.
* Which schema BLOCKS were actually present. Every feature declares a `missing` substitute and
  all thirty are currently 0.0, so without this record a reader cannot tell a measured pressure
  of 0.0 from a pressure block that was never recorded - and would report a mean over
  substituted zeros as a measurement.

The manifest is not decoration either: it is the only way a stale or truncated table is
detectable rather than silently used. `read_table` refuses the table unless the manifest's
checksum, row count, per-user and per-task counts and feature order all still agree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from dataclasses import dataclass, fields
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable, Iterator, Mapping

from bhorosha_ato import features
from bhorosha_ato.datasets import (
    DEFAULT_DATA_DIR,
    HMOG_ZIP,
    HMOG_ZIP_MD5,
    hmog_present,
    iter_hmog_sessions,
)
from bhorosha_ato.schema import (
    FEATURES, INDEX, KEYRANK_KEYS, NAMES, names_for, to_vector,
)

# Bumped whenever the meaning of a record field changes. Stored in the manifest so a table
# written by an older extractor is a visible mismatch rather than a silent misreading.
EXTRACTOR_VERSION = 1

# The WIDE table format, written by the standalone extractor
# (bhorosha_ato/hmog_wide_extract.py; its v2 predecessor wrote the same shape) and read by
# `read_wide_table`. A separate version line, not a bump of the one above, because the two
# formats are different files that both exist on disk today and neither supersedes the other:
# version 1 rows carry a POSITIONAL `features` vector in this schema's order, version 2 rows
# carry a NAMED `values` mapping of 80 candidate features, most of which this schema has no
# column for. Reading one with the other's loader is the mistake the version guard exists to
# make loud, so the two numbers must never be made equal.
WIDE_EXTRACTOR_VERSION = 2

# Later wide extractions that keep the same ROW CONTRACT - a named `values` mapping plus
# `blocks_present` - and only add candidate columns. Version 3 adds per-key hold-time counts,
# medians and within-session ranks; its 174 names are a strict superset of version 2's 80,
# verified by the extractor's own tests. They share a reader because the shape is identical and
# the column set is deliberately not fixed; what must stay loud is the version 1 boundary,
# where rows are POSITIONAL and reading them with this loader would train on the wrong columns.
WIDE_EXTRACTOR_VERSIONS: tuple[int, ...] = (2, 3)

# Default table location. Sits next to the mule artefacts under models/, relative to libs/ato,
# which is where both this module and eval/ato_eval.py are run from.
DEFAULT_TABLE = Path("../../models/ato/hmog_features.jsonl")

# Schema blocks in wire order, read off the schema rather than retyped here: a new block in
# schema.FEATURES has to appear in every record's block-presence map, and deriving the list means
# that shows up as a loud KeyError in SessionRecord instead of an absent key nobody notices.
BLOCKS: tuple[str, ...] = tuple(dict.fromkeys(f.block for f in FEATURES))

# HMOG's three session tasks. The grouping is a property of the dataset's protocol, which is
# why it lives here and not in schema.py.
#
# Identity reads the WRITING sessions, which is not where the first version looked. The
# reasoning was that identity needs swipe geometry, pressure and grip, and reading and map
# sessions carry those - but those tasks carry no typing, so pin_tap_offset_mean_px and
# pin_pressure_mean are absent and the model sees 12 of its 14 features. Measured on the real
# archive, over 98-100 users:
#
#   reading + map, 10+6 sessions, 12 of 14 features    EER 0.1818
#   writing only,   5+3 sessions, 14 of 14 features    EER 0.1165   <- best
#   all three,     10+6 sessions, mixed                EER 0.2233
#   all three,     14+8 sessions, mixed                EER 0.1968
#
# Writing wins despite having the fewest sessions, because it is the only task where every
# morphology feature is actually recorded. And mixing tasks is worse than either single task:
# the model starts separating tasks rather than people, which is the same confound as mixing
# postures. Task is held fixed for the same reason posture is.
TASKS: tuple[str, ...] = ("reading", "writing", "map")
IDENTITY_TASKS: tuple[str, ...] = ("writing",)
COACHING_TASKS: tuple[str, ...] = ("writing",)

# Spellings seen for the three tasks. Unknown spellings are rejected rather than bucketed into a
# default: a reading session filed as writing would be fed to the coaching model as a genuine
# typing sample, and nothing downstream could detect it.
TASK_ALIASES: dict[str, str] = {
    "reading": "reading",
    "read": "reading",
    "writing": "writing",
    "write": "writing",
    "typing": "writing",
    "map": "map",
    "map_navigation": "map",
    "mapnavigation": "map",
    "navigation": "map",
}

# Probe id for checking whether the reader exists. Never a real HMOG user id.
_PROBE_USER = "__extract_probe__"


class StaleTableError(RuntimeError):
    """The table on disk and its manifest disagree, so the table cannot be trusted.

    Raised instead of returning what is there: a truncated table still parses line by line, and
    an eval run over the first 400 of 2400 sessions would report a number that looks fine.
    """


POSTURES = ("sit", "walk", "unknown")


@dataclass(frozen=True, slots=True)
class SessionRecord:
    """One session: who, which session, which task, the 30 features, what was measured.

    Validated on construction. A record with 29 features or an unknown task would otherwise
    reach the table and only fail much later, inside a model fit, with no sign of which session
    was at fault.
    """

    user: str
    session: str
    task: str
    features: tuple[float, ...]
    blocks_present: dict[str, bool]
    # HMOG's TaskID encodes posture as well as task: each task is 4 sitting and 4 walking.
    # It has to survive into the eval, because the literature puts the EER penalty for mixing
    # postures at around 86% - a model trained sitting and tested walking learns posture, not
    # identity. Defaults to "unknown" so a table written before this field existed still loads.
    posture: str = "unknown"

    def __post_init__(self) -> None:
        if not self.user or not self.session:
            raise ValueError("a record needs both a user id and a session id")
        if self.task not in TASKS:
            raise ValueError(f"unknown task {self.task!r}; expected one of {TASKS}")
        if len(self.features) != len(FEATURES):
            raise ValueError(f"expected {len(FEATURES)} features, got {len(self.features)}")
        if self.posture not in POSTURES:
            raise ValueError(f"unknown posture {self.posture!r}; expected one of {POSTURES}")
        if set(self.blocks_present) != set(BLOCKS):
            raise ValueError(
                f"blocks_present must cover every schema block {BLOCKS}, got "
                f"{sorted(self.blocks_present)}"
            )

    @property
    def key(self) -> str:
        """Globally unique session id, used wherever sessions are compared across users.

        HMOG numbers sessions within a user, so a bare session id can repeat across users. An
        unqualified id would make the train/test disjointness assertion in the eval vacuous the
        moment impostor sessions are involved, which is exactly the check that is worth having.
        """
        return f"{self.user}/{self.session}"

    def as_dict(self) -> dict:
        return {
            "user": self.user,
            "session": self.session,
            "task": self.task,
            "features": list(self.features),
            "blocks_present": {block: bool(self.blocks_present[block]) for block in BLOCKS},
            "posture": self.posture,
        }

    @classmethod
    def from_dict(cls, raw: dict) -> SessionRecord:
        missing = {"user", "session", "task", "features", "blocks_present"} - set(raw)
        if missing:
            raise StaleTableError(f"record is missing {sorted(missing)}: {raw!r}")
        return cls(
            user=str(raw["user"]),
            session=str(raw["session"]),
            task=str(raw["task"]),
            features=tuple(float(v) for v in raw["features"]),
            # Blocks this schema declares that the row does not mention are False, not missing.
            # A version 1 table predates the per-key order block and cannot carry it, and the
            # alternative - omitting it - trips the coverage check for the wrong reason.
            blocks_present={
                **{block: False for block in BLOCKS},
                **{str(k): bool(v) for k, v in raw["blocks_present"].items()},
            },
            # Optional, so a table written before posture existed still loads - but it is the
            # field the identity split stratifies on, so losing it silently would reintroduce
            # the posture confound with no sign that anything changed.
            posture=str(raw.get("posture", "unknown")),
        )

    def measured(self, feature_name: str) -> bool:
        """Whether this feature is a measurement or the schema's `missing` substitute.

        The question a downstream reader actually has, and it cannot be answered from the value:
        every feature's declared missing value is 0.0, which is also a legal measurement.
        """
        return self.blocks_present[FEATURES[INDEX[feature_name]].block]


@dataclass(frozen=True, slots=True)
class Manifest:
    """What the table should contain, written beside it so a mismatch is detectable.

    `table_sha256` catches truncation and hand edits; `rows_per_user` and `rows_per_task` catch a
    partial extraction that happened to end on a line boundary; `schema_names` catches the one
    failure schema.py is built around - a table extracted against a different feature order,
    which produces a model that scores garbage without raising anything.
    """

    dataset: str
    source: str
    table: str
    table_sha256: str
    table_bytes: int
    rows: int
    schema_length: int
    schema_names: tuple[str, ...]
    rows_per_user: dict[str, int]
    rows_per_task: dict[str, int]
    extractor_version: int
    generated_at: str

    def as_dict(self) -> dict:
        return {
            "dataset": self.dataset,
            "source": self.source,
            "table": self.table,
            "table_sha256": self.table_sha256,
            "table_bytes": self.table_bytes,
            "rows": self.rows,
            "schema_length": self.schema_length,
            "schema_names": list(self.schema_names),
            "rows_per_user": dict(self.rows_per_user),
            "rows_per_task": dict(self.rows_per_task),
            "extractor_version": self.extractor_version,
            "generated_at": self.generated_at,
        }

    @classmethod
    def from_dict(cls, raw: dict) -> Manifest:
        expected = {
            "dataset", "source", "table", "table_sha256", "table_bytes", "rows",
            "schema_length", "schema_names", "rows_per_user", "rows_per_task",
            "extractor_version", "generated_at",
        }
        missing = expected - set(raw)
        if missing:
            raise StaleTableError(f"manifest is missing {sorted(missing)}")
        return cls(
            dataset=str(raw["dataset"]),
            source=str(raw["source"]),
            table=str(raw["table"]),
            table_sha256=str(raw["table_sha256"]),
            table_bytes=int(raw["table_bytes"]),
            rows=int(raw["rows"]),
            schema_length=int(raw["schema_length"]),
            schema_names=tuple(str(n) for n in raw["schema_names"]),
            rows_per_user={str(k): int(v) for k, v in raw["rows_per_user"].items()},
            rows_per_task={str(k): int(v) for k, v in raw["rows_per_task"].items()},
            extractor_version=int(raw["extractor_version"]),
            generated_at=str(raw["generated_at"]),
        )


def manifest_path(table: Path) -> Path:
    """Sibling manifest for a table. Suffix appended, not replaced, so `features.jsonl` and
    `features.manifest.json` can never be confused for two tables."""
    return table.with_name(table.name + ".manifest.json")


def normalise_task(raw: str) -> str:
    """One of TASKS, or an error naming what was seen."""
    task = TASK_ALIASES.get(str(raw).strip().lower().replace("-", "_").replace(" ", "_"))
    if task is None:
        raise ValueError(
            f"unknown HMOG session task {raw!r}; expected one of {TASKS} (aliases: "
            f"{sorted(TASK_ALIASES)}). Add the spelling to TASK_ALIASES rather than guessing: a "
            "reading session filed as writing becomes a genuine typing sample for the coaching "
            "model."
        )
    return task


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _counts(records: Iterable[SessionRecord]) -> tuple[dict[str, int], dict[str, int]]:
    per_user: Counter[str] = Counter()
    per_task: Counter[str] = Counter()
    for record in records:
        per_user[record.user] += 1
        per_task[record.task] += 1
    return dict(sorted(per_user.items())), {task: per_task.get(task, 0) for task in TASKS}


def write_table(
    records: Iterable[SessionRecord], out: Path, dataset: str, source: str
) -> Manifest:
    """Write the table and its manifest. Returns the manifest that was written.

    The manifest is removed before the table is rewritten: otherwise an interrupted run leaves
    last run's manifest describing this run's half-written table, which is the one combination
    `read_table` cannot distinguish from a healthy pair.
    """
    rows = list(records)
    if not rows:
        raise ValueError("nothing to write: no session records")

    seen: set[tuple[str, str]] = set()
    for record in rows:
        if (record.user, record.session) in seen:
            raise ValueError(
                f"duplicate session {record.key}: a table appended to twice would double-count "
                "sessions and could put the same session in both train and test"
            )
        seen.add((record.user, record.session))

    out.parent.mkdir(parents=True, exist_ok=True)
    manifest_file = manifest_path(out)
    manifest_file.unlink(missing_ok=True)
    out.write_text(
        "".join(json.dumps(record.as_dict(), sort_keys=True) + "\n" for record in rows),
        encoding="utf-8",
    )

    per_user, per_task = _counts(rows)
    manifest = Manifest(
        dataset=dataset,
        source=source,
        table=out.name,
        table_sha256=_sha256(out),
        table_bytes=out.stat().st_size,
        rows=len(rows),
        schema_length=len(FEATURES),
        schema_names=NAMES,
        rows_per_user=per_user,
        rows_per_task=per_task,
        extractor_version=EXTRACTOR_VERSION,
        generated_at=datetime.now(UTC).isoformat(),
    )
    manifest_file.write_text(json.dumps(manifest.as_dict(), indent=2) + "\n", encoding="utf-8")
    return manifest


def read_manifest(table: Path) -> Manifest:
    path = manifest_path(table)
    if not path.exists():
        raise StaleTableError(
            f"no manifest beside {table} (expected {path}). Without it a truncated table is "
            "indistinguishable from a complete one. Re-run bhorosha_ato.extract."
        )
    return Manifest.from_dict(json.loads(path.read_text(encoding="utf-8")))


def read_table(table: Path) -> list[SessionRecord]:
    """The whole table, verified against its manifest.

    Every check here exists because the alternative is an eval run that reports a number from
    the wrong rows: a different feature order, a truncated file, a doubled file, a manifest left
    behind by an earlier run.
    """
    if not table.exists():
        raise FileNotFoundError(
            f"no extracted feature table at {table}; run bhorosha_ato.extract first"
        )
    manifest = read_manifest(table)

    if manifest.schema_names != NAMES or manifest.schema_length != len(FEATURES):
        raise StaleTableError(
            f"{table} was extracted against a different feature order or length "
            f"({manifest.schema_length} features) than bhorosha_ato.schema now declares "
            f"({len(FEATURES)}). Positions are the wire format, so these rows would train a "
            "model on the wrong columns. Re-run bhorosha_ato.extract."
        )
    if manifest.extractor_version != EXTRACTOR_VERSION:
        raise StaleTableError(
            f"{table} was written by extractor version {manifest.extractor_version}; this is "
            f"version {EXTRACTOR_VERSION}. Re-run bhorosha_ato.extract."
        )
    actual_sha = _sha256(table)
    if actual_sha != manifest.table_sha256:
        raise StaleTableError(
            f"{table} does not match its manifest checksum (table {actual_sha[:12]}, manifest "
            f"{manifest.table_sha256[:12]}): the table was truncated, edited or written by a "
            "later run than the manifest. Re-run bhorosha_ato.extract."
        )

    records = [
        SessionRecord.from_dict(json.loads(line))
        for line in table.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    _verify_against_manifest(table, manifest, records)
    return records


def _verify_against_manifest(table: Path, manifest: Manifest, records: list[SessionRecord]) -> None:
    """The checks both loaders share: nothing silently short, doubled or re-ordered.

    Pulled out rather than duplicated, because a guard that exists in one loader and not the
    other is worse than no guard: whichever table happens to be read by the weaker path reports
    a confident number from the wrong rows.
    """
    if len(records) != manifest.rows:
        raise StaleTableError(
            f"{table} holds {len(records)} rows, manifest says {manifest.rows}. Re-run "
            "bhorosha_ato.extract."
        )
    per_user, per_task = _counts(records)
    if per_user != manifest.rows_per_user:
        raise StaleTableError(
            f"{table}: per-user row counts disagree with the manifest. Re-run "
            "bhorosha_ato.extract."
        )
    if per_task != manifest.rows_per_task:
        raise StaleTableError(
            f"{table}: per-task row counts disagree with the manifest "
            f"(table {per_task}, manifest {manifest.rows_per_task}). Re-run "
            "bhorosha_ato.extract."
        )
    duplicates = {key for key, n in Counter(r.key for r in records).items() if n > 1}
    if duplicates:
        raise StaleTableError(
            f"{table}: {len(duplicates)} session ids appear more than once, e.g. "
            f"{sorted(duplicates)[:3]}. Re-run bhorosha_ato.extract."
        )


def keyrank_values(keyhold_codes: object) -> dict[str, float]:
    """`keyhold_codes` -> the `keyrank_*` columns, ranked within this session.

    The version 3 extractor wrote per-key ranks against a key set that turned out to be wrong:
    it assumed KeyID was an Android keycode, and the ids are character codepoints, so its named
    rank columns matched almost nothing. What saved the extraction from being a wasted 6 GB pass
    was the raw `keyhold_codes` dump it carried beside them - `[[codepoint, pairs, median_ms],
    ...]` for every key pressed - so the right columns are derived here instead of re-extracted.
    Its own `keyhold_*_rank` columns are left alone: the schema does not declare them, so they
    are dropped like any other candidate, and nothing reads a value computed over the wrong set.

    Ranked quantity is the key's MEDIAN hold in that session, ascending, over the declared keys
    present in that session - so a rank is comparable only within a row, which is the point.
    Ties share a midrank, because two keys with the same median have no order to measure and
    breaking the tie by codepoint would dress a coin flip as a measurement.

    A key the session did not press gets NO entry, so `to_vector` substitutes its declared 0.0 -
    which is outside the (0, 1) range a real rank can occupy, and so stays detectable. See the
    note beside KEYRANK_KEYS in schema.py.
    """
    if not isinstance(keyhold_codes, list):
        return {}
    wanted = dict(KEYRANK_KEYS)
    medians: dict[int, float] = {}
    for entry in keyhold_codes:
        # [codepoint, pairs, median_ms]. A row of a different shape, or one whose fields are
        # not numbers, is SKIPPED rather than converted: these conversions were unguarded once,
        # and a single `["x", 1, 2.0]` anywhere in a 2398-row table raised ValueError out of
        # read_wide_table and took the whole read down. One malformed entry must cost that key,
        # not the table.
        if not isinstance(entry, (list, tuple)) or len(entry) != 3:
            continue
        try:
            code, pairs, median = int(entry[0]), float(entry[1]), float(entry[2])
        except (TypeError, ValueError):
            continue
        if code in wanted and pairs > 0:
            medians[code] = median
    if not medians:
        return {}

    order = sorted(medians, key=lambda code: (medians[code], code))
    n = len(order)
    out: dict[str, float] = {}
    index = 0
    while index < n:
        last = index
        while last + 1 < n and medians[order[last + 1]] == medians[order[index]]:
            last += 1
        # 1-based positions, so this tie group spans index+1 .. last+1 and shares their mean.
        midrank = ((index + 1) + (last + 1)) / 2.0
        for code in order[index:last + 1]:
            out[f"keyrank_{wanted[code]}"] = midrank / (n + 1.0)
        index = last + 1
    return out


def _record_from_wide_row(raw: dict, line_number: int) -> SessionRecord:
    """One row of the WIDE table -> one record against the CURRENT schema.

    The wide table stores `values` as a mapping of NAME -> float, deliberately: it was written
    while the feature set was still being chosen, and a positional row would have shifted
    silently the day one feature was added. So this is the one place where a name is translated
    into a position, and it is done by `schema.to_vector` rather than by zipping two lists.

    Names the current schema does not declare are DROPPED, not an error. The wide table carries
    80 candidate features on purpose - selecting locally against a measured EER is free, and
    re-reading a 6 GB archive is not - so most of them have no column here and were never
    expected to. Names the schema declares and the row does not carry take that feature's
    declared `missing` value from `to_vector`, which is exactly what the 39-feature contract
    says an unmeasured feature looks like.
    """
    absent = {"user", "session", "task", "values"} - set(raw)
    if absent:
        raise StaleTableError(
            f"wide row {line_number} is missing {sorted(absent)}: {raw!r}"
        )
    values = raw["values"]
    if not isinstance(values, Mapping):
        raise StaleTableError(
            f"wide row {line_number} stores `values` as {type(values).__name__}, not a mapping "
            "of feature name -> float. A positional vector here is the v1 format; use "
            "read_table for that."
        )

    # Block presence as the writer recorded it, plus the blocks that postdate the writer. The
    # wide table predates the size and tap blocks, so its map has four keys where the schema now
    # has six - and SessionRecord refuses a record that cannot account for every block.
    #
    # The two newcomers are DERIVED from whether their values are actually in the row rather
    # than assumed either way. Assuming present would report substituted zeros as measurements
    # for every session that recorded no taps; assuming absent would throw away the nine columns
    # this table does carry, which are the ones that moved the EER. A name-keyed row makes the
    # question answerable, which is the advantage of the format.
    # Only blocks this schema declares. A wide table exists to carry MORE than the schema does,
    # and extra columns are deliberately tolerated - but SessionRecord requires its block keys to
    # match BLOCKS exactly, so a writer announcing a block the schema has no column for (version
    # 3 announces `keyhold`) was fatal while its extra columns were fine. That inconsistency is
    # the bug, not the writer. Nothing is lost by dropping the key: a candidate block's presence
    # rides in its own columns - `keyhold_keys_present` is the count of keys that were measured -
    # and it gets a real block here the moment one of its columns graduates into the schema.
    present = {
        str(name): bool(flag)
        for name, flag in raw.get("blocks_present", {}).items()
        if str(name) in BLOCKS
    }
    # The ranks are derived here, not carried, so the writer's `blocks_present` cannot speak for
    # them - and version 3's own `keyhold` flag refers to its wrong-key-set columns, which this
    # schema drops. Presence is therefore whether the derivation produced anything.
    derived = keyrank_values(raw.get("keyhold_codes"))
    present["keyrank"] = bool(derived)
    for block in BLOCKS:
        if block not in present:
            present[block] = any(name in values for name in names_for(block=block))

    return SessionRecord(
        user=str(raw["user"]),
        session=str(raw["session"]),
        task=normalise_task(raw["task"]),
        features=to_vector({
            name: float(value)
            # The derived ranks win over anything of the same name in `values`, because version
            # 3's own rank columns were computed over the wrong key set.
            for name, value in {**values, **derived}.items()
            if name in INDEX
        }),
        blocks_present=present,
        posture=str(raw.get("posture", "unknown")),
    )


def read_any_table(table: Path) -> list[SessionRecord]:
    """Read either table format, choosing the reader by what the manifest says wrote it.

    Both callers that load a real table - the trainer and the eval harness - were written
    against `read_table` alone, so both were dead on the version 2 table that the only real
    extraction produced. The version is dispatched on rather than sniffed from the filename or
    discovered by catching the first reader's exception: a filename is not evidence, and a
    try/except would turn a genuinely corrupt version 1 table into a silent attempt to read it
    as version 2.

    An unknown version names what it found and what can be read, because the alternative is a
    caller guessing which extractor it needs to re-run.
    """
    readers = {EXTRACTOR_VERSION: read_table}
    readers.update(dict.fromkeys(WIDE_EXTRACTOR_VERSIONS, read_wide_table))
    version = read_manifest(table).extractor_version
    reader = readers.get(version)
    if reader is None:
        known = ", ".join(
            f"{v} ({r.__name__})" for v, r in sorted(readers.items())
        )
        raise StaleTableError(
            f"{table} was written by extractor version {version}; this build can read {known}. "
            f"Re-extract with bhorosha_ato/hmog_wide_extract.py to get version "
            f"{max(WIDE_EXTRACTOR_VERSIONS)}, which is the one the per-key hold order needs."
        )
    return reader(table)


def read_wide_table(table: Path) -> list[SessionRecord]:
    """The WIDE, name-keyed table (extractor version 2), verified against its manifest.

    Reads what `bhorosha_ato/hmog_wide_extract.py` writes - rows of
    `{"user", "session", "task_id", "task", "posture", "values": {name: float},
    "blocks_present": {...}}` - and projects each row onto the current 39-feature schema. Use
    `read_table` for the version 1 table, whose rows carry a positional `features` vector
    instead; the extractor version in the manifest decides which, and the two refuse each
    other's files rather than guessing.

    The manifest guards are the same ones `read_table` applies and are not relaxed here. A
    missing manifest or a checksum mismatch means a truncated, hand-edited or half-rewritten
    table, and such a table still parses line by line: an eval over the first 400 of 2400
    sessions reports a number that looks completely plausible.

    The one check that is deliberately NOT made is `schema_names == NAMES`. That check exists
    because version 1 rows are positional, so a different feature order silently trains a model
    on the wrong columns. These rows are keyed by name, so order cannot drift - and demanding
    equality would reject this table for carrying the 41 extra candidate features it was written
    to carry. What is checked instead is that the manifest's names overlap this schema at all,
    which catches a table from some other feature set.
    """
    if not table.exists():
        raise FileNotFoundError(
            f"no wide feature table at {table}; see bhorosha_ato/hmog_wide_extract.py"
        )
    manifest = read_manifest(table)

    if manifest.extractor_version not in WIDE_EXTRACTOR_VERSIONS:
        raise StaleTableError(
            f"{table} was written by extractor version {manifest.extractor_version}; "
            f"read_wide_table reads versions {WIDE_EXTRACTOR_VERSIONS} (name-keyed `values`). "
            f"Version {EXTRACTOR_VERSION} tables are positional - use read_table."
        )
    if manifest.schema_length != len(manifest.schema_names):
        raise StaleTableError(
            f"{table}: manifest says {manifest.schema_length} features but lists "
            f"{len(manifest.schema_names)} names. Re-run the extractor."
        )
    recognised = set(manifest.schema_names) & set(INDEX)
    if not recognised:
        raise StaleTableError(
            f"{table} carries none of the {len(FEATURES)} features bhorosha_ato.schema declares "
            f"(it lists {manifest.schema_length}, e.g. {sorted(manifest.schema_names)[:3]}). "
            "This is a table for some other feature set; every row would be substituted zeros."
        )
    actual_sha = _sha256(table)
    if actual_sha != manifest.table_sha256:
        raise StaleTableError(
            f"{table} does not match its manifest checksum (table {actual_sha[:12]}, manifest "
            f"{manifest.table_sha256[:12]}): the table was truncated, edited or written by a "
            "later run than the manifest. Re-extract it."
        )

    records = [
        _record_from_wide_row(json.loads(line), number)
        for number, line in enumerate(table.read_text(encoding="utf-8").splitlines(), start=1)
        if line.strip()
    ]
    _verify_against_manifest(table, manifest, records)
    return records


def group_by_user(
    records: Iterable[SessionRecord], tasks: Iterable[str]
) -> dict[str, list[SessionRecord]]:
    """Records of the given task types, keyed by user, each list ordered by session id.

    Ordered rather than left in file order so a split taken from it is reproducible from the
    seed alone, whatever order the extractor happened to walk the archive in.
    """
    wanted = set(tasks)
    unknown = wanted - set(TASKS)
    if unknown:
        raise ValueError(f"not HMOG tasks: {sorted(unknown)}")
    grouped: dict[str, list[SessionRecord]] = {}
    for record in records:
        if record.task in wanted:
            grouped.setdefault(record.user, []).append(record)
    return {
        user: sorted(sessions, key=lambda r: r.session)
        for user, sessions in sorted(grouped.items())
    }


def _as_session_mapping(session: object) -> dict:
    """The reader's session, as a plain mapping of field name -> value.

    `bhorosha_ato.datasets.iter_hmog_sessions` yields an `HmogSession` dataclass, while the
    tests and any hand-built session are plain dicts. Both are accepted here rather than making
    one of them wrong: the field names already agree, and the alternative was this function
    calling `.get` on a dataclass and raising deep inside an archive walk.
    """
    if isinstance(session, Mapping):
        return dict(session)
    try:
        return {f.name: getattr(session, f.name) for f in fields(session)}  # type: ignore[arg-type]
    except TypeError as exc:
        raise TypeError(
            f"a session must be a mapping or a dataclass with the reader's field names, got "
            f"{type(session).__name__}"
        ) from exc


def record_from_session(session: object) -> SessionRecord:
    """One session from the reader -> one table record.

    The only place that assumes the reader's shape, so when `iter_hmog_sessions` changes its
    field names this function changes and nothing else does. The signal keys are the argument
    names the `bhorosha_ato.features` block functions already take - `strokes` for
    `swipe_features`/`pressure_features`/`size_features`, `key_events` and `taps` for
    `pin_features`, `taps` for `tap_geometry`, `accel` and `gyro` for `imu_features` - which is
    the closest thing to a settled contract this repo has. `user`, `session` and `task` have to
    come from the reader because nothing else knows which of the 24 sessions this is.

    A signal the session does not carry is left out of `session_row` entirely rather than passed
    as an empty list: `swipe_features([])` happily returns a dict of substituted zeros, and
    handing that to `session_row(swipe=...)` would record the swipe block as present and its
    zeros as measurements.
    """
    session = _as_session_mapping(session)
    missing = {"user", "session", "task"} - set(session)
    if missing:
        raise KeyError(
            f"session dict is missing {sorted(missing)}; a record without its task type cannot "
            "be assigned to the identity or the coaching evaluation"
        )
    strokes = session.get("strokes") or []
    key_events = session.get("key_events") or []
    taps = session.get("taps") or []
    accel = session.get("accel") or []
    gyro = session.get("gyro") or []
    # The IMU statistics are windowed on the touches, so a session with motion but no strokes is
    # measured over the whole session rather than over nothing. See `features.imu_features`.
    anchors = [stroke[0]["t_ms"] for stroke in strokes if stroke]

    # Which blocks this session actually carries. HMOG's tasks differ here by design - a reading
    # session has no typing, so `pin` is absent and its eleven columns are substitutes - and this
    # map is the only record of that fact once the raw events are gone.
    #
    # Pressure rides on the same touch stream as the swipe geometry (HMOG records a pressure per
    # touch point), so there is no session with strokes but no pressure. Any new schema block
    # must be added here too; SessionRecord raises if one is unaccounted for rather than letting
    # an unrecorded block pass as measured.
    #
    # Size and tap are NOT derivable from `bool(strokes)`:
    #  - size rides on the touch samples, but Contact_size can be blank even where geometry is
    #    recorded, so presence is asked of the samples themselves. This is the block that came
    #    back silently empty once, when the samples were built without their size.
    #  - tap geometry comes from the separate OneFingerTouchEvent table, which a session can have
    #    without strokes and vice versa, and whose rows need usable coordinates to count at all.
    sized = features.has_contact_size(strokes)
    tap_points = features.tap_points(taps)
    blocks_present = {
        "swipe": bool(strokes),
        "pressure": bool(strokes),
        "pin": bool(key_events),
        "size": sized,
        "tap": bool(tap_points),
        "imu": bool(accel or gyro),
        # This path reads the archive directly and computes no per-key order: the ranks are
        # derived from the wide table's `keyhold_codes`, which only the standalone
        # extractor (hmog_wide_extract.py) writes.
        # Absent and SAYING so, rather than omitted - an omitted block is what SessionRecord's
        # coverage check exists to refuse.
        "keyrank": False,
    }
    row = features.session_row(
        swipe=features.swipe_features(strokes) if strokes else None,
        pressure=features.pressure_features(strokes) if strokes else None,
        # Taps carry the coordinates and pressure KeyPressEvent does not, so the PIN block needs
        # both tables; without them pin_tap_offset_mean_px and pin_pressure_mean are substitutes.
        pin=features.pin_features(key_events, taps=taps) if key_events else None,
        size=features.size_features(strokes) if sized else None,
        tap=features.tap_geometry(taps) if tap_points else None,
        imu=features.imu_features(accel, gyro, anchors) if (accel or gyro) else None,
    )
    return SessionRecord(
        user=str(session["user"]),
        session=str(session["session"]),
        task=normalise_task(session["task"]),
        features=row,
        blocks_present=blocks_present,
        posture=str(session.get("posture", "unknown")),
    )


def extract_hmog(data_dir: Path, user_ids: Iterable[str]) -> Iterator[SessionRecord]:
    """Walk the archive once, yielding one record per session.

    `user_ids` is a parameter rather than something discovered here because it cannot be
    discovered: `bhorosha_ato.datasets` exposes `iter_hmog_sessions(user_id, ...)` and nothing
    that enumerates the users inside the archive. The refusal message below says so.
    """
    for user_id in user_ids:
        for session in iter_hmog_sessions(user_id, data_dir):
            yield record_from_session(session)


def _reader_available(data_dir: Path) -> bool:
    """Whether `iter_hmog_sessions` is implemented yet.

    Probed rather than inspected: NotImplementedError raised by the function itself is the only
    honest signal, and probing works whether the stub stays a plain function (raises on call) or
    becomes a generator (raises on the first next()).
    """
    try:
        next(iter(iter_hmog_sessions(_PROBE_USER, data_dir)), None)
    except NotImplementedError:
        return False
    except Exception:
        # Anything else means the reader exists and is unhappy about a probe user id that does
        # not exist. That is the reader's business, not this check's.
        return True
    return True


def _stub_blocks() -> tuple[str, ...]:
    """Which schema blocks still have no extractor, probed the same way and for the same reason.

    `features.swipe_features` and `.pressure_features` are implemented; `.pin_features` and
    `.imu_features` are blocked on HMOG's column layout. A block without an extractor cannot be
    filled from the archive at all, so extracting now would write a table whose PIN and IMU
    columns are substituted zeros while every record claimed those blocks were present.
    """
    probes = {
        "swipe": features.swipe_features,
        "pressure": features.pressure_features,
        "pin": features.pin_features,
        "size": features.size_features,
        "tap": features.tap_geometry,
        "imu": features.imu_features,
    }
    stubs = []
    for block, probe in probes.items():
        try:
            probe([])
        except NotImplementedError:
            stubs.append(block)
        except Exception:
            # Implemented and unhappy about an empty input: that is the function's business.
            pass
    return tuple(stubs)


def refuse_hmog(data_dir: Path) -> str:
    """Why the archive cannot be extracted yet, and what to do about it.

    Shaped like `eval/ato_eval.py::_refuse_dataset` on purpose: the two commands are reached in
    sequence and a reader who has just seen one message should not have to learn a second format.
    Every missing piece is listed at once, because fixing one of four and re-running only to hit
    the next message wastes someone's afternoon.
    """
    archive = data_dir / HMOG_ZIP
    blockers = []
    if not hmog_present(data_dir):
        blockers.append(f"the archive is NOT present at {archive}")
    if not _reader_available(data_dir):
        blockers.append("bhorosha_ato.datasets.iter_hmog_sessions is still a stub")
    stubs = _stub_blocks()
    if stubs:
        named = " and ".join(", ".join(stubs).rsplit(", ", 1))
        blockers.append(
            f"no extractor for the {named} block{'s' if len(stubs) > 1 else ''} ("
            + ", ".join(f"bhorosha_ato.features.{block}_features" for block in stubs) + ")"
        )
    blockers.append(
        "bhorosha_ato.datasets has no way to enumerate the users in the archive, so --users has "
        "to be given explicitly"
    )
    return (
        "--dataset hmog cannot be extracted: " + "; ".join(blockers) + ".\n"
        "To unblock it: accept the Terms of Use at https://hmog-dataset.github.io/hmog/, "
        f"download {HMOG_ZIP} into {data_dir} (or pass --data-dir), check its md5 against "
        f"{HMOG_ZIP_MD5}, implement bhorosha_ato.datasets.iter_hmog_sessions and the remaining "
        "bhorosha_ato.features block functions, then re-run this command with the user ids.\n"
        "No reader is invented here: a feature table guessed from an archive layout nobody has "
        "opened would be worse than no table, because the eval would read it as measured."
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--dataset", choices=("hmog",), required=True,
                        help="hmog: the only dataset with a checksum and a reader stub in "
                             "bhorosha_ato.datasets (BB-MAS has neither)")
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR,
                        help="where the archive lives (it is not in this repo)")
    parser.add_argument("--out", type=Path, default=DEFAULT_TABLE,
                        help="JSONL table to write; a sibling .manifest.json goes beside it")
    parser.add_argument("--users", nargs="*", default=[], metavar="USER_ID",
                        help="user ids to extract; required until bhorosha_ato.datasets can "
                             "enumerate them")
    args = parser.parse_args(argv)

    # Checked before a single byte is read: the point of the refusal is to say everything that
    # is missing at once, not to fail partway through a six-gigabyte walk.
    if (not args.users or not hmog_present(args.data_dir)
            or not _reader_available(args.data_dir) or _stub_blocks()):
        raise SystemExit(refuse_hmog(args.data_dir))

    manifest = write_table(
        extract_hmog(args.data_dir, args.users),
        args.out,
        dataset=args.dataset,
        source=str(args.data_dir / HMOG_ZIP),
    )
    print(json.dumps({
        "out": str(args.out),
        "manifest": str(manifest_path(args.out)),
        "rows": manifest.rows,
        "users": len(manifest.rows_per_user),
        "rows_per_task": manifest.rows_per_task,
        "schema_length": manifest.schema_length,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
