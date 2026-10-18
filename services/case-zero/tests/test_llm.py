from google.genai import types

from case_zero.config import Settings
from case_zero.llm import GeminiLLM, cost_usd, load_role, parse_response, select_backend
from case_zero.schemas import CaseDraft
from case_zero.tools import TOOL_SPECS

ROLE = load_role(Settings().models_yaml, "workhorse")


def test_role_from_models_yaml():
    assert ROLE.id == "gemini-3.8-flash"
    assert ROLE.input_usd_per_m == 0.75 and ROLE.output_usd_per_m == 3.75


def test_tool_config_low_thinking_no_temperature():
    cfg = GeminiLLM(client=None, role=ROLE).build_config("system", TOOL_SPECS, None)
    assert cfg.temperature is None
    assert cfg.thinking_config.thinking_level == types.ThinkingLevel.LOW
    assert [f.name for f in cfg.tools[0].function_declarations][:2] == ["get_account", "score"]
    assert cfg.automatic_function_calling.disable is True
    assert cfg.response_json_schema is None


def test_schema_config_requests_json():
    cfg = GeminiLLM(client=None, role=ROLE).build_config("system", None, CaseDraft)
    assert cfg.response_mime_type == "application/json"
    assert cfg.response_json_schema["title"] == "CaseDraft"
    assert not cfg.tools


def test_select_backend():
    assert select_backend({"GOOGLE_API_KEY": "k"}) == ("api_key", "k")
    assert select_backend({"GEMINI_API_KEY": "g"}) == ("api_key", "g")
    assert select_backend({"CASE_ZERO_PROJECT_ID": "p"}) == ("vertex", "p")
    assert select_backend({}) == ("none", "")


def test_parse_response_reads_calls_and_usage():
    resp = types.GenerateContentResponse(
        candidates=[types.Candidate(content=types.Content(role="model", parts=[
            types.Part(text="thinking…", thought=True),
            types.Part(function_call=types.FunctionCall(id="fc1", name="neighbours", args={"acct_id": "acct_01070", "hops": 2})),
        ]))],
        usage_metadata=types.GenerateContentResponseUsageMetadata(prompt_token_count=1200, candidates_token_count=40, thoughts_token_count=60),
    )
    turn = parse_response(resp, ROLE.id, latency_ms=900.0, schema=None)
    assert turn.function_calls[0].name == "neighbours" and turn.function_calls[0].id == "fc1"
    assert turn.function_calls[0].args == {"acct_id": "acct_01070", "hops": 2}
    assert turn.text == "" and turn.tokens_in == 1200 and turn.tokens_out == 100
    assert turn.raw_content.parts[1].function_call.name == "neighbours"


def test_cost():
    assert cost_usd(1_000_000, 0, ROLE) == 0.75
    assert round(cost_usd(0, 1_000_000, ROLE), 2) == 3.75
