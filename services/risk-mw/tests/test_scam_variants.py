"""The detector's reasoning variants V1-V5, with a fake model call (no paid call anywhere)."""

import json
import logging
import threading
from types import SimpleNamespace
from typing import Literal

import pytest
from pydantic import BaseModel, Field

from app import genai_client, scam_variants
from app.settings import Settings


class Tactic(BaseModel):
    tactic: Literal["AUTHORITY_IMPERSONATION", "CREDENTIAL_REQUEST"]
    quote: str
    turn: int


class Extraction(BaseModel):
    """Stand-in for the detector's evidence-first schema: the evidence first, the verdict after it."""

    tactics: list[Tactic] = []
    claimed_identity: Literal["bank_mfs_staff", "unknown", "none"] = "none"
    ask: Literal["none", "otp", "pin"] = "none"
    scam_type: str = "none"
    verdict: Literal["SAFE", "UNCERTAIN", "SCAM"]
    confidence: float = Field(ge=0, le=1)
    injection_attempt: bool = False


def reply(verdict="SCAM", confidence=0.95, **extra):
    return {"tactics": [], "claimed_identity": "bank_mfs_staff", "ask": "otp", "scam_type": "otp_pin_harvest", "verdict": verdict,
            "confidence": confidence, "injection_attempt": False, **extra}


class FakeCall:
    """Answers each role from its own queue; records every call. Thread-safe, because v5 samples in parallel."""

    COST = {"volume": 0.001, "workhorse": 0.005}

    def __init__(self, **queues):
        self.queues = {role: list(items) for role, items in queues.items()}
        self.calls = []
        self.lock = threading.Lock()

    def __call__(self, task, role_name, contents, schema=None, system=None, timeout_s=None, thinking_level=None, max_output_tokens=None):
        with self.lock:
            self.calls.append({"task": task, "role": role_name, "contents": contents, "schema": schema, "system": system,
                               "timeout_s": timeout_s, "thinking": thinking_level})
            item = self.queues[role_name].pop(0)
        if isinstance(item, Exception):
            raise item
        body, latency = (item if isinstance(item, tuple) else (item, 100.0))
        return SimpleNamespace(text=json.dumps(body), parsed=None, cost_usd=self.COST[role_name], latency_ms=latency, model_id=role_name,
                               thoughts="caller claims bank staff and asks for the OTP")


SETTINGS = Settings(scam_timeout_s=4.0)


def run(variant, fake, **kwargs):
    return scam_variants.extract(variant, prefix="PREFIX", transcript_part="caller: হ্যালো", schema=Extraction, settings=SETTINGS,
                                 call=fake, escalation_call=kwargs.pop("escalation_call", fake), **kwargs)


def test_the_five_variants_and_the_default_setting():
    assert scam_variants.VARIANTS == ("v1", "v2", "v3", "v4", "v5")
    # v3 won the comparison (eval/results/variant_comparison.md, 2026-10-17): best recall at FPR <= 10% and sync p95 <= 2.5 s
    assert Settings().scam_variant == scam_variants.DEFAULT_VARIANT == "v3"


def test_v1_is_one_flash_lite_read_at_minimal_thinking_with_the_prefix_as_the_cacheable_system_part():
    fake = FakeCall(volume=[reply()])
    out = run("v1", fake)
    (c,) = fake.calls
    assert (c["role"], c["thinking"], c["system"], c["contents"], c["schema"], c["timeout_s"]) == \
        ("volume", "minimal", "PREFIX", "caller: হ্যালো", Extraction, 4.0)
    assert out.extraction["verdict"] == "SCAM" and out.latency_ms == 100.0 and out.cost_usd == 0.001
    assert out.escalated is False and out.escalation is None


def test_v2_writes_a_short_check_just_before_the_verdict_and_keeps_every_other_field_in_order():
    fake = FakeCall(volume=[reply(check="bank staff asks for the OTP: bank staff never ask for it")])
    out = run("v2", fake)
    schema = fake.calls[0]["schema"]
    names = list(schema.model_fields)
    assert names == ["tactics", "claimed_identity", "ask", "scam_type", "check", "verdict", "confidence", "injection_attempt"]
    assert schema.model_json_schema()["propertyOrdering"] == names
    assert "norm" in schema.model_fields["check"].description
    with pytest.raises(ValueError):
        schema.model_validate({**reply(check="x"), "confidence": 1.5})  # the base field's own bounds survive the copy
    assert out.extraction["check"].startswith("bank staff") and out.extraction["verdict"] == "SCAM"
    assert scam_variants.checked_schema(Extraction) is schema  # built once per schema


def test_v2_ordering_survives_the_sdk_conversion_vertex_generates_from():
    from google.genai import _transformers

    converted = _transformers.t_schema(SimpleNamespace(vertexai=True), scam_variants.checked_schema(Extraction))
    order = converted.property_ordering
    assert order.index("check") == order.index("verdict") - 1 and len(order) == len(converted.properties)


def test_v3_is_v1_at_thinking_low():
    fake = FakeCall(volume=[reply()])
    run("v3", fake)
    assert [(c["role"], c["thinking"]) for c in fake.calls] == [("volume", "low")]


@pytest.mark.parametrize("verdict,confidence,escalates", [
    ("SCAM", 0.95, False), ("SAFE", 0.1, False), ("SAFE", 0.95, False),
    ("UNCERTAIN", 0.3, True), ("SCAM", 0.7, True), ("SCAM", 0.9, True), ("SAFE", 0.5, True), ("SCAM", 0.91, False)])
def test_v4_escalates_only_uncertain_or_borderline_reads(verdict, confidence, escalates):
    fake = FakeCall(volume=[reply(verdict, confidence)], workhorse=[reply("SCAM", 0.92)])
    out = run("v4", fake)
    assert out.escalated is escalates and len(fake.calls) == (2 if escalates else 1)


def test_v4_second_read_is_3_8_flash_at_low_thinking_with_thoughts_logged_and_its_own_latency(caplog):
    fake = FakeCall(volume=[(reply("UNCERTAIN", 0.5), 900.0)], workhorse=[(reply("SCAM", 0.93), 2600.0)])
    with caplog.at_level(logging.INFO, logger="app.scam_variants"):
        out = run("v4", fake)
    first, second = fake.calls
    assert (second["role"], second["thinking"], second["system"], second["schema"]) == ("workhorse", "low", "PREFIX", Extraction)
    esc = out.escalation
    assert esc["kind"] == "second_read" and esc["background"] is True and esc["trigger"] == "uncertain"
    assert esc["stage1"]["verdict"] == "UNCERTAIN" and esc["verdict"] == "SCAM" and esc["changed"] is True
    assert out.extraction["verdict"] == "SCAM"          # the second read replaces the first once it has landed
    assert out.latency_ms == 900.0 and esc["latency_ms"] == 2600.0  # the synchronous path waits for the first read only
    assert out.cost_usd == pytest.approx(0.006) and esc["cost_usd"] == 0.005
    assert "asks for the OTP" in esc["thoughts"] and "asks for the OTP" in caplog.text


def test_v4_a_failed_second_read_leaves_the_first_standing():
    fake = FakeCall(volume=[reply("SCAM", 0.8)], workhorse=[TimeoutError("slow")])
    out = run("v4", fake)
    assert out.extraction["verdict"] == "SCAM" and out.extraction["confidence"] == 0.8
    assert out.escalated is True and out.escalation["error"] == "TimeoutError" and out.escalation["extraction"] is None


def test_v4_in_production_answers_with_the_first_read_and_delivers_the_second_when_it_lands():
    landed, done = [], threading.Event()
    fake = FakeCall(volume=[reply("UNCERTAIN", 0.4)], workhorse=[reply("SCAM", 0.95)])
    out = run("v4", fake, on_escalation=lambda esc: (landed.append(esc), done.set()))
    assert out.extraction["verdict"] == "UNCERTAIN" and out.escalated is True and out.escalation["pending"] is True
    assert done.wait(5) and landed[0]["verdict"] == "SCAM" and landed[0]["stage1"]["verdict"] == "UNCERTAIN"


def test_v4_under_the_eval_reads_in_line_and_lands_the_callback_after_the_turn():
    """The eval measures the production path without its thread: the second read runs before extract returns, and the callback
    lands when the eval's turn is over, so the turn still answers with the first read, as production would."""
    landed = []
    fake = FakeCall(volume=[reply("UNCERTAIN", 0.4)], workhorse=[reply("SCAM", 0.95)])
    with scam_variants.synchronous_escalations():
        out = run("v4", fake, on_escalation=landed.append)
        assert landed == [] and out.extraction["verdict"] == "UNCERTAIN" and out.escalation["verdict"] == "SCAM"
    assert landed == [out.escalation] and out.cost_usd == pytest.approx(0.006)
    fake = FakeCall(volume=[reply("UNCERTAIN", 0.4)], workhorse=[reply("SCAM", 0.95)])
    done = threading.Event()
    out = run("v4", fake, on_escalation=lambda esc: done.set())  # outside the context: background again
    assert out.escalation["pending"] is True and done.wait(5)


def test_v5_borderline_takes_three_samples_and_the_majority_verdict():
    fake = FakeCall(volume=[(reply("UNCERTAIN", 0.6), 1000.0), (reply("SCAM", 0.8), 1200.0), (reply("SCAM", 0.85), 1500.0)])
    out = run("v5", fake)
    assert len(fake.calls) == 3 and all(c["role"] == "volume" and c["thinking"] == "minimal" for c in fake.calls)
    assert out.extraction["verdict"] == "SCAM" and out.escalated is True
    esc = out.escalation
    assert esc["kind"] == "self_consistency" and esc["samples"] == 3 and esc["votes"] == {"UNCERTAIN": 1, "SCAM": 2}
    assert esc["majority"] == "SCAM" and esc["agreement"] == pytest.approx(0.667, abs=1e-3) and esc["background"] is False
    assert out.latency_ms == 2500.0  # first read plus the slower of the two parallel samples, not their sum
    assert out.cost_usd == pytest.approx(0.003)


def test_v5_a_clear_read_is_not_resampled():
    fake = FakeCall(volume=[reply("SCAM", 0.97)])
    out = run("v5", fake)
    assert len(fake.calls) == 1 and out.escalated is False


def test_v5_three_different_verdicts_give_the_uncertain_sample():
    fake = FakeCall(volume=[reply("SCAM", 0.7), reply("SAFE", 0.2), reply("UNCERTAIN", 0.5)])
    out = run("v5", fake)
    assert out.extraction["verdict"] == "UNCERTAIN" and out.escalation["majority"] is None


def test_v5_a_failed_sample_is_left_out_of_the_vote():
    fake = FakeCall(volume=[reply("SCAM", 0.7), RuntimeError("boom"), reply("SCAM", 0.8)])
    out = run("v5", fake)
    assert out.extraction["verdict"] == "SCAM" and out.escalation["samples"] == 2 and out.escalation["errors"] == ["RuntimeError"]


def test_an_unknown_variant_falls_back_to_the_default_rather_than_silencing_the_detector(caplog):
    fake = FakeCall(volume=[reply()])
    out = run("v9", fake)
    assert [(c["role"], c["thinking"]) for c in fake.calls] == [("volume", "low")] and out.extraction["verdict"] == "SCAM"  # v3
    assert "v9" in caplog.text


def test_the_default_call_is_whatever_genai_client_call_is_at_call_time(monkeypatch):
    fake = FakeCall(volume=[reply()])
    monkeypatch.setattr(genai_client, "call", fake)
    out = scam_variants.extract("v1", prefix="P", transcript_part="T", schema=Extraction, settings=SETTINGS)
    assert out.extraction["verdict"] == "SCAM" and len(fake.calls) == 1


def test_a_first_read_that_does_not_parse_raises_so_the_detector_falls_back_as_it_does_today():
    class Bad:
        def __call__(self, *a, **k):
            return SimpleNamespace(text="not json", parsed=None, cost_usd=0.0, latency_ms=1.0)
    with pytest.raises(ValueError):
        scam_variants.extract("v1", prefix="P", transcript_part="T", schema=Extraction, settings=SETTINGS, call=Bad())


def test_recording_collects_each_result_in_its_own_context():
    fake = FakeCall(volume=[reply(), reply()])
    with scam_variants.recording() as results:
        run("v1", fake)
    run("v1", fake)  # outside: not recorded
    assert len(results) == 1 and results[0].extraction["verdict"] == "SCAM"


def test_call_with_thoughts_asks_for_thought_summaries_at_the_given_level_and_prices_the_cached_prefix(monkeypatch):
    seen = {}
    parts = [SimpleNamespace(thought=True, text="He says he is from bKash and wants the code."),
             SimpleNamespace(thought=None, text=json.dumps(reply()))]
    usage = SimpleNamespace(prompt_token_count=4000, cached_content_token_count=3000, candidates_token_count=200, thoughts_token_count=300)
    response = SimpleNamespace(text=json.dumps(reply()), parsed=None, usage_metadata=usage,
                               candidates=[SimpleNamespace(content=SimpleNamespace(parts=parts), finish_reason="STOP")])

    def generate_content(model, contents, config):
        seen.update(model=model, config=config)
        return response
    monkeypatch.setattr(genai_client, "_client", lambda: SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    genai_client.LEDGER.reset()
    try:
        out = scam_variants.call_with_thoughts("scam_escalation", "workhorse", "T", schema=Extraction, system="P", timeout_s=10,
                                               thinking_level="low")
        role = genai_client.roles()["workhorse"]
        assert seen["model"] == role.id and seen["config"].thinking_config.include_thoughts is True
        assert seen["config"].thinking_config.thinking_level.value == "LOW"
        assert out.thoughts.startswith("He says") and out.tokens_cached == 3000 and out.tokens_out == 500
        assert out.cost_usd == genai_client.cost_usd(role, 4000, 500, 3000) and genai_client.LEDGER.spent() == pytest.approx(out.cost_usd)
    finally:
        genai_client.LEDGER.reset()


def test_v5_records_when_the_vote_overturns_the_first_read():
    """Review finding (H): the self-consistency trace had no 'changed', so the summary always said 0."""
    fake = FakeCall(volume=[reply(verdict="UNCERTAIN", confidence=0.6), reply(verdict="SCAM", confidence=0.9), reply(verdict="SCAM", confidence=0.9)])
    out = run("v5", fake)
    assert out.escalation["changed"] is True and out.escalation["majority"] == "SCAM" and out.escalation["wall_ms"] >= 0
