# Synthetic world, entity graph and mule-ring scorer (`bhorosha_synth`, `bhorosha_graph`)

## Purpose

- `bhorosha_synth` builds a deterministic, Bangladesh-flavoured mobile-money world with labelled fraud rings.
- `bhorosha_graph` turns that world into an entity graph, exposes graph tool functions for the investigator agent,
  and trains a LightGBM mule-account scorer with SHAP reasons.

Every person, account, phone and transaction is synthetic.

## How it fits in FinNest

- The generated files are in `data/seed` (the demo seed) and `data/seed-campaign` (the campaign world). See
  `data/README.md`.
- `load_seed.py` loads the demo seed into BigQuery, Firestore or the Firestore emulator, so every component sees one
  world.
- `services/case-zero` (the investigator agent) calls the graph tools in `bhorosha_graph/tools.py`.
- `services/risk-mw` serves `inbound_mule_score` from the scorer artefacts in `models/mule`.
- `libs/radar` reads the campaign world.

## Requirements

- Python 3.12, `pip install -r requirements.txt` (numpy, pandas, pyarrow, networkx, lightgbm, shap, scikit-learn,
  faker).
- LightGBM needs OpenMP: `brew install libomp` on macOS, `libgomp1` on slim Linux images.
- `load_seed.py --target bigquery|firestore` also needs `google-cloud-bigquery` / `google-cloud-firestore` and
  Application Default Credentials.

## Configuration

The world defaults are in `bhorosha_synth/schema.py: WorldConfig`. The loader reads:

| Variable | Used by | Meaning |
|---|---|---|
| `RISK_MW_PROJECT_ID` or `GOOGLE_CLOUD_PROJECT` | `load_seed.py` | target project for BigQuery and Firestore (required for the cloud targets; the emulator uses `demo-bhorosha`) |
| `FIRESTORE_EMULATOR_HOST` | `load_seed.py --target firestore` | for example `localhost:8080`, to load into the emulator |

## Run locally

```bash
cd libs/synth
python -m bhorosha_synth.generate --seed 42 --out ../../data/seed                          # about 3 s
python -m bhorosha_synth.generate --seed 42 --campaigns 3 --out ../../data/seed-campaign   # the campaign world
python load_seed.py --seed-dir ../../data/seed --target local       # validate only; --target bigquery | firestore
python eval/mule_eval.py --out ../../eval/results/mule.json         # train and evaluate; writes no artefacts
python eval/mule_eval.py --artefacts ../../models/mule              # retrain and rewrite the shipped scorer artefacts
```

Generation is deterministic: the same seed writes the same bytes, and `CHECKSUM` in each directory proves it.

## Test

```bash
cd libs/synth
python -m pytest -q    # determinism, personas, traceable ring, leakage, metrics, tool latency, campaign world
```

One test regenerates the demo seed in a temporary directory and compares it byte for byte with `data/seed`.

## Deploy

This is a library. `services/risk-mw` and `services/case-zero` copy it into their images at deploy time.

## Layout

```
bhorosha_synth/
  schema.py       entity schema, constants, persona ids, WorldConfig and CampaignConfig (no I/O, no randomness)
  population.py   customers, accounts, SIMs, devices, agents and merchants
  background.py   benign traffic: salaries, cash-ins and cash-outs, payments, recharges, look-alike bursts
  typologies.py   the fraud rings, and the call-centre campaigns of the campaign world
  attempts.py     the payment-attempt stream of the campaign world
  world.py        the World container and its checksum
  generate.py     command line: writes the JSONL files, config.json and CHECKSUM
bhorosha_graph/
  bundle.py       load a world, build the graph bundle, save and load graph.pkl
  features.py     about 55 leakage-safe account features at a cutoff
  scorer.py       LightGBM mule scorer, TreeSHAP reasons, temporal evaluation
  tools.py        graph tool functions for the investigator agent
eval/mule_eval.py train, evaluate, and optionally write the artefacts
load_seed.py      load a seed directory into BigQuery or Firestore
tests/
```

## The world

Defaults: 2,004 customers, 40 agents (one colluding till, `AG-0192`), 20 merchants, 35 days (2026-10-07 to
2026-11-10, two paydays), about 12,000 transactions, and 18 rings (3 per typology). Rings are spread early, mid and late,
so every typology appears on both sides of the temporal split.

| File | Columns | Notes |
|---|---|---|
| `customers.jsonl` | cust_id, name (Bangla), gender, age, district, segment, nid_hash, phone_hash, onboarding_agent_id, created_at, persona | Faker `bn_BD` names; hashes only, no identities |
| `accounts.jsonl` | acct_id, owner_id, kind (customer / agent_till / merchant / payroll), district, opened_at, onboarding_agent_id | personas: `acct_rina`, `acct_rafiq`, `acct_rahima`, `acct_newphone_benign` |
| `sims.jsonl`, `sim_events.jsonl` | activation and `swap` events | Rina's takeover swap and one benign new-phone swap |
| `devices.jsonl`, `device_links.jsonl` | phone models; account to device with first_seen | purchased-mule clusters share one device |
| `agents.jsonl`, `merchants.jsonl` | district, lat/lon, commission; category | merchant names are generic ("ফার্মেসি ১"); `MR-0007` is the merchant whose ledger "leaks" |
| `transactions.jsonl` | txn_id, ts, type (cash_in / cash_out / send_money / payment / salary / recharge), amount_bdt, from_acct, to_acct, channel, agent_id, device_id, ring_id | PaySim-style; no balance columns; `ring_id` is for evaluation only and is never a feature |
| `labels.jsonl` | acct_id, ring_id, role (victim / mule_L1 / mule_L2 / cashout_agent / purchased_mule / controller), typology, first_bad_ts | ground truth |

Typologies: `otp_takeover_cashout` (the demo ring `ring_demo_otp`: Rina to L1 to 4 x L2 to `AG-0192`, 3 hops, 72
minutes on payday Nov 10), `purchased_mule_cluster`, `ledger_leak_targeting`, `agent_round_tripping`,
`fan_in_fan_out`, `dormant_then_active`. Hard benign look-alikes: payday cash-outs, a wedding, a hospital fan-in, a
new phone, travel.

## The campaign world

A second world for the Campaign Radar. It is written beside the demo seed and never over it. Without `--campaigns`
the generator writes the demo seed byte for byte. The generator refuses an `--out` that holds the demo seed, and
`load_seed.py` refuses to load the campaign world into the cloud. It is the seed-42 demo world plus:

- **`callcentre_campaign`**: three rings `ring_callcentre_0..2` on days 12, 22 and 30. Thirty customers of one
  district (victims) try to pay three to five new accounts (`mule_L1`) within ninety minutes. One onboarding agent
  opened the payee accounts; their SIMs were activated on one day five to twelve days earlier, and two share a phone.
  Nineteen attempts are held, eleven go through and are cashed out at one till 30 to 120 minutes later.
- **`attempts.jsonl`**: payment attempts only (`send_money`). Every ledger payment is an `allow` with its `txn_id`;
  synthetic refusals are `hold` with no `txn_id`. `is_new_payee` is true until an earlier allowed payment on the
  pair. `truth_campaign` is the `ring_id` of any labelled ring (null when benign); only the radar harness reads it.
- **`bursts.jsonl`**: the benign-burst truth (`payday_1`, `payday_2`, `wedding`, `hospital`).
- `config.json` gains `"campaign": {"campaigns": 3, "days": [...]}`; `CHECKSUM` covers the two new files.

The campaigns draw on their own random stream after the main stream is spent, so every demo row is unchanged
(transaction ids renumber after the first campaign). `--campaigns 0` writes the campaign-free replay: the demo tables
plus attempts and bursts. The mule scorer and Case Zero read only the demo seed.

## Graph tools (`bhorosha_graph/tools.py`)

Each tool takes `as_of` and runs in under 50 ms: `neighbours`, `path_between`, `shared_entities`, `velocity_stats`,
`agent_till_stats`, `kyc_dupe_check`, `known_fraud_proximity`.

`known_fraud_proximity` counts only fraud that an analyst would have confirmed by `as_of`: three days after the first
bad event (`features.CONFIRMATION_LAG_DAYS`, the same rule the scorer features use). A hit is
`{acct_id, hops, confirmed_before}`. Ring ids and roles are ground truth for evaluation and are never returned. Load
the graph with `bhorosha_graph.bundle.load_bundle(Path("models/mule/graph.pkl"))`.

## Scorer (`bhorosha_graph/scorer.py`)

About 55 leakage-safe features per account at weekly cutoffs: 7-day and 30-day velocity, pass-through, forwarding
speed, cash-out shape, dormancy, shared device, SIM activation and onboarding clusters, hops to confirmed fraud (with
the 3-day confirmation lag), hops to a recent SIM swap. Training cutoffs are days 7, 14 and 21; test cutoffs are days
28 and 35. `MuleScorer.score(acct_id)` returns a probability and ten SHAP reasons in under 20 ms;
`load_scorer(Path("models/mule"))` restores it.

`score(acct_id)` is frozen at the artefact cutoff (the end of the world). When the question has a time, use
`score_at(bundle, acct_id, as_of)`: it builds the features from events before `as_of` (about 1 s the first time for
each distinct `as_of`, then cached), so a case in the middle of a theft does not see the future.

Metrics come from `python eval/run.py` at the repository root (writes `eval/results/`). `eval/mule_eval.py --artefacts`
is the only command that rewrites the shipped artefacts. Synthetic data inflates scores; the per-typology table shows
where the scorer is weak (small-amount L2 mules in fan-out and takeover rings).
