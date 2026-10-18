"""The score is per app then noisy-OR, capped below BLOCK without a hard escalator."""

from bhorosha_app_safety_check import schema as s, scoring
from bhorosha_app_safety_check.schema import Hit


def _hit(signal="CLASSIFIER_HIGH", severity="medium", package="p", soft=False):
    return Hit(signal, severity, package, "e", "bn", "en", soft)


def test_soft_hits_are_one_group_that_never_reaches_caution():
    hits = tuple(_hit(severity="medium", package=f"p{i}", soft=True) for i in range(5))
    out = scoring.combine(hits)
    assert out.verdict == "SAFE" and out.risk == scoring.SOFT_GROUP_CAP and not out.hard


def test_rooted_phone_plus_many_soft_hits_is_caution_not_block():
    hits = (_hit("DEVICE_ROOTED", "high", "device"),) + tuple(_hit(severity="low", package=f"p{i}", soft=True) for i in range(6))
    assert scoring.combine(hits).verdict == "CAUTION"


def test_five_non_soft_medium_apps_are_capped_below_block():
    hits = tuple(_hit(signal="OVERLAY_CAPABLE", severity="medium", package=f"p{i}") for i in range(5))
    out = scoring.combine(hits)
    assert out.verdict == "CAUTION" and out.risk == scoring.SOFT_CAP and not out.hard


def test_one_critical_blocks_and_two_lows_stay_safe():
    assert scoring.combine((_hit(severity="critical"),)).verdict == "BLOCK"
    assert scoring.combine((_hit(severity="low", package="a"), _hit(severity="low", package="b"))).verdict == "SAFE"
    assert scoring.combine((_hit(severity="low", package="a"), _hit(severity="low", package="b"), _hit(severity="low", package="c"))).verdict == "CAUTION"


def test_strongest_hit_per_app_counts_once():
    same_app = (_hit(severity="medium"), _hit(signal="OVERLAY_CAPABLE", severity="medium"), _hit(signal="DEVICE_ADMIN", severity="medium"))
    assert scoring.combine(same_app).risk == s.SEVERITY_WEIGHT["medium"]


def test_floor_ignores_soft_hits():
    hits = (_hit(severity="high", soft=True), _hit(signal="OVERLAY_CAPABLE", severity="medium", package="q"))
    assert scoring.floor(hits).risk == s.SEVERITY_WEIGHT["medium"]
    assert scoring.combine(hits).hard is False
    assert scoring.combine(hits).risk > scoring.floor(hits).risk
