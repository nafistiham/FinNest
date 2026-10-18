"""Full-world acceptance on the campaign world (data/seed-campaign; the demo seed has no attempts)."""
from pathlib import Path
import time

import pytest

from radar_eval import evaluate

SEED=Path(__file__).resolve().parents[3]/'data'/'seed-campaign'


@pytest.fixture(scope='module')
def timed():
    started=time.monotonic()
    result=evaluate(SEED)
    return result,time.monotonic()-started


@pytest.mark.skipif(not (SEED/'attempts.jsonl').exists(),reason='data/seed-campaign has not been generated; fixture success is not world acceptance')
def test_seed_acceptance_under_one_minute(timed):
    result,seconds=timed
    assert not result['missing'],result['missing']
    assert all(m['status'] in ('pass','n/a') for m in result['measures'].values()),result['measures']
    assert seconds<60


@pytest.mark.skipif(not (SEED/'attempts.jsonl').exists(),reason='data/seed-campaign has not been generated')
def test_campaign_free_replay_runs_with_no_campaign_truth_and_reports_every_route(timed):
    replay=timed[0]['false_incidents_per_week']['campaign_free_replay']
    assert replay['status']=='run' and replay['campaigns']==0
    assert set(replay['by_route'])=={'poisson','velocity_cap'} and set(replay['summary'])=={'poisson','velocity_cap'}
    assert replay['nominal']['p_branch_only']>0
