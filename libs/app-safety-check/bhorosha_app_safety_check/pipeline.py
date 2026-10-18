"""One check end to end, with no I/O of its own: rules -> classifier -> Play Integrity -> Gemini -> fused report.

The adapter in risk-mw supplies the classifier (loaded artefacts) and a `gemini` callable; the eval supplies a
fake or the real thing; the tests supply nothing and get the deterministic path. Decisions:
- no rule or classifier hit -> SAFE without a model call (a clean device cannot become a CAUTION by accident);
- Gemini may raise to CAUTION, clear soft hits, never lower a hard hit, never produce a BLOCK by itself;
- a model failure with a hard hit present -> at least CAUTION with the generic Bangla message; with only
  soft hits the deterministic SAFE stands, because nothing hard was found and a model outage must not frighten everyone.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass, field

from bhorosha_app_safety_check import rules, schema as s, scoring, triage
from bhorosha_app_safety_check.schema import Bundle, Hit
from bhorosha_app_safety_check.triage import TriageVerdict

log = logging.getLogger(__name__)
GeminiCall = Callable[[str, str, type[TriageVerdict]], TriageVerdict]
Classifier = Callable[[tuple[str, ...]], tuple[float, tuple[tuple[str, float], ...]]]  # permissions -> (p, contributions)
BLOCK_ACTIONS = ("DELAY_24H", "BLOCK_AND_CALL_BANK")
CAUTION_ACTIONS = ("PROCEED_WITH_OTP", "DELAY_24H")


@dataclass(frozen=True)
class UninstallTarget:
    package: str
    label: str
    primary_signal: str
    deep_link: str  # Android Settings ACTION_APPLICATION_DETAILS_SETTINGS data URI


@dataclass(frozen=True)
class Report:
    verdict: str
    risk: float
    findings: tuple[Hit, ...]
    recommended_action: str
    apps_to_uninstall: tuple[str, ...]
    user_message_bn: str
    user_message_en: str
    simulated_verdict: bool
    agrees_with_classifier: bool | None
    disagreement_reason: str
    gemini_used: bool
    gemini_error: str | None
    classifier_scores: dict[str, float] = field(default_factory=dict)
    gemini_reasons: tuple[dict, ...] = ()
    validation_notes: tuple[str, ...] = ()
    prompt: str = ""
    response: str = ""
    resolution: str = "NONE"  # schema.Resolution: what lifts the verdict
    uninstall_targets: tuple[UninstallTarget, ...] = ()
    attestation: str = "none"


SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}


def _sorted(hits: tuple[Hit, ...]) -> tuple[Hit, ...]:
    return tuple(sorted(hits, key=lambda h: (SEVERITY_ORDER[h.severity], h.soft, h.package)))


STEP_UP_ONLY_SIGNALS = frozenset({"DEVICE_ROOTED", "DEVICE_INTEGRITY_FAILED", "UNATTESTED_CLIENT"})  # nothing Rina can fix on the spot: the OTP is the way


def resolution_for(verdict: str, hits: tuple[Hit, ...], uninstall: tuple[str, ...]) -> str:
    """What lifts the verdict, as one next step the panel can render. Never a step the customer cannot take."""
    if verdict == "SAFE":
        return "NONE"
    signals = {h.signal for h in hits if not h.soft}
    if "CLIENT_TAMPERED" in signals:
        return "REINSTALL_FROM_PLAY"
    if signals & s.CALL_BANK_SIGNALS:
        return "CALL_BANK"
    if uninstall:
        return "UNINSTALL_AND_RECHECK"
    fixable = (signals & s.DEVICE_LEVEL_SIGNALS) - STEP_UP_ONLY_SIGNALS
    if fixable or "DEVICE_ADMIN" in signals:
        return "FIX_PHONE_AND_RECHECK"
    return "NONE"  # a step-up (OTP) is all that is asked; nothing to fix or wait for


def action_for(verdict: str, hits: tuple[Hit, ...], uninstall: tuple[str, ...]) -> str:
    """BLOCK_AND_CALL_BANK when the client or the screen itself is compromised; DELAY_24H otherwise (an uninstall and a
    clean re-check lift it earlier, see resolution); PROCEED_WITH_OTP for CAUTION; PROCEED for SAFE."""
    if verdict == "BLOCK":
        return "BLOCK_AND_CALL_BANK" if {h.signal for h in hits if not h.soft} & s.CALL_BANK_SIGNALS else "DELAY_24H"
    return s.VERDICT_ACTION[verdict]


def uninstall_targets(bundle: Bundle, hits: tuple[Hit, ...], uninstall: tuple[str, ...]) -> tuple[UninstallTarget, ...]:
    by_package = {app.package: app for app in bundle.apps}
    primary: dict[str, str] = {}
    for h in _sorted(hits):
        if h.package in uninstall and h.package not in primary:
            primary[h.package] = h.signal
    return tuple(UninstallTarget(p, by_package[p].name if p in by_package else p, primary.get(p, "OTHER"), f"package:{p}") for p in uninstall)


def classifier_hits(bundle: Bundle, classifier: Classifier | None) -> tuple[tuple[Hit, ...], dict[str, tuple[float, tuple[tuple[str, float], ...]]]]:
    """CLASSIFIER_HIGH per app above the threshold; soft when the app came through a trusted store."""
    if classifier is None:
        return (), {}
    hits: list[Hit] = []
    scores: dict[str, tuple[float, tuple[tuple[str, float], ...]]] = {}
    # Declared services reach the model as pseudo-permissions, the way the LAMDA trainer encodes them.
    features = {
        app.package: app.permissions + (("android.permission.BIND_ACCESSIBILITY_SERVICE",) if app.has_accessibility_service else ()) + (("android.permission.BIND_NOTIFICATION_LISTENER_SERVICE",) if app.has_notification_listener else ())
        for app in bundle.apps
    }
    predicted: dict[str, tuple[float, tuple[tuple[str, float], ...]]] = {}
    many = getattr(classifier, "classify_many", None)
    if many is not None and bundle.apps:
        # One call for the whole phone (the serving classifier batches into two booster calls); per app only as a fallback.
        try:
            predicted = dict(zip(features, many(list(features.values())), strict=True))
        except Exception as exc:  # noqa: BLE001 - fall back to scoring one app at a time
            log.warning("batch classifier failed (%s); scoring per app", exc.__class__.__name__)
            predicted = {}
    for app in bundle.apps:
        try:
            p, contributions = predicted[app.package] if app.package in predicted else classifier(features[app.package])
        except Exception as exc:  # noqa: BLE001 - a scoring failure loses one signal, never the check
            log.warning("classifier failed for %s: %s", app.package, exc.__class__.__name__)
            continue
        scores[app.package] = (p, contributions)
        if p >= s.CLASSIFIER_HIGH_THRESHOLD:
            # Hard on a sideloaded unknown app; soft on anything from a store or from a known publisher (a sideloaded
            # bKash is still bKash: the classifier's permission pattern cannot distinguish it, Gemini and the rules can).
            hard = s.is_sideloaded(app.installer) and app.package not in s.KNOWN_PUBLISHER_PACKAGES
            bn, en = s.SIGNAL_TEXT["CLASSIFIER_HIGH"]
            hits.append(Hit(
                "CLASSIFIER_HIGH", "high" if hard else "low", app.package,
                f"p={p:.2f} top={[name for name, _ in contributions]} installer={app.installer or 'unknown'} known_publisher={app.package in s.KNOWN_PUBLISHER_PACKAGES}",
                bn.format(app=app.name), en.format(app=app.name), soft=not hard, contributions=contributions,
            ))
    return tuple(hits), scores


def _names(bundle: Bundle, packages: tuple[str, ...]) -> list[str]:
    by_package = {app.package: app.name for app in bundle.apps}
    return [by_package.get(p, p) for p in packages]


def _uninstall_candidates(hits: tuple[Hit, ...]) -> tuple[str, ...]:
    return tuple(sorted({h.package for h in hits if h.package != s.DEVICE and not h.soft and s.SEVERITY_WEIGHT[h.severity] >= s.SEVERITY_WEIGHT["medium"]}))


def _join_bn(names: list[str]) -> str:
    return names[0] if len(names) == 1 else " ও ".join(names)


def _join_en(names: list[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def _template_messages(verdict: str, apps: list[str], hits: tuple[Hit, ...] = ()) -> tuple[str, str]:
    """The customer line. Names the app(s) when there are any to remove; otherwise the strongest device-level finding
    speaks for itself (a rooted phone, a tampered client), which is better than "an unfamiliar app"."""
    if verdict == "SAFE":
        return s.VERDICT_TEXT[("SAFE", False)]
    if not apps:
        strongest = next((h for h in _sorted(hits) if not h.soft), None)
        if strongest is not None and strongest.package == s.DEVICE:
            return strongest.text_bn, strongest.text_en
        return s.GENERIC_CAUTION_TEXT
    bn, en = s.VERDICT_TEXT[(verdict, len(apps) > 1)]
    return bn.format(apps=_join_bn(apps)), en.format(apps=_join_en(apps))


def _deterministic(bundle: Bundle, hits: tuple[Hit, ...], score: scoring.Score, scores: dict, *, gemini_used: bool, error: str | None, generic: bool = False) -> Report:
    hits = _sorted(hits)
    uninstall = _uninstall_candidates(hits) if score.verdict != "SAFE" else ()
    if generic:
        bn, en = s.GENERIC_CAUTION_TEXT
    else:
        bn, en = _template_messages(score.verdict, _names(bundle, uninstall), hits)
    return Report(
        verdict=score.verdict, risk=score.risk, findings=hits, recommended_action=action_for(score.verdict, hits, uninstall),
        apps_to_uninstall=uninstall, user_message_bn=bn, user_message_en=en, simulated_verdict=bundle.integrity.simulated,
        agrees_with_classifier=None, disagreement_reason="", gemini_used=gemini_used, gemini_error=error,
        classifier_scores={k: v[0] for k, v in scores.items()}, resolution=resolution_for(score.verdict, hits, uninstall),
        uninstall_targets=uninstall_targets(bundle, hits, uninstall), attestation=bundle.attestation,
    )


def _explain_with_gemini(hits: tuple[Hit, ...], g: TriageVerdict, notes: list[str]) -> tuple[Hit, ...]:
    """Swap a finding's template copy for Gemini's explanation when the model wrote one for that signal on that app.

    The evidence string stays deterministic; only the customer-facing sentence changes, and only when the reason
    names the same signal and package (or the device). That is how "Gemini explains" becomes visible in the panel.
    """
    by_key = {(r.signal, r.package or s.DEVICE): r for r in g.reasons if r.explanation_bn.strip() and r.explanation_en.strip()}
    if not by_key:
        return hits
    out, swapped = [], 0
    for h in hits:
        r = by_key.get((h.signal, h.package))
        if r is None:
            out.append(h)
            continue
        out.append(Hit(h.signal, h.severity, h.package, h.evidence, r.explanation_bn.strip(), r.explanation_en.strip(), h.soft, h.contributions))
        swapped += 1
    if swapped:
        notes.append(f"{swapped} finding explanation(s) written by Gemini")
    return tuple(out)


def fuse(bundle: Bundle, hits: tuple[Hit, ...], full: scoring.Score, hard: scoring.Score, g: TriageVerdict, scores: dict, notes: list[str], prompt: str, response: str) -> Report:
    """Combine the rule floor with a validated Gemini verdict."""
    verdict = scoring.max_verdict(hard.verdict, scoring.min_verdict(g.verdict, "CAUTION"))
    gemini_risk = g.risk_score / 100
    risk = round(max(hard.risk, gemini_risk if verdict == "BLOCK" else min(gemini_risk, scoring.SOFT_CAP)), 3)
    if verdict == "BLOCK":
        risk = max(risk, s.BLOCK_THRESHOLD)
    elif verdict == "CAUTION":
        risk = max(risk, s.CAUTION_THRESHOLD)
    else:
        risk = min(risk, s.CAUTION_THRESHOLD - 0.001)
    lowered = s.VERDICT_RANK[verdict] < s.VERDICT_RANK[full.verdict]
    raised = s.VERDICT_RANK[verdict] > s.VERDICT_RANK[full.verdict]
    soft_present = any(h.soft for h in hits)
    overruled = s.VERDICT_RANK[g.verdict] < s.VERDICT_RANK[verdict]  # Gemini wanted less than the floor allows
    agrees = g.agrees_with_classifier and not lowered and not overruled
    reason = g.disagreement_reason or ("Gemini cleared a soft flag" if lowered else "")
    if overruled:
        reason = f"Gemini said {g.verdict}; overruled by the rule floor {hard.verdict}" + (f" ({reason})" if reason else "")
    if lowered and not soft_present:
        notes.append("verdict lowered without soft hits")  # cannot happen by construction (the floor holds every non-soft hit); a tripwire for the audit log
    uninstall: tuple[str, ...] = ()
    if verdict != "SAFE":
        # Gemini may add to the uninstall list only from the apps code found a hard finding on: the floor protects the
        # verdict, this protects the one button the panel renders (without it the model could
        # put WhatsApp on the list and the demo ends with Rina uninstalling it).
        hard_packages = {h.package for h in hits if not h.soft and h.package != s.DEVICE}
        model_picks = [p for p in g.apps_to_uninstall if p in hard_packages]
        if len(model_picks) != len(g.apps_to_uninstall):
            notes.append(f"apps_to_uninstall: {len(g.apps_to_uninstall) - len(model_picks)} package(s) without a hard finding dropped")
        uninstall = tuple(sorted(set(model_picks) | set(_uninstall_candidates(hits))))
    # The action is code's, not the model's: an app-caused BLOCK is DELAY_24H with an uninstall-and-re-check way out,
    # BLOCK_AND_CALL_BANK is reserved for a compromised client or screen; Gemini may only choose between the two
    # CAUTION actions.
    action = action_for(verdict, hits, uninstall)
    if verdict == "CAUTION" and g.recommended_action in CAUTION_ACTIONS:
        action = g.recommended_action
    names = _names(bundle, uninstall)
    bn, en = g.user_message_bn.strip(), g.user_message_en.strip()
    if overruled:
        # Gemini argued for less than the floor allows; its reassurance must not ship under a hold.
        notes.append("Gemini overruled; template message used")
        bn, en = _template_messages(verdict, names, hits)
    elif verdict != "SAFE" and not names:
        # Device-only verdict (rooted, integrity, unattested): the finding's own line carries the one action the panel
        # shows; Gemini's free text has contradicted the action here ("call the bank" under an OTP step-up).
        notes.append("device-level verdict; finding text used")
        bn, en = _template_messages(verdict, names, hits)
    elif verdict != "SAFE" and names and not any(n in bn for n in names) and not any(p in bn for p in uninstall):
        notes.append("user_message_bn did not name the app; template used")
        bn, en = _template_messages(verdict, names, hits)
    elif len(bn) > triage.MAX_MESSAGE_CHARS or len(bn.split("।")) > 3:
        notes.append("user_message_bn too long for the panel; template used")
        bn, en = _template_messages(verdict, names, hits)
    if raised:
        notes.append("Gemini raised the verdict")
    findings = _sorted(hits if overruled else _explain_with_gemini(hits, g, notes))
    return Report(
        verdict=verdict, risk=risk, findings=findings, recommended_action=action, apps_to_uninstall=uninstall,
        user_message_bn=bn, user_message_en=en, simulated_verdict=bundle.integrity.simulated,
        agrees_with_classifier=agrees, disagreement_reason=reason, gemini_used=True, gemini_error=None,
        classifier_scores={k: v[0] for k, v in scores.items()},
        gemini_reasons=tuple(r.model_dump() for r in g.reasons), validation_notes=tuple(notes), prompt=prompt, response=response,
        resolution=resolution_for(verdict, findings, uninstall), uninstall_targets=uninstall_targets(bundle, findings, uninstall), attestation=bundle.attestation,
    )


def run(bundle: Bundle, classifier: Classifier | None = None, gemini: GeminiCall | None = None) -> Report:
    hits = rules.evaluate(bundle)
    c_hits, scores = classifier_hits(bundle, classifier)
    hits = hits + c_hits
    full = scoring.combine(hits)
    hard = scoring.floor(hits)
    # Gemini earns its 2 s when there is something to arbitrate: any hard hit, or a soft classifier flag (the judge
    # case). A phone whose only hits are soft reach flags on well-known apps is SAFE by construction and
    # answers at once; real Bangladeshi phones (bKash, imo, Facebook Lite, SHAREit) look like that.
    worth_a_call = any(not h.soft or h.signal == "CLASSIFIER_HIGH" for h in hits)
    if not hits or gemini is None or not worth_a_call:
        return _deterministic(bundle, hits, full, scores, gemini_used=False, error=None)
    prompt = triage.evidence_bundle(bundle, hits, scores)
    try:
        raw = gemini(triage.SYSTEM_INSTRUCTION, prompt, TriageVerdict)
        if not isinstance(raw, TriageVerdict):
            raise TypeError(f"gemini returned {type(raw).__name__}, not TriageVerdict")
        verdict, notes = triage.validate(raw, bundle)
    except triage.GeminiDeclined as exc:
        # The adapter had no quota or budget left for this call: expected under load, not a failure. Same answer as a
        # failure (FR-4), but logged quietly and recorded as "not used" so the audit can tell the two apart.
        log.info("gemini triage declined (%s); deterministic verdict", exc)
        return _fallback(bundle, hits, full, scores, gemini_used=False, error=f"declined: {str(exc)[:160]}")
    except Exception as exc:  # noqa: BLE001 - FR-4: a model failure degrades to CAUTION, never to a 500
        error = f"{exc.__class__.__name__}: {str(exc)[:160]}"
        log.warning("gemini triage failed, deterministic fallback: %s", error)
        return _fallback(bundle, hits, full, scores, gemini_used=True, error=error)
    return fuse(bundle, hits, full, hard, verdict, scores, notes, prompt, raw.model_dump_json())


def _fallback(bundle: Bundle, hits: tuple[Hit, ...], full: scoring.Score, scores: dict, *, gemini_used: bool, error: str) -> Report:
    """FR-4: with a hard hit present the answer is at least CAUTION with the generic line; soft-only hits keep the
    deterministic verdict, because nothing hard was found and a model outage must not frighten everyone."""
    if s.VERDICT_RANK[full.verdict] >= s.VERDICT_RANK["CAUTION"] or all(h.soft for h in hits):
        fallback = full
    else:
        fallback = scoring.Score(max(full.risk, s.CAUTION_THRESHOLD), "CAUTION", full.hard)
    return _deterministic(bundle, hits, fallback, scores, gemini_used=gemini_used, error=error, generic=fallback is not full)
