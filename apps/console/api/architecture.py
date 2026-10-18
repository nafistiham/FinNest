"""What is actually running, and how a payment moves through it.

The console had every number the system produces and no picture of the system. This builds that
picture - and builds most of it by reading risk-mw's own source, which ships inside this image,
rather than by someone typing a diagram that drifts the first time a router is renamed.

What is read from the code: every router, its URL prefix, every route on it, every module in
`app/`, and which of those modules reach Gemini, Firestore or the trained artefacts. What is
written by hand: the plain sentence saying what each piece is *for*, because no amount of parsing
will tell a reader why a module exists. Each hand-written line names the file it describes, so it
can be checked against the thing it claims to describe.
"""

from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from api import aggregate
from api.risk_mw import SERVICE, VENDOR

ROUTE = re.compile(r'@router\.(get|post|put|delete)\(\s*"([^"]*)"')
PREFIX = re.compile(r'APIRouter\(\s*prefix="([^"]*)"')
# A module "reaches" something when it imports it. Import is the honest test: a module that merely
# mentions Firestore in a comment is not talking to Firestore.
REACHES: dict[str, tuple[str, ...]] = {
    "gemini": ("genai_client", "google.genai", "vertexai"),
    "firestore": ("firestore",),
    "artefacts": ("joblib", "lightgbm", "pickle"),
}


def _app_dir() -> Path | None:
    """risk-mw's `app/` package, wherever this is running.

    In the repo it sits under `services/risk-mw`; in the container the deploy vendors it
    into `apps/console/vendor/app`. Returns None rather than guessing if neither is there.
    """
    for root in (SERVICE / "app", VENDOR / "app"):
        if root.is_dir():
            return root
    return None


def _reaches(text: str) -> list[str]:
    out = []
    for name, needles in REACHES.items():
        if any(re.search(rf"^\s*(from|import)\s+.*\b{re.escape(n)}\b", text, re.M) for n in needles):
            out.append(name)
    return out


@lru_cache(maxsize=1)
def routers() -> list[dict[str, Any]]:
    """Every router risk-mw mounts, with the routes actually on it."""
    root = _app_dir()
    if root is None:
        return []
    out: list[dict[str, Any]] = []
    for path in sorted((root / "routers").glob("*.py")):
        if path.name == "__init__.py":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        routes = [
            {"method": method.upper(), "path": f"{(PREFIX.search(text).group(1) if PREFIX.search(text) else '')}{suffix}"}
            for method, suffix in ROUTE.findall(text)
        ]
        if not routes:
            continue
        out.append({
            "id": path.stem,
            "file": f"services/risk-mw/app/routers/{path.name}",
            "prefix": PREFIX.search(text).group(1) if PREFIX.search(text) else "",
            "routes": routes,
            "reaches": _reaches(text),
        })
    return out


@lru_cache(maxsize=1)
def modules() -> list[dict[str, Any]]:
    """Every module in risk-mw's `app/`, and what each one reaches outside the process."""
    root = _app_dir()
    if root is None:
        return []
    out = []
    for path in sorted(root.glob("*.py")):
        if path.name == "__init__.py":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        out.append({
            "id": path.stem,
            "file": f"services/risk-mw/app/{path.name}",
            "lines": text.count("\n") + 1,
            "reaches": _reaches(text),
        })
    return out


def available() -> bool:
    return _app_dir() is not None


# --- the written half -------------------------------------------------------
#
# Everything above is read from the code. Everything below is a sentence about why a piece exists,
# which no parser can tell you. Each one names the file it is about so it can be checked, and each
# was checked against that file when it was written.

SYSTEMS: tuple[dict[str, Any], ...] = (
    {"id": "app", "name": "The phone", "name_bn": "ফোন",
     "what": "Shows the balance and takes the payment. Decides nothing about risk.",
     "what_bn": "ব্যালান্স দেখায়, পেমেন্ট নেয়। ঝুঁকির সিদ্ধান্ত নেয় না।",
     "where": "apps/mobile", "badge": "RULE"},
    {"id": "risk-mw", "name": "Decision service", "name_bn": "ডিসিশন সার্ভিস",
     "what": "The only thing that may hold a payment. Writes every answer down first.",
     "what_bn": "পেমেন্ট আটকানোর অধিকার কেবল এটার। প্রতিটা উত্তর আগে লিখে রাখে।",
     "where": "services/risk-mw", "badge": "MODEL"},
    {"id": "case-zero", "name": "Investigator", "name_bn": "ইনভেস্টিগেটর",
     "what": "Works a case on its own. Never touches a live payment.",
     "what_bn": "নিজেই একটা কেস নিয়ে কাজ করে। চলমান পেমেন্টে হাত দেয় না।",
     "where": "services/case-zero", "badge": "MODEL"},
    {"id": "console", "name": "This console", "name_bn": "এই কনসোল",
     "what": "Reads and replays. Never decides, never writes.",
     "what_bn": "পড়ে আর আবার চালায়। সিদ্ধান্ত নেয় না, লেখেও না।",
     "where": "apps/console", "badge": "SYNTHETIC"},
    {"id": "firestore", "name": "The record", "name_bn": "ডাটাবেস",
     "what": "Every answer, kept as it was given.",
     "what_bn": "প্রতিটা উত্তর, যেভাবে দেওয়া হয়েছিল সেভাবেই।",
     "where": "Firestore · audit", "badge": "RULE"},
    {"id": "artefacts", "name": "Model files", "name_bn": "মডেল ফাইল",
     "what": "The weights on disk. Loaded at start-up; missing means it says so, not scores blind.",
     "what_bn": "ডিস্কে রাখা ওজন। চালুর সময় তোলা হয়; না থাকলে অন্ধভাবে স্কোর না করে বলে দেয়।",
     "where": "models", "badge": "MODEL"},
    {"id": "ledger", "name": "Her own history", "name_bn": "লেজার · তাঁর নিজের ইতিহাস",
     "what": "What she normally sends, and to whom. A first payment is only unusual against this.",
     "what_bn": "তিনি সাধারণত কত পাঠান, কাকে পাঠান। প্রথমবার পাঠানো অস্বাভাবিক কেবল এর তুলনাতেই।",
     "where": "services/risk-mw/app/ledger.py", "badge": "RULE"},
    {"id": "trusted", "name": "Trusted contact", "name_bn": "ট্রাস্টেড কন্টাক্ট",
     "what": "A second person. When a payment is held, they are the one asked to approve it.",
     "what_bn": "দ্বিতীয় একজন মানুষ। পেমেন্ট আটকালে অনুমোদনের জন্য তাঁকেই জিজ্ঞেস করা হয়।",
     "where": "/v1/actions/trusted-contact · app/notify.py", "badge": "RULE"},
    {"id": "gemini", "name": "Gemini", "name_bn": "জেমিনাই",
     "what": "Reads a call, judges an app, speaks. Never the payment decision.",
     "what_bn": "কল পড়ে, অ্যাপ বিচার করে, কথা বলে। পেমেন্টের সিদ্ধান্ত কখনো নয়।",
     "where": "Vertex AI", "badge": "MODEL"},
)

# The arrows. Each one is a thing that actually happens, in one or two words.
LINKS: tuple[dict[str, str], ...] = (
    {"from": "app", "to": "risk-mw", "label": "asks", "label_bn": "জিজ্ঞেস করে"},
    # The answer going back was missing entirely, which is the one arrow the whole picture is for.
    {"from": "risk-mw", "to": "app", "label": "answers", "label_bn": "উত্তর দেয়"},
    {"from": "risk-mw", "to": "ledger", "label": "reads", "label_bn": "পড়ে"},
    {"from": "risk-mw", "to": "trusted", "label": "asks on a hold", "label_bn": "হোল্ড হলে জিজ্ঞেস করে"},
    {"from": "risk-mw", "to": "firestore", "label": "writes", "label_bn": "লেখে"},
    {"from": "risk-mw", "to": "artefacts", "label": "loads", "label_bn": "তোলে"},
    {"from": "risk-mw", "to": "gemini", "label": "asks", "label_bn": "জিজ্ঞেস করে"},
    {"from": "case-zero", "to": "gemini", "label": "asks", "label_bn": "জিজ্ঞেস করে"},
    {"from": "console", "to": "firestore", "label": "reads", "label_bn": "পড়ে"},
    {"from": "console", "to": "case-zero", "label": "reads", "label_bn": "পড়ে"},
)

JOURNEY: tuple[dict[str, Any], ...] = (
    {"step": 1, "title": "Signals", "title_bn": "সিগন্যাল",
     "plain": "The phone sends what it can see: a call, a SIM change, a shared screen.",
     "plain_bn": "ফোন যা দেখতে পায় পাঠায়: কল, সিম বদল, স্ক্রিন শেয়ার।",
     "route": "POST /v1/risk/signals", "module": "device_signals"},
    {"step": 2, "title": "Scored", "title_bn": "স্কোর",
     "plain": "One call carries the payment. The rules add up what they find.",
     "plain_bn": "একটা কলেই পেমেন্ট যায়। রুলগুলো যা পায় যোগ করে।",
     "route": "POST /v1/risk/score", "module": "rules"},
    {"step": 3, "title": "Four questions", "title_bn": "চারটি প্রশ্ন",
     "plain": "The hand holding it, the apps on it, the call on it, the payee behind it.",
     "plain_bn": "যে হাত ধরে আছে, যে অ্যাপ বসানো, যে কল চলছে, যে প্রাপক পিছনে।",
     "route": "same call", "module": "session_model, appsafety_engine, scam, mule"},
    {"step": 4, "title": "One answer", "title_bn": "একটাই উত্তর",
     "plain": "Allow, step up, delay or hold - with the reasons in the customer's words.",
     "plain_bn": "ছেড়ে দেওয়া, স্টেপ-আপ, দেরি বা আটকে রাখা — গ্রাহকের ভাষায় কারণ সহ।",
     "route": "the response", "module": "rules, interventions"},
    {"step": 5, "title": "Written down", "title_bn": "লিখে রাখা",
     "plain": "Into the record before the phone sees it. This console reads that.",
     "plain_bn": "ফোনে পৌঁছানোর আগেই নথিতে। এই কনসোল সেটাই পড়ে।",
     "route": "Firestore audit", "module": "audit"},
    {"step": 6, "title": "Looked into", "title_bn": "খতিয়ে দেখা",
     "plain": "A suspect payee becomes a case, and a watch-list. Not yet a block.",
     "plain_bn": "সন্দেহভাজন প্রাপক কেস হয়, ওয়াচ-লিস্ট হয়। এখনো ব্লক নয়।",
     "route": "POST /v1/investigate", "module": "investigator"},
)


# What each model is for, and which box on the map carries it. The version, the headline metric and
# the badge are not here on purpose: those come from the eval files through `aggregate.models()`,
# the same source the Models view reads, so a retrained model changes this page too. Only the job -
# the sentence saying what it is *for* - is written.
MODEL_JOBS: dict[str, dict[str, str]] = {
    "mule-lgbm": {
        "inside": "risk-mw",
        "job": "Scores the payee: has money like this reached this account before?",
        "job_bn": "প্রাপককে স্কোর করে: এমন টাকা আগে কি এই অ্যাকাউন্টে এসেছে?",
    },
    "ato-identity": {
        "inside": "risk-mw",
        "job": "Reads how the phone is being held and typed on. Is this the owner?",
        "job_bn": "ফোনটা কীভাবে ধরা আর টাইপ করা হচ্ছে পড়ে। এটা কি মালিক নিজেই?",
    },
    "app-safety": {
        "inside": "risk-mw",
        "job": "Judges what is installed: can anything here watch or drive the screen?",
        "job_bn": "কী কী বসানো আছে বিচার করে: কিছু কি স্ক্রিন দেখতে বা চালাতে পারে?",
    },
    "fna-intervention": {
        "inside": "risk-mw",
        "job": "Decides what the assistant says, and when it interrupts.",
        "job_bn": "সহকারী কী বলবে আর কখন বাধা দেবে, সেটা ঠিক করে।",
    },
    "case-zero": {
        "inside": "case-zero",
        "job": "Works a ring: asks for accounts, follows the money, writes the case up.",
        "job_bn": "একটা চক্র নিয়ে কাজ করে: অ্যাকাউন্ট চায়, টাকার পথ ধরে, কেসটা লিখে দেয়।",
    },
}


# The checks inside the decision service, in the order a payment meets them. Each names the module
# or model that answers it; `available()` already proves those files exist, and the model rows carry
# their real version and metric. The last one is the merge - the rules do not answer a question,
# they add up the answers.
CHECKS: tuple[dict[str, Any], ...] = (
    {"id": "device_signals", "kind": "module", "label": "device signals",
     "asks": "What can the handset see right now?", "asks_bn": "হ্যান্ডসেট এখন কী দেখতে পায়?"},
    {"id": "ato-identity", "kind": "model", "label": "behaviour",
     "asks": "Is this the owner holding the phone?", "asks_bn": "ফোনটা কি মালিকই ধরে আছেন?"},
    {"id": "app-safety", "kind": "model", "label": "app check",
     "asks": "Can anything installed watch the screen?", "asks_bn": "বসানো কিছু কি স্ক্রিন দেখতে পারে?"},
    {"id": "scam", "kind": "module", "label": "call",
     "asks": "Does the call sound like a scam?", "asks_bn": "কলটা কি স্ক্যামের মতো শোনায়?"},
    {"id": "mule-lgbm", "kind": "model", "label": "payee",
     "asks": "Has money reached this payee this way before?", "asks_bn": "এই প্রাপকের কাছে আগে কি এভাবে টাকা গেছে?"},
    {"id": "fna-intervention", "kind": "model", "label": "assistant",
     "asks": "Should the assistant interrupt?", "asks_bn": "সহকারীর কি বাধা দেওয়া উচিত?"},
)


def checks() -> list[dict[str, Any]]:
    """The checks, each marked with whether its model is real or still a stub."""
    by_id = {m["id"]: m for m in models_in_play()}
    out = []
    for check in CHECKS:
        model = by_id.get(check["id"])
        out.append({**check, "badge": model["badge"] if model else "RULE",
                    "version": model.get("version") if model else None})
    return out


def models_in_play() -> list[dict[str, Any]]:
    """The models, as the eval files report them, with the job each one does.

    Never a typed version or a typed metric: an unmeasured model would look measured.
    """
    out = []
    for row in aggregate.models():
        job = MODEL_JOBS.get(row["id"])
        if job is None:
            continue
        out.append({
            "id": row["id"],
            "inside": job["inside"],
            "job": job["job"],
            "job_bn": job["job_bn"],
            "version": row.get("version"),
            "headline": row.get("headline"),
            "badge": row.get("badge", "NO DATA"),
        })
    return out


def snapshot() -> dict[str, Any]:
    """The map: what is written, plus what the code says is actually there."""
    rs, ms = routers(), modules()
    return {
        "available": available(),
        "systems": list(SYSTEMS),
        "links": list(LINKS),
        "journey": list(JOURNEY),
        "models": models_in_play(),
        "checks": checks(),
        "risk_mw": {
            "routers": rs,
            "modules": ms,
            "counts": {
                "routers": len(rs),
                "routes": sum(len(r["routes"]) for r in rs),
                "modules": len(ms),
                "reaching_gemini": sum(1 for m in ms if "gemini" in m["reaches"]),
                "reaching_firestore": sum(1 for m in ms if "firestore" in m["reaches"]),
            },
        },
        "badge": "RULE",
        "source": "routes and modules read from risk-mw's own source",
    }
