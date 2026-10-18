#!/usr/bin/env python3
"""Keep the FinNest design tokens in step with the Flutter app and the web files.

Run from anywhere (standard library only, Python 3.10+):

  python3 design-system/tools/sync.py check    # exit 1 if tokens.json or the web files drifted
  python3 design-system/tools/sync.py tokens   # rewrite tokens.json from the Flutter theme sources
  python3 design-system/tools/sync.py web      # rewrite the generated block of web/finnest.css and web/finnest.tailwind.js

The values live in the Flutter theme today (`apps/mobile/lib/app/theme/*.dart`,
`widgets/animated/expressive_text.dart`, `widgets/hero_balance.dart`, `tool/make_brand_assets.py`).
`tokens` reads them and writes `tokens.json` (W3C Design Tokens format, every value quoting the Dart
constant it mirrors); `web` turns `tokens.json` into CSS custom properties and the Tailwind preset.
Change a value in Dart, run `tokens` then `web`, and commit all three; `check` fails on any drift.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DS = Path(__file__).resolve().parent.parent
APP = DS.parent / "apps" / "mobile"
THEME = APP / "lib" / "app" / "theme"
TOKENS = DS / "tokens.json"
CSS = DS / "web" / "finnest.css"
TAILWIND = DS / "web" / "finnest.tailwind.js"
CSS_START = "/* @generated tokens: start (tools/sync.py web; do not edit by hand) */"
CSS_END = "/* @generated tokens: end */"

# --------------------------------------------------------------------------------------------
# Reading the Flutter sources
# --------------------------------------------------------------------------------------------


def _hex(argb: str) -> str:
    """'0xFF0F6E67' -> '#0F6E67' (the app uses opaque colours only)."""
    assert argb.upper().startswith("0XFF"), argb
    return "#" + argb[4:].upper()


def _block(src: str, start: str) -> str:
    """The text from `start` to its matching closing bracket."""
    i = src.index(start)
    j = i + len(start)
    depth = 1
    while depth:
        c = src[j]
        depth += c in "([{"
        depth -= c in ")]}"
        j += 1
    return src[i:j]


def _colors(block: str) -> dict[str, str]:
    return {k: _hex(v) for k, v in re.findall(r"(\w+): Color\((0x[0-9A-Fa-f]{8})\)", block)}


def read_palette() -> dict:
    src = (THEME / "palette.dart").read_text()
    status = {m: _colors(_block(src, f"const _status{m.title()} = _Status(")) for m in ("light", "dark")}
    fills = {
        k: _hex(v) for k, v in re.findall(r"Color get (\w+Fill) => const Color\((0x[0-9A-Fa-f]{8})\)", src)
    }
    brand_map = _block(src, "const _brand = <BhPreset, (_Brand, _Brand)>{")
    presets: dict[str, dict[str, dict[str, str]]] = {}
    for name in re.findall(r"BhPreset\.(\w+): \(", brand_map):
        entry = _block(brand_map, f"BhPreset.{name}: (")
        light, dark = (_colors(b) for b in re.findall(r"_Brand\((.*?)\n    \)", entry, re.S))
        presets[name] = {"light": light, "dark": dark}
    logo = {}
    for key in ("brandLeaf", "brandNavy"):
        m = re.search(
            rf"get {key} =>\s*isDark \? const Color\((0x\w+)\) : const Color\((0x\w+)\)", src
        )
        logo[key] = {"dark": _hex(m.group(1)), "light": _hex(m.group(2))}
    default = re.search(r"static const fallback = BhPreset\.(\w+);", src).group(1)
    return {"status": status, "fills": fills, "presets": presets, "logo": logo, "default": default}


def read_dims() -> dict:
    src = (THEME / "tokens.dart").read_text()
    out = {}
    for cls in ("BhSpace", "BhSize"):
        body = _block(src, f"abstract final class {cls} {{")
        out[cls] = {k: float(v) for k, v in re.findall(r"static const (\w+) = ([\d.]+);", body)}
    return out


_FLUTTER_CURVES = {
    # Flutter's named curves as CSS cubic-bezier control points (flutter/lib/src/animation/curves.dart).
    "Curves.easeOut": [0.0, 0.0, 0.58, 1.0],
    "Curves.easeInOut": [0.42, 0.0, 0.58, 1.0],
    "Curves.easeOutCubic": [0.215, 0.61, 0.355, 1.0],
    "Curves.easeInOutCubic": [0.645, 0.045, 0.355, 1.0],
}


def read_motion() -> dict:
    src = (THEME / "motion.dart").read_text()
    standard = _block(src, "static const standard = BhMotion._(")
    durations = {k: int(v) for k, v in re.findall(r"(\w+): Duration\(milliseconds: (\d+)\)", standard)}
    durations["crossfade"] = int(re.search(r"crossfade = Duration\(milliseconds: (\d+)\)", src).group(1))
    curves_src = _block(src, "abstract final class BhCurves {")
    curves: dict[str, tuple[list[float], str]] = {}
    for name, expr in re.findall(r"static const (\w+) = ([^;]+);", curves_src):
        expr = expr.strip()
        if expr in _FLUTTER_CURVES:
            curves[name] = (_FLUTTER_CURVES[expr], expr)
        elif expr.startswith("Cubic("):
            curves[name] = ([float(x) for x in re.findall(r"[\d.]+", expr)], expr)
        else:  # an alias of another curve in the same class
            curves[name] = (curves[expr][0], f"{expr} ({curves[expr][1]})")
    return {"durations": durations, "curves": curves}


def read_type() -> dict:
    src = (THEME / "typography.dart").read_text()
    text_theme = src[src.index("static TextTheme textTheme("):src.index("static BhTextRoles roles(")]
    bn_src = _block(text_theme, "if (bn) {")
    en_src = text_theme[text_theme.index(bn_src) + len(bn_src):]
    weights = {"w4": 400, "w5": 500, "w7": 700}

    def scale(body: str) -> dict:
        out = {}
        pat = r"(\w+): s\((\d+), (w\d), ([\d.]+)(?:, spacing: (-?[\d.]+))?(, color: muted)?(?:, body: true)?\)"
        for role, size, w, lh, ls, muted in re.findall(pat, body):
            out[role] = {
                "size": int(size), "weight": weights[w], "lineHeight": float(lh),
                "tracking": float(ls) if ls else 0.0, "muted": bool(muted),
                "dart": f"{role}: s({size}, {w}, {lh}" + (f", spacing: {ls}" if ls else "") + ")",
            }
        return out

    bn, en = scale(bn_src), scale(en_src)
    roles_src = src[src.index("static BhTextRoles roles("):src.index("static const script = TextStyle(")]
    pat = r"(\w+): s\((bn \? (\d+) : (\d+)|\d+), (bn \? ([\d.]+) : ([\d.]+)|[\d.]+)(, color: muted)?(, bold: false)?\)"
    for role, size, sbn, sen, lh, lbn, len_, muted, notbold in re.findall(pat, roles_src):
        for lang, table in (("bn", bn), ("en", en)):
            sz = int((sbn if lang == "bn" else sen) or size)
            line = float((lbn if lang == "bn" else len_) or lh)
            weight = 400 if notbold else (700 if lang == "bn" else 500)
            tracking = 0.0 if lang == "bn" or sz < 40 else -0.5
            table[role] = {
                "size": sz, "weight": weight, "lineHeight": line, "tracking": tracking,
                "muted": bool(muted), "dart": f"BhType.roles {role}: s({size}, {lh}{muted}{notbold})",
            }
    script = _block(roles_src, "script: TextStyle(")
    bn["script"] = {
        "size": int(re.search(r"fontSize: (\d+)", script).group(1)),
        "weight": int(re.search(r"FontWeight\.w(\d)00", script).group(1)) * 100,
        "lineHeight": float(re.search(r"height: ([\d.]+)", script).group(1)),
        "tracking": 0.0, "muted": False,
        "dart": "BhType.roles script: TextStyle(fontFamily: family, fontSize: 22, fontWeight: w700, height: 1.5)",
    }
    disp = (APP / "lib/app/widgets/animated/expressive_text.dart").read_text()
    hero = (APP / "lib/app/widgets/hero_balance.dart").read_text()
    display = {
        "family": re.search(r"static const family = '(\w+)';", disp).group(1),
        "weight": int(float(re.search(r"static const weight = ([\d.]+);", disp).group(1))),
        "lineHeight": {
            "bn": float(re.search(r"height: _bangla\(locale\) \? ([\d.]+) : ([\d.]+)", disp).group(1)),
            "en": float(re.search(r"height: _bangla\(locale\) \? ([\d.]+) : ([\d.]+)", disp).group(2)),
        },
        "trackingEm": {"bn": 0.0, "en": -float(re.search(r"-size \* ([\d.]+)", disp).group(1))},
        "defaultSize": int(float(re.search(r"double size = ([\d.]+)", disp).group(1))),
        "heroSize": int(float(re.search(r"static const amountSize = ([\d.]+);", hero).group(1))),
    }
    return {"bn": bn, "en": en, "display": display}


def read_icon_background() -> str:
    src = (APP / "tool/make_brand_assets.py").read_text()
    return "#" + re.search(r'OFF_WHITE_HEX = "#FF(\w{6})"', src).group(1).upper()


# --------------------------------------------------------------------------------------------
# Building tokens.json
# --------------------------------------------------------------------------------------------

BRAND_MEANING = {
    "primary": "Trust and the one primary action per screen; links; focus ring; selected state.",
    "onPrimary": "Text and icons on primary.",
    "primaryContainer": "Selected chips and tiles, person avatars, numpad key press tint (60 %).",
    "onPrimaryContainer": "Text on primaryContainer.",
    "accent": "Secondary accent: the assistant ring, 'new' badge, selected-preset tick. Icons, rings, badges; text only on surface.",
    "surface": "Screen background.",
    "surfaceVariant": "Cards, input fills in dark mode, skeletons, neutral tags.",
    "onSurface": "Body text and amounts.",
    "mutedText": "Captions, subtitles, secondary icons.",
    "outline": "Borders that must read (chips, inputs), >= 3:1 on surface.",
    "outlineVariant": "Decorative dividers and hairlines.",
}
STATUS_MEANING = {
    "danger": "Block, danger, errors, wrong PIN. The only red; never decorative.",
    "warning": "Hold, wait, delay, step-up, pending, simulated.",
    "success": "Done, safe, credits.",
    "info": "Neutral facts, demo notes, requested.",
}


def _c(value: str, dart: str, meaning: str = "") -> dict:
    return {"$value": value, "$description": (meaning + " " if meaning else "") + f"Dart: {dart}"}


def build_tokens() -> dict:
    pal, dims, motion, typ = read_palette(), read_dims(), read_motion(), read_type()
    default = pal["default"]
    color: dict = {"$type": "color"}
    for mode, idx in (("light", "$1"), ("dark", "$2")):
        g: dict = {"$description": f"Semantic colours, {mode} mode, default preset ({default})."}
        for k, v in pal["presets"][default][mode].items():
            g[k] = _c(v, f"palette.dart _brand[BhPreset.{default}].{idx} {k}: Color(0xFF{v[1:]})", BRAND_MEANING.get(k, ""))
        for k, v in pal["status"][mode].items():
            base = re.sub(r"^on|Container$", "", k).lower()
            g[k] = _c(v, f"palette.dart _status{mode.title()} {k}: Color(0xFF{v[1:]})",
                      STATUS_MEANING.get(k, f"Status ({base})."))
        for k, v in pal["fills"].items():
            g[k] = _c(v, f"palette.dart _Status get {k} => const Color(0xFF{v[1:]}) (same in both modes)",
                      "Strong status fill: buttons, stripes, the hold overlay strip.")
        for k, v in pal["logo"].items():
            half = "Fin" if k == "brandLeaf" else "Nest"
            g[k] = _c(v[mode], f"palette.dart BhPalette.{k} ({mode}): Color(0xFF{v[mode][1:]})",
                      f"Wordmark '{half}' colour, every preset; display sizes only.")
        color[mode] = g
    color["brand"] = {
        "iconBackground": _c(read_icon_background(), "tool/make_brand_assets.py OFF_WHITE_HEX = \"#FFF6F8EA\"",
                             "Off-white behind the mark on the launcher icon and splash."),
    }
    preset_names = {
        "teal": "FinNest teal / ফিননেস্ট টিল (default)", "padma": "Padma green / পদ্মা সবুজ",
        "jamdani": "Jamdani indigo / জামদানি নীল", "shapla": "Shapla plum / শাপলা বেগুনি",
        "slate": "Monsoon slate / বর্ষা স্লেট",
    }
    color["preset"] = {"$description": "User-selectable app themes (Settings). Brand tokens only; status colours never change with the preset."}
    for name, modes in pal["presets"].items():
        color["preset"][name] = {"$description": preset_names.get(name, name)}
        for mode, idx in (("light", "$1"), ("dark", "$2")):
            color["preset"][name][mode] = {
                k: _c(v, f"palette.dart _brand[BhPreset.{name}].{idx} {k}: Color(0xFF{v[1:]})")
                for k, v in modes[mode].items()
            }

    status: dict = {"$type": "color", "$description": "Status roles by meaning. Every status also carries an icon and a word; colour is never the only signal."}
    for s, meaning in STATUS_MEANING.items():
        roles = {"text": s, "container": f"{s}Container", "onContainer": f"on{s.title()}Container"}
        if s != "info":
            roles |= {"fill": f"{s}Fill", "onFill": f"on{s.title()}Fill"}
        status[s] = {"$description": meaning}
        for role, tok in roles.items():
            status[s][role] = {m: {"$value": f"{{color.{m}.{tok}}}"} for m in ("light", "dark")}
    status["neutral"] = {
        "$description": "Cancelled, released: no status colour.",
        "text": {m: {"$value": f"{{color.{m}.mutedText}}"} for m in ("light", "dark")},
        "container": {m: {"$value": f"{{color.{m}.surfaceVariant}}"} for m in ("light", "dark")},
    }

    def px(v: float) -> str:
        return f"{v:g}px"

    space = {"$type": "dimension", "$description": "8 dp grid with a 4 dp half-step. dp = CSS px."}
    for k, v in dims["BhSpace"].items():
        space[k] = {"$value": px(v), "$description": f"Dart: tokens.dart BhSpace.{k} = {v}"}
    size = {"$type": "dimension", "$description": "Component sizes in dp (= CSS px)."}
    for k, v in dims["BhSize"].items():
        size[k] = {"$value": px(v), "$description": f"Dart: tokens.dart BhSize.{k} = {v}"}

    families = {
        "$type": "fontFamily",
        "bangla": {"$value": ["SolaimanLipi", "Roboto", "sans-serif"],
                   "$description": "Dart: typography.dart BhType.family = 'SolaimanLipi', fallback ['Roboto'] (bn)."},
        "latin": {"$value": ["Roboto", "system-ui", "-apple-system", "Segoe UI", "SolaimanLipi", "sans-serif"],
                  "$description": "Dart: fontFamily null (system Roboto), fallback ['SolaimanLipi'] (en)."},
        "display": {"$value": [typ["display"]["family"], "SolaimanLipi", "Roboto", "sans-serif"],
                    "$description": "Dart: expressive_text.dart DisplayAmountStyle.family = 'BalooDa2'. Big amounts only, never words."},
    }
    typography: dict = {"$type": "typography", "$description": "Sizes in sp (= CSS px at 100 % zoom). Bangla tracking is always 0."}
    for lang, fam in (("bn", "bangla"), ("en", "latin")):
        g: dict = {}
        for role, t in typ[lang].items():
            g[role] = {
                "$value": {
                    "fontFamily": f"{{font.family.{fam}}}", "fontSize": px(t["size"]),
                    "fontWeight": t["weight"], "lineHeight": t["lineHeight"], "letterSpacing": px(t["tracking"]),
                },
                "$description": ("Muted colour. " if t["muted"] else "") + f"Dart: typography.dart ({lang}) {t['dart']}",
            }
        typography[lang] = g
    d = typ["display"]
    typography["display"] = {
        lang: {
            name: {
                "$value": {
                    "fontFamily": "{font.family.display}", "fontSize": px(sz), "fontWeight": d["weight"],
                    "lineHeight": d["lineHeight"][lang], "letterSpacing": f"{d['trackingEm'][lang]:g}em",
                },
                "$description": f"Dart: DisplayAmountStyle (size {sz}, w800, height {d['lineHeight'][lang]}"
                + (", letterSpacing -size * 0.01, tabular figures" if lang == "en" else ", letterSpacing 0")
                + ")" + (" ; HeroBalance.amountSize = 52" if name == "hero" else ""),
            }
            for name, sz in (("amount", d["defaultSize"]), ("hero", d["heroSize"]))
        }
        for lang in ("bn", "en")
    }

    dur = {"$type": "duration", "$description": "Reduced motion: every duration is 0 except crossfade."}
    for k, v in motion["durations"].items():
        dur[k] = {"$value": f"{v}ms", "$description": f"Dart: motion.dart BhMotion.{'crossfade' if k == 'crossfade' else 'standard.' + k} = Duration(milliseconds: {v})"}
    ease = {"$type": "cubicBezier"}
    for k, (pts, expr) in motion["curves"].items():
        ease[k] = {"$value": pts, "$description": f"Dart: motion.dart BhCurves.{k} = {expr}"}

    return {
        "$description": (
            "FinNest design tokens (W3C Design Tokens Community Group format). Generated by "
            "design-system/tools/sync.py from the Flutter theme; do not edit values by hand. "
            "Prose and rules: design-system/README.md."
        ),
        "color": color,
        "status": status,
        "font": {"family": families, "weight": {
            "$type": "fontWeight",
            "regular": {"$value": 400, "$description": "Body text (both scripts)."},
            "medium": {"$value": 500, "$description": "Latin titles, labels, buttons. Never for Bangla (SolaimanLipi has 400 and 700 only)."},
            "bold": {"$value": 700, "$description": "Bangla titles, labels, buttons."},
            "display": {"$value": d["weight"], "$description": "Display face for big amounts."},
        }},
        "typography": typography,
        "space": space,
        "size": size,
        "radius": {"$type": "dimension", "none": {"$value": "0px", "$description": "Square corners everywhere. Dart: theme.dart _square = RoundedRectangleBorder(borderRadius: BorderRadius.zero)"}},
        "border": {"$type": "dimension",
                   "hairline": {"$value": "1px", "$description": "Dividers, input outline. Dart: DividerThemeData(thickness: 1)"},
                   "focus": {"$value": "2px", "$description": "Focused input, outlined button, selected tile. Dart: BorderSide(width: 2)"},
                   "stripe": {"$value": px(dims["BhSize"]["stripe"]), "$description": "Leading status stripe on soft status cards. Dart: BhSize.stripe"}},
        "elevation": {"$type": "number", "none": {"$value": 0, "$description": "No shadows; separation comes from fills and 1 px dividers. Dart: elevation: 0"}},
        "motion": {"duration": dur, "easing": ease},
    }


# --------------------------------------------------------------------------------------------
# Web output
# --------------------------------------------------------------------------------------------


def kebab(s: str) -> str:
    return re.sub(r"([A-Z])", r"-\1", s).lower()


def _vals(group: dict) -> dict:
    return {k: v["$value"] for k, v in group.items() if not k.startswith("$")}


def _rem(px: str) -> str:
    return f"{float(px[:-2]) / 16:g}rem"


def build_css_block(t: dict) -> str:
    out = [CSS_START, ""]
    light, dark = _vals(t["color"]["light"]), _vals(t["color"]["dark"])
    presets = {k: v for k, v in t["color"]["preset"].items() if not k.startswith("$")}
    default = next(k for k, v in presets.items() if _vals(v["light"]).items() <= light.items())

    def decl(vals: dict, indent: str = "  ") -> list[str]:
        return [f"{indent}--fn-{kebab(k)}: {v};" for k, v in vals.items()]

    fam = {k: ", ".join(f'"{f}"' if " " in f or f[0].isupper() else f for f in v["$value"])
           for k, v in t["font"]["family"].items() if not k.startswith("$")}
    # `only light`, not `light`: a browser with forced dark mode (Chrome's "Auto Dark Mode for Web
    # Contents", Samsung Internet's night mode) repaints any page that declares only `light`, so a
    # reader who picked light saw an algorithmically darkened page. The design system ships its own
    # dark mode; in light it must opt out of that repaint. The dark rules below set `dark`.
    out += [":root {", "  color-scheme: only light;", "  /* Colour: light mode, default preset */"]
    out += decl(light)
    # One swatch per preset (its primary), so a preset picker can show every choice at once
    # whatever preset is active. Dark-mode values are redeclared in the dark rules.
    out += [f"  --fn-preset-{name}: {_vals(p['light'])['primary']};" for name, p in presets.items()]
    out.append(f"  --fn-icon-background: {t['color']['brand']['iconBackground']['$value']};")
    out.append("  /* Space and size (dp = px) */")
    out += [f"  --fn-space-{k}: {v};" for k, v in _vals(t["space"]).items()]
    out += [f"  --fn-size-{kebab(k)}: {v};" for k, v in _vals(t["size"]).items()]
    out += ["  --fn-radius: 0px;", "  --fn-border-hairline: 1px;", "  --fn-border-focus: 2px;",
            f"  --fn-border-stripe: {t['border']['stripe']['$value']};", "  --fn-elevation: none;"]
    out.append("  /* Motion */")
    out += [f"  --fn-duration-{kebab(k)}: {v};" for k, v in _vals(t["motion"]["duration"]).items()]
    out += [f"  --fn-ease-{kebab(k)}: cubic-bezier({', '.join(f'{x:g}' for x in v)});"
            for k, v in _vals(t["motion"]["easing"]).items()]
    out.append("  /* Font stacks */")
    out += [f"  --fn-font-{k}: {v};" for k, v in fam.items()]
    out.append("}")
    out.append("")

    def type_vars(lang: str) -> list[str]:
        lines = []
        roles = dict(_vals(t["typography"][lang]))
        if lang == "en":
            roles.setdefault("script", t["typography"]["bn"]["script"]["$value"])
        for role, v in roles.items():
            r = kebab(role)
            lines += [f"  --fn-{r}-size: {_rem(v['fontSize'])};", f"  --fn-{r}-weight: {v['fontWeight']};",
                      f"  --fn-{r}-line: {v['lineHeight']:g};", f"  --fn-{r}-tracking: {v['letterSpacing']};"]
        for name, v in _vals(t["typography"]["display"][lang]).items():
            lines += [f"  --fn-display-{name}-size: {_rem(v['fontSize'])};",
                      f"  --fn-display-{name}-line: {v['lineHeight']:g};",
                      f"  --fn-display-{name}-tracking: {v['letterSpacing']};"]
        return lines

    out += ["/* Type scale follows the language: Bangla by default, Latin under lang=\"en\". */",
            ":root, :lang(bn) {", "  --fn-font-text: var(--fn-font-bangla);"]
    out += type_vars("bn") + ["}", ":lang(en) {", "  --fn-font-text: var(--fn-font-latin);"]
    out += type_vars("en") + ["}", ""]

    for name, p in presets.items():
        if name == default:
            continue
        out.append(f':root[data-preset="{name}"] {{')
        out += decl(_vals(p["light"]))
        out.append("}")
    out.append("")

    dark_rules = ["  color-scheme: dark;"] + decl(dark)
    dark_rules += [f"  --fn-preset-{name}: {_vals(p['dark'])['primary']};" for name, p in presets.items()]
    out += ["@media (prefers-color-scheme: dark) {", '  :root:not([data-theme="light"]) {']
    out += ["  " + line for line in dark_rules] + ["  }"]
    for name, p in presets.items():
        if name != default:
            out += [f'  :root:not([data-theme="light"])[data-preset="{name}"] {{']
            out += decl(_vals(p["dark"]), "    ") + ["  }"]
    out += ["}", ':root[data-theme="dark"] {'] + dark_rules + ["}"]
    for name, p in presets.items():
        if name != default:
            out += [f':root[data-theme="dark"][data-preset="{name}"] {{'] + decl(_vals(p["dark"])) + ["}"]
    out.append("")

    out += ["@media (prefers-reduced-motion: reduce) {", "  :root {"]
    out += [f"    --fn-duration-{kebab(k)}: 0ms;" for k in _vals(t["motion"]["duration"]) if k != "crossfade"]
    out += ["  }", "}", ""]

    out.append("/* One class per type role: .fn-body-medium, .fn-title-large, ... */")
    roles = list(_vals(t["typography"]["bn"]))
    for role in roles:
        r = kebab(role)
        muted = "Muted colour" in t["typography"]["bn"][role]["$description"]
        out.append(
            f".fn-{r} {{ font-family: var(--fn-font-text); font-size: var(--fn-{r}-size); "
            f"font-weight: var(--fn-{r}-weight); line-height: var(--fn-{r}-line); "
            f"letter-spacing: var(--fn-{r}-tracking);" + (" color: var(--fn-muted-text);" if muted else "") + " }"
        )
    out += ["", CSS_END]
    return "\n".join(out)


def build_tailwind(t: dict) -> str:
    light, dark = _vals(t["color"]["light"]), _vals(t["color"]["dark"])
    colors = {kebab(k): f"var(--fn-{kebab(k)})" for k in light}
    font_size = {}
    for role in _vals(t["typography"]["bn"]):
        r = kebab(role)
        font_size[r] = [f"var(--fn-{r}-size)", {"lineHeight": f"var(--fn-{r}-line)",
                                                 "letterSpacing": f"var(--fn-{r}-tracking)",
                                                 "fontWeight": f"var(--fn-{r}-weight)"}]
    preset = {
        "theme": {
            "extend": {
                "colors": {"fn": colors},
                "spacing": {f"fn-{k}": v for k, v in _vals(t["space"]).items()}
                | {f"fn-{kebab(k)}": v for k, v in _vals(t["size"]).items()},
                "fontFamily": {"fn-text": ["var(--fn-font-text)"], "fn-bangla": t["font"]["family"]["bangla"]["$value"],
                               "fn-latin": t["font"]["family"]["latin"]["$value"], "fn-display": t["font"]["family"]["display"]["$value"]},
                "fontSize": {f"fn-{k}": v for k, v in font_size.items()},
                "minHeight": {"fn-touch": "var(--fn-size-touch)"},
                "minWidth": {"fn-touch": "var(--fn-size-touch)"},
                "transitionDuration": {f"fn-{kebab(k)}": f"var(--fn-duration-{kebab(k)})" for k in _vals(t["motion"]["duration"])},
                "transitionTimingFunction": {f"fn-{kebab(k)}": f"var(--fn-ease-{kebab(k)})" for k in _vals(t["motion"]["easing"])},
            },
            "borderRadius": {"none": "0px", "DEFAULT": "0px"},
            "boxShadow": {"none": "none", "DEFAULT": "none"},
        }
    }
    raw = {"light": light, "dark": dark}
    return (
        "// FinNest Tailwind preset. Generated by design-system/tools/sync.py from tokens.json; do not edit.\n"
        "// Load web/finnest.css first: the colours and type roles are CSS variables, so light/dark mode,\n"
        "// presets (data-preset) and the bn/en type scale switch without rebuilding.\n"
        "// Usage (tailwind.config.js): import finnest from './finnest.tailwind.js'; export default { presets: [finnest], ... }\n"
        "// Classes: bg-fn-primary text-fn-on-primary, text-fn-body-medium, p-fn-m, min-h-fn-touch, duration-fn-normal ease-fn-enter.\n"
        "// Radius and shadow are flattened on purpose: FinNest is square and flat.\n\n"
        f"export const finnestColors = {json.dumps(raw, indent=2)};\n\n"
        f"const finnest = {json.dumps(preset, indent=2, ensure_ascii=False)};\n\n"
        "export default finnest;\n"
    )


def render_css(t: dict) -> str:
    css = CSS.read_text()
    i, j = css.index(CSS_START), css.index(CSS_END) + len(CSS_END)
    return css[:i] + build_css_block(t) + css[j:]


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "check"
    if cmd == "tokens":
        TOKENS.write_text(json.dumps(build_tokens(), indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {TOKENS.relative_to(DS)}")
        return 0
    if cmd == "web":
        t = json.loads(TOKENS.read_text())
        CSS.write_text(render_css(t))
        TAILWIND.write_text(build_tailwind(t))
        print("wrote web/finnest.css (generated block), web/finnest.tailwind.js")
        return 0
    if cmd == "check":
        drift = []
        t = json.loads(TOKENS.read_text())
        if build_tokens() != t:
            drift.append("tokens.json differs from the Flutter theme (run: sync.py tokens)")
        if render_css(t) != CSS.read_text():
            drift.append("web/finnest.css generated block is stale (run: sync.py web)")
        if build_tailwind(t) != TAILWIND.read_text():
            drift.append("web/finnest.tailwind.js is stale (run: sync.py web)")
        for d in drift:
            print("DRIFT:", d)
        print("ok" if not drift else f"{len(drift)} file(s) drifted")
        return 1 if drift else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
