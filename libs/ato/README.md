# ato: account-takeover behaviour models

## Purpose

This library gives two scores for one app session and explains them in Bangla and English.

1. **`ato_score`: "Is this the account owner?"** A per-user one-class model reads touch,
   pressure and motion features. A high score means the session does not look like the owner.
2. **`coaching_score`: "Is someone talking the owner through this payment?"** A small
   supervised model reads timing and dead-time features. A high score means the session looks
   coached.

The important case is when the two scores disagree. The owner is typing (low `ato_score`), but
somebody on a call is telling her what to do (high `coaching_score`).

The Python package name is `bhorosha_ato`. "Bhorosha" is an old internal codename and is kept
only in identifiers.

## How it fits in FinNest

- The mobile app computes a fixed-order vector of behaviour features for each session and
  sends it to `services/risk-mw` in `SignalsRequest.behaviour.features`.
- `services/risk-mw` imports `bhorosha_ato` and loads the trained artefacts from the directory
  in `RISK_MW_ATO_ARTEFACTS_DIR` (normally `models/ato`). It turns the two scores into risk
  codes and a step-up or hold decision.
- `bhorosha_ato.explain` turns the top feature attributions into a short structured
  explanation. It takes a Gemini call function as an argument and has a rule-based fallback, so
  it also works with Gemini off.
- `eval/ato_eval.py` writes `eval/results/ato*.json` and `.md`. The repository-level
  `eval/run.py` reads that result file into the shared summary.

If the artefacts or this package are missing, `risk-mw` turns the behaviour signal off. It does
not fail.

### Two scores, two feature sets

The two scores must not share features. If they did, a coached session (slow, hesitant PIN
entry) would also look like a stranger, and the scores could not disagree. Each feature in
`schema.py` declares which question it may answer:

| Score | Reads | Examples | Why |
|---|---|---|---|
| `ato_score` | morphology | swipe geometry, pressure, tap offset from key centre, IMU grip | Coercion does not change the hand or the phone. |
| `coaching_score` | tempo | hold and flight times, dead gaps, retries, swipe speed | Being talked through a payment changes these. |

`test_identity_and_tempo_partition_the_features` checks that there is no overlap.

This has a cost. Keystroke timing is a strong identity feature, and this design gives it to the
coaching model instead. On HMOG, an identity model with timing ratios reached an EER of 0.058 but
recognised 0% of coached sessions as the owner. The morphology-only model has an EER of 0.119 and
recognises 88.3% of coached sessions as the owner. The design keeps the second model.

### Why the schema is a separate module

`behaviour.features` in the `risk-mw` contract is a bare `tuple[float, ...]`: positions, no
names. A wrong order does not raise an error; the model scores garbage. So the order is defined
in one place, `schema.py`, and the extractor, the trainer and the app all follow it.

## Requirements

- Python 3.12.
- The packages in `services/risk-mw/requirements.txt` (scikit-learn, shap, numpy, pandas,
  pyarrow) plus `libs/ato/requirements.txt` (joblib, pytest, httpx).
- For training on real data only: the HMOG archive (see below). The tests and the synthetic
  eval do not need it.

## Configuration

| Variable | Used by | Default | Meaning |
|---|---|---|---|
| `FINNEST_ATO_DATA_DIR` | `datasets.py`, `extract.py`, `eval/ato_eval.py` | `~/finnest-data` | Directory that holds `hmog_dataset.zip`. `--data-dir` overrides it. Keep it outside the repository. |
| `RISK_MW_ATO_ARTEFACTS_DIR` | `services/risk-mw` (not this library) | unset | Directory with the trained artefacts. Unset means the behaviour signal is off. |

Default paths in the command-line tools are relative to `libs/ato`:

| Path | Meaning |
|---|---|
| `../../models/ato/hmog_features.jsonl` | Feature table (`extract.DEFAULT_TABLE`) and its `.manifest.json` |
| `../../models/ato/` | Trained artefacts (`train.DEFAULT_OUT`) |
| `eval/results/` | Eval reports |

## Run locally

From the repository root:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r services/risk-mw/requirements.txt -r libs/ato/requirements.txt
cd libs/ato
python eval/ato_eval.py                 # synthetic sessions, no dataset needed
python eval/ato_eval.py --help
```

The synthetic run writes `eval/results/ato.json` and `eval/results/ato.md`. Every metric in the
report records its source. An identity EER below 3% on generated data is flagged `SUSPECT`,
because it means the generator is too easy.

## Test

```bash
cd libs/ato
python -m pytest -q
```

`pytest.ini` puts `libs/ato` on `sys.path`. The suite uses generated sessions and small
fabricated archives. It does not need the HMOG archive or any trained artefact.

## Training the behaviour models

The models are trained from the public **HMOG** dataset (Sitova et al., "HMOG: New Behavioral
Biometric Features for Continuous Authentication of Smartphone Users", IEEE TIFS 11(5), 2016,
DOI 10.1109/TIFS.2015.2506542). HMOG has raw touch, virtual-keyboard press and release times,
pressure, and accelerometer and gyroscope data for 100 volunteers and 24 sessions each.

**The trained behaviour models are not in this repository.** HMOG has its own licence and terms
of use. They allow non-commercial research and education use, forbid redistribution without
the approval of the College of William & Mary, and forbid attempts to de-anonymise
participants. The models carry derived features of individual participants, so no behaviour
artefact (per-user, cold-start or coaching model, or manifest) is redistributed here, and
`models/ato` does not exist until you train. You must request and download the dataset yourself:

1. Open <https://hmog-dataset.github.io/hmog/> and accept the terms of use.
2. Download `hmog_dataset.zip` from the link on that page.
3. Put it in `$FINNEST_ATO_DATA_DIR` (or pass `--data-dir`). Do not put it in the repository.
4. Check `md5 hmog_dataset.zip` against `4fd46756abec13815f426c66a58e626f`.

Then run the three steps from `libs/ato`:

```bash
# 1. Extract: archive -> feature table and manifest (one pass, about an hour, standard library only)
python bhorosha_ato/hmog_wide_extract.py "$FINNEST_ATO_DATA_DIR/hmog_dataset.zip" \
    ../../models/ato/hmog_features.jsonl

# 2. Train: feature table -> ato_<user>.pkl, cold_start.pkl, coaching.pkl, artefacts.json
python -m bhorosha_ato.train --table ../../models/ato/hmog_features.jsonl --out ../../models/ato \
    --persona rina=151985 --persona rafiq=180679 --persona rahima=186676

# 3. Evaluate: feature table -> eval/results/ato_hmog.json and .md
python eval/ato_eval.py --dataset hmog --table ../../models/ato/hmog_features.jsonl
```

`hmog_wide_extract.py` imports nothing from the rest of the package. You can copy it alone to
the machine that holds the archive and run it there. Copy back both the table and its
`.manifest.json`; the readers refuse a table whose manifest is missing or whose checksum does
not match.

The coached side of the coaching model's training data is generated by `synth.coach`, because
no public dataset records a person being coached through a payment. The eval reports that
limitation separately from measured numbers.

### Demo personas

Rina, Rafiq and Rahima are fictional. The app sends `user_id: "rina"`, and `risk-mw` looks for
`ato_rina.pkl`. `--persona NAME=USER_ID` writes that file from one HMOG volunteer's sessions.
The three volunteers are the three lowest user ids among those at the median crossover rate,
not the best-separating ones, so the demo does not look better than the shipped system.
`artefacts.json` records the source volunteer, the session ids and the calibration of each
persona. A persona whose source user is missing is skipped and the reason is recorded.

### Measured identity results on HMOG

| Configuration | Pooled EER | 95% interval |
|---|---|---|
| HMOG free text, with `keyrank_*` features | 0.0797 | 0.0605-0.0967 |
| Product configuration, without `keyrank_*` | 0.1192 | 0.0972-0.1450 |

The intervals are a bootstrap over users (2000 resamples). The `keyrank_*` features rank hold
times of space, backspace, a period and thirteen English letters. FinNest users type amounts and
PINs (digits), so at serving time those features are absent. The number to quote for the product
is 0.1192. The eval reports the EER against a 0.03-0.10 band but fails it only below 0.03, which
indicates a session leak. The gates that can fail are the leak floor, the coached detection rate
and the latency ceiling.

A fallback dataset with keystroke, swipe and IMU data is BB-MAS (IEEE DataPort, DOI
10.21227/rpaz-0h66). No reader exists for it yet; `--dataset bbmas` explains this and stops.

## Deploy

Not applicable. This is a library. `services/risk-mw` vendors the `bhorosha_ato` package into
its image and reads the artefacts from `RISK_MW_ATO_ARTEFACTS_DIR`.

## Layout

```
bhorosha_ato/
  schema.py              ordered feature contract; the single source of truth for the vector order
  datasets.py            HMOG archive reader
  features.py            raw events -> one feature row
  hmog_wide_extract.py   standalone extractor: HMOG archive -> wide feature table + manifest
  extract.py             feature table readers (extractor versions 1, 2 and 3) and the direct extraction path
  synth.py               genuine and coached session generators
  model.py               per-user one-class model, coaching model, EER
  train.py               feature table -> artefacts in models/ato
  explain.py             SHAP attributions -> structured explanation, with a rule-based fallback
eval/
  ato_eval.py            reproducible metrics -> eval/results/ato*.json and .md
tests/                   pytest suite
pytest.ini
requirements.txt
```
