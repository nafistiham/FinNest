"""Archive enumeration, driven by a fabricated zip with the real layout.

The real archive is 6 GB and not redistributable, so these tests build a stand-in with the same
member naming. That is enough to pin the part that can silently go wrong: which members count as
users, and which are ignored.
"""

from __future__ import annotations

import zipfile

import pytest

from bhorosha_ato import datasets


@pytest.fixture
def fake_archive(tmp_path):
    """The real archive's shape: per-user zips plus a PDF and a directory entry."""
    path = tmp_path / datasets.HMOG_ZIP
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("public_dataset/", "")
        for uid in ("151985", "100669", "998757"):
            z.writestr(f"public_dataset/{uid}.zip", b"PK\x03\x04 stand-in")
        z.writestr("public_dataset/data_description.pdf", b"%PDF-1.4 stand-in")
    return tmp_path


def test_lists_user_ids_sorted(fake_archive):
    assert datasets.list_hmog_users(fake_archive) == ["100669", "151985", "998757"]


def test_ignores_the_pdf_and_the_directory_entry(fake_archive):
    """Filtering on "numeric zip" rather than on known filenames, so an extra doc file added to
    a future release does not get mistaken for a user."""
    users = datasets.list_hmog_users(fake_archive)
    assert all(u.isdigit() for u in users)
    assert "data_description" not in users


def test_does_not_decompress_anything(fake_archive):
    """The members here are not valid zips. If enumeration tried to open them it would raise,
    so this passing proves only the central directory is read - which is what keeps it fast on
    a 6 GB archive."""
    assert len(datasets.list_hmog_users(fake_archive)) == 3


def test_missing_archive_says_how_to_get_it(tmp_path):
    with pytest.raises(FileNotFoundError, match="Terms of Use"):
        datasets.list_hmog_users(tmp_path)


def test_hmog_present_tracks_the_archive(tmp_path, fake_archive):
    assert datasets.hmog_present(fake_archive) is True
    assert datasets.hmog_present(tmp_path / "nowhere") is False


# --- the session reader ----------------------------------------------------

def _touch_csv(rows: list[tuple[int, float, float, float]]) -> str:
    """rows are (ActionID, EventTime, X, Y). Headerless, like the real files."""
    return "\n".join(
        f"1700000000,{t},100669091000001,1,0,{action},{x},{y},0.5,0.1,0"
        for action, t, x, y in rows
    ) + "\n"


def _activity_csv(task_id: int) -> str:
    """Headerless, and TaskID in its real position (9th of 10)."""
    return f"x,100669,1,0,1,0,1,{1 if task_id % 2 else 2},{task_id},1\n"


def _nested_archive(tmp_path, sessions: dict[int, int], touch: str | None = None):
    """sessions maps session_number -> TaskID, mirroring the real nesting."""
    inner = tmp_path / "inner.zip"
    with zipfile.ZipFile(inner, "w") as z:
        for number, task_id in sessions.items():
            base = f"100669/100669_session_{number}/"
            z.writestr(base, "")
            z.writestr(base + "Activity.csv", _activity_csv(task_id))
            z.writestr(base + "TouchEvent.csv", touch if touch is not None else "")
            z.writestr(base + "KeyPressEvent.csv", "")
            z.writestr(base + "Accelerometer.csv", "")
            z.writestr(base + "Gyroscope.csv", "")
    archive = tmp_path / datasets.HMOG_ZIP
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("public_dataset/100669.zip", inner.read_bytes())
    return tmp_path


def test_task_and_posture_come_from_the_activity_table(tmp_path):
    """Not from the session number: the number alone does not say which task was performed."""
    root = _nested_archive(tmp_path, {1: 1, 2: 4, 3: 23})
    got = {s.session: (s.task, s.posture) for s in datasets.iter_hmog_sessions("100669", root)}
    assert got["100669_session_1"] == ("reading", "sit")
    assert got["100669_session_2"] == ("writing", "walk")
    assert got["100669_session_3"] == ("map", "sit")


def test_sessions_come_back_in_numeric_order(tmp_path):
    """Lexicographic order would put session_10 before session_2 and scramble any split that
    assumes the first N sessions are the earliest."""
    root = _nested_archive(tmp_path, {1: 1, 2: 1, 10: 1, 11: 1})
    numbers = [int(s.session.rsplit("_", 1)[1]) for s in datasets.iter_hmog_sessions("100669", root)]
    assert numbers == [1, 2, 10, 11]


def test_a_session_with_no_resolvable_task_is_skipped(tmp_path):
    """Guessing would put a typing session into the identity split and corrupt the EER."""
    root = _nested_archive(tmp_path, {1: 1, 2: 99})
    assert [s.task_id for s in datasets.iter_hmog_sessions("100669", root)] == [1]


def test_strokes_are_grouped_between_down_and_up(tmp_path):
    root = _nested_archive(tmp_path, {1: 1}, touch=_touch_csv([
        (0, 100.0, 10.0, 20.0),   # down
        (2, 120.0, 15.0, 25.0),   # move
        (1, 140.0, 20.0, 30.0),   # up
        (0, 300.0, 50.0, 60.0),   # a second stroke
        (2, 320.0, 55.0, 65.0),
        (1, 340.0, 60.0, 70.0),
    ]))
    session = next(datasets.iter_hmog_sessions("100669", root))
    assert len(session.strokes) == 2
    assert [len(s) for s in session.strokes] == [3, 3]
    assert session.strokes[0][0]["t_ms"] == 100.0
    assert session.strokes[0][0]["pressure"] == 0.5


def test_second_pointer_action_codes_are_not_dropped(tmp_path):
    """DOWN is 0 or 5 and UP is 1 or 6 - Android reports later pointers with the second code.
    Treating only 0 and 1 as down and up silently discards those strokes."""
    root = _nested_archive(tmp_path, {1: 1}, touch=_touch_csv([
        (5, 100.0, 10.0, 20.0),
        (2, 120.0, 15.0, 25.0),
        (6, 140.0, 20.0, 30.0),
    ]))
    session = next(datasets.iter_hmog_sessions("100669", root))
    assert len(session.strokes) == 1


def test_an_unterminated_stroke_is_still_kept(tmp_path):
    """A session can end mid-gesture; the samples before it are real."""
    root = _nested_archive(tmp_path, {1: 1}, touch=_touch_csv([
        (0, 100.0, 10.0, 20.0), (2, 120.0, 15.0, 25.0),
    ]))
    assert len(next(datasets.iter_hmog_sessions("100669", root)).strokes) == 1


def test_empty_keypress_file_is_normal_not_an_error(tmp_path):
    """KeyPressEvent.csv is 0 bytes in every reading session - there is no typing to record."""
    root = _nested_archive(tmp_path, {1: 1})
    assert next(datasets.iter_hmog_sessions("100669", root)).key_events == []


def test_session_key_is_namespaced_by_user(tmp_path):
    root = _nested_archive(tmp_path, {1: 1})
    assert next(datasets.iter_hmog_sessions("100669", root)).key == "100669/100669_session_1"


def test_unknown_user_points_at_the_enumerator(tmp_path):
    root = _nested_archive(tmp_path, {1: 1})
    with pytest.raises(KeyError, match="list_hmog_users"):
        next(datasets.iter_hmog_sessions("999999", root))


def test_crlf_line_endings_parse():
    """The archive's CSVs use CRLF. StringIO does no newline translation by default, so csv
    reads the carriage return as part of the last field and raises. This failed only on the
    real archive, because the fixtures above are LF - hence a test with explicit CRLF.
    """
    blob = b"1396395534261,2739159,100669091000001,1,0,0,1060.0,1188.0,1.0,0.0215,0\r\n" * 3
    rows = datasets._rows(blob, datasets.TOUCH_FILE)
    assert len(rows) == 3
    assert rows[0]["Phone_orientation"] == "0"      # not "0\r"
    assert float(rows[0]["X"]) == 1060.0


def test_bare_cr_line_endings_parse():
    """Belt and braces: csv with newline="" handles CR, LF and CRLF alike."""
    blob = b"1396395534261,2739159,100669091000001,1,0,0,1060.0,1188.0,1.0,0.0215,0\r" * 2
    assert len(datasets._rows(blob, datasets.TOUCH_FILE)) == 2
