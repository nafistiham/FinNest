"""The committed fixture must be what the code produces today.

The console, the API and the proposal all read fixtures/overview.json. If it drifts from the
aggregate, every one of them ships yesterday's numbers quietly. This is the test that makes that
loud instead. It recomputes, so it costs a few seconds.

The model-health rows and the weakest-link sentence are read from eval result files, which are not
committed (run eval/run.py to make them). When any is absent, those two sections are left out of
the comparison and everything built from the seed world is still checked.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import aggregate  # noqa: E402
from api.risk_mw import REPO  # noqa: E402
from tools.build_overview import FIXTURE, VOLATILE, main  # noqa: E402

EVAL_SECTIONS = ("models", "weakest_link")


def _eval_results_present() -> bool:
    return all((REPO / path).exists() for _id, path, _badge in aggregate.EVAL_FILES)


def test_fixture_matches_a_fresh_build() -> None:
    if _eval_results_present():
        assert main(["--check"]) == 0, "fixtures/overview.json is stale; run tools/build_overview.py"
        return
    world = aggregate.load_world()
    replayed = aggregate.replay(world)
    replayed.pop("payee_rollup")
    fresh = aggregate.build(world=world, replayed=replayed)
    committed = json.loads(FIXTURE.read_text())
    skip = set(VOLATILE) | set(EVAL_SECTIONS)
    assert {k: v for k, v in committed.items() if k not in skip} == {k: v for k, v in fresh.items() if k not in skip}, \
        "fixtures/overview.json is stale; run tools/build_overview.py"
