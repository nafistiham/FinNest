"""App Safety adapter: the App Safety Check inside risk-mw.

Everything that decides lives in `bhorosha_app_safety_check` (rules, classifier, Play Integrity mapping, Gemini triage and
fusion); this module is the glue: artefacts from RISK_MW_APPSAFETY_ARTEFACTS_DIR (cached, optional, degrades to
rules-only the way `app.mule` and `app.ato` do), the Gemini call through `genai_client` under a wall-clock budget,
the Firestore report `appsafety_reports/{uid}_{ts}` (FR-6), and the latest verdict per uid that `/v1/risk/score`
reads so the transfer is held without the app having to resend the verdict (US-1 S3).
"""

from __future__ import annotations

import json
import logging
import secrets
import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Any

from app import genai_client
from app.contracts import AppSafetyContext, AppSafetyLatest, AppSafetyRequest, AppSafetyResponse, DemoIntegrityRequest, DemoIntegrityResponse, Finding, SafetyVerdict, ScoreRequest, UninstallTarget
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)
REPORTS_COLLECTION = "appsafety_reports"
GEMINI_TASK = "appsafety_triage"
GEMINI_ROLE = "volume"  # gemini-3.5-flash-lite per config/models.yaml; thinking minimal for latency
THINKING_LEVEL = "minimal"
VERDICT_RANK: dict[str, int] = {"SAFE": 0, "CAUTION": 1, "BLOCK": 2}
_LATEST_LIMIT = 1024
# Sized against Cloud Run's concurrency (80 request slots, of which the long-lived investigation streams hold some):
# a burst of checks with hits must not queue behind slow model calls, since the future's budget starts at submit.
_EXECUTOR = ThreadPoolExecutor(max_workers=20, thread_name_prefix="appsafety-gemini")
# Report writes leave the request path: a real 80-app phone spent about 1.4 s of its 5.5 s in the Firestore set
# (2026-10-17), and a write failure never failed the check anyway. Two workers keep a burst from piling up.
_WRITER = ThreadPoolExecutor(max_workers=2, thread_name_prefix="appsafety-report")
FIRESTORE_TIMEOUT_S = 3.0
GEMINI_HTTP_MIN_TIMEOUT_S = 10.0
_DEVICE = "device"


@lru_cache(maxsize=1)
def classifier():
    """The LightGBM permission classifier, or None (logged) when artefacts or the package are missing."""
    artefacts = get_settings().appsafety_artefacts_dir
    # deploy.sh always creates the directory and the Dockerfile always sets the variable, so "present" means the model
    # file is there, not that the directory exists.
    if artefacts is None or not (Path(artefacts) / "model.txt").is_file():
        log.info("RISK_MW_APPSAFETY_ARTEFACTS_DIR not set or no model.txt in it; app-safety classifier is off (rules only)")
        return None
    try:
        from bhorosha_app_safety_check.model import AppClassifier

        started = time.perf_counter()
        loaded = AppClassifier.load(Path(artefacts))
    except ImportError as exc:
        log.warning("bhorosha_app_safety_check unavailable (%s); app-safety classifier is off", exc)
        return None
    except Exception as exc:  # noqa: BLE001 - LightGBMError, KeyError, bad JSON: every load failure is rules-only, never a 500
        log.error("app-safety artefacts at %s could not be loaded: %s", artefacts, exc)
        return None
    log.info("app-safety classifier %s loaded from %s in %.0f ms", loaded.version, artefacts, (time.perf_counter() - started) * 1000)
    return loaded


def engine_version() -> str:
    loaded = classifier()
    try:
        from bhorosha_app_safety_check import __version__
    except ImportError:
        __version__ = "appsafety"
    return loaded.version if loaded is not None else f"{__version__}-rules-only"


def _classify(permissions: tuple[str, ...]) -> tuple[float, tuple[tuple[str, float], ...]]:
    prediction = classifier().predict(permissions)
    return prediction.probability, prediction.contributions


def _classify_many(apps: list[tuple[str, ...]]) -> list[tuple[float, tuple[tuple[str, float], ...]]]:
    """The whole phone in one go (pipeline.classifier_hits looks for this attribute on the classifier callable)."""
    return [(p.probability, p.contributions) for p in classifier().predict_many(apps)]


_classify.classify_many = _classify_many  # type: ignore[attr-defined]


def gemini_available(settings: Settings) -> bool:
    try:
        genai_client.select_backend(settings)
    except genai_client.GenAIDisabled:
        return False
    return True


def _gemini(system: str, contents: str, schema: type) -> Any:
    """One triage call under the wall-clock budget; anything that goes wrong propagates to the pipeline's fallback."""
    settings = get_settings()
    budget = settings.appsafety_gemini_timeout_s
    # The future timeout is what frees this request; the HTTP timeout is what frees the worker thread. The Gemini API
    # rejects deadlines under 10 s ("Minimum allowed deadline is 10s", seen 2026-10-16), so the HTTP side is never shorter.
    # By name: positionally, the timeout landed in thinking_level and every triage raised (since 6afa922, fixed 2026-10-18).
    future = _EXECUTOR.submit(
        genai_client.call, GEMINI_TASK, GEMINI_ROLE, contents, schema=schema, system=system,
        timeout_s=max(GEMINI_HTTP_MIN_TIMEOUT_S, budget), thinking_level=THINKING_LEVEL,
        max_output_tokens=settings.appsafety_max_output_tokens,
    )
    try:
        return future.result(timeout=budget).parsed
    except FutureTimeout as exc:
        future.cancel()
        raise TimeoutError(f"gemini triage exceeded {budget}s") from exc


def _gated_gemini(admit: Callable[[], bool] | None):
    """The triage call behind the quota: `admit` spends the caller's and the shared Gemini bucket at the moment the
    pipeline has decided it wants the model, so a check that never reaches the model never costs a slot. Refused,
    the pipeline answers from the rules (triage.GeminiDeclined), never 429."""
    if admit is None:
        return _gemini

    def call(system: str, contents: str, schema: type) -> Any:
        if not admit():
            from bhorosha_app_safety_check.triage import GeminiDeclined

            raise GeminiDeclined("gemini quota exhausted for this caller or for the instance")
        return _gemini(system, contents, schema)

    return call


# --- demo Play Integrity secret ------------------------------------------------
_DEMO_SECRET_LOCK = threading.Lock()
_GENERATED_DEMO_SECRET: str | None = None


def demo_secret(settings: Settings) -> str:
    """RISK_MW_DEMO_INTEGRITY_SECRET, or a random per-process secret when it is unset (review finding 2026-10-16: the
    old default lived in source). Tokens are minted by this same process, so the demo still works; they just do not
    survive a restart or reach another instance, which the one-line warning says."""
    global _GENERATED_DEMO_SECRET
    if settings.demo_integrity_secret:
        return settings.demo_integrity_secret
    with _DEMO_SECRET_LOCK:
        if _GENERATED_DEMO_SECRET is None:
            _GENERATED_DEMO_SECRET = secrets.token_urlsafe(32)
            log.warning("RISK_MW_DEMO_INTEGRITY_SECRET is not set: demo Play Integrity tokens are signed with a random per-instance secret and will not verify after a restart; scripts/deploy.sh sets one")
    return _GENERATED_DEMO_SECRET


# --- latest verdict per uid ---------------------------------------------------
# In-process and bounded, with the same honesty note as app.ato: one Cloud Run instance for the demo; across two
# instances the check and the score could land on different ones. The production answer is the Firestore report this
# module already writes, read back by the score route.
# Note for the demo: callers that send no X-Demo-User all share the uid "demo" (app/auth.py), so a BLOCK from one
# anonymous tester holds the next transfer of every other anonymous tester for the TTL. The app sends the persona uid.
@dataclass(frozen=True)
class Remembered:
    verdict: str
    risk: float
    at: float  # monotonic
    expires_at: float  # monotonic
    app_count: int
    flagged: frozenset[str]  # packages the verdict rests on
    attestation: str = "none"
    checked_at: str = ""  # ISO-8601 wall clock
    valid_until: str = ""
    response: AppSafetyResponse | None = None  # the answer that set this verdict; a kept BLOCK is re-served from it


_LATEST: OrderedDict[str, Remembered] = OrderedDict()
_LATEST_LOCK = threading.Lock()
LOWERING_LEVELS = frozenset({"device", "strong", "basic", "unbound", "none"})  # attestation levels whose SAFE may replace a BLOCK (none/unbound only in demo)


def recheck_can_lower(attestation: str, settings: Settings) -> bool:
    """Whether a re-check from a client at this attestation level may replace a stored BLOCK with less: a Play-recognised
    bound token always; none/unbound only in demo mode, where the build is not on Play yet."""
    return attestation in LOWERING_LEVELS and (attestation not in ("none", "unbound") or settings.demo_mode)


def recheck_lifts(verdict: str, resolution: str, attestation: str, settings: Settings) -> bool:
    """The contract's `recheck_lifts_block`, derived (review finding 2026-10-16: it was a constant True): a BLOCK the
    customer can act on (uninstall / fix the phone, then check again) from a client whose re-check would be accepted."""
    from bhorosha_app_safety_check.schema import RECHECK_RESOLUTIONS

    return verdict == "BLOCK" and resolution in RECHECK_RESOLUTIONS and recheck_can_lower(attestation, settings)


def remember_verdict(
    uid: str, verdict: str, risk: float, *, app_count: int, flagged: frozenset[str], attestation: str, settings: Settings,
    plausibility_failed: bool = False, response: AppSafetyResponse | None = None,
) -> bool:
    """Store this check as the uid's latest verdict. Returns False when a stored BLOCK was kept instead.

    A BLOCK is replaced by a lower verdict only by a check that could honestly show the flagged apps gone: a non-empty,
    plausible bundle (no IMPLAUSIBLE_BUNDLE / BUNDLE_SHRUNK finding) from an attested (or, in demo mode,
    unattested-but-recorded) client that no longer lists any flagged package. An empty or shrunken bundle, a
    failed/tampered/mismatched attestation or a bundle still carrying a flagged app keeps the BLOCK (review findings
    2026-10-16: the collector posts an empty bundle on a channel timeout; a 3-of-20-apps re-check scored CAUTION and
    used to replace the BLOCK in demo mode).
    """
    now = time.monotonic()
    ttl = settings.appsafety_block_ttl_s if verdict == "BLOCK" else settings.appsafety_verdict_ttl_s
    with _LATEST_LOCK:
        previous = _LATEST.get(uid)
        if previous is not None and previous.verdict == "BLOCK" and VERDICT_RANK[verdict] < VERDICT_RANK["BLOCK"] and now < previous.expires_at:
            honest = app_count > 0 and not plausibility_failed and recheck_can_lower(attestation, settings)
            if not honest:
                log.info("appsafety uid=%s keeps BLOCK: re-check not trustworthy (apps=%d plausible=%s attestation=%s)", uid, app_count, not plausibility_failed, attestation)
                return False
        wall = datetime.now(UTC)
        valid_until = response.valid_until if response is not None else (wall + timedelta(seconds=ttl)).isoformat()  # the same instant the caller was told
        _LATEST[uid] = Remembered(verdict, risk, now, now + ttl, app_count, flagged, attestation, wall.isoformat(), valid_until, response)
        _LATEST.move_to_end(uid)
        while len(_LATEST) > _LATEST_LIMIT:
            _LATEST.popitem(last=False)
    return True


def remembered(uid: str) -> Remembered | None:
    """The live entry for a uid, or None (an expired one is dropped on the way)."""
    with _LATEST_LOCK:
        entry = _LATEST.get(uid)
        if entry is None:
            return None
        if time.monotonic() > entry.expires_at:
            _LATEST.pop(uid, None)
            return None
        return entry


def latest_verdict(uid: str) -> tuple[str, float] | None:
    entry = remembered(uid)
    return None if entry is None else (entry.verdict, entry.risk)


def latest_for(uid: str, include_phone: bool = False, settings: Settings | None = None) -> AppSafetyLatest:
    """What the service holds for a uid, for Case Zero and the fraud desk (GET /v1/appsafety/latest/{uid}).

    A persona is found by its uid or its account id ("rina" / "acct_rina"): the app checks and scores by uid, Case Zero
    asks by account (2026-10-18). With include_phone, the phone's last valid report (what it sent with a payment)
    answers when it is stronger than this instance's own check or there is none, labelled source "phone"; the app's own
    fallback never asks for it, so the app never reads its own report back as the standing verdict."""
    from app import personas
    from app.warnings.signals import facts_from  # signals reads this module; importing it here keeps the two apart

    settings = settings or get_settings()
    ids = [i for i in dict.fromkeys((uid, personas.account_for(uid, settings), personas.uid_for_account(uid, settings))) if i]
    entry = next((e for e in map(remembered, ids) if e is not None), None)
    phone = next((c for c in map(carried_for, ids) if c is not None), None) if include_phone else None
    if entry is not None and (phone is None or VERDICT_RANK[entry.verdict] >= VERDICT_RANK[phone.verdict]):
        findings = entry.response.findings if entry.response is not None else ()
        return AppSafetyLatest(
            uid=uid, known=True, verdict=entry.verdict, risk_score=entry.risk, flagged_packages=tuple(sorted(entry.flagged)),  # type: ignore[arg-type]
            attestation=entry.attestation, checked_at=entry.checked_at, valid_until=entry.valid_until, source="server",
            facts=facts_from(((f.signal, f.severity) for f in findings), entry.attestation),
        )
    if phone is not None:
        return AppSafetyLatest(uid=uid, known=True, verdict=phone.verdict, risk_score=phone.risk, valid_until=phone.valid_until,  # type: ignore[arg-type]
                               source="phone", facts=phone.facts)
    return AppSafetyLatest(uid=uid, known=False)


def previous_app_count(uid: str) -> int | None:
    with _LATEST_LOCK:
        entry = _LATEST.get(uid)
        return entry.app_count if entry is not None else None


def forget_verdicts() -> None:
    """For tests and for an artefacts redeploy."""
    with _LATEST_LOCK:
        _LATEST.clear()


def _instant(value: str, what: str, uid: str) -> datetime | None:
    """An ISO-8601 instant from the phone's copy; a date without a zone is UTC, an unreadable one is no date (logged)."""
    if not value:
        return None
    try:
        at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        log.info("app_safety_bad_date uid=%s field=%s", uid, what)
        return None
    return at if at.tzinfo is not None else at.replace(tzinfo=UTC)


def _valid_until(ctx: AppSafetyContext, settings: Settings, uid: str) -> datetime | None:
    """valid_until, else checked_at plus the server's TTL for the verdict, else None; a date past the calendar's end is none."""
    until = _instant(ctx.valid_until, "valid_until", uid)
    if until is None and (checked := _instant(ctx.checked_at, "checked_at", uid)) is not None:
        ttl = settings.appsafety_block_ttl_s if ctx.verdict == "BLOCK" else settings.appsafety_verdict_ttl_s
        try:
            until = checked + timedelta(seconds=ttl)
        except OverflowError:
            log.info("app_safety_bad_date uid=%s field=checked_at (overflow)", uid)
            return None
    return until


def stale_reason(ctx: AppSafetyContext, now: datetime, settings: Settings, uid: str = "") -> str | None:
    """Why the phone's App Safety result no longer counts ("simulated", "expired"), or None while it does (D3, D4).

    It counts until the server's own valid_until; without one, until checked_at plus the server's TTL for that verdict
    (the same 15 min / 24 h this instance keeps its own verdicts for). With neither date it still counts: the phone's copy
    can only raise the verdict, so an undated one costs at most a cautious answer, and the log says so. A simulated
    verdict (a demo-token check) counts only while the service runs in demo mode."""
    if ctx.simulated_verdict and not settings.demo_mode:
        return "simulated"
    until = _valid_until(ctx, settings, uid)
    if until is None:
        log.info("app_safety_undated uid=%s verdict=%s source=%s", uid, ctx.verdict, ctx.source)
        return None
    return "expired" if now > until else None


def carried(ctx: AppSafetyContext | None, now: datetime, settings: Settings, uid: str = "") -> AppSafetyContext | None:
    """The phone's App Safety result if it still counts, else None (see stale_reason)."""
    if ctx is None or stale_reason(ctx, now, settings, uid) is not None:
        return None
    return ctx


# What the phone itself reported with its last score (2026-10-18), kept apart from _LATEST: a client
# never writes this service's standing verdict (with_latest_verdict, /v1/appsafety/latest). FNA's warning reads it when
# this instance holds nothing as strong (a restart, another instance, an expired entry), so the hold that the phone's copy
# caused can still say why.
@dataclass(frozen=True)
class Carried:
    """What the warning needs of the phone's report, and nothing the phone wrote: its verdict and its closed-set facts
    (final review, 2026-10-18: whole reports, up to 151 KiB each, could fill the single instance's memory)."""
    verdict: str
    facts: tuple[str, ...]
    expires_at: float  # monotonic
    risk: float = 0.0        # the phone's risk_score, for Case Zero (GET /v1/appsafety/latest?include_phone=true)
    valid_until: str = ""    # the same instant as expires_at, on the wall clock


_CARRIED: OrderedDict[str, Carried] = OrderedDict()
_CARRIED_LOCK = threading.Lock()
_CARRIED_LIMIT = 10_000


def remember_carried(uid: str, ctx: AppSafetyContext, settings: Settings | None = None) -> None:
    """Keep the phone's report until its own validity ends (valid_until, else checked_at plus the server's TTL, else the
    server's TTL from now), never longer than a BLOCK's day. One that is already over is not kept."""
    from app.warnings.signals import facts_from  # signals reads this module; importing it here keeps the two apart

    settings = settings or get_settings()
    wall = datetime.now(UTC)
    ttl = settings.appsafety_block_ttl_s if ctx.verdict == "BLOCK" else settings.appsafety_verdict_ttl_s
    until = _valid_until(ctx, settings, uid)
    seconds = min(float(settings.appsafety_block_ttl_s), (until - wall).total_seconds() if until is not None else float(ttl))
    if seconds <= 0:
        return
    facts = facts_from(((f.signal, f.severity) for f in ctx.findings), ctx.attestation)
    with _CARRIED_LOCK:
        _CARRIED[uid] = Carried(ctx.verdict, facts, time.monotonic() + seconds, risk=ctx.risk_score,
                                valid_until=(wall + timedelta(seconds=seconds)).isoformat())
        _CARRIED.move_to_end(uid)
        while len(_CARRIED) > _CARRIED_LIMIT:
            _CARRIED.popitem(last=False)


def carried_for(uid: str) -> Carried | None:
    """The phone's last report for a uid (its verdict and facts) while it is valid, else None (an expired one is dropped)."""
    with _CARRIED_LOCK:
        entry = _CARRIED.get(uid)
        if entry is None:
            return None
        if time.monotonic() > entry.expires_at:
            _CARRIED.pop(uid, None)
            return None
        return entry


def forget_carried() -> None:
    """For tests."""
    with _CARRIED_LOCK:
        _CARRIED.clear()


def with_latest_verdict(body: ScoreRequest, uid: str, settings: Settings) -> ScoreRequest:
    """Fuse the app-safety verdict into demo_flags.app_safety_verdict: the stronger of what this instance stored for
    the uid, the demo flag the request carries, and the App Safety Check result the phone sent along
    (`app_safety`). The phone's copy can only raise the verdict, never lower it."""
    verdict = body.demo_flags.app_safety_verdict
    latest = latest_verdict(uid)
    if latest is not None and VERDICT_RANK[latest[0]] > VERDICT_RANK[verdict]:
        verdict = latest[0]
    if body.app_safety is not None and VERDICT_RANK[body.app_safety.verdict] > VERDICT_RANK[verdict]:
        verdict = body.app_safety.verdict
    if verdict == body.demo_flags.app_safety_verdict:
        return body
    return body.model_copy(update={"demo_flags": body.demo_flags.model_copy(update={"app_safety_verdict": verdict})})


# --- the check ----------------------------------------------------------------


def require_attestation(settings: Settings) -> bool:
    return (not settings.demo_mode) if settings.appsafety_require_attestation is None else settings.appsafety_require_attestation


def _rows(body: AppSafetyRequest | DemoIntegrityRequest):
    """Contract rows -> package rows, by keyword, in one place: the token is minted over the same hash the check computes
    (review finding 2026-10-16: a second, positional copy could silently drift from this one)."""
    from bhorosha_app_safety_check import schema as s

    apps = tuple(
        s.AppRow(
            package=a.package, label=a.label, installer=a.installer, version=a.version, permissions=a.permissions,
            has_accessibility_service=a.has_accessibility_service, accessibility_enabled=a.accessibility_enabled,
            target_sdk=a.target_sdk, first_install=a.first_install, has_notification_listener=a.has_notification_listener,
            has_hce_service=a.has_hce_service, is_default_sms_app=a.is_default_sms_app, launcher_icon_hidden=a.launcher_icon_hidden,
            installer_declares_install_packages=a.installer_declares_install_packages,
        )
        for a in body.installed_apps
    )
    device = s.DeviceRow(
        overlay_holders=body.device.overlay_holders, device_admins=body.device.device_admins, dev_options=body.device.dev_options,
        adb=body.device.adb, rooted=body.device.rooted, play_protect=body.device.play_protect, sdk_int=body.device.sdk_int,
        default_sms_package=body.device.default_sms_package, nfc_default_payment_package=body.device.nfc_default_payment_package,
    )
    return apps, device


def _bundle(body: AppSafetyRequest, settings: Settings, uid: str = ""):
    from bhorosha_app_safety_check import integrity, schema as s

    apps, device = _rows(body)
    verdict = integrity.resolve(
        body.integrity_token, demo_secret=demo_secret(settings), demo_allowed=settings.demo_mode,
        package_name=settings.appsafety_package_name, google_enabled=settings.appsafety_google_integrity_enabled,
    )
    # The token is a signature over the evidence only if its requestHash equals the hash of what we actually received.
    level = integrity.attestation_level(verdict, integrity.bundle_hash(apps, device), expected_package=settings.appsafety_package_name, expected_cert_digests=tuple(settings.appsafety_cert_digests))
    return s.Bundle(apps=apps, device=device, integrity=verdict, attestation=level, require_attestation=require_attestation(settings), previous_app_count=previous_app_count(uid) if uid else None)


def _response(report, version: str, check_id: str, valid_until: datetime, *, lifts: bool) -> AppSafetyResponse:
    from bhorosha_app_safety_check.schema import SIGNAL_TITLE

    findings = tuple(
        Finding(
            package=h.package, signal=h.signal, severity=h.severity, evidence=h.evidence, explanation_bn=h.text_bn, explanation_en=h.text_en,
            title_bn=SIGNAL_TITLE.get(h.signal, ("", ""))[0], title_en=SIGNAL_TITLE.get(h.signal, ("", ""))[1], scope="device" if h.package == _DEVICE else "app",
        )
        for h in report.findings
    )
    verdict: SafetyVerdict = report.verdict  # type: ignore[assignment]
    return AppSafetyResponse(
        verdict=verdict, risk_score=report.risk, findings=findings, recommended_action=report.recommended_action,
        apps_to_uninstall=report.apps_to_uninstall, user_message_bn=report.user_message_bn, user_message_en=report.user_message_en,
        simulated_verdict=report.simulated_verdict, model_version=version, agrees_with_classifier=report.agrees_with_classifier,
        disagreement_reason=report.disagreement_reason, attestation=report.attestation, resolution=report.resolution,
        recheck_lifts_block=lifts, uninstall_targets=tuple(UninstallTarget(package=u.package, label=u.label, primary_signal=u.primary_signal, deep_link=u.deep_link) for u in report.uninstall_targets),
        check_id=check_id, valid_until=valid_until.isoformat(),
    )


def _write_report(uid: str, report, response: AppSafetyResponse, settings: Settings, doc_id: str) -> str | None:
    """FR-6: appsafety_reports/{uid}_{ts}. Logged when Firestore is off; a write failure never fails the check."""
    ts = datetime.now(UTC)
    doc = {
        "id": doc_id, "uid": uid, "at": ts.isoformat(), **response.model_dump(),
        "gemini_used": report.gemini_used, "gemini_error": report.gemini_error, "classifier_scores": report.classifier_scores,
        "gemini_reasons": list(report.gemini_reasons), "validation_notes": list(report.validation_notes),
        "prompt": report.prompt, "response": report.response, "service": settings.service_name,
    }
    if not settings.firestore_enabled:
        log.info("appsafety_report %s", json.dumps({k: v for k, v in doc.items() if k not in ("prompt", "response")}, ensure_ascii=False))
        return doc_id
    try:
        from app.audit import _firestore_client

        _firestore_client().collection(REPORTS_COLLECTION).document(doc_id).set(doc, timeout=FIRESTORE_TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001 - report persistence must not fail the request
        log.error("appsafety report write failed id=%s err=%s", doc_id, exc)
    return doc_id


def _kept_block(kept: Remembered, fresh: AppSafetyResponse, check_id: str, attestation: str, settings: Settings) -> AppSafetyResponse:
    """The answer when a stored BLOCK survives a re-check: the stored answer itself (its findings, its uninstall targets,
    its Bangla line) plus whatever the re-check found on top (review finding 2026-10-16: the kept answer used to carry
    UNINSTALL_AND_RECHECK with nothing to uninstall). The caller sees what the bank will act on."""
    stored = kept.response
    if stored is None:  # an entry remembered before this field existed: the best that can be said
        return fresh.model_copy(update={"verdict": kept.verdict, "risk_score": kept.risk, "recommended_action": "DELAY_24H", "resolution": "UNINSTALL_AND_RECHECK", "recheck_lifts_block": recheck_can_lower(attestation, settings)})
    seen = {(f.signal, f.package) for f in stored.findings}
    findings = tuple(stored.findings) + tuple(f for f in fresh.findings if (f.signal, f.package) not in seen)
    return stored.model_copy(update={
        "findings": findings, "attestation": attestation, "check_id": check_id, "valid_until": kept.valid_until,
        "simulated_verdict": fresh.simulated_verdict, "model_version": fresh.model_version,
        "recheck_lifts_block": recheck_lifts("BLOCK", stored.resolution, attestation, settings),
        "agrees_with_classifier": None, "disagreement_reason": "stored BLOCK kept: this re-check could not show the flagged apps gone",
    })


def check(body: AppSafetyRequest, uid: str, settings: Settings | None = None, admit: Callable[[], bool] | None = None) -> AppSafetyResponse:
    """One check. `admit` is the route's hook into the Gemini quota, consulted only when the pipeline wants the model."""
    settings = settings or get_settings()
    from bhorosha_app_safety_check import pipeline, schema as s

    bundle = _bundle(body, settings, uid)
    report = pipeline.run(
        bundle,
        classifier=_classify if classifier() is not None else None,
        gemini=_gated_gemini(admit) if gemini_available(settings) else None,
    )
    now = datetime.now(UTC)
    check_id = f"{uid}_{now.strftime('%Y%m%dT%H%M%S%fZ')}"
    ttl = settings.appsafety_block_ttl_s if report.verdict == "BLOCK" else settings.appsafety_verdict_ttl_s
    response = _response(report, engine_version(), check_id, now + timedelta(seconds=ttl), lifts=recheck_lifts(report.verdict, report.resolution, bundle.attestation, settings))
    flagged = frozenset(h.package for h in report.findings if h.package != _DEVICE and not h.soft)
    plausibility_failed = any(h.signal in s.PLAUSIBILITY_SIGNALS for h in report.findings)
    stored = remember_verdict(
        uid, response.verdict, response.risk_score, app_count=len(bundle.apps), flagged=flagged, attestation=bundle.attestation,
        settings=settings, plausibility_failed=plausibility_failed, response=response,
    )
    if not stored:
        kept = remembered(uid)
        if kept is not None:
            response = _kept_block(kept, response, check_id, bundle.attestation, settings)
    _WRITER.submit(_write_report, uid, report, response, settings, check_id)
    log.info(
        "appsafety uid=%s verdict=%s risk=%.2f attestation=%s findings=%d gemini=%s%s%s",
        uid, response.verdict, response.risk_score, bundle.attestation, len(response.findings), report.gemini_used,
        f" error={report.gemini_error}" if report.gemini_error else "", "" if stored else " kept_block=true",
    )
    return response


def mint_demo_token(body: DemoIntegrityRequest, settings: Settings) -> DemoIntegrityResponse:
    """Demo mode only: sign a synthetic Play Integrity verdict bound to the bundle the app is about to send, so the
    demo panel can play "clean phone", "screen controlled", "modded app" or "rooted phone" without holding the secret."""
    from bhorosha_app_safety_check import integrity

    apps, device = _rows(body)
    digest = integrity.bundle_hash(apps, device)
    token = integrity.sign_demo_verdict(
        demo_secret(settings), list(body.apps_detected), body.play_protect_verdict, request_hash=digest if body.bound else None,
        app_recognition=body.app_recognition, device_recognition=list(body.device_recognition), package_name=settings.appsafety_package_name,
        certificate_digests=list(settings.appsafety_cert_digests[:1]),  # a demo "genuine build" carries the configured digest, if any
    )
    return DemoIntegrityResponse(integrity_token=token, bundle_hash=digest, expires_in_s=integrity.DEMO_TOKEN_TTL_S)


def _warm_gemini(settings: Settings) -> None:
    started = time.perf_counter()
    try:
        genai_client.warm_client()  # the client and, on Vertex, the credentials: no tokens, no money
        if settings.appsafety_warm_up_call:
            from bhorosha_app_safety_check.triage import SYSTEM_INSTRUCTION, TriageVerdict

            genai_client.call("appsafety_warmup", GEMINI_ROLE, '{"apps_with_findings": [], "rule_hits": []}', schema=TriageVerdict,
                              system=SYSTEM_INSTRUCTION, thinking_level=THINKING_LEVEL, timeout_s=20.0, max_output_tokens=256)
        log.info("appsafety gemini warm-up ok in %.0f ms (model call: %s)", (time.perf_counter() - started) * 1000, settings.appsafety_warm_up_call)
    except Exception as exc:  # noqa: BLE001 - a cold model at start-up is a log line, not an outage
        log.warning("appsafety gemini warm-up failed: %s", exc.__class__.__name__)


def warm_up(settings: Settings | None = None, *, wait: bool = False) -> None:
    """Load the classifier now; warm the Gemini client in the background, so the first real check is not the slow one.

    Start-up does not wait for it (review finding 2026-10-16: the lifespan used to block up to 25 s and spend from the
    ledger on every instance start). By default no model call is made; RISK_MW_APPSAFETY_WARM_UP_CALL=true adds one
    background call (about $0.0005 on Flash-Lite, counted in the ledger like any other) for a demo whose first triage
    must not be the cold one. `wait` is for tests.
    """
    settings = settings or get_settings()
    classifier()
    if not gemini_available(settings):
        return
    future = _EXECUTOR.submit(_warm_gemini, settings)
    if wait:
        future.result(timeout=30)


def reset_cache() -> None:
    classifier.cache_clear()
    forget_verdicts()
