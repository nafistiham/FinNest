"""The audit drawer's Gemini reading, rendered with the real strings in both languages."""
from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def test_the_drawer_section_renders_gemini_s_reading() -> None:
    node = shutil.which('node')
    if not node or not (ROOT / 'web/node_modules/typescript').exists():
        pytest.skip('requires npm ci in apps/console/web and Node.js')
    result = subprocess.run(
        [node, str(Path(__file__).with_name('gemini_insight_harness.cjs'))],
        text=True, capture_output=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_reading_sits_above_the_verbatim_reasons_and_never_replaces_them() -> None:
    drawer = (ROOT / 'web/src/components/AuditDrawer.tsx').read_text()
    reading = drawer.index('<GeminiInsight')
    verbatim = drawer.index("t('audit.reasons')")
    assert reading < verbatim
    # The customer's reasons are still rendered from the stored row, word for word, in both languages.
    assert '{reason.text_bn}' in drawer and '{reason.text_en}' in drawer


def test_the_drawer_asks_only_for_scores_with_reasons() -> None:
    drawer = (ROOT / 'web/src/components/AuditDrawer.tsx').read_text()
    assert re.search(r"row\.kind === 'score' && row\.reason_codes\.length > 0", drawer)
    assert 'getAuditInsight(row.id)' in drawer
