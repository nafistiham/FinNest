"""The eval scripts run the way the spec writes them (FR-7: `python eval/intervention_eval.py`), not only as `python -m eval.x`.

Run as a script, sys.path[0] is eval/, so `from app import ...` failed with ModuleNotFoundError before any metric."""

import os
import subprocess
import sys
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parent.parent
SCRIPTS = ("intervention_eval", "transcription_smoke", "apa_judge", "build_dialogues")


def test_every_eval_script_answers_help_when_run_by_its_path():
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}  # nothing outside the script may make app importable
    runs = {name: subprocess.Popen([sys.executable, f"eval/{name}.py", "--help"], cwd=SERVICE_DIR, env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE) for name in SCRIPTS}
    for name, run in runs.items():
        out, err = run.communicate(timeout=60)
        assert run.returncode == 0 and "usage" in out, f"{name}: {err[-400:]}"
