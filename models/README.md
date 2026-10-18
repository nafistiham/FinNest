# Model artefacts

This directory holds the trained artefacts that the services load at start-up. Each section below is a short model
card: what the model does, what it was trained on, how to rebuild it, and how well it does.

**Security note.** `graph.pkl` is a Python pickle, and LightGBM text models and parquet files are parsed by their
libraries. Loading a pickle can run arbitrary code. Load these files only from this repository or another source you
trust. Never point a service at an artefact directory that someone else can write to.

| Directory | Model | Loaded by | Setting |
|---|---|---|---|
| `mule/` | mule-account scorer (LightGBM) and entity graph | `services/risk-mw`, `services/case-zero` | `RISK_MW_MULE_ARTEFACTS_DIR` |
| `app-safety-check/` | app permission classifier (LightGBM) | `services/risk-mw` | `RISK_MW_APPSAFETY_ARTEFACTS_DIR` |
| `ato/` | behaviour (account-takeover) models | `services/risk-mw` | `RISK_MW_ATO_ARTEFACTS_DIR` |

`ato/` is not included in this repository (see below). When an artefact directory is unset or absent, the service
still runs: the mule signal and the behaviour signal are off, and the App Safety Check runs on rules only.

## Mule scorer (`mule/`)

- **Task.** The probability that an account is a money mule at a point in time, with ten SHAP reasons.
- **Files.** `model.lgb` (LightGBM booster), `scorer.json` (feature names, cutoff, version `mule-lgbm-0.1`),
  `features.parquet` (the feature table at the artefact cutoff), `graph.pkl` (the entity-graph bundle that the
  graph tools and `score_at` use).
- **Features.** 57 leakage-safe account features at weekly cutoffs: 7-day and 30-day velocity, pass-through ratio,
  forwarding speed, cash-out shape, dormancy, shared device, SIM-activation and onboarding clusters, hops to
  confirmed fraud (with a 3-day confirmation lag) and hops to a recent SIM swap. `ring_id` and labels are never
  features.
- **Training data.** The synthetic demo seed in `data/seed` only. Training cutoffs are days 7, 14 and 21; test cutoffs
  are days 28 and 35 (a temporal split).
- **Rebuild.**

  ```bash
  cd libs/synth
  python eval/mule_eval.py --artefacts ../../models/mule --out ../../eval/results/mule.json
  ```

  Without `--artefacts` the command evaluates only and writes nothing here. `python eval/run.py` at the repository root
  runs the evaluate-only form.
- **Evaluation** (test cutoffs, as `eval/run.py` reproduces them):

  | Metric | Value |
  |---|---|
  | AUC-PR | 0.841 |
  | Precision at top 50 per cutoff | 0.90 |
  | Recall at precision 0.9 | 0.61 |
  | Ring-level recall at 50 | 0.909 |

  Recall at 50 by typology: agent round-tripping 1.0, dormant-then-active 1.0, purchased mule cluster 0.61, ledger
  leak 0.42, fan-in fan-out 0.31, OTP takeover cash-out 0.20.
- **Limits.** Synthetic data inflates every score. The scorer is weak on small-amount second-layer mules in fan-out
  and takeover rings. It is a ranking signal for review, not a verdict.

## App permission classifier (`app-safety-check/`)

- **Task.** The probability that an Android app is malware, from its declared permissions and declared services.
  It is one input to the App Safety Check; the rules decide the hard cases.
- **Files.** `model.txt` (LightGBM text dump, 4.35 MB), `columns.json` (the 178 feature columns in training order),
  `meta.json` (dataset provenance, split, parameters, metrics, calibration knots, gates).
- **Training data.** LAMDA Baseline (IQSeC Lab, UTEP), <https://huggingface.co/datasets/IQSeC-Lab/LAMDA>, MIT licence:
  AndroZoo APKs labelled malware when VirusTotal detections are at least 4. Years 2019-2022, 288,554 training rows.
  The dataset is not redistributed here.
- **Rebuild.**

  ```bash
  cd libs/app-safety-check
  python -m bhorosha_app_safety_check.train_lamda --lamda /path/to/lamda --years 2019-2022   # writes ../../models/app-safety-check
  ```
- **Evaluation** (from `meta.json`; operating threshold 0.80 after calibration):

  | Slice | Accuracy | ROC-AUC | Recall | Benign flagged |
  |---|---|---|---|---|
  | In-distribution hold-out, 2019-2022 | 0.903 | 0.965 | 0.834 | 3.7 % |
  | 2023, unseen future | 0.926 | 0.927 | 0.585 | 0.7 % |
  | 2024, unseen future (few labels) | 0.956 | 0.857 | 0.451 | 0.7 % |

  Gates in `meta.json`: accuracy at least 0.90, ROC-AUC at least 0.95, model under 5 MB. All pass.
- **Limits.** Recall falls to about one half on future years. The newest banking-trojan behaviours (accessibility
  abuse, overlays, sideloading) are deterministic rules in `libs/app-safety-check`, not learned features. Retrain
  each year as labels mature. Details: `libs/app-safety-check/README.md`.

## Behaviour models (`ato/`, not included)

- **Task.** Per-user identity models over PIN-entry and swipe timing, a population (cold-start) model, and a
  coaching detector ("is someone telling this person what to type"). See `libs/ato/README.md`.
- **Why they are not here.** The models are trained on the HMOG dataset, which has its own licence terms and must be
  requested from its authors (<https://hmog-dataset.github.io/hmog/>). Models fitted on its sessions are not
  redistributed. The repository ships no behaviour artefacts.
- **Effect.** With `RISK_MW_ATO_ARTEFACTS_DIR` unset or empty, risk-mw returns no behaviour hits, and every other
  signal works as before.
- **Rebuild.** Download HMOG, then follow "Training the behaviour models" in `libs/ato/README.md`. The trainer writes
  to `models/ato/` by default.
