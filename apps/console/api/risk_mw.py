"""The single place that reaches into risk-mw.

risk-mw is a separate Python root with its own `app` package. We import its rule engine
rather than reimplementing it: two implementations of the same rules always diverge, and a console
that disagrees with the service is worse than no console at all.

Keeping every cross-root import here means a rename costs one line in this file rather than twenty
across the package.

Two layouts are supported. In the repo, risk-mw sits at services/risk-mw. In a container,
scripts/deploy.sh copies that package to vendor/app and the graph bundle to vendor/, so the same
imports resolve with vendor/ on the path. The repo layout wins when both are present.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]                      # apps/console/api -> the repo root
SERVICE = REPO / "services" / "risk-mw"
SYNTH = REPO / "libs" / "synth"             # bhorosha_graph, bhorosha_synth
VENDOR = HERE.parent / "vendor"             # the container layout
SEED_DIR = REPO / "data" / "seed"
MULE_ARTEFACTS = REPO / "models" / "mule"
ATO_ARTEFACTS = REPO / "models" / "ato"
ATO_PACKAGE = REPO / "libs" / "ato"         # bhorosha_ato, which the behaviour model needs


def _roots() -> tuple[Path, ...]:
    if (SERVICE / "app").is_dir():
        return (SERVICE, SYNTH, ATO_PACKAGE)
    return (VENDOR,)


for _root in _roots():
    if _root.is_dir() and str(_root) not in sys.path:
        sys.path.insert(0, str(_root))

# The mule scorer reads its artefacts from an env var. Set it here, before app.settings is imported
# and caches itself, so that nothing downstream has to remember to.
os.environ.setdefault("RISK_MW_MULE_ARTEFACTS_DIR", str(MULE_ARTEFACTS))
# The behaviour model reads its own. Without them it answers "off" to everything, which is honest:
# the per-user behaviour models are not part of the public repo, so "off" is the expected answer here.
if ATO_ARTEFACTS.is_dir():
    os.environ.setdefault("RISK_MW_ATO_ARTEFACTS_DIR", str(ATO_ARTEFACTS))

from app import genai_client, mule  # noqa: E402
from app.clock import scenario_now  # noqa: E402
from app.contracts import DemoFlags, ScoreRequest, Txn  # noqa: E402
from app.rules import decide, evaluate  # noqa: E402
from app.settings import get_settings  # noqa: E402

__all__ = [
    "DemoFlags", "ScoreRequest", "Txn", "decide", "evaluate", "genai_client", "get_settings", "mule", "scenario_now",
    "REPO", "SERVICE", "SEED_DIR", "MULE_ARTEFACTS", "ATO_ARTEFACTS",
]
