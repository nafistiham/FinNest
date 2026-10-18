"""Case Zero: an investigator agent over the FinNest synthetic world.

The `bhorosha_graph` and `bhorosha_synth` packages live in libs/synth and are imported
unchanged. This module puts them on the path, both in the repository and in the container.

PROJECT_DIR is the repository root (CASE_ZERO_PROJECT_DIR overrides it). The world files are
read from PROJECT_DIR/models/mule and PROJECT_DIR/data/seed.
"""

import os
import sys
from pathlib import Path

PROJECT_DIR = Path(os.environ.get("CASE_ZERO_PROJECT_DIR", Path(__file__).resolve().parents[3]))
_SYNTH = str(PROJECT_DIR / "libs" / "synth")
if _SYNTH not in sys.path:
    sys.path.insert(0, _SYNTH)
