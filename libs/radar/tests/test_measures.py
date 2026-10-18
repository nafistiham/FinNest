"""Hand-numbered acceptance measures: future money cannot inflate retention."""
from types import SimpleNamespace

import pytest

from bhorosha_radar.measures import (
    CampaignTruth, flag_ts, incident_class, measure, money_at_flag,
    precision_recall, time_to_flag_min, victim_coverage,
)


def sample(**changes):
    base = dict(campaign_id="c", attempt_ids=frozenset({"a", "b"}), victims=frozenset({"v1", "v2"}),
                tenth_ts="2026-10-17T10:12:00", allowed=(("2026-10-17T10:00:00", 52000),),
                cashouts=(("2026-10-17T10:10:00", 12000),), payees=frozenset({"p"}), till=None)
    return CampaignTruth(**(base | changes))


def test_flag_uses_first_relevant_firing_not_incident_opening():
    firings = [SimpleNamespace(run_ts="2026-10-17T09:00:00", attempt_ids=("unrelated",)),
               SimpleNamespace(run_ts="2026-10-17T10:15:00", attempt_ids=("a",))]
    assert flag_ts(sample(), firings) == "2026-10-17T10:15:00"
    assert time_to_flag_min(sample(), firings) == 3
    assert flag_ts(sample(), []) is None


def test_retention_counts_received_and_exited_by_flag_only():
    result = money_at_flag(sample(), "2026-10-17T10:15:00")
    assert result == dict(allowed_by_flag=52000, cashed_out_by_flag=12000,
                          retained_by_flag=40000, retained_fraction=40000/52000,
                          future_allowed_after_flag=0)


def test_future_money_never_claimed_retained():
    t = sample(allowed=(("2026-10-17T10:00:00", 10000), ("2026-10-17T11:00:00", 90000)),
               cashouts=(("2026-10-17T10:14:00", 10000),))
    m = money_at_flag(t, "2026-10-17T10:15:00")
    assert m["retained_fraction"] == 0
    assert m["future_allowed_after_flag"] == 90000


def test_zero_credit_is_na_and_exact_flag_boundary_is_future():
    m = money_at_flag(sample(allowed=(("2026-10-17T10:15:00", 52000),), cashouts=()), "2026-10-17T10:15:00")
    assert m["retained_fraction"] is None and m["allowed_by_flag"] == 0
    assert m["future_allowed_after_flag"] == 52000
    assert measure(None, ">=", .5, na=True)["status"] == "n/a"
    assert measure(None, ">=", .5)["status"] == "missing"
    assert measure(.4, ">=", .5)["status"] == "fail"


def test_attempt_precision_recall_and_all_targeted_victims():
    t = sample(attempt_ids=frozenset(str(i) for i in range(30)))
    campaign = SimpleNamespace(attempt_ids=tuple(str(i) for i in range(31)), senders=("v1", "v2", "noise"))
    assert precision_recall(t, campaign) == (30/31, 1.0)
    assert victim_coverage(t, campaign) == 1.0
    assert precision_recall(t, None) == (0.0, 0.0)
    assert victim_coverage(t, None) == 0.0


@pytest.mark.parametrize("ids,expected", [(('b',), 'benign_only'), (('a', 'b'), 'mixed'), (('a',), 'fraud_dominant')])
def test_mixed_incidents_remain_false_alarm_candidates(ids, expected):
    assert incident_class(SimpleNamespace(attempt_ids=ids), frozenset({'a'})) == expected


def test_burst_counts_mixed_and_benign_incidents_and_route_rates_use_exposure():
    from bhorosha_radar.measures import burst_incidents,false_incidents_by_route
    from bhorosha_radar.surprise import Firing
    burst=SimpleNamespace(start='2026-10-17T10:00:00',end='2026-10-17T11:00:00',types=('send_money',),acct_ids=('benign',))
    attempts=(SimpleNamespace(attempt_id='b',ts='2026-10-17T10:01:00',sender='benign',payee='p',type='send_money'),)
    incs=(SimpleNamespace(attempt_ids=('a','b')),SimpleNamespace(attempt_ids=('b',)))
    assert burst_incidents(burst,attempts,incs,frozenset({'a'}))==2
    firing=Firing('2026-10-17T10:15:00','payee','p',15,12,.5,1e-10,10,'poisson',('b',))
    routes=false_incidents_by_route((firing,),frozenset({'a'}),'2026-10-17T00:00:00','2026-10-24T00:00:00')
    assert routes['poisson']['2026-10-17T00:00:00']['per_week']==1
    assert routes['velocity_cap']['2026-10-17T00:00:00']['benign_only_incidents']==0


def test_burst_with_no_attempts_in_the_stream_is_not_evaluated_never_zero():
    from bhorosha_radar.measures import burst_incidents
    burst=SimpleNamespace(start='2026-10-17T10:00:00',end='2026-10-17T11:00:00',types=('send_money',),acct_ids=('absent',))
    attempts=(SimpleNamespace(attempt_id='b',ts='2026-10-17T10:01:00',sender='benign',payee='p',type='send_money'),)
    assert burst_incidents(burst,attempts,(SimpleNamespace(attempt_ids=('b',)),),frozenset()) is None
