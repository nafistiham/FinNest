"""Favicons, the apple-touch-icon and the web-manifest icons, from the FinNest mark.

    python3 tools/make_icons.py        (needs Pillow; run from apps/console/)

Source: design-system/assets/finnest-mark.png, used as drawn - scaled, never recoloured,
cropped, redrawn or shadowed (README section 1, "The mark").

Composition follows the design system's own launcher rule ("Adaptive icon: mark at 56 dp on the
108 dp canvas") on the icon off-white #F6F8EA (`color.iconBackground` in tokens.json). That leaves
26/108 of clear space on every side, more than the 25 % of the mark's width the README asks for,
and keeps the mark inside the 80 % safe circle a maskable icon is cut to.

The outputs are committed in web/public/; rerun this only when the mark changes.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
CONSOLE = HERE.parent
DESIGN_SYSTEM = CONSOLE.parents[1] / "design-system"   # apps/console -> the repo root
MARK = DESIGN_SYSTEM / "assets" / "finnest-mark.png"
TOKENS = DESIGN_SYSTEM / "tokens.json"
OUT = CONSOLE / "web" / "public"

MARK_SHARE = 56 / 108  # the adaptive-icon rule


def icon_background() -> str:
    """`color.iconBackground` from tokens.json, so the off-white is never retyped here."""
    tokens = json.loads(TOKENS.read_text())

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "iconBackground" and isinstance(value, dict) and "$value" in value:
                    return value["$value"]
                found = walk(value)
                if found:
                    return found
        return None

    value = walk(tokens)
    if not value:
        raise SystemExit("iconBackground not found in tokens.json")
    return value


def tile(size: int, mark: Image.Image, background: str) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), background)
    side = round(size * MARK_SHARE)
    scaled = mark.resize((side, side), Image.LANCZOS)
    offset = (size - side) // 2
    canvas.alpha_composite(scaled, (offset, offset))
    return canvas


def main() -> None:
    mark = Image.open(MARK).convert("RGBA")
    background = icon_background()
    OUT.mkdir(parents=True, exist_ok=True)

    outputs = {
        "favicon-32.png": 32,
        "favicon-48.png": 48,
        "apple-touch-icon.png": 180,
        "icon-192.png": 192,
        "icon-512.png": 512,
    }
    for name, size in outputs.items():
        image = tile(size, mark, background)
        if name == "apple-touch-icon.png":
            image = image.convert("RGB")  # iOS draws transparency black
        image.save(OUT / name, optimize=True)
        print(f"  {name:22} {size}px")

    tile(48, mark, background).save(OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
    print("  favicon.ico            16, 32, 48px")


if __name__ == "__main__":
    main()
