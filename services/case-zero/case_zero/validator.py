"""Deterministic checks of a CaseDraft against the investigation's ledger.

Every account id, transaction id, agent id, Taka amount and clock time the case states must
have been returned by a tool call in this investigation, and every citation must exist.
Bangla digits, commas, lakh grouping, ৳/Tk/টাকা and k/হাজার/লাখ/কোটি are normalised first.
An App Safety verdict the customer's phone reported, or a CAUTION, is cited as no more than that.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

from case_zero.schemas import CaseDraft

BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
ACCT_RE = re.compile(r"acct_[A-Za-z0-9_]+(?:-\d{4})?")
TXN_RE = re.compile(r"txn_\d{6}")
AGENT_RE = re.compile(r"AG-\d{4}")
CALL_RE = re.compile(r"tc_\d{2}")
STAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}(?:T(\d{2}):(\d{2})(?::(\d{2}))?)?")
CLOCK_RE = re.compile(r"(?<![\d:])(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*([ap])\.?m\.?)?(?![\d:])", re.IGNORECASE)
TOKEN_ID_RE = re.compile(r"(?:\b(?:device|sim|nid|phone|onboarding_agent):\S+)|(?:\S*_\S*)|(?:\b(?=[0-9a-fA-F]*[a-fA-F])(?=[0-9a-fA-F]*\d)[0-9a-fA-F]{8,}\b)")
THOUSAND_PLUS_RE = re.compile(r"(\d+)\s*(?:হাজার|thousand)\s+(\d{1,3})(?!\d)")
PERCENT_RE = re.compile(r"\d+(?:\.\d+)?\s*%")
AMOUNT_RE = re.compile(
    r"(?<![\w.])(?P<cur>(?:Tk\.?|BDT|৳)\s*)?"
    r"(?P<num>\d{1,3}(?:,\d{2,3})+(?:\.\d+)?|\d+(?:\.\d+)?)"
    r"(?P<suf>\s*(?:k\b|K\b|thousand\b|হাজার|lakh\b|lac\b|লাখ|crore\b|কোটি))?"
    r"(?P<after>\s*(?:টাকা|taka\b|Taka\b))?"
    r"(?![\w.]*\d)"
)
MULTIPLIER = {"k": 1e3, "thousand": 1e3, "হাজার": 1e3, "lakh": 1e5, "lac": 1e5, "লাখ": 1e5, "crore": 1e7, "কোটি": 1e7}
SENTENCE_RE = re.compile(r"(?<=[.!?।])\s+")
DATE_RE = re.compile(r"(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)")
_MONTHS = ("jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
           "|জানুয়ারি|ফেব্রুয়ারি|মার্চ|এপ্রিল|মে|জুন|জুলাই|আগস্ট|আগষ্ট|অগাস্ট|সেপ্টেম্বর|অক্টোবর|নভেম্বর|ডিসেম্বর")
_EDGE = r"\w\u0980-\u09FF"
BAD_DATE_RE = re.compile(rf"(?<![{_EDGE}])(?:\d{{1,2}}\s*(?:{_MONTHS})|(?:{_MONTHS})\s*\d{{1,2}})(?![{_EDGE}])"
                         rf"|(?<![{_EDGE}])\d{{1,2}}[/.-]\d{{1,2}}[/.-]\d{{2,4}}(?![{_EDGE}])", re.IGNORECASE)


# Which tools can show each red flag in prompts.RED_FLAGS (seed_brief is code's tc_00: the seed's score, its
# reasons and the pattern leads). A flag stands only when it cites a successful call of one of its tools made
# for an account its text names; drop_unsupported_flags removes the rest and policy.escalation_flags counts
# only these. The SIM-swap and new-device signals of RF04 reach the agent only as score reasons and the phone's
# App Safety verdict, so RF04 is the one behavioural flag a score call can show.
ALL_TOOLS = frozenset({"seed_brief", "get_account", "score", "score_neighbours", "neighbours", "path_between", "shared_entities", "velocity_stats",
                       "agent_till_stats", "kyc_dupe_check", "known_fraud_proximity", "dormant_cohort", "device_safety", "common_point_of_compromise"})
FLAG_EVIDENCE: dict[str, frozenset[str]] = {
    "RF01": frozenset({"velocity_stats", "neighbours", "path_between"}),                      # rapid pass-through: what came in and went out, when
    "RF02": frozenset({"neighbours", "velocity_stats"}),                                      # fan-out: the receivers
    "RF03": frozenset({"velocity_stats", "neighbours", "path_between", "agent_till_stats"}),  # cash-out at a till shortly after receipt
    "RF04": frozenset({"seed_brief", "score", "device_safety"}),                              # takeover: SIM-swap / new-device reasons, the phone's verdict
    "RF05": frozenset({"dormant_cohort", "velocity_stats", "seed_brief"}),                    # woke from dormancy (seed_brief holds the seed's wake)
    "RF06": frozenset({"shared_entities", "kyc_dupe_check"}),                                 # shared device, SIM, NID or phone
    "RF07": frozenset({"shared_entities"}),                                                   # the onboarding agent shared by two or more accounts
    "RF08": frozenset({"known_fraud_proximity"}),
    "RF09": frozenset({"agent_till_stats"}),                                                  # repeat counterparties at a till
    "RF10": frozenset({"kyc_dupe_check", "shared_entities"}),                                 # NID or phone reused
    "RF11": frozenset({"neighbours", "path_between"}),                                        # the amounts and order of the payments
    "RF12": frozenset({"seed_brief", "score", "score_neighbours"}),                           # the model score (never counts for escalation)
    "RF16": ALL_TOOLS,                                                                        # an instruction can hide in any tool's output
}


@dataclass(frozen=True)
class Violation:
    code: str
    field: str
    detail: str


def _strip_non_amounts(text: str) -> str:
    text = text.translate(BN_DIGITS)
    for rx in (ACCT_RE, TXN_RE, AGENT_RE, CALL_RE, STAMP_RE, PERCENT_RE, TOKEN_ID_RE):
        text = rx.sub(" ", text)
    text = CLOCK_RE.sub(" ", text)
    return THOUSAND_PLUS_RE.sub(lambda m: str(int(m[1]) * 1000 + int(m[2])), text)


def amount_mentions(text: str) -> list[tuple[int, bool]]:
    """(value, marked) for each amount-like number; marked = it carries Tk/৳/টাকা or a k/lakh suffix."""
    found = []
    for m in AMOUNT_RE.finditer(_strip_non_amounts(text)):
        value = float(m["num"].replace(",", ""))
        suffix = (m["suf"] or "").strip().lower()
        marked = bool(m["cur"] or m["after"] or suffix)
        if suffix:
            value *= MULTIPLIER[suffix]
        is_year = not marked and m["num"].isdigit() and 1990 <= value <= 2100
        if marked or (value >= 100 and not is_year):
            found.append((int(round(value)), marked))
    return found


def normalise_amounts(text: str) -> set[int]:
    return {v for v, _ in amount_mentions(text)}


def _ids(text: str) -> set[str]:
    accts = set(ACCT_RE.findall(text))
    rest = ACCT_RE.sub(" ", text)
    return accts | set(TXN_RE.findall(rest)) | set(AGENT_RE.findall(rest))


def _clock(h: str, m: str, sec: str | None, ampm: str | None) -> str:
    hour = int(h)
    if ampm:
        hour = hour % 12 + (12 if ampm.lower() == "p" else 0)
    return f"{hour:02d}:{m}" + (f":{sec}" if sec else "")


def _clocks(text: str) -> set[str]:
    text = text.translate(BN_DIGITS)
    stamped = {_clock(h, m, sec, None) for h, m, sec in STAMP_RE.findall(text) if h}
    return stamped | {_clock(*c) for c in CLOCK_RE.findall(STAMP_RE.sub(" ", text))}


def _dates(text: str) -> set[str]:
    return set(DATE_RE.findall(text.translate(BN_DIGITS)))


def _bad_dates(text: str) -> list[str]:
    return [m.group(0) for m in BAD_DATE_RE.finditer(text.translate(BN_DIGITS))]


def _ledger_clocks(ledger) -> set[str]:
    stamps = set(ledger.times) | {ledger.as_of}
    return {t[11:16] for t in stamps if len(t) >= 16} | {t[11:19] for t in stamps if len(t) >= 19}


def _known_ids(ledger) -> set[str]:
    derived = {AGENT_RE.search(i).group(0) for i in ledger.ids if AGENT_RE.search(i)}
    return set(ledger.ids) | derived


def validate(draft: CaseDraft, ledger) -> list[Violation]:
    out: list[Violation] = []
    known_calls = {e["call_id"] for e in ledger.entries if e["ok"]}
    known_ids = _known_ids(ledger)
    cited_groups = [("members", m.acct_id, m.evidence) for m in draft.members] + [("excluded", x.acct_id, x.evidence) for x in draft.excluded] \
        + [("red_flags", f.code, f.evidence) for f in draft.red_flags] + [("timeline", t.ts, t.evidence) for t in draft.timeline]
    for field, label, evidence in cited_groups:
        if not evidence:
            out.append(Violation("missing_citation", field, f"{label}: no call id cited"))
        for call in evidence:
            if call not in known_calls:
                out.append(Violation("missing_citation", field, f"{label}: {call} is not a successful call in this investigation"))
    for m in draft.members + draft.excluded:
        cited_ids = {i for c in m.evidence if (e := ledger.entry(c)) for i in e["ids"]}
        if m.acct_id not in cited_ids:
            out.append(Violation("member_not_in_citation", "members", f"{m.acct_id} does not appear in {', '.join(m.evidence) or 'any call'}"))
    narratives = {"narrative_en": draft.narrative_en, "narrative_bn": draft.narrative_bn}
    texts = {**narratives, "red_flags": " ".join(f.text for f in draft.red_flags), "timeline": " ".join(t.text for t in draft.timeline),
             "excluded": " ".join(x.reason for x in draft.excluded), "limitations": draft.limitations}
    clocks = _ledger_clocks(ledger)
    minutes = {t[:16] for t in set(ledger.times) | {ledger.as_of}}
    for item in draft.timeline:
        if item.ts[:16] not in minutes:
            out.append(Violation("unknown_time", "timeline_ts", item.ts))
    bare_ok = ledger.amounts_bdt | getattr(ledger, "numbers", set())
    for field, text in texts.items():
        for i in sorted(_ids(text) - known_ids):
            out.append(Violation("unknown_id", field, i))
        for a, marked in sorted(set(amount_mentions(text))):
            if a not in (ledger.amounts_bdt if marked else bare_ok):
                out.append(Violation("unknown_amount", field, str(a)))
        for c in sorted(_clocks(text) - clocks):
            out.append(Violation("unknown_time", field, c))
        for d in sorted(_dates(text) - {t[:10] for t in set(ledger.times) | {ledger.as_of}}):
            out.append(Violation("unknown_date", field, d))
    for d in _bad_dates(draft.narrative_bn):  # the spec: Bangla dates as YYYY-MM-DD
        out.append(Violation("date_format", "narrative_bn", f"{d}: write dates as YYYY-MM-DD"))
    en, bn = narratives["narrative_en"], narratives["narrative_bn"]
    if _ids(en) != _ids(bn) or normalise_amounts(en) != normalise_amounts(bn):
        out.append(Violation("en_bn_mismatch", "narrative_bn", f"ids {sorted(_ids(en) ^ _ids(bn))} amounts {sorted(normalise_amounts(en) ^ normalise_amounts(bn))}"))
    return out + app_safety_overclaims(draft, ledger)


# App Safety evidence (2026-10-18). A device_safety verdict with source "phone" is the customer's phone's own
# report, which the bank did not re-run, and a CAUTION is a warning; both describe the phone now, not at any transfer.
# Seen live: a CAUTION the phone reported (REMOTE_CONTROL) became RF04 "remote control compromise" and "acct_rina was
# compromised via remote control" at 14:13. A red flag, timeline entry or narrative sentence about such a verdict says
# what the phone reported: no compromise word (not even denied), attributed to the phone, and no time in its clause. It
# is about the verdict when its citations are only such verdicts, when it names that account (or none) and uses a
# compromise word with no other basis, when it names that account and speaks of App Safety,
# or when it names no account but uses a word that names App Safety by itself ("a block of transfers" or
# "frozen for safety" is not about the phone). The other way round, what the bank's own check found (source server) is
# not called the phone's report: an end-to-end run on 2026-10-18 wrote "acct_rina's phone reported
# com.google.chromeremotedesktop (CAUTION)" for the bank's check, copying the phone example. The writer is sent back
# once; redact() then removes what still overclaims. Limitations may say what the report is not, so they are not checked.
def _bn(pattern: str) -> re.Pattern:
    return re.compile(unicodedata.normalize("NFC", pattern), re.IGNORECASE)   # য় and ড় compare the same however they were typed


OVERCLAIM_RE = _bn(r"(?<!point of )(?<!point_of_)compromis|\bhack|\bhijack|\bbreach|\btak(?:e|es|en|ing)\s+over\b|\btook\s+over\b|\btake-?over|remotely[\s-]+controll?ed|controll?ed\s+remotely|under\s+remote\s+control"
                   r"|হ্যাক|হাইজ্যাক|কম্প্রোমাইজ|আপস|বেহাত|দখল|টেকওভার|আক্রান্ত|নিয়ন্ত্রিত|নিয়ন্ত্রণ নে|নিয়ন্ত্রণ নিয়ে|নিয়ন্ত্রণে নে|নিয়ন্ত্রণে নিয়ে|নিয়ন্ত্রণ করা হ")
# Words that name App Safety by themselves (the facts' codes and glosses among them): enough even in a sentence that
# names no account.
APP_SAFETY_RE = _bn(r"remote[\s_-]*(?:control|access)|remotely|app[\s_-]*safety|device[\s_-]*safety|attestation|tamper"
                    r"|(?:see|control|share|sharing|record\w*)\s+(?:\w+\s+)?screen|screen[\s_]+capture|read(?:s|ing)?[\s_]+(?:\w+\s+)?(?:messages|sms|otp)"
                    r"|modified[\s_]+(?:\w+\s+)?app|changed\s+copy|fake[\s_]+(?:\w+[\s_]+)?app|pretend\w*\s+to\s+be\s+a\s+bank|loan[\s_]+app|unsafe[\s_]+phone"
                    r"|safety\s+settings|protections\s+are\s+off|malware|spyware|malicious|risky\s+app|suspicious\s+app"
                    r"|রিমোট|দূরবর্তী নিয়ন্ত্রণ|দূর থেকে নিয়ন্ত্রণ|অ্যাপ সেফটি|অ্যাপ সেইফটি|ডিভাইস সেফটি|ফোনের নিরাপত্তা|অ্যাপ নিরাপত্তা|স্ক্রিন নিয়ন্ত্রণ|স্ক্রিন দেখ|স্ক্রিন শেয়ার"
                    r"|ম্যালওয়্যার|ক্ষতিকর অ্যাপ|ঝুঁকিপূর্ণ অ্যাপ|মেসেজ পড়|বার্তা পড়|নকল অ্যাপ|ভুয়া অ্যাপ|ঋণের অ্যাপ|লোন অ্যাপ")
# Ordinary words that speak of App Safety only beside the account whose verdict it is: the verdicts as App Safety writes
# them (BLOCK, CAUTION; "a block of transfers" is not one), screen, and the Bangla for safety, warning and "from afar".
APP_SAFETY_WORD_RE = re.compile(r"\bBLOCK\b|\bCAUTION\b|" + unicodedata.normalize("NFC", r"(?i:screen|নিরাপত্তা|সতর্কতা|স্ক্রিন|সেফটি|সেইফটি|দূর থেকে)"))
# A compromise word with a basis of its own (a SIM swap, a new device, a PIN reset) is about that basis. Without one, in a
# case with such a verdict, it rests on the verdict: a console run on 2026-10-18 wrote "Due to active compromise
# indicators ..., freezing ... is proposed" in a narrative that named no SIM swap.
OTHER_BASIS_RE = _bn(r"\bsim\b|sim[\s-]*swap|new\s+device|pin\s+reset|\botp\b|সিম|নতুন ডিভাইস|পিন")
PHONE_RE = _bn(r"\bphone|ফোন")
REPORTED_RE = _bn(r"\breport|\bfound\b|জানি|রিপোর্ট|পাওয়া|শনাক্ত|ধরা পড়")
PHONE_REPORT_RE = _bn(r"phone\s+(?:had\s+|has\s+|itself\s+)?reported|reported\s+by\s+(?:\S+\s+){0,3}phone|phone's\s+own\s+report"
                      r"|ফোন(?:টি)?\s+জানি|ফোন(?:টি)?\s+(?:\S+\s+){0,3}রিপোর্ট কর")   # the phone as the one who reported it
CLAUSE_RE = re.compile(r";\s*")
# Order or cause put on the phone's state now: "funds were taken following remote access device risk", "because of the
# remote-control risk ... freeze" (end-to-end runs, 2026-10-18). Not "due to", which explains the verdict itself.
ORDER_RE = _bn(r"\b(?:after|afterwards|(?<!the\s)following|followed|before|prior\s+to|preceded|preceding|led\s+to|leading\s+to"
               r"|resulted\s+in|resulting\s+in|enabled|then|subsequently|during|while|at\s+the\s+time|because)\b"
               r"|পরে|পরপর|আগে|ফলে|কারণে|যেহেতু|পরবর্তীতে|এর পর|তারপর|চলাকালীন")
# What each phone fact says, for the example the writer is given (risk-mw's app.warnings.planner.PHONE_GLOSS, impersonal).
FACT_GLOSS = {"REMOTE_CONTROL": "an app that can control the screen", "SCREEN_CAPTURE": "something sharing the screen",
              "READS_MESSAGES": "an app that can read messages", "MODIFIED_APP": "a changed copy of the FinNest app",
              "FAKE_APP": "an app pretending to be a bank", "FAKE_LOAN_APP": "a loan app that can take contacts and photos",
              "UNSAFE_PHONE": "that its own protections are off"}
NO_COMPROMISE = "do not call it compromised, hacked or taken over, not even to deny it"
SAY_REPORTED = "say it is what the customer's phone reported"
NO_TIME = "give it no time or date: it describes the phone now, not the phone at a transfer"
NO_ORDER = "give it no order or cause (after, before, following, because): it describes the phone now, not what came before a transfer"
SAY_FOUND = "it is the bank's own App Safety Check (source server), not a report from the phone: say the check found it"


def _app_safety_verdicts(ledger) -> tuple[dict[str, list[dict]], dict[str, list[dict]]]:
    """Successful device_safety calls by account, as (weak, bank). A SAFE is in neither: it has nothing to overclaim (the
    app sends one with every score).
    - weak: a CAUTION, or a BLOCK the phone reported. An account the bank's own check found BLOCK or 'tampered' is left
      out: that verdict may support a takeover.
    - bank: a CAUTION, BLOCK or 'tampered' the bank's own check found (source server), which is not the phone's report."""
    weak: dict[str, list[dict]] = {}
    bank: dict[str, list[dict]] = {}
    strong: set[str] = set()
    for e in ledger.entries:
        d = e["data"] if e["ok"] and e["name"] == "device_safety" else None
        if not (isinstance(d, dict) and d.get("known")):
            continue
        acct = d.get("acct_id") or e["args"].get("acct_id")
        verdict, phone = d.get("verdict"), d.get("source") == "phone"
        if verdict == "CAUTION" or (verdict == "BLOCK" and phone):
            weak.setdefault(acct, []).append(e)
        elif verdict == "BLOCK" or d.get("attestation") == "tampered":
            strong.add(acct)
        if not phone and (verdict in ("CAUTION", "BLOCK") or d.get("attestation") == "tampered"):
            bank.setdefault(acct, []).append(e)
    return {a: es for a, es in weak.items() if a not in strong}, bank


def _resting_on(entries: list[dict], weak: dict[str, list[dict]]) -> list[dict]:
    """The entries, when every one of them is such a verdict (an item those verdicts alone back); otherwise none."""
    ids = {id(e) for es in weak.values() for e in es}
    return entries if entries and all(id(e) in ids for e in entries) else []


def _example(entry: dict) -> str:
    d = entry["data"]
    who, verdict = d.get("acct_id") or entry["args"].get("acct_id"), d.get("verdict")
    found = FACT_GLOSS.get(next(iter(d.get("facts") or ()), ""), "a risky app")
    return f"{who}'s phone reported {found} ({verdict})" if d.get("source") == "phone" else f"the App Safety Check found {found} on {who}'s phone ({verdict})"


def _speaks_of_app_safety(text: str, beside_account: bool) -> bool:
    return bool(APP_SAFETY_RE.search(text) or (beside_account and APP_SAFETY_WORD_RE.search(text)))


def _overclaim(text: str, weak: dict[str, list[dict]], bank: dict[str, list[dict]], resting: list[dict], resting_bank: list[dict]) -> tuple[list[dict], list[str]]:
    """The verdicts this text speaks of and what is wrong with how it does; ([], []) when it is not about one."""
    norm, named = unicodedata.normalize("NFC", text), set(ACCT_RE.findall(text))
    speaks = _speaks_of_app_safety(norm, bool(named)) or bool(OVERCLAIM_RE.search(norm) and not OTHER_BASIS_RE.search(norm))

    def about_in(verdicts: dict[str, list[dict]], alone: list[dict]) -> list[dict]:
        return alone or ([e for a in sorted((named or set(verdicts)) & verdicts.keys()) for e in verdicts[a]] if speaks else [])

    about, by_bank, problems = about_in(weak, resting), about_in(bank, resting_bank), []
    if about:
        if OVERCLAIM_RE.search(norm):
            problems.append(NO_COMPROMISE)
        if any(e["data"].get("source") == "phone" for e in about) and not (PHONE_RE.search(norm) and REPORTED_RE.search(norm)):
            problems.append(SAY_REPORTED)
        clauses = [c for c in CLAUSE_RE.split(norm) if resting or _speaks_of_app_safety(c, True)]
        if any(_clocks(c) or _dates(c) for c in clauses):
            problems.append(NO_TIME)
        if any(ORDER_RE.search(c) for c in clauses):
            problems.append(NO_ORDER)
    if by_bank and not any(e["data"].get("source") == "phone" for e in about) and PHONE_REPORT_RE.search(norm):
        problems.append(SAY_FOUND)
    return about or by_bank, problems


def app_safety_overclaims(draft: CaseDraft, ledger) -> list[Violation]:
    """Red flags, timeline entries and narrative sentences that say more than a phone-reported or CAUTION verdict shows,
    or call the bank's own check the phone's report."""
    weak, bank = _app_safety_verdicts(ledger)
    if not (weak or bank):
        return []
    units = []   # (field, label, text, cited entries, timeline entry)
    for f in draft.red_flags:
        backing = [e for c in f.evidence if (e := ledger.entry(c)) and e["ok"] and e["name"] in FLAG_EVIDENCE.get(f.code, ()) and _named(f.text) & _subjects(e["args"])]
        units.append(("red_flags", f"{f.code} ", f.text, backing, False))
    for t in draft.timeline:
        units.append(("timeline", f"{t.ts} ", t.text, [e for c in t.evidence if (e := ledger.entry(c)) and e["ok"]], True))
    for field in ("narrative_en", "narrative_bn"):
        units += [(field, "", s.strip(), [], False) for s in SENTENCE_RE.split(getattr(draft, field)) if s.strip()]
    out = []
    for field, label, text, cited, timeline in units:
        resting = _resting_on(cited, weak)
        about, problems = _overclaim(text, weak, bank, resting, _resting_on(cited, bank))
        fix = 'Write e.g. "{}", or remove it'
        if timeline and resting:
            problems.append(f"it is not a timeline event: {', '.join(e['call_id'] for e in resting)} has no time")
            fix = 'Leave it out of the timeline; say it in a red flag or the narrative, e.g. "{}"'
        if problems:
            e = about[0]
            d = e["data"]
            by = f"that {d.get('acct_id') or e['args'].get('acct_id')}'s phone reported" if d.get("source") == "phone" else "from the bank's App Safety Check"
            facts = f" ({', '.join(d.get('facts') or ())})" if d.get("facts") else ""
            what = "describes the phone now and is not a confirmed compromise" if any(e in es for es in weak.values()) else "describes the phone now"
            out.append(Violation("app_safety_overclaim", field, f'{label}"{text}": {e["call_id"]} is an App Safety {d.get("verdict")} {by}{facts}, '
                                 f'which {what}; {"; ".join(problems)}. ' + fix.format(_example(e))))
    return out


def _offending(sentence: str, bad: set[str]) -> bool:
    tokens = _ids(sentence) | {str(a) for a in normalise_amounts(sentence)} | _clocks(sentence) | _dates(sentence)
    return bool(tokens & bad) or ("date_format" in bad and bool(_bad_dates(sentence)))


def redact(draft: CaseDraft, violations: list[Violation], when: str = "after a failed retry") -> CaseDraft:
    """Drop sentences and items that carry a violation; say so in limitations."""
    bad = {v.detail for v in violations if v.code in ("unknown_id", "unknown_amount", "unknown_time", "unknown_date")}
    if any(v.code == "date_format" for v in violations):
        bad.add("date_format")
    bad_members = {v.detail.split(" ", 1)[0] for v in violations if v.code == "member_not_in_citation"}
    overclaimed = [v.detail for v in violations if v.code == "app_safety_overclaim"]   # each quotes the text it is about

    def overclaims(text: str) -> bool:
        return any(f'"{text.strip()}"' in d for d in overclaimed)

    def clean(text: str) -> str:
        return " ".join(s for s in SENTENCE_RE.split(text) if not _offending(s, bad) and not overclaims(s))

    def cited_ok(evidence: list[str]) -> bool:
        return bool(evidence) and not any(v.code == "missing_citation" and any(c in v.detail for c in evidence) for v in violations)

    note = f"{len(violations)} unsupported statement(s) removed {when}."
    return draft.model_copy(update={
        "narrative_en": clean(draft.narrative_en),
        "narrative_bn": clean(draft.narrative_bn),
        "members": [m for m in draft.members if m.acct_id not in bad_members and cited_ok(m.evidence)],
        "red_flags": [f for f in draft.red_flags if cited_ok(f.evidence) and not _offending(f.text, bad) and not overclaims(f.text)],
        "timeline": [t for t in draft.timeline if cited_ok(t.evidence) and not _offending(t.text, bad) and t.ts not in bad and not overclaims(t.text)],
        "excluded": [x for x in draft.excluded if cited_ok(x.evidence) and not _offending(x.reason, bad)],
        "limitations": " ".join(x for x in (" ".join(s for s in SENTENCE_RE.split(draft.limitations) if not _offending(s, bad)), note) if x),
    })


def _named(text: str) -> set[str]:
    """Account and agent ids a sentence names (a till's agent id too, so AG-0192 and acct_till_AG-0192 meet)."""
    return set(ACCT_RE.findall(text)) | set(AGENT_RE.findall(text))


def _subjects(args: dict) -> set[str]:
    """The accounts a call was made for: its account arguments, and agent_till_stats's agent and till."""
    accts = {args[k] for k in ("acct_id", "source", "target") if isinstance(args.get(k), str)}
    accts |= {a for a in args.get("acct_ids") or () if isinstance(a, str)}
    if isinstance(args.get("agent_id"), str):
        accts |= {args["agent_id"], f"acct_till_{args['agent_id']}"}
    return accts | {m.group(0) for a in accts if (m := AGENT_RE.search(a))}


AGENT_FLAGS = frozenset({"RF07", "RF09"})   # about an agent (onboarding, a till): the flag may name just the agent


def case_accounts(draft: CaseDraft, ledger) -> set[str]:
    """The accounts this case is about: its members and the seed."""
    return {m.acct_id for m in draft.members} | {ledger.seed}


def flag_supported(flag, ledger, case: set[str] | frozenset[str] = frozenset()) -> bool:
    """The flag cites a successful call of a tool that can show it (FLAG_EVIDENCE), made for an account it names.
    An agent-based flag (AGENT_FLAGS) may instead name an agent id that the cited call's output shows, when that
    call was made for an account in the case: "share onboarding agent AG-0014", cited to shared_entities over members."""
    tools, named = FLAG_EVIDENCE.get(flag.code, frozenset()), _named(flag.text)
    agents = set(AGENT_RE.findall(flag.text)) if flag.code in AGENT_FLAGS else set()
    for call in flag.evidence:
        e = ledger.entry(call)
        if not (e and e["ok"] and e["name"] in tools):
            continue
        subjects = _subjects(e["args"])
        if named & subjects:
            return True
        if agents & {m for i in e.get("ids", ()) for m in AGENT_RE.findall(i)} and subjects & case:
            return True
    return False


def _tools_text(code: str) -> str:
    tools = sorted(FLAG_EVIDENCE.get(code, ()))
    return "tool" if FLAG_EVIDENCE.get(code) == ALL_TOOLS else (", ".join(tools[:-1]) + " or " + tools[-1] if len(tools) > 1 else "".join(tools))


def flag_feedback(draft: CaseDraft, ledger) -> list[Violation]:
    """Why each unsupported red flag fails, for the writer's one retry (shared with the citation check)."""
    case, out = case_accounts(draft, ledger), []
    for f in draft.red_flags:
        if flag_supported(f, ledger, case):
            continue
        named = sorted(set(ACCT_RE.findall(f.text)))
        cite = f"cite a {_tools_text(f.code)} call made for {', '.join(named) or 'that account'}"
        why = cite if named else f"its text names no account; name the account it is about by its id and {cite}"
        out.append(Violation("unsupported_flag", "red_flags", f'{f.code} "{f.text}": {why}, or remove the flag'))
    return out


def drop_unsupported_flags(draft: CaseDraft, ledger) -> tuple[CaseDraft, list[str]]:
    """Remove red flags no fitting call backs, one limitations line each. Nothing to drop: the same draft."""
    case = case_accounts(draft, ledger)
    notes = [f"Red flag {f.code} removed: it cites no {_tools_text(f.code)} call made for an account it names."
             for f in draft.red_flags if not flag_supported(f, ledger, case)]
    if not notes:
        return draft, []
    kept = [f for f in draft.red_flags if flag_supported(f, ledger, case)]
    return draft.model_copy(update={"red_flags": kept, "limitations": " ".join(x for x in (draft.limitations, *notes) if x)}), notes
