from case_zero.policy import ACTIONS, final_action, floor_action


def test_actions_order():
    assert ACTIONS == ("close_no_action", "monitor", "edd", "freeze")


def test_floor_bands():  # risk-mw bands: critical >= 0.85, high >= 0.60, medium >= 0.30
    assert floor_action(0.85) == "freeze"
    assert floor_action(0.84) == "edd"
    assert floor_action(0.60) == "edd"
    assert floor_action(0.59) == "monitor"
    assert floor_action(0.30) == "monitor"
    assert floor_action(0.29) == "close_no_action"


def test_escalates_one_level_only():
    assert final_action(0.1, "freeze", 1) == "monitor"


def test_never_lowered():
    assert final_action(0.9, "monitor", 3) == "freeze"


def test_no_escalation_without_validated_flags():
    assert final_action(0.1, "edd", 0) == "close_no_action"
