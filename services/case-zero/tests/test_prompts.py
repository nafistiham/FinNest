from typing import get_args

from case_zero import prompts
from case_zero.schemas import Role, Typology


def test_every_typology_and_role_is_defined_for_the_writer():
    for name in get_args(Typology) + get_args(Role):
        assert f"- {name}:" in prompts.WRITER_SYSTEM, name


def test_investigator_knows_how_to_spot_a_controller():
    assert "controller" in prompts.INVESTIGATOR_SYSTEM and "small" in prompts.INVESTIGATOR_SYSTEM


def test_prompt_hash_is_stable_and_short():
    assert prompts.PROMPT_SHA == prompts.prompt_sha() and len(prompts.PROMPT_SHA) == 12


def test_investigator_is_told_to_use_model_candidates_and_go_deeper():
    assert "score_neighbours" in prompts.INVESTIGATOR_SYSTEM and "model_candidates" in prompts.INVESTIGATOR_SYSTEM
    assert "3 hops" in prompts.INVESTIGATOR_SYSTEM and "shared device" in prompts.INVESTIGATOR_SYSTEM


def test_investigator_knows_the_pattern_tools_and_leads():
    for word in ("dormant_cohort", "common_point_of_compromise", "pattern_leads"):
        assert word in prompts.INVESTIGATOR_SYSTEM, word


def test_both_agents_are_told_code_rechecks_membership():
    assert "Code re-checks membership" in prompts.WRITER_SYSTEM and "Code re-checks membership" in prompts.INVESTIGATOR_SYSTEM
