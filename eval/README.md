# Evaluation summary (`eval/run.py`)

## Purpose

`eval/run.py` regenerates the measured numbers of FinNest with one command and writes one summary. It runs the cheap
parts itself and reads the expensive parts from the result files that each component's own harness writes.

## How it fits in FinNest

| Section | Source | Run by `run.py`? |
|---|---|---|
| Mule scorer | `libs/synth/eval/mule_eval.py` on `data/seed` (evaluate only; never rewrites `models/mule`) | yes |
| Test suites | `pytest` in `services/risk-mw` and `libs/synth` | yes |
| Behaviour model | `libs/ato/eval/results/ato_hmog.json` (`libs/ato/eval/ato_eval.py`, needs the HMOG dataset) | no, read only |
| App Safety Check | `eval/results/appsafety.json` (`libs/app-safety-check/eval/appsafety_eval.py`) | no, read only |
| Investigator | `services/case-zero/eval/results/case_zero.json` (`services/case-zero/eval/run_eval.py`, spends Gemini money) | no, read only |
| Campaign Radar | `eval/results/campaign.json` (`libs/radar/eval/radar_eval.py`) | no, read only |
| Common point of cash-out | `eval/results/cashout.json` (`libs/radar/eval/cashout_eval.py`) | no, read only |
| Gemini usage | `services/risk-mw/config/models.yaml`, plus the spend that Case Zero measured | yes |
| Deployment | `services/risk-mw/scripts/smoke.sh` and 20 latency probes, only with `--url` | optional |

A module with no result file is listed under "Not run yet". A corrupt file costs its section one line, not the run.
The summary keeps only the fields that it renders: no per-user, per-case or per-account rows, and no absolute paths.

## Requirements

- Python 3.12 with the requirements of `libs/synth` and `services/risk-mw` installed, plus `pyyaml`.
- Run it with the interpreter of that environment: `run.py` starts the sub-commands with the same interpreter.

## Configuration

| Option | Default | Meaning |
|---|---|---|
| `--url` | none | base URL of a deployed risk-mw, for the smoke test and the latency probe |

There are no environment variables. The latency probe sends `X-Demo-User: eval-runner`, so its audit rows are never
mistaken for demo traffic.

## Run locally

```bash
python eval/run.py                              # from the repository root
python eval/run.py --url "$RISK_MW_URL"         # also smoke + latency against a deployed service
```

Outputs: `eval/results/summary.json` and `eval/results/summary.md`. `eval/results/` is not committed; every file in
it is generated. To fill the read-only sections, run the component harnesses first, for example:

```bash
(cd libs/radar && python eval/radar_eval.py --seed-dir ../../data/seed-campaign && python eval/cashout_eval.py)
(cd libs/app-safety-check && python eval/appsafety_eval.py)
```

Exit code: 0 when every module that ran is `ok`, else 1.

## Test

```bash
python -m pytest -q eval/tests
```

The tests use synthetic result dictionaries. They make no network call and need no result files.

## Deploy

Not deployed. This is a developer tool.

## Layout

```
eval/
  run.py              the summary runner
  tests/              unit tests for the projections and the Markdown
  results/            generated output (not committed)
```
