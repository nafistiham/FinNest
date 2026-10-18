import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SERVICE_DIR.parent.parent
sys.path.insert(0, str(SERVICE_DIR))
sys.path.insert(0, str(PROJECT_DIR / "libs" / "synth"))


@pytest.fixture(scope="session")
def world():
    from case_zero.world import World

    return World.load(PROJECT_DIR)


@pytest.fixture(scope="session")
def dev(tmp_path_factory):
    """The seed-7 tuning world (thresholds are chosen here, never on seed 42)."""
    from case_zero.world import World
    from eval.dev_world import build_dev_world

    return World.load(build_dev_world(7, tmp_path_factory.mktemp("dev")))


@pytest.fixture(scope="session")
def dev_rings(dev):
    from eval.seeds import ring_seeds

    return {r["ring_id"]: r for r in ring_seeds(dev)}
