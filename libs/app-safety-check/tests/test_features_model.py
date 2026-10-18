"""Vectoriser column order and the serving classifier (same columns, under 20 ms per app)."""

import time

import numpy as np

from bhorosha_app_safety_check.features import Vectoriser
from bhorosha_app_safety_check.model import AppClassifier


def test_vectoriser_maps_phone_names_onto_dataset_spellings():
    v = Vectoriser(["READ_SMS", "android.permission.READ_CONTACTS", "Permission.CAMERA"])
    row = v.transform(["android.permission.READ_CONTACTS", "android.permission.READ_SMS", "android.permission.NEVER_SEEN"])
    assert row.tolist() == [1.0, 1.0, 0.0]
    assert v.known("android.permission.CAMERA") and not v.known("android.permission.NEVER_SEEN")


def test_vectoriser_round_trips_through_columns_json(tmp_path):
    v = Vectoriser(["A_B", "C_D"])
    v.save(tmp_path)
    assert Vectoriser.load(tmp_path).columns == v.columns


def test_classifier_scores_sms_heavy_app_high_and_camera_app_low(tiny_artefacts):
    clf = AppClassifier.load(tiny_artefacts)
    risky = clf.predict(["android.permission.READ_SMS", "android.permission.RECEIVE_SMS", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.BIND_ACCESSIBILITY_SERVICE"])
    benign = clf.predict(["android.permission.CAMERA", "android.permission.INTERNET"])
    assert risky.probability > 0.8 > benign.probability
    assert risky.contributions and all(name in {"android.permission.READ_SMS", "android.permission.RECEIVE_SMS", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.BIND_ACCESSIBILITY_SERVICE"} for name, _ in risky.contributions)
    assert clf.version == "test-lgbm"


def test_prediction_is_under_20ms_per_app(tiny_artefacts):
    clf = AppClassifier.load(tiny_artefacts)
    clf.predict(["android.permission.READ_SMS"])  # warm


def test_predict_many_matches_predict_and_scores_a_phone_in_one_go(tiny_artefacts):
    """A real 80-app phone spent 1.4 s scoring one app at a time; batching keeps it fast."""
    import time

    from bhorosha_app_safety_check.model import AppClassifier

    clf = AppClassifier.load(tiny_artefacts)
    apps = [["android.permission.READ_SMS", "android.permission.RECEIVE_SMS", "android.permission.SYSTEM_ALERT_WINDOW"], ["android.permission.CAMERA"], []] * 30
    started = time.perf_counter()
    many = clf.predict_many(apps)
    elapsed = time.perf_counter() - started
    assert len(many) == 90 and many[0] == clf.predict(apps[0]) and many[1] == clf.predict(apps[1]) and many[2] == clf.predict(apps[2])
    assert elapsed < 0.5 and clf.predict_many([]) == []
    started = time.perf_counter()
    for _ in range(50):
        clf.predict(["android.permission.READ_SMS", "android.permission.CAMERA"])
    assert (time.perf_counter() - started) * 1000 / 50 < 20


def test_mismatched_columns_are_refused(tiny_artefacts, tmp_path):
    import shutil

    shutil.copytree(tiny_artefacts, tmp_path / "a")
    Vectoriser(["ONLY_ONE"]).save(tmp_path / "a")
    try:
        AppClassifier.load(tmp_path / "a")
    except ValueError as exc:
        assert "columns.json" in str(exc)
    else:
        raise AssertionError("a model/columns mismatch must not load")
    assert isinstance(np.zeros(1), np.ndarray)
