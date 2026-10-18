"""Regression checks on the real incident component's asynchronous request handling."""
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('scenario', ['unavailable', 'late-error', 'late-success', 'reselect-failed'])
def test_incident_detail_recovery_and_request_order(scenario: str) -> None:
    node = shutil.which('node')
    if not node or not (ROOT / 'web/node_modules/typescript').exists():
        pytest.skip('requires npm ci in apps/console/web and Node.js')
    result = subprocess.run(
        [node, str(Path(__file__).with_name('campaigns_view_harness.cjs')), scenario],
        text=True, capture_output=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
