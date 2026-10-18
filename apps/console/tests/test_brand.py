"""The console carries the FinNest brand the design system defines.

Cheap, static checks, no browser: every chrome string has a Bangla sibling, the old names are gone
from what a reader sees, the page links its favicons and manifest, the icons exist, the design
system's stylesheet is the one imported.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"
sys.path.insert(0, str(ROOT))

BENGALI = re.compile(r"[ঀ-৿]")
ENTRY = re.compile(
    r"^  '([^']+)': \[\s*('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")\s*,\s*('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")\s*,?\s*\]",
    re.M | re.S,
)


def _strings() -> dict[str, tuple[str, str]]:
    source = (WEB / "src" / "lib" / "i18n.ts").read_text()
    table = source[source.index("const STRINGS") : source.index("export const LangContext")]
    entries = {key: (en[1:-1], bn[1:-1]) for key, en, bn in ENTRY.findall(table)}
    # Every entry in the table parsed: a malformed one would otherwise escape the checks below.
    assert len(entries) == table.count("\n  '"), "an i18n entry did not parse"
    return entries


def test_every_chrome_string_has_a_bangla_sibling() -> None:
    strings = _strings()
    assert len(strings) > 300
    # Bangla script, or no letters at all (a "/" separator reads the same in both languages).
    missing = [
        key
        for key, (_, bn) in strings.items()
        if not bn.strip() or (not BENGALI.search(bn) and re.search(r"[A-Za-z]", bn))
    ]
    assert missing == [], f"no Bangla for: {missing}"


def test_the_old_names_are_gone_from_the_copy() -> None:
    forbidden = re.compile(r"Bhorosha|ভরসা|\bApa\b|আপা", re.I)
    leaks = [key for key, pair in _strings().items() if any(forbidden.search(text) for text in pair)]
    assert leaks == []


def test_the_page_links_its_icons_and_manifest() -> None:
    html = (WEB / "index.html").read_text()
    for needle in ('rel="icon"', "favicon.ico", "apple-touch-icon.png", 'rel="manifest"', "manifest.webmanifest"):
        assert needle in html, needle
    assert "<title>FinNest Admin" in html
    assert 'lang="bn"' in html and 'class="fn"' in html
    assert "Bhorosha" not in html


def test_the_built_page_still_links_them() -> None:
    built = WEB / "dist" / "index.html"
    if not built.exists():
        pytest.skip("console not built (npm run build)")
    html = built.read_text()
    for needle in ("favicon.ico", "apple-touch-icon.png", "manifest.webmanifest"):
        assert needle in html, needle
        assert (WEB / "dist" / needle).exists(), needle


def test_the_manifest_and_its_icons() -> None:
    manifest = json.loads((WEB / "public" / "manifest.webmanifest").read_text())
    assert manifest["name"] == "FinNest Admin"
    assert manifest["background_color"].upper() == "#F6F8EA"  # the design system's icon background
    for icon in manifest["icons"]:
        assert (WEB / "public" / icon["src"]).exists(), icon["src"]
    assert any(icon.get("purpose") == "maskable" for icon in manifest["icons"])
    for name in ("favicon.ico", "favicon-32.png", "favicon-48.png", "apple-touch-icon.png"):
        assert (WEB / "public" / name).exists(), name


def test_the_design_system_is_imported_not_forked() -> None:
    main = (WEB / "src" / "main.tsx").read_text()
    assert "../../../../design-system/web/finnest.css" in main
    styles = (WEB / "src" / "styles.css").read_text()
    # No colour of its own: hex values appear only for the always-light ring-graph stage, and
    # those are the light palette's tokens.
    hexes = re.findall(r"#[0-9A-Fa-f]{6}\b", styles)
    assert set(h.upper() for h in hexes) <= {"#F1EFE8", "#FBFAF6", "#878C88", "#1B1B1B"}, hexes
    assert "border-radius: var(--fn-radius)" in styles
    assert "box-shadow: 0 " not in styles
