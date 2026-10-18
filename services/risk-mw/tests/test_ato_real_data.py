"""The shipping path, end to end, on the real HMOG table: table -> trainer -> adapter -> hits.

Every other test of this model measures something generated. `tests/test_ato_adapter.py` fits
artefacts from `bhorosha_ato.synth` and says so in its own first paragraph - its job is the
plumbing, and generated sessions separate cleanly enough to pin wiring without a dataset.
`ato/eval/ato_eval.py` does measure real HMOG, but it scores `model.AtoModel` directly inside
the harness: it never writes a .pkl, never loads one back through `app.ato`, and never looks at
a customer-visible reason code. So nothing in the repo joined the two halves, and the claim
"this works on real people" rested on two measurements of different things.

This file joins them. One pass, no harness in the middle:

    hmog_features_v2.jsonl  ->  extract.read_wide_table
                            ->  train.train_user_model / train_cold_start / train_coaching_model
                            ->  model.save into a tmp directory, under train.ato_file names
                            ->  RISK_MW_ATO_ARTEFACTS_DIR
                            ->  app.ato.behaviour_hits  (the function /v1/risk/score calls)
                            ->  ATO_BEHAVIOUR_MISMATCH, or no hit at all

Two things it deliberately does NOT do.

It does not call `train.train_artefacts` or the trainer's CLI, which is what a deploy runs.
That entry point reads `extract.read_table` - the POSITIONAL version 1 table - and refuses this
one outright (`StaleTableError: extracted against a different feature order or length (80
features) than bhorosha_ato.schema now declares (55)`). So the per-user, cold-start and
coaching fits are driven here one call below that, exactly as `train_artefacts` drives them.
Measured, not assumed, and re-measured when the schema grew to 55; see the note in the test
module's report.

It does not fit on everything the way `train_artefacts` does. A model scored on a row that
trained it reports nothing, so each user's 8 writing sessions are split 6 enrolment / 2
held-out, stratified by posture (HMOG's TaskID encodes sitting vs walking, and an unstratified
split makes the model separate postures rather than people - see `extract.TASKS`). Disjointness
is asserted on session keys rather than trusted, because that is the assertion the numbers below
are worth nothing without.

WHAT THIS TABLE CANNOT SUPPLY, which bounds every rate below.

Measured over all 2,398 rows: seventeen of the 55 schema columns are 0.0 in EVERY row, because
the version 2 extractor had no source for them - `pin_backspaces` and all sixteen `keyrank_*`
features. Sixteen of those are identity columns, so the identity model here is fitted on 23 live
columns out of the 39 it declares, and the per-key hold-time ORDER block that the schema added is
structurally absent rather than merely weak.

That is worth knowing in both directions. It explains why the rates below did not move when the
schema grew from 39 features to 55 - the sixteen new columns are constant zeros in this table,
and a constant column cannot change a fit. And it means these numbers measure the PRE-KEYRANK
model, while `models/ato` shipped artefacts trained from the version 3 table, which
does carry those columns. The gain keyrank bought is measured where the table carrying it is, in
`ato/eval/ato_eval.py` and the note above `schema.KEYRANK_KEYS`; it is not visible from here.
Pointing this module at the v3 table would make it measure what deploys, and would move every
floor in it - a deliberate change, not a drive-by.

WHAT THIS MEASURES, on all 100 real users (run it to reproduce; the numbers are deterministic,
and every one below was re-measured against the 55-feature schema):

    owner's held-out session earns NO mismatch      186/200   = 93.0%
    users with BOTH held-out sessions rejected        2/100
    a stranger's session on her account IS caught   857/1000  = 85.7%

The stranger figure is a seeded uniform sample of 1000 of the 19,800 (owner, stranger-session)
combinations, taken to keep this module quick: 2.6 s for that test and 6.8 s for the module,
against the 48 s the whole population costs. The full 19,800 come to
16,986 = 85.8% - measured when this file was written and again against the 55-feature schema,
48 seconds to reproduce - so the sample is not a flattering slice of the population: it is the
population to within a tenth of a point.

These are RATES and are asserted as rates. A per-session assertion on a hand-picked set of users
would pass here - the first twelve users in id order give 24/24 clean on the owner side, and
18/24 caught when each is scored against the next one's two held-out sessions - and would be a
claim about those twelve people, not about the model. (The full twelve-user grid is 215/264,
which is the same 85% again; the small pairing is flattering only by being small.) The real
model false-rejects a genuine session roughly one time in fourteen and misses a stranger roughly
one time in seven. That is what this signal costs and what it buys; the equal error rate behind
it is reported by `ato/eval/ato_eval.py`, against the table that carries every column. A test
that implied better than this would be worse than no test.
"""

from __future__ import annotations

import os
import random
import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SERVICE_DIR.parent.parent
# conftest.py vendors `ato` onto sys.path; repeated here for the same reason
# tests/test_ato_adapter.py repeats it - this module imports the package at collection time.
if str(PROJECT_DIR / "libs" / "ato") not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR / "libs" / "ato"))

from bhorosha_ato import extract  # noqa: E402
from bhorosha_ato import model as ato_model  # noqa: E402
from bhorosha_ato import train as ato_train  # noqa: E402

from app import ato  # noqa: E402
from app.contracts import ScoreRequest  # noqa: E402
from app.rules import DECISION_RANK, RuleHit, decide  # noqa: E402
from app.settings import Settings, get_settings  # noqa: E402

# The real table is about 5 MB of extracted HMOG features. It is NOT in the repository (it is
# derived from the 6 GB HMOG archive). Set BHOROSHA_HMOG_V2_TABLE to its path to run this module;
# without it, the module skips.
_TABLE_ENV = os.environ.get("BHOROSHA_HMOG_V2_TABLE", "").strip()
TABLE = Path(_TABLE_ENV) if _TABLE_ENV else None

SKIP_REASON = (
    "set BHOROSHA_HMOG_V2_TABLE to the real HMOG feature table (with its sibling "
    "<table>.manifest.json) to run this module. The table is derived from the HMOG archive and "
    "is not committed. Every other ATO test runs without it."
)

# Skipped at collection, so a machine without the table pays nothing and sees why.
pytestmark = pytest.mark.skipif(
    TABLE is None or not (TABLE.exists() and extract.manifest_path(TABLE).exists()), reason=SKIP_REASON
)

# HMOG gives every user 8 writing sessions (the only identity task - see
# extract.IDENTITY_TASKS, and the EER table above it that chose it). 6 enrol, 2 are held out.
# MIN_ENROLMENT_SESSIONS is 3, so 6 is comfortably a personalised model and not a global one
# wearing her filename.
N_ENROL = 6
N_HELD_OUT = 2

# Drives the posture-stratified split and the stranger sample. Same default as the trainer's.
SEED = ato_train.DEFAULT_SEED

# Stranger pairs scored, out of the 19,800 that exist. Enough to resolve the rate to a point or
# so; the full population was measured once and agrees (see the module docstring).
STRANGER_SAMPLE = 1000

MISMATCH = "ATO_BEHAVIOUR_MISMATCH"

# --- the floors, each sitting under a number that was actually measured -----------------
# Set below the measurement with room for sklearn's own drift, and above the level at which the
# signal would have stopped being worth shipping. A floor at the measured value would turn a
# library upgrade into a red suite; a floor at 0.5 would pass a coin.
OWNER_CLEAN_FLOOR = 0.88        # measured 0.930 (186/200)
STRANGER_HIT_FLOOR = 0.80       # measured 0.857 (857/1000); 0.858 over all 19,800
BOTH_HELD_OUT_REJECTED_MAX = 5  # measured 2 of 100 users


def _split_by_posture(
    sessions: list[extract.SessionRecord], n_enrol: int, n_held_out: int, rng: random.Random
) -> tuple[list[extract.SessionRecord], list[extract.SessionRecord]]:
    """One user's sessions -> (enrolment, held-out), each posture split in the same proportion.

    `extract.group_by_user` hands these over sorted by session id; the shuffle is seeded so the
    split follows from SEED and not from the order the extractor walked the archive. Postures
    are split separately and recombined because HMOG's 8 writing sessions are 4 sitting and 4
    walking: train on one posture and test on the other and the model is reading posture, not
    identity, which would show up here as the model failing when it is really the protocol.
    """
    by_posture: dict[str, list[extract.SessionRecord]] = {}
    for session in sessions:
        by_posture.setdefault(session.posture, []).append(session)

    enrol: list[extract.SessionRecord] = []
    held_out: list[extract.SessionRecord] = []
    total = len(sessions) or 1
    for posture in sorted(by_posture):
        group = list(by_posture[posture])
        rng.shuffle(group)
        want_enrol = max(1, round(n_enrol * len(group) / total))
        want_held = max(1, round(n_held_out * len(group) / total))
        enrol += group[:want_enrol]
        held_out += group[want_enrol:want_enrol + want_held]
    return enrol[:n_enrol], held_out[:n_held_out]


@pytest.fixture(scope="session")
def real_artefacts(tmp_path_factory) -> dict:
    """Real artefacts in a real directory, plus the held-out sessions nothing was trained on.

    Built once: the whole thing - reading 2,398 rows, 100 per-user fits, the population
    cold-start forest and the coaching model - takes about a second.
    """
    records = extract.read_wide_table(TABLE)
    identity = extract.group_by_user(records, extract.IDENTITY_TASKS)
    coaching = extract.group_by_user(records, extract.COACHING_TASKS)

    # Every user's identity sessions pooled. This is both the cold-start training set and the
    # reference each per-user calibration is anchored against; `train_user_model` drops the
    # user's own rows out of the reference, so nobody is their own impostor.
    population = [record for sessions in identity.values() for record in sessions]

    users = sorted(
        user for user, sessions in identity.items() if len(sessions) >= N_ENROL + N_HELD_OUT
    )

    directory = tmp_path_factory.mktemp("ato-real-artefacts")
    held_out: dict[str, list[extract.SessionRecord]] = {}
    enrolled: dict[str, tuple[str, ...]] = {}
    for user in users:
        enrol, test = _split_by_posture(
            identity[user], N_ENROL, N_HELD_OUT, random.Random(f"{SEED}:{user}")
        )
        fit = ato_train.train_user_model(enrol, user, reference=population)
        ato_model.save(fit.fitted, directory / fit.file)
        held_out[user] = test
        enrolled[user] = fit.session_ids

    # Both global artefacts, fitted the way train_artefacts fits them: on the whole table.
    ato_model.save(
        ato_train.train_cold_start(population), directory / ato_train.COLD_START_FILE
    )
    ato_model.save(
        ato_train.train_coaching_model(
            [record for sessions in coaching.values() for record in sessions],
            random.Random(SEED),
        ),
        directory / ato_train.COACHING_FILE,
    )

    return {
        "dir": directory,
        "users": users,
        "held_out": held_out,
        "enrolled": enrolled,
        "rows": len(records),
    }


@pytest.fixture
def serving(real_artefacts, monkeypatch):
    """The adapter, pointed at those artefacts exactly the way the service points at a deploy."""
    monkeypatch.setenv("RISK_MW_ATO_ARTEFACTS_DIR", str(real_artefacts["dir"]))
    get_settings.cache_clear()
    ato.reset_cache()
    yield real_artefacts
    get_settings.cache_clear()  # monkeypatch has restored the environment by now
    ato.reset_cache()


def _codes(user: str, record: extract.SessionRecord) -> set[str]:
    """The customer-visible reason codes one real session earns on one real account."""
    return {hit.reason.code for hit in ato.behaviour_hits(user, record.features)}


# --- the split, before any number taken from it means anything ---------------------------


def test_no_model_was_scored_on_a_row_that_trained_it(real_artefacts):
    """The precondition for every rate below. Asserted on session keys, not trusted.

    `SessionRecord.key` is user-qualified because HMOG numbers sessions within a user: an
    overlap check on bare ids would compare "session_3" against "session_3" and pass whatever
    happened.
    """
    assert real_artefacts["users"], "no user in the table had 8 identity sessions"
    for user in real_artefacts["users"]:
        enrolled = set(real_artefacts["enrolled"][user])
        held_out = {record.key for record in real_artefacts["held_out"][user]}
        assert len(enrolled) == N_ENROL
        assert len(held_out) == N_HELD_OUT
        assert not (enrolled & held_out), f"{user}: a held-out session also trained her model"
        assert all(key.startswith(f"{user}/") for key in enrolled | held_out)


def test_the_table_is_the_real_one_and_every_persona_ships_personalised(serving):
    """What the adapter actually loaded: 100 real people, each with her own model.

    The per-user check is the one that matters for every claim after it. `train_ato` returns a
    population model below MIN_ENROLMENT_SESSIONS and records that in `per_user`, and `app.ato`
    relabels such an answer `_COLD_START` - so if these fits had quietly globalised, the rates
    below would be measuring the cold-start forest while reading as personalised.
    """
    assert serving["rows"] == 2398, "not the 2,398-session HMOG v2 table these numbers came from"
    assert len(serving["users"]) == 100

    for user in serving["users"]:
        model = ato.user_model(user)
        assert model is not None, f"{user}: the adapter found no artefact the trainer wrote"
        assert model.per_user, f"{user}: shipped as personalised but is a population model"
        assert model.n_train_sessions == N_ENROL
        # Without a stored background the explainer has no evidence to cite and the customer
        # gets a decision with nothing behind it.
        assert len(model.background) > 0


# --- the owner side: the cost of this signal to a real customer ---------------------------


def test_a_real_owners_held_out_session_usually_earns_no_mismatch(serving):
    """Measured 186/200 = 93.0%: a genuine session is wrongly challenged about 1 time in 14.

    This is the number that decides whether the signal is shippable, and it is asserted as a
    rate because that is the only form in which it is true. Pinning it to one user's one
    session would be a statement about that session.
    """
    clean = 0
    total = 0
    rejected_outright = []
    for user in serving["users"]:
        passes = sum(
            1 for record in serving["held_out"][user] if MISMATCH not in _codes(user, record)
        )
        clean += passes
        total += len(serving["held_out"][user])
        if passes == 0:
            # Every held-out session of hers challenged: for this user the model is not a
            # convenience, it is a wall. Counted rather than averaged away.
            rejected_outright.append(user)

    rate = clean / total
    assert rate >= OWNER_CLEAN_FLOOR, (
        f"only {clean}/{total} ({rate:.3f}) of real owners' held-out sessions passed clean; "
        f"measured 0.930 when this test was written"
    )
    assert len(rejected_outright) <= BOTH_HELD_OUT_REJECTED_MAX, (
        f"{len(rejected_outright)} of {len(serving['users'])} real users had EVERY held-out "
        f"session challenged ({rejected_outright}); measured 2 when this test was written"
    )


def test_a_real_owner_is_never_answered_by_the_cold_start_model(serving):
    """She enrolled; a verdict labelled `_COLD_START` would mean her artefact was not found."""
    for user in serving["users"]:
        for record in serving["held_out"][user]:
            codes = _codes(user, record)
            assert not any(code.endswith(ato.COLD_START_SUFFIX) for code in codes), (
                f"{user} has her own artefact but was answered by the stand-in: {codes}"
            )


# --- the stranger side: what the signal is for -------------------------------------------


def test_a_real_stranger_on_her_account_usually_earns_a_mismatch(serving):
    """Measured 857/1000 = 85.7%: a different real person is caught about 6 times in 7.

    The pairs are a seeded uniform sample of all 19,800 (owner, stranger-session)
    combinations - not a chosen pair, and not the first N users. The full 19,800 give 85.8%.
    """
    users = serving["users"]
    pairs = [
        (owner, stranger, index)
        for owner in users
        for stranger in users
        if stranger != owner
        for index in range(N_HELD_OUT)
    ]
    sample = random.Random(SEED).sample(pairs, STRANGER_SAMPLE)

    caught = sum(
        1
        for owner, stranger, index in sample
        if MISMATCH in _codes(owner, serving["held_out"][stranger][index])
    )
    rate = caught / len(sample)
    assert rate >= STRANGER_HIT_FLOOR, (
        f"only {caught}/{len(sample)} ({rate:.3f}) of real strangers earned {MISMATCH}; "
        f"measured 0.857 when this test was written"
    )


def test_a_caught_stranger_reaches_the_customer_as_a_usable_decision(serving):
    """One real caught stranger, carried the rest of the way: hits -> rules.decide -> action.

    The rate above says the model fires. This says what firing is worth: `rules.decide` takes
    every customer-visible reason from rule hits alone, so a hit that is malformed - an unknown
    decision, an empty Bangla message, a weight outside [0, 1] - moves a number and changes
    nothing a person would see.
    """
    users = serving["users"]
    owner = users[0]
    stranger_hits = next(
        (
            hits
            for stranger in users[1:]
            for record in serving["held_out"][stranger]
            for hits in [ato.behaviour_hits(owner, record.features)]
            if any(hit.reason.code == MISMATCH for hit in hits)
        ),
        None,
    )
    assert stranger_hits, f"no real stranger was caught on {owner}'s account at all"

    for hit in stranger_hits:
        assert isinstance(hit, RuleHit)
        assert hit.decision in DECISION_RANK
        assert 0.0 <= hit.reason.weight <= 1.0
        assert hit.reason.text_bn.strip() and hit.reason.text_en.strip()

    request = ScoreRequest.model_validate({
        "user_id": owner,
        "session_id": "real-data-1",
        "txn": {"type": "send_money", "amount_bdt": 500, "to_account": "acct_x"},
    })
    result = decide(request, stranger_hits, 0.0, "ato-real-data-test", Settings())
    assert result.decision in ("step_up", "hold")
    assert result.risk_score >= 0.60
    assert {reason.code for reason in result.reasons} == {
        hit.reason.code for hit in stranger_hits
    }
    assert result.actions, "a step_up or hold decision must carry an action"
