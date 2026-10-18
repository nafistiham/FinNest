"""Dataset readers.

Datasets live outside the repo: HMOG is not redistributable, and both are large.
The directory that holds them is $FINNEST_ATO_DATA_DIR, or ~/finnest-data when that is unset.
"""

from __future__ import annotations

import csv
import io
import os
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Literal

DEFAULT_DATA_DIR = Path(
    os.environ.get("FINNEST_ATO_DATA_DIR") or Path.home() / "finnest-data"
).expanduser()

HMOG_ZIP = "hmog_dataset.zip"
HMOG_ZIP_MD5 = "4fd46756abec13815f426c66a58e626f"

# The archive nests one zip per user inside a single directory, named by numeric user id:
#
#   hmog_dataset.zip
#   └── public_dataset/
#       ├── 100669.zip        one user, 27-119 MB
#       ├── 151985.zip
#       ├── ...               100 users
#       └── data_description.pdf
#
# Verified against the real archive (6,132,356,276 bytes, md5 4fd46756...). One zip per user is
# why nothing here ever needs to hold more than one user in memory, and why extraction can be
# parallelised per user if it ever needs to be.
HMOG_MEMBER_DIR = "public_dataset"
HMOG_USER_MEMBER = re.compile(r"^public_dataset/(\d+)\.zip$")
HMOG_SESSION_DIR = re.compile(r"^\d+/(\d+)_session_(\d+)/$")

Task = Literal["reading", "writing", "map"]
Posture = Literal["sit", "walk"]

# From data_description.pdf, Activity.csv. TaskID encodes BOTH the task and the posture:
#
#   1, 7, 13, 19  Reading + Sitting      2, 8, 14, 20  Reading + Walking
#   3, 9, 15, 21  Writing + Sitting      4, 10, 16, 22 Writing + Walking
#   5, 11, 17, 23 Map + Sitting          6, 12, 18, 24 Map + Walking
#
# Posture is not a detail to average over. The keystroke-dynamics literature reports EER rising
# by around 86% across hand postures, so a model trained on sitting sessions and tested on
# walking ones learns posture rather than identity. Both are surfaced so the eval can hold
# posture fixed instead of discovering this as noise.
TASK_BY_ID: dict[int, Task] = {
    i: ("reading", "writing", "map")[((i - 1) // 2) % 3] for i in range(1, 25)
}
POSTURE_BY_ID: dict[int, Posture] = {i: ("sit" if i % 2 else "walk") for i in range(1, 25)}

# Files inside one session directory, as documented in data_description.pdf.
TOUCH_FILE = "TouchEvent.csv"
KEYPRESS_FILE = "KeyPressEvent.csv"
ONEFINGER_FILE = "OneFingerTouchEvent.csv"
ACCEL_FILE = "Accelerometer.csv"
GYRO_FILE = "Gyroscope.csv"
ACTIVITY_FILE = "Activity.csv"

# The CSVs carry NO HEADER ROW - every file starts at data - so columns are read by position.
# Verified against real rows from user 100669, session 9.
#
# KeyPressEvent's real order is NOT the order data_description.pdf prints: the doc lists
# PressType before ActivityID, but the third field is plainly an ActivityID
# (100669091000001 = subject 100669, session 09, content 1, counter 000001). Positions here
# follow the file, not the document.
COLUMNS: dict[str, tuple[str, ...]] = {
    ACTIVITY_FILE: ("ID", "SubjectID", "Session_number", "Start_time", "End_time",
                    "Relative_Start_time", "Relative_End_time", "Gesture_scenario",
                    "TaskID", "ContentID"),
    TOUCH_FILE: ("Systime", "EventTime", "ActivityID", "Pointer_count", "PointerID",
                 "ActionID", "X", "Y", "Pressure", "Contact_size", "Phone_orientation"),
    KEYPRESS_FILE: ("Systime", "PressTime", "ActivityID", "PressType", "KeyID",
                    "Phone_orientation"),
    ONEFINGER_FILE: ("Systime", "PressTime", "ActivityID", "TapID", "Tap_type",
                     "Action_type", "X", "Y", "Pressure", "Contact_size",
                     "Phone_orientation"),
    ACCEL_FILE: ("Systime", "EventTime", "ActivityID", "X", "Y", "Z", "Phone_orientation"),
    GYRO_FILE: ("Systime", "EventTime", "ActivityID", "X", "Y", "Z", "Phone_orientation"),
}

# Relative timestamps are NOT in one unit across files, and the documentation does not say so.
# Measured on the same instant in session 9: TouchEvent.EventTime 2739159 and
# KeyPressEvent.PressTime 2754182 are milliseconds since boot (about 45.6 minutes), while
# Accelerometer.EventTime 2731401331000 is nanoseconds for the same 45.5 minutes. They are a
# factor of a million apart. Normalising everything to milliseconds here means no feature
# function has to know which file its numbers came from - and an IMU window computed in the
# wrong unit would silently be either empty or the entire session.
TIME_DIVISOR_TO_MS: dict[str, float] = {
    TOUCH_FILE: 1.0,
    KEYPRESS_FILE: 1.0,
    ONEFINGER_FILE: 1.0,
    ACCEL_FILE: 1_000_000.0,
    GYRO_FILE: 1_000_000.0,
}

# KeyPressEvent.KeyID is -1 when the touch was not a key at all - per the docs, the suggestion
# strip or the text area. Those are not keystrokes and must not become hold or flight times.
NON_KEY_ID = -1

# Android KEYCODE_DEL. A correction is behavioural evidence, which is why the schema has a
# backspace count at all.
KEYCODE_DEL = 67

# TouchEvent.ActionID. DOWN and UP each have two codes - 0/5 and 1/6 - because Android reports
# the first pointer and subsequent pointers differently. Treating only 0 and 1 as down and up
# would silently drop every stroke that began as a second pointer.
ACTION_DOWN = frozenset({0, 5})
ACTION_UP = frozenset({1, 6})
ACTION_MOVE = frozenset({2})


@dataclass(slots=True)
class HmogSession:
    """One session of one user, with its raw event tables already parsed.

    `task` and `posture` come from Activity.csv's TaskID rather than from the session number,
    because the session number alone does not say which task was performed.
    """

    user: str
    session: str
    task_id: int
    task: Task
    posture: Posture
    strokes: list[list[dict]] = field(default_factory=list)
    key_events: list[dict] = field(default_factory=list)
    taps: list[dict] = field(default_factory=list)
    accel: list[dict] = field(default_factory=list)
    gyro: list[dict] = field(default_factory=list)

    @property
    def key(self) -> str:
        """user/session, because HMOG numbers sessions within a user."""
        return f"{self.user}/{self.session}"


def _rows(blob: bytes, filename: str) -> list[dict]:
    """Parse one headerless CSV member into dicts keyed by the documented column names.

    Empty members are normal: KeyPressEvent.csv is 0 bytes in every reading session, because
    there is no typing to record. Rows with the wrong field count are dropped rather than
    zip-truncated into plausible nonsense.
    """
    if not blob.strip():
        return []
    # newline="" is required, not cosmetic: the archive's CSVs use CRLF, and StringIO does no
    # newline translation by default, so csv sees the carriage return as part of the last field
    # and raises "new-line character seen in unquoted field". Passing newline="" hands line
    # splitting to csv itself, which handles CR, LF and CRLF alike.
    names = COLUMNS[filename]
    divisor = TIME_DIVISOR_TO_MS.get(filename, 1.0)
    out: list[dict] = []
    for fields in csv.reader(io.StringIO(blob.decode("utf-8", errors="replace"), newline="")):
        if len(fields) != len(names):
            continue
        row = dict(zip(names, fields, strict=True))
        if divisor != 1.0:
            for key in ("EventTime", "PressTime"):
                raw = row.get(key)
                if raw:
                    try:
                        row[key] = str(float(raw) / divisor)
                    except ValueError:
                        pass
        out.append(row)
    return out


def _float(row: dict, *names: str) -> float | None:
    """First parseable value among `names`, or None. Column spelling varies between releases
    (the docs themselves print "Gyroscrope"), so callers pass the alternatives they accept."""
    for name in names:
        raw = row.get(name)
        if raw not in (None, ""):
            try:
                return float(raw)
            except ValueError:
                continue
    return None


def _strokes_from_touch(rows: list[dict]) -> list[list[dict]]:
    """Group TouchEvent rows into strokes: the samples between a DOWN and its matching UP.

    Yields the sample shape `features.swipe_features` already expects, so the extractor and the
    runtime path share one definition of a stroke.
    """
    strokes: list[list[dict]] = []
    current: list[dict] = []
    for row in rows:
        action = _float(row, "ActionID")
        t = _float(row, "EventTime", "Systime")
        x, y = _float(row, "X"), _float(row, "Y")
        if action is None or t is None or x is None or y is None:
            continue
        sample = {
            "x": x,
            "y": y,
            "t_ms": t,
            "pressure": _float(row, "Pressure"),
            "size": _float(row, "Contact_size"),
        }
        code = int(action)
        if code in ACTION_DOWN:
            if len(current) > 1:
                strokes.append(current)
            current = [sample]
        elif code in ACTION_MOVE:
            if current:
                current.append(sample)
        elif code in ACTION_UP:
            if current:
                current.append(sample)
                strokes.append(current)
                current = []
    if len(current) > 1:
        strokes.append(current)
    return strokes


def iter_hmog_sessions(user_id: str, data_dir: Path = DEFAULT_DATA_DIR) -> Iterator[HmogSession]:
    """Yield one HMOG session at a time for a user: touch, keystroke latency and IMU.

    One user per inner zip, 24 session directories inside it, each holding the event tables
    documented in data_description.pdf. Only the requested user's zip is read into memory
    (27-119 MB), so peak usage does not scale with the archive.

    Access: Terms of Use must be accepted before the Box download is available. Non-commercial
    research and education only; no redistribution without the College of William & Mary's
    written approval; no attempt to de-anonymise. Cite Sitova et al., IEEE TIFS 11(5) 2016,
    DOI 10.1109/TIFS.2015.2506542. Not vendored here, and must not be committed.
    """
    archive = data_dir / HMOG_ZIP
    if not archive.exists():
        raise FileNotFoundError(f"{archive} not found; see list_hmog_users for the access steps.")

    member = f"{HMOG_MEMBER_DIR}/{user_id}.zip"
    with zipfile.ZipFile(archive) as outer:
        if member not in outer.namelist():
            raise KeyError(f"user {user_id!r} not in {archive.name}; try list_hmog_users()")
        blob = outer.read(member)

    with zipfile.ZipFile(io.BytesIO(blob)) as inner:
        names = inner.namelist()
        session_dirs = sorted(
            (m.group(0) for name in names if (m := HMOG_SESSION_DIR.match(name))),
            key=lambda d: int(d.rstrip("/").rsplit("_", 1)[1]),
        )
        for directory in session_dirs:
            session = directory.rstrip("/").rsplit("/", 1)[-1]

            def read(filename: str) -> list[dict]:
                try:
                    return _rows(inner.read(directory + filename), filename)
                except KeyError:
                    return []

            activity = read(ACTIVITY_FILE)
            task_id = next(
                (int(v) for row in activity if (v := _float(row, "TaskID")) is not None), None
            )
            if task_id is None or task_id not in TASK_BY_ID:
                # A session whose task cannot be established is skipped rather than guessed:
                # assigning it to the wrong task would put typing sessions into the identity
                # split and quietly corrupt the EER.
                continue

            yield HmogSession(
                user=user_id,
                session=session,
                task_id=task_id,
                task=TASK_BY_ID[task_id],
                posture=POSTURE_BY_ID[task_id],
                strokes=_strokes_from_touch(read(TOUCH_FILE)),
                key_events=read(KEYPRESS_FILE),
                taps=read(ONEFINGER_FILE),
                accel=read(ACCEL_FILE),
                gyro=read(GYRO_FILE),
            )


def list_hmog_users(data_dir: Path = DEFAULT_DATA_DIR) -> list[str]:
    """Every user id in the archive, sorted, so a caller never has to be told them.

    Reads only the outer zip's central directory - no member is decompressed, so this is fast
    and cheap even on a 6 GB archive. Ignores anything that is not a numeric per-user zip, which
    skips `data_description.pdf` and the directory entry without special-casing them by name.
    """
    archive = data_dir / HMOG_ZIP
    if not archive.exists():
        raise FileNotFoundError(
            f"{archive} not found. Accept the Terms of Use at "
            "https://hmog-dataset.github.io/hmog/, download hmog_dataset.zip, and verify its md5 "
            f"against {HMOG_ZIP_MD5}."
        )
    with zipfile.ZipFile(archive) as outer:
        users = [m.group(1) for name in outer.namelist()
                 if (m := HMOG_USER_MEMBER.match(name))]
    return sorted(users)


def hmog_present(data_dir: Path = DEFAULT_DATA_DIR) -> bool:
    """Whether the archive has been placed yet, so callers can fail with a useful message."""
    return (data_dir / HMOG_ZIP).exists()
