# Campaign Radar (`bhorosha_radar`)

## Purpose

The Campaign Radar is an offline detector for call-centre scam campaigns: many victims who each pay a few related
payees within hours. It also contains the "common point of cash-out" rules, which look for agent tills and small
areas where confirmed mule accounts take out cash.

- Stage 0 reads payment attempts.
- Stage 1 flags cells (payee, device, SIM day, district, till and similar keys) that received far more distinct
  senders than their baseline.
- Stage 2 links the flagged attempts into campaigns, with one piece of evidence per link.

The package makes no Gemini, Firestore or network call.

## How it fits in FinNest

- It reads the synthetic worlds in `data/seed` (the demo seed) and `data/seed-campaign` (the demo world plus three
  injected call-centre campaigns, `attempts.jsonl` and `bursts.jsonl`). `libs/synth` generates both.
- The demo seed has no payment attempts, so the radar measures on the campaign world.
- The fraud console (`apps/console`) shows the radar output from fixtures that its own build tools make from
  `eval/results/campaign.json` and `eval/results/cashout.json`.
- `eval/run.py` renders the Campaign Radar and cash-out sections from the same files.

All numbers are synthetic. Each report carries a caveat that says so.

## Requirements

- Python 3.12, `pip install -r requirements.txt` (numpy, pandas, scipy, networkx, pytest).
- `libs/synth` on the path (the test configuration adds it), for the campaign-free replay and the confirmation-lag
  constant.
- `eval/export_audit.py` only: `google-cloud-firestore` and Application Default Credentials.

## Configuration

Every detector threshold is a named constant with its reason in `bhorosha_radar/config.py`. There are no environment
variables. Command-line options:

| Command | Option | Default |
|---|---|---|
| `eval/radar_eval.py` | `--seed-dir` | `data/seed` |
| | `--out` | `eval/results/campaign.json` (or `audit_reader.json` with `--audit`) |
| | `--audit <export.jsonl>` | off: read a local audit export instead of the seed |
| | `--no-campaign-free` | off: skip the campaign-free replay |
| `eval/cashout_eval.py` | `--seed-dir` (repeatable) | `data/seed-campaign` and `data/seed` |
| | `--out` | `eval/results/cashout.json` |
| `eval/export_audit.py` | `--project`, `--since`, `--out` | all required |

Paths are relative to the repository root. `eval/results/` is not committed.

## Run locally

```sh
cd libs/radar
python eval/radar_eval.py --seed-dir ../../data/seed-campaign                 # about 12 s; writes campaign.json / .md
python eval/radar_eval.py --seed-dir ../../data/seed-campaign --no-campaign-free --out /tmp/radar/campaign.json
python eval/radar_eval.py --audit /path/to/export.jsonl --seed-dir ../../data/seed   # live reader sanity check
python eval/cashout_eval.py                                                    # both worlds -> cashout.json / .md
```

Export of the deployed `audit` collection (read-only, needs credentials for your project):

```sh
python eval/export_audit.py --project "$PROJECT_ID" --since 2026-10-17T00:00:00Z --out /path/to/export.jsonl
```

Exit codes: 0 every measure passes or is `n/a`; 1 a measure fails (or, with `--audit`, a document was rejected);
2 a measure or an input is missing. `radar_eval.py --seed-dir ../../data/seed` exits 2, because the demo seed has no
attempts.

Seed mode writes `campaign.json` and `campaign.md`, and after a detector run also `radar_firings.jsonl`,
`radar_incidents.jsonl` and `radar_campaigns.jsonl`. A run with missing data leaves earlier files alone. Audit mode
writes only the reader report, and refuses an `--out` that already holds detector results.

## Test

```sh
cd libs/radar
python -m pytest -q        # fixtures, plus full-world acceptance on data/seed-campaign (tests/test_world.py)
```

Tests that need `data/seed` or `data/seed-campaign` skip with a reason when the files are absent.

## Deploy

This is an offline library and evaluation harness. It is not deployed.

## Layout

- `bhorosha_radar/config.py`: every threshold as a named constant with its reason.
- `stream.py` (stage 0): `read_seed`, `read_audit` (score documents only; a bad document is a reject, never an
  exception), `enrich` (devices, SIM day, till, next hops, all as of the timestamp of each attempt), `to_frame`.
- `baseline.py`, `surprise.py` (stage 1): hour-of-week empirical-Bayes rate over four earlier weeks with a payday
  factor and a causal cell universe; Poisson tail over 15, 60 and 180-minute windows; p <= 1e-7 with ten distinct
  senders, or the velocity cap for cells with an expected count of at most 3 that are not tills or merchants. Each
  run gives frozen `Firing` snapshots; `incidents(firings, as_of)` merges them.
- `link.py` (stage 2): `link(firings, attempts, relations, as_of)` over incidents opened in the last 24 hours and
  attempts strictly before `as_of`; evidence per edge, synchrony, concentration, time-filtered payee links.
- `cashout.py`, `geo.py`: every `cash_out` as one event at the coordinates of its till; `haversine_km`.
- `cashout_seeds.py`: `confirmed_mules(labels, as_of)`, the same confirmation rule as `libs/synth` (first bad event
  at least `CONFIRMATION_LAG_DAYS` = 3 days before `as_of`); victim rows never seed.
- `cashout_rules.py`: takes the seeds as an argument and runs on each cash-out:
  - `till_reuse`: at least two distinct seeds at a till in 30 days, and a Poisson tail of at most 1e-3 against the
    till's own volume;
  - `space_time_clusters`: three distinct seeds within 2.5 km and 90 minutes, at least six cash-outs in the circle,
    p <= 1e-7 against a per-till hour-of-week baseline;
  - `candidates` under two filters side by side: `first_time_senders` (at least three first-time senders in the 24
    hours before the cash-out) and `pass_through` (money in from a new counterparty, and cash-outs of at least 80 %
    of everything paid in over the same 24 hours);
  - `run_cashout`: the JSON-ready output with both.
- `measures.py`, `eval/truth.py`, `eval/radar_eval.py`: the campaign harness. `truth.py` is the only reader of labels,
  `bursts.jsonl` and `truth_` fields. `radar_eval.py` removes `ring_id` and every `truth_` column from the tables it
  gives the detector. A test checks that the detector modules never read `truth_`, `ring_id` or `labels`.
- `eval/cashout_eval.py`, `eval/cashout_report.py`: the rolling cash-out evaluation at every midnight of a world.
- `eval/export_audit.py`: operator-only, read-only export of the deployed audit collection.
- `tests/`: fixtures (`tests/fixtures.py`) and full-world tests.

## Measures

- Time to flag: at most 15 min after the tenth victim payment.
- `retained_fraction`: at least 0.5 at the flag.
- Attempt precision and recall: at least 0.9.
- Zero benign-only or mixed incidents on the two paydays, the wedding and the hospital fan-in.
- Victim coverage: 1.0.

Money at the flag uses `ts < flag_ts` throughout (`allowed_by_flag`, `cashed_out_by_flag`, `retained_by_flag`,
`retained_fraction`, `future_allowed_after_flag`). No "money saved" figure is claimed: that needs an action policy and
a counterfactual replay. A benign burst with no attempt in the stream is reported `not evaluated`, never as zero
incidents. A burst with no payment type at all (the wedding: three cash-outs) is reported `outside stream`.

The nominal false-incident figure is a p-branch union bound (about 0.86 a week on the campaign world), not a
measurement. The report also gives measured benign-only incidents per route, on the world and on its campaign-free
replay.

## Known limits

- Week 0 has no earlier weeks. Its baseline is backfilled from later weeks, and every firing says so.
- The Poisson tail assumes no over-dispersion. The report gives a dispersion index per key. On the campaign world
  every key is over-dispersed (2.3 to 11.4), so the p-values are optimistic. The ten-sender floor, not the p
  threshold, keeps the benign bursts quiet.
- Linkage pulls in what broad cells hold. A `sender_district` incident can carry benign payments of that district.
- An attempt counts as fraud when it carries a `truth_campaign`, or when its ledger row has a `ring_id`. The
  generator sets `truth_campaign = ring_id` on the attempts of every labelled ring. A ledger ring attempt without a
  `truth_campaign` is reported as an issue (exit 2).
- With the three-day confirmation lag the live cash-out circle rarely fires. Till reuse is the live rule.
- One synthetic world is not evidence that a rule works on a real ledger.
