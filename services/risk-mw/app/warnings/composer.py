"""Apa's warning composer: the plan in, four streamed lines out, each checked before it is kept.

The `volume` role (gemini-3.5-flash-lite, minimal thinking, default temperature so the wording varies from call to call)
reads only the plan and writes A| T| R| X|, each with an English rendering after " || ". A line is validated the moment it
is complete. The repair policy never edits a word: a failed T or R is dropped; a failed A or X is replaced by the last line
for that role validated earlier in this call, else the model gets one regeneration at temperature 0. With neither A nor X
left there is no warning at all (the floor: earcon, vibration and the hold card), because a sentence assembled by code
would be a hand-written message under another name.
"""

from __future__ import annotations

import json
import logging
import re
import time
from collections.abc import Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field

from app import genai_client
from app.settings import Settings
from app.warnings.planner import Plan
from app.warnings.validator import ACTION_ROLES, ROLES, Check, validate, validate_en

log = logging.getLogger(__name__)

ROLE = "volume"
THINKING = "MINIMAL"
REGEN_TEMPERATURE = 0.0
MIN_REGEN_S = 0.5  # a regeneration needs at least this much of the deadline left
LINE = re.compile(r"^\W*([ATRX])\s*\|\s*(.*?)\s*(?:\|\|\s*(.*?))?\s*$")
UNTAGGED = re.compile(r"^\s*(.*?\S)\s*\|\|\s*(.*?)\s*$")  # "<bangla> || <english>" with its tag left off

# The persona, the voice and the action vocabulary stay fixed so Apa is recognisable; the words around them vary.
# The Bangla example is a non-native draft (NATIVE CHECK) and an example only, never a template.
SYSTEM_TEMPLATE = """You write the spoken warning of Apa, the calm, protective older-sister voice of {brand_en} ({brand_bn}), a Bangladeshi
mobile-money bank. The app has stopped or paused something risky: a phone call may be going on, or the app's own checks found
something wrong with the customer's phone, with how it is being used or with the payment. You are given a PLAN of facts
chosen by code. Use those facts and nothing else; you never see the call, the phone or the account.

Write exactly four lines, in this order, each on its own line, then stop:
A| attention and the primary action, at most 10 Bangla words; it must make sense alone
T| what is happening: the request on the call (the plan's tactics), what is wrong with the customer's phone or with how
   it is being used (the plan's phone facts and behaviour facts), or why the app held it (the plan's hold facts), at most
   12 Bangla words
R| the rule a real bank or office always follows (for behaviour facts, see below), at most 12 Bangla words
X| the primary action again with the safe path, at most 14 Bangla words
Begin every line with its letter and a bar ("A| ", "T| ", "R| ", "X| ") exactly as in the example. After the Bangla of
each line write " || " and a faithful English rendering of that line.

Every line speaks to the customer directly, in Bangla and in English: আপনি and আপনার in Bangla, "you" and "your" in
English, as in the examples. The plan's facts say "you" too. Never refer to the customer in the third person: no "she",
"her", "he", "his", "they" or "their" for the customer, no তার, তাঁর or উনার in place of আপনার, and never "the customer"
or "the user".

The Bangla is read aloud exactly as written:
- Bangla script only, Dhaka standard colloquial, the polite আপনি form. End every sentence with "।"; never use "?", "!" or ".".
- No digits, no number words, no amounts, times, durations or timers. Spell letters out: OTP is "ও-টি-পি", PIN is "পিন".
- Name nobody except the plan's address (start line A with it when there is one). Never repeat who the caller says they are
  as fact; speak about the call and the request ("ফোনে ... চাওয়া হচ্ছে"), never call the person a fraud.
- Mention only the secret, tactics, identity class, pending action, phone facts, behaviour facts and hold facts in the
  plan. Say a phone, behaviour or hold fact in plain everyday words, as its "means" says: never an app's name, an
  account, an amount, how it was found, a number or the word "system".
- If the plan has no tactics, ask, phone facts, behaviour facts or hold facts, describe nothing: line T says only that
  the app has paused this to check it, and line R that {brand_en} checks first when something looks unusual.
- When the plan has phone facts and no tactics or ask, line R says the first phone fact's rule (its "rule") in plain
  words; never say that a bank controls the customer's phone, messages or other apps.
- When the plan has hold facts, line T says the first hold fact's "means" and line R says its "rule", in plain words.
  Never say that the receiving account or anyone is a fraud, that money was stolen, or that someone took the customer's
  SIM; say only what the fact says.
- For behaviour facts, line R says that {brand_en} checks before money leaves when the phone is used unlike the customer's
  usual way, only when the plan has behaviour facts and no phone facts; never say a bank blocks, allows or judges a way of
  using the phone.
- Say the certainty with the plan's certainty words, never a number.
- Never mention police, an investigation, detection, a system, AI, recordings, scores, rings or anything else the bank
  knows beyond the plan's facts.
- Use only these actions: hang up (কলটা কেটে দিন), stop (একটু থামুন), don't say or type the code (কোডটা কাউকে বলবেন না),
  don't send (টাকা পাঠাবেন না), call {brand_en} from the app (অ্যাপের ‘{button_bn}’ বোতাম চাপুন), talk to family
  (পরিবারের কারও সাথে কথা বলে নিন); don't change the PIN now (এখন পিন বদল করবেন না), only when the pending action is
  pin_reset; check phone safety in the app (অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা দেখে নিন), only when it is the plan's safe
  path. Lines A and X carry the plan's primary action; X adds the plan's safe path.
- Never tell the customer to call or text a number, call back, go to an agent, move money to a safe account, keep
  talking, argue, install anything or open anything outside this app; never promise a refund or say the money is safe.
- If simple is true, use short, everyday words and repeat the action.
- Vary the wording from one warning to the next (the plan says which warning this is). Do not copy the examples.

Example, for a plan with an OTP request, a bank identity class, the certainty "likely" and the address রহিমা:
A| রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না। || Rahima, stop for a moment: don't tell anyone the code.
T| ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে। || The code that came in your message is being asked for on the phone.
R| আসল ব্যাংক বা {brand_bn} কখনো ফোনে এই কোড চায় না। || A real bank, or {brand_en}, never asks for this code on the phone.
X| কলটা কেটে দিন, তারপর অ্যাপের ‘{button_bn}’ বোতাম চাপুন। || Hang up, then press the app's '{button_en}' button.

Example, for a plan with the phone fact REMOTE_CONTROL, the pending action send_money, the certainty "likely" and no address:
A| একটু থামুন, এখন টাকা পাঠাবেন না। || Stop for a moment; don't send the money now.
T| আপনার ফোনের কোনো অ্যাপ স্ক্রিন দেখতে ও চালাতে পারে। || An app on your phone can see and control the screen.
R| {brand_bn} কখনো অন্য কাউকে আপনার স্ক্রিন দেখাতে বলে না। || {brand_en} never asks you to let anyone else see your screen.
X| টাকা পাঠাবেন না, তারপর অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা দেখে নিন। || Don't send the money, then open 'Phone safety' in the app.

Example, for a plan with the phone fact READS_MESSAGES, the pending action pin_reset, the certainty "likely" and no address:
A| একটু থামুন, এখন পিন বদল করবেন না। || Stop for a moment; don't change the PIN now.
T| আপনার ফোনের একটি অ্যাপ আপনার মেসেজ পড়তে পারে। || An app on your phone can read your messages.
R| {brand_bn} কখনো কারও কাছে মেসেজে আসা কোড চায় না। || {brand_en} never asks anyone for the code that comes in your messages.
X| এখন পিন বদল করবেন না, তারপর অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা দেখে নিন। || Don't change the PIN now, then open 'Phone safety' in the app.

Example, for a plan with the behaviour fact NOT_HER_PATTERN, the pending action send_money, the certainty "possible" and no address:
A| একটু থামুন, টাকাটা এখনই পাঠাবেন না। || Stop for a moment; don't send the money right now.
T| ফোনটা এখন আপনার চেনা ধরনে ব্যবহার হচ্ছে না। || The phone is not being used in your usual way right now.
R| ফোন অন্যভাবে ব্যবহার হলে {brand_bn} টাকা পাঠানোর আগে নিশ্চিত হয়ে নেয়। || When the phone is used differently, {brand_en} checks before money is sent.
X| টাকা পাঠাবেন না, তারপর অ্যাপের ‘{button_bn}’ বোতাম চাপুন। || Don't send the money, then press the app's '{button_en}' button.

Example, for a plan with the hold fact PAYEE_MULE, the pending action send_money, the certainty "likely" and no address:
A| এই টাকাটা এখন পাঠাবেন না, একটু থামুন। || Don't send this money now; stop for a moment.
T| এই টাকা পেলে প্রাপকের অ্যাকাউন্টটা টাকা পেয়েই সরিয়ে দেওয়ার মতো দেখায়। || With this money, the receiving account looks like one that passes money straight on.
R| এমন অ্যাকাউন্টে টাকা যাওয়ার আগে {brand_bn} নিশ্চিত হয়ে নেয়। || {brand_en} checks first before money goes to an account like this.
X| টাকা পাঠাবেন না, তারপর অ্যাপের ‘{button_bn}’ বোতাম চাপুন। || Don't send the money, then press the app's '{button_en}' button.

Example, for a plan with the hold fact SIM_CHANGED, the pending action pin_reset, the certainty "likely" and no address:
A| এখন পিন বদল করবেন না, একটু থামুন। || Don't change the PIN now; stop for a moment.
T| আপনার নম্বরের সিমটা সম্প্রতি বদলানো হয়েছে। || The SIM for your number was changed recently.
R| সিম সদ্য বদলালে {brand_bn} আগে নিশ্চিত হয়ে নেয়। || When a SIM has just been changed, {brand_en} checks first.
X| এখন পিন বদল করবেন না, তারপর অ্যাপের ‘{button_bn}’ বোতাম চাপুন। || Don't change the PIN now, then press the app's '{button_en}' button.

Example, for a plan with the hold fact CALL_ON, the pending action pin_reset, the certainty "likely" and no address:
A| একটু থামুন, কলটা কেটে দিন। || Stop for a moment; hang up the call.
T| আপনি ফোনে কথা বলতে বলতে পিন বদল করছেন। || You are changing your PIN while talking on the phone.
R| {brand_bn} কখনো ফোনে কথা বলার সময় পিন বদল করতে বলে না। || {brand_en} never asks anyone to change a PIN during a phone call.
X| কলটা কেটে দিন, তারপর অ্যাপের ‘{button_bn}’ বোতাম চাপুন। || Hang up the call, then press the app's '{button_en}' button.

Example, for a plan with the hold fact NEW_PAYEE_LARGE, the pending action send_money, the certainty "possible" and no address:
A| একটু থামুন, টাকাটা এখন পাঠাবেন না। || Stop for a moment; don't send the money now.
T| এঁকে আগে কখনো টাকা পাঠাননি, আর অঙ্কটাও স্বাভাবিকের চেয়ে বেশি। || You have never sent this person money, and the amount is more than usual.
R| নতুন কাউকে বড় অঙ্কের টাকা পাঠানোর আগে {brand_bn} নিশ্চিত হয়ে নেয়। || {brand_en} checks first before a large payment to someone new.
X| টাকা পাঠাবেন না, তারপর অ্যাপের ‘{button_bn}’ বোতাম চাপুন। || Don't send the money, then press the app's '{button_en}' button."""


def system_prompt(settings: Settings) -> str:
    """The composer's system instruction, naming the bank and the app's call button as settings give them."""
    return SYSTEM_TEMPLATE.format(brand_bn=settings.brand_bn, brand_en=settings.brand_en, button_bn=settings.call_button_bn,
                                  button_en=settings.call_button_en)


@dataclass(frozen=True)
class WarningLine:
    role: str
    text_bn: str
    text_en: str


@dataclass(frozen=True)
class Warning:
    lines: tuple[WarningLine, ...] = ()                 # A, T, R, X in that order, each validated; () is the floor
    dropped: tuple[tuple[str, str], ...] = ()           # (role, rule) for every line that failed
    regenerated: tuple[str, ...] = ()                   # roles that got their one regeneration
    timings_ms: Mapping[str, float] = field(default_factory=dict)
    reused: tuple[str, ...] = ()                        # roles filled by the call's last validated line
    cost_usd: float = 0.0

    @property
    def script_bn(self) -> str:
        return " ".join(line.text_bn for line in self.lines)

    @property
    def script_en(self) -> str:
        return " ".join(line.text_en for line in self.lines)


def prompt(plan: Plan, only: str | None = None) -> str:
    """The model's whole input besides the system prompt: the plan's facts (and, for a regeneration, the one line wanted)."""
    ask = f"Write only the {only} line, in the same format, and nothing else." if only else "Write the four lines."
    return f"PLAN:\n{plan.to_prompt()}\n\n{ask}"


def parse(chunks: Iterable[str], order: Sequence[str] = ROLES) -> Iterator[tuple[str, str, str]]:
    """(role, bangla, english) for each line as soon as it is complete; anything else the model writes is ignored. A line the
    model wrote without its tag but with its " || " rendering takes the next role of `order` (the prompt fixes the order; a
    regeneration asks for one role): Flash-Lite left the tags off on its first real run. Code reads the role, never a word."""
    buffer, seen = "", []

    def one(raw: str) -> tuple[str, str, str] | None:
        if m := LINE.match(raw):
            seen.append(m.group(1))
            return m.group(1), m.group(2), m.group(3) or ""
        if (m := UNTAGGED.match(raw)) and (role := next((r for r in order if r not in seen), None)):
            seen.append(role)
            return role, m.group(1), m.group(2)
        return None

    for chunk in chunks:
        buffer += chunk
        *complete, buffer = buffer.split("\n")
        for raw in complete:
            if item := one(raw):
                yield item
    if item := one(buffer):
        yield item


@dataclass
class _Spend:
    usd: float = 0.0


def _text_of(response: object) -> str:
    parts = [p for c in getattr(response, "candidates", None) or () for p in getattr(getattr(c, "content", None), "parts", None) or ()]
    return "".join(p.text for p in parts if isinstance(getattr(p, "text", None), str) and not getattr(p, "thought", None))


def _model_text(contents: str, settings: Settings, temperature: float | None, timeout_s: float, spend: _Spend | None = None) -> Iterator[str]:
    """Text from the volume role as it streams. Raises GenAIDisabled at once when Gemini is off or over its spend cap."""
    genai_client.select_backend(settings)
    from google.genai import types

    role, system = genai_client.roles()[ROLE], system_prompt(settings)
    worst = genai_client.worst_case_usd(role, contents, system, None, settings.warning_max_output_tokens)
    genai_client.fits(worst, settings)  # at once, so the composer knows before it asks; the reservation is taken when reading starts
    config = types.GenerateContentConfig(system_instruction=system, temperature=temperature,
                                         thinking_config=types.ThinkingConfig(thinking_level=types.ThinkingLevel(THINKING)),
                                         http_options=genai_client.http_options(timeout_s), max_output_tokens=settings.warning_max_output_tokens)

    def stream() -> Iterator[str]:
        # Reserved here, not above: a stream nobody reads never starts, so it must hold nothing (a generator's finally only
        # runs once it has started). A stream cut after its request left counts at its worst case.
        held = genai_client.Spend(worst, settings)
        started, usage, done = time.perf_counter(), None, False
        try:
            client = genai_client._client()
            held.sent = True
            for response in client.models.generate_content_stream(model=role.id, contents=contents, config=config):
                usage = getattr(response, "usage_metadata", None) or usage
                if text := _text_of(response):
                    yield text
            done = True
        finally:
            tokens_in, tokens_out = genai_client.billed_tokens(usage) if usage is not None else (0, 0)
            cost = genai_client.cost_usd(role, tokens_in, tokens_out) if done else (held.worst_usd if held.sent else 0.0)
            spent = held.settle(cost)
            if spend is not None:
                spend.usd += cost
            log.info(json.dumps({"task": "apa_warning", "model_id": role.id, "tokens_in": tokens_in, "tokens_out": tokens_out, "cost_usd": cost,
                                 "latency_ms": round((time.perf_counter() - started) * 1000, 1), "spent_usd": round(spent, 6)}))
    return stream()


def check(role: str, text_bn: str, text_en: str, plan: Plan, caller_turns: Sequence[str]) -> Check:
    """The Bangla line's nine rules, then its English rendering's."""
    result = validate(role, text_bn, plan, caller_turns, address=plan.address)
    return validate_en(role, text_en) if result.ok else result


def _last_good(last_good: Mapping[str, WarningLine] | Iterable[WarningLine] | None) -> dict[str, WarningLine]:
    if not last_good:
        return {}
    return dict(last_good) if isinstance(last_good, Mapping) else {line.role: line for line in last_good}


class _Run:
    """One generate() call's bookkeeping."""

    def __init__(self, plan: Plan, caller_turns: Sequence[str], settings: Settings) -> None:
        self.plan, self.caller_turns, self.settings = plan, tuple(caller_turns), settings
        self.started, self.deadline = time.perf_counter(), time.monotonic() + settings.warning_timeout_s
        self.kept: dict[str, WarningLine] = {}
        self.dropped: list[tuple[str, str]] = []
        self.timings: dict[str, float] = {"validate_max_ms": 0.0}
        self.spend, self.model_on = _Spend(), True

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def lines(self, contents: str, temperature: float | None, order: Sequence[str] = ROLES) -> Iterator[tuple[str, str, str]]:
        """Parsed lines from one model call; an outage or a cut stream just ends them (GenAIDisabled turns the model off)."""
        try:
            for item in parse(_model_text(contents, self.settings, temperature, max(self.left(), 0.1), self.spend), order):
                yield item
                if self.left() <= 0:
                    return
        except genai_client.GenAIDisabled:
            self.model_on = False
        except Exception as exc:  # noqa: BLE001 - a failed or cut stream keeps what validated; the repair policy does the rest
            log.warning("apa warning stream ended early: %s", exc.__class__.__name__)

    def offer(self, role: str, text_bn: str, text_en: str) -> bool:
        if role in self.kept or role not in ROLES:
            return False
        if role not in ACTION_ROLES and any(r == role for r, _ in self.dropped):
            return False  # a failed T or R is dropped for good, also when the model repeats the role
        t0 = time.perf_counter()
        result = check(role, text_bn, text_en, self.plan, self.caller_turns)
        self.timings["validate_max_ms"] = max(self.timings["validate_max_ms"], round((time.perf_counter() - t0) * 1000, 3))
        if not result.ok:
            self.dropped.append((role, str(result.rule)))
            return False
        self.kept[role] = WarningLine(role, text_bn, text_en)
        self.timings.setdefault("first_line_ms", round((time.perf_counter() - self.started) * 1000, 1))
        return True


def _composition(run: _Run, plan: Plan, last_good: Mapping[str, WarningLine] | Iterable[WarningLine] | None,
                 result: list[Warning]) -> Iterator[WarningLine]:
    """The one composition generate() and stream() share. Lines are handed over in A, T, R, X order as soon as every role
    before them is settled: kept, or a T or R that failed (dropped for good). A failed A or X waits for its repair, so after
    one nothing more is handed over until the end, and T or R never go out without an A or X (the floor). The Warning lands
    in `result` once the composition is done."""
    handed: set[str] = set()

    def ready(final: bool) -> Iterator[WarningLine]:
        if final and not set(ACTION_ROLES) & set(run.kept):
            return
        for role in ROLES:
            if role in handed:
                continue
            if role in run.kept:
                handed.add(role)
                yield run.kept[role]
            elif not final and not any(r == role for r, _ in run.dropped if r not in ACTION_ROLES):
                return

    if run.model_on:
        for role, bn, en in run.lines(prompt(plan), None):
            if run.offer(role, bn, en):
                yield from ready(final=False)
    earlier, reused, regenerated = _last_good(last_good), [], []
    for role in ACTION_ROLES:
        if role in run.kept:
            continue
        prior = earlier.get(role)
        if prior is not None and check(role, prior.text_bn, prior.text_en, plan, run.caller_turns).ok:
            run.kept[role] = prior
            reused.append(role)
        elif run.model_on and run.left() >= MIN_REGEN_S:
            regenerated.append(role)
            for got, bn, en in run.lines(prompt(plan, only=role), REGEN_TEMPERATURE, order=(role,)):
                if got == role:
                    run.offer(role, bn, en)
                    break
    yield from ready(final=True)
    lines = tuple(run.kept[r] for r in ROLES if r in run.kept) if set(ACTION_ROLES) & set(run.kept) else ()
    run.timings["total_ms"] = round((time.perf_counter() - run.started) * 1000, 1)
    run.timings.setdefault("first_line_ms", run.timings["total_ms"])
    result.append(Warning(lines=lines, dropped=tuple(run.dropped), regenerated=tuple(regenerated), timings_ms=dict(run.timings),
                          reused=tuple(reused), cost_usd=round(run.spend.usd, 6)))


def generate(plan: Plan, caller_turns: Sequence[str], settings: Settings,
             last_good: Mapping[str, WarningLine] | Iterable[WarningLine] | None = None, offline: bool = False) -> Warning:
    """Apa's warning for this plan: streamed, validated line by line, repaired without editing a word (see the module doc).

    `caller_turns` is only for the parroting check; the model never sees it. `last_good` holds lines validated earlier in
    this call (by role). `offline` skips the model (over quota): the call's last good lines, or the floor.
    """
    run, result = _Run(plan, caller_turns, settings), []
    run.model_on = not offline
    for _ in _composition(run, plan, last_good, result):
        pass
    return result[0]


def stream(plan: Plan, caller_turns: Sequence[str], settings: Settings,
           last_good: Mapping[str, WarningLine] | Iterable[WarningLine] | None = None, offline: bool = False) -> Iterator[WarningLine]:
    """generate()'s lines, each handed over as soon as it is validated and every role before it is settled: the same lines
    in the same order, so the cold path can speak A while the model is still writing T, R and X."""
    run = _Run(plan, caller_turns, settings)
    run.model_on = not offline
    yield from _composition(run, plan, last_good, [])
