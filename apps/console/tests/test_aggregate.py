"""What the aggregate must never get wrong.

These are not tests of the rule engine - risk-mw has 111 of those. They test the three promises the
console makes on every screen: the totals add up, every rate carries its denominator, and every
section says what stands behind it. Each one of those is easy to break with a one-line edit and
impossible to notice by eye on a rendered page.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
import sys  # noqa: E402

sys.path.insert(0, str(ROOT))

from api import aggregate  # noqa: E402
from api.risk_mw import SEED_DIR  # noqa: E402


@pytest.fixture(scope="module")
def world() -> dict:
    return aggregate.load_world(SEED_DIR)


@pytest.fixture(scope="module")
def replay(world: dict) -> dict:
    return aggregate.replay(world)


@pytest.fixture(scope="module")
def overview() -> dict:
    """The committed fixture, so the whole-object tests cost nothing to run."""
    return json.loads((ROOT / "fixtures" / "overview.json").read_text())


# --- the totals add up ------------------------------------------------------

def test_decisions_and_bands_sum_to_the_denominator(replay: dict) -> None:
    assert sum(replay["mix"].values()) == replay["denominator"]
    assert sum(replay["bands"].values()) == replay["denominator"]
    assert sum(replay["histogram"]) == replay["denominator"]
    assert sum(replay["confusion"].values()) == replay["denominator"]


def test_ground_truth_comes_from_the_labels_not_the_engine(world: dict, replay: dict) -> None:
    """The fraud denominator must equal the seed's own labelling, counted independently."""
    fraudulent = sum(1 for r in world["transactions"]
                     if r["type"] == "send_money" and r["ring_id"] is not None)
    assert replay["confusion"]["catch"] + replay["confusion"]["miss"] == fraudulent
    assert replay["rates"]["catch_rate_denominator"] == fraudulent


def test_stopped_counts_agree_between_mix_and_confusion(replay: dict) -> None:
    stopped = replay["mix"]["hold"] + replay["mix"]["block"]
    assert replay["confusion"]["catch"] + replay["confusion"]["false_positive"] == stopped
    assert replay["rates"]["stopped"] == stopped


# --- every rate carries its denominator -------------------------------------

def _walk(node, path=""):
    if isinstance(node, dict):
        yield path, node
        for key, value in node.items():
            yield from _walk(value, f"{path}.{key}" if path else key)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from _walk(value, f"{path}[{i}]")


def test_every_rate_has_a_denominator(overview: dict) -> None:
    missing = []
    for path, node in _walk(overview):
        if not isinstance(node, dict):
            continue
        for key in node:
            if key.endswith("_rate") and f"{key}_denominator" not in node:
                missing.append(f"{path}.{key}")
    assert not missing, f"rates without a denominator: {missing}"


def test_catch_rate_and_false_positive_rate_ship_together(overview: dict) -> None:
    """One function emits both, so a screen cannot show the flattering half on its own."""
    rates = overview["replay"]["rates"]
    assert ("catch_rate" in rates) == ("false_positive_rate" in rates)
    assert rates["catch_rate"] is not None and rates["false_positive_rate"] is not None


# --- every section says what stands behind it -------------------------------

BADGES = {"MODEL", "RULE", "STUB", "OFF", "NONE", "NO DATA", "SYNTHETIC"}
BADGED_SECTIONS = ("world", "replay", "mule_board_meta")


def test_top_level_sections_carry_a_badge(overview: dict) -> None:
    for section in BADGED_SECTIONS:
        assert overview[section]["badge"] in BADGES, section


def test_every_gate_model_and_target_carries_a_badge(overview: dict) -> None:
    for collection in ("gates", "targets", "models"):
        for row in overview[collection]:
            assert row.get("badge") in BADGES, f"{collection}: {row.get('id')}"


def test_unmeasured_gates_say_nothing_rather_than_zero(overview: dict) -> None:
    """A gate with no measurement reports None. A zero would read as 'this gate caught nothing'."""
    for gate in overview["gates"]:
        if gate["badge"] == "NONE":
            assert gate["volume"] is None and gate["caught"] is None, gate["id"]


# --- the honesty properties -------------------------------------------------

def test_the_seed_can_only_fire_the_two_ledger_codes(overview: dict) -> None:
    """Which codes cannot fire is computed; what matters is that the list is complete.

    It was not. MODEL_RISK and MONEY_LOCK_ACTIVE are emitted by the rule engine and
    ATO_BEHAVIOUR_MISMATCH_COLD_START by the behaviour adapter, and all three were missing from
    ALL_CODES - so they appeared in neither column and the console quietly understated how much of
    the defence the seed world cannot exercise.
    """
    replay = overview["replay"]
    assert set(replay["codes"]) == {"NEW_PAYEE_ABOVE_P95", "DEST_MULE_RISK"}
    assert len(replay["codes_that_cannot_fire"]) == len(aggregate.ALL_CODES) - 2
    for code in ("MODEL_RISK", "MONEY_LOCK_ACTIVE", "ATO_BEHAVIOUR_MISMATCH_COLD_START"):
        assert code in replay["codes_that_cannot_fire"], code
    assert replay["codes_that_cannot_fire_reason"]


def test_no_payment_model_reached_block(overview: dict) -> None:
    """The defence-in-depth plan, section 5. If this ever fails, a model took an analyst's decision."""
    check = next(p for p in overview["policy"] if p["id"] == "no_model_block")
    assert check["ok"], check["evidence"]
    assert overview["replay"]["mix"]["block"] == 0


def test_the_analyst_half_of_the_policy_is_reported_as_failing(overview: dict) -> None:
    """The plan's sentence is two claims and they do not have the same answer.

    Checked together, `block = 0` in the replay carried the other half, while the engine's only
    path to block declines on a device verdict with no analyst and no payee in it at all.
    """
    check = next(p for p in overview["policy"] if p["id"] == "decline_needs_an_analyst")
    assert check["ok"] is False
    assert "APP_SAFETY_BLOCK" in check["evidence"]


def test_the_synthetic_flag_is_set(overview: dict) -> None:
    assert overview["source"]["synthetic"] is True


def test_the_weakest_link_is_named(overview: dict) -> None:
    weakest = overview["weakest_link"]
    assert weakest["typology"] and weakest["ring_recall"] is not None
    assert weakest["gates_not_built"] and weakest["stubs"]
