"""The audit drawer's App Safety section, rendered with the real strings in both languages."""
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def test_the_drawer_shows_the_phones_app_safety_report() -> None:
    node = shutil.which('node')
    if not node or not (ROOT / 'web/node_modules/typescript').exists():
        pytest.skip('requires npm ci in apps/console/web and Node.js')
    result = subprocess.run(
        [node, str(Path(__file__).with_name('app_safety_harness.cjs'))],
        text=True, capture_output=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_drawer_renders_the_section() -> None:
    drawer = (ROOT / 'web/src/components/AuditDrawer.tsx').read_text()
    assert '<AppSafetyReport inputs={inputs}' in drawer
