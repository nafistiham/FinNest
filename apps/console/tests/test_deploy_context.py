"""The image carries every project package the console imports.

When api/scenarios.py started to import bhorosha_ato, scripts/deploy.sh did not vendor it, so the image died on
import while the tests, which run from the repo, stayed green. This reads the imports and the deploy script and
fails the moment they drift.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOY = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")


def _imported_project_packages() -> set[str]:
    found: set[str] = set()
    for source in (ROOT / "api").glob("*.py"):
        found |= set(re.findall(r"^\s*(?:from|import)\s+(bhorosha_[a-z_]+)", source.read_text(encoding="utf-8"), re.M))
    return found


def test_every_project_package_the_console_imports_is_vendored_by_the_deploy():
    packages = _imported_project_packages()
    assert "bhorosha_ato" in packages  # the regression this guards; drop the line if the console stops using it
    missing = sorted(p for p in packages if not re.search(rf"/{p}\b", DEPLOY))
    assert missing == [], f"scripts/deploy.sh does not vendor: {missing}"


def test_the_behaviour_models_ship_with_the_image():
    assert re.search(r'rsync -a "\$ROOT/models/ato" "\$STAGE/models/"', DEPLOY)
