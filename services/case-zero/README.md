# Case Zero

## Purpose

Case Zero is the investigator agent of FinNest. An analyst gives it one flagged account and an investigation time.
Gemini then calls graph tools over the synthetic FinNest world, step by step, to map the mule ring around the
account. A case writer drafts the case in English and Bangla. Code checks the case before it leaves the service and
sets the minimum action.

All data is synthetic. The numbers that Case Zero produces show behaviour on a generated world, not real-world
accuracy.

## How it fits in FinNest

```
apps/console ──► services/risk-mw ──► services/case-zero ──► Gemini (Vertex AI)
                 POST /v1/investigate      │
                                           ├── libs/synth (graph tools, mule scorer), models/mule, data/seed
                                           └── risk-mw GET /v1/appsafety/latest/{uid} (device_safety tool)
```

- risk-mw fronts Case Zero (`services/risk-mw/app/investigator.py`). `POST /v1/investigate` starts a case with
  `POST /api/investigations`, relays `GET /api/investigations/{id}/events` as its own event stream, and reads the
  final case from `GET /api/cases/{id}/contract`, in risk-mw's `CaseReport` shape. When Case Zero is not set, busy
  or down, risk-mw answers from a scripted stub.
- Case Zero calls risk-mw back for one tool: `device_safety` reads the customer's App Safety verdict.
- The operator console plays a recorded investigation (`GET /api/replay`) and reads the payee watch-list
  (`GET /api/payee-risk`).

## How an investigation runs

1. **Opening brief (`tc_00`).** Code, not the model, fetches the seed account's mule score and band, the high-scoring
   accounts around it and any pattern leads.
2. **Tool loop.** Gemini calls tools (at least 4, at most 15). Every call gets an id (`tc_01`, `tc_02`, ...) and is
   streamed to the console. Calls in one turn run concurrently. The investigation time (`as_of`) is put into every
   tool by code; the model cannot choose it.
3. **Case writer.** Gemini writes the case: typology, members and roles, red flags, timeline and two narratives.
4. **Citation check.** Code checks that every account id, transaction id, agent id, Taka amount, date and time in the
   case appears in a tool output of this investigation, that every cited call exists, and that the English and Bangla
   narratives name the same facts (`case_zero/validator.py`). A failed case goes back to the writer once. What still
   fails is removed, and the case leaves as `degraded`.
5. **Membership check.** Code keeps only the members it can link to the ring by this incident's money, a shared
   identity, a pattern lead or, for agent tills, repeat cash-outs (`case_zero/gate.py`). Dropped members move to
   `excluded` with the reason.
6. **Action.** Code copies the model score and sets the action floor from risk-mw's score bands
   (`case_zero/policy.py`). Red flags with fitting citations can raise the action one level.

The citation check proves that a cited fact exists in a tool output. It does not prove that the sentence follows from
the cited row (for example, the direction of a transfer). The eval judge scores that part.

The agent is a tool-calling loop written directly on the `google-genai` SDK (`case_zero/orchestrator.py`,
`case_zero/llm.py`). It does not use the Agent Development Kit.

## Tools

| Tool | What it returns |
|---|---|
| `get_account` | Account profile: kind, district, opening date, status, onboarding agent. |
| `score` | The mule model's probability at the investigation time, with its top 10 reasons. |
| `score_neighbours` | Mule scores for accounts within 1 to 3 transfers or sharing a device, SIM, NID or phone. |
| `neighbours` | Money counterparties within 1 or 2 transfers, both directions, one row per transfer. |
| `path_between` | The shortest time-ordered money path between two accounts. |
| `shared_entities` | Devices, SIMs, NIDs, phones or onboarding agents that two or more accounts share. |
| `velocity_stats` | Inbound and outbound counts and totals in a window, counterparties, pass-through ratio. |
| `agent_till_stats` | Cash-in and cash-out activity at an agent till, with repeat counterparties. |
| `kyc_dupe_check` | Other accounts that share this account's NID, phone, device or SIM. |
| `known_fraud_proximity` | Hops to accounts already confirmed as fraud, with a 3-day confirmation lag. |
| `dormant_cohort` | Other accounts that woke from dormancy within hours of this one. |
| `common_point_of_compromise` | A place most of the recent senders paid, and other accounts its payers sent money to. |
| `device_safety` | The App Safety verdict for the customer's phone, from risk-mw. `known=false` when risk-mw is not set or down. |

The tools wrap `bhorosha_graph` from `libs/synth` without changes to it. Two corrections are made in
`case_zero/world.py`: known fraud counts only after the scorer's confirmation lag, and scores are computed at the
investigation time, not at the artefact cutoff. Persona account ids are aliased, and identity ids are hashed, so the
model never sees a label.

## Endpoints

| Method and path | What it does |
|---|---|
| `GET /` | The console (`static/index.html`). |
| `GET /health` | Liveness. |
| `GET /api/seeds` | Suggested seed accounts and times. |
| `POST /api/investigations` | Starts a case (`{seed or acct_id, as_of?}`); returns `case_id`, `stream_url`, `status_url`. |
| `GET /api/investigations/{id}/events` | The case as server-sent events; resumes after `Last-Event-ID`. |
| `GET /api/investigations/{id}` | Status and events since `?since=n` (polling fallback). |
| `POST /api/investigate` | One request that streams the whole case. |
| `GET /api/cases/{id}` | The case report. |
| `GET /api/cases/{id}/contract` | The case in risk-mw's `CaseReport` shape. |
| `POST /api/cases/{id}/approve` | Analyst approval; needs the `X-Admin-Token` header. |
| `GET /api/decisions/{id}` | The stored decision: members, roles, action. |
| `GET /api/payee-risk` | The watch-list of payees that decided cases name. |
| `GET /api/replay` | The recorded investigation in `static/replay/demo.jsonl`. |

Case ids are `CZ-` and ten random base32 characters. The read routes have no authentication, so a case id works as a
bearer secret. risk-mw, which fronts these routes, answers 404 for a case that the caller did not start when
`RISK_MW_AUTH_REQUIRED=true`. Before real data, put the read routes behind a token or make them reachable only from
risk-mw.

## Requirements

- Python 3.12 and the packages in `requirements.txt` (tests and the dev-world generator: `requirements-dev.txt`).
- On macOS, `brew install libomp` for LightGBM.
- The repository layout: `libs/synth`, `models/mule`, `data/seed` and `services/risk-mw/config/models.yaml`.
- For Gemini: a Google Cloud project with Vertex AI, and Application Default Credentials.

## Configuration

`.env.example` lists these variables.

| Variable | Default | Effect |
|---|---|---|
| `CASE_ZERO_PROJECT_ID` | empty | Google Cloud project. When set, Gemini runs on Vertex AI. |
| `CASE_ZERO_LOCATION` | `global` | Vertex AI location. |
| `CASE_ZERO_BUDGET_USD` | `1.40` | Hard cap on Gemini spend, kept in `.spend.json`. |
| `CASE_ZERO_SPEND_FILE` | `.spend.json` | Where the spend ledger is kept. |
| `CASE_ZERO_TRUSTED_HOPS` | `1` | Proxies that append to `X-Forwarded-For`: 1 on run.app, 2 behind a load balancer, 0 locally. |
| `CASE_ZERO_ADMIN_TOKEN` | empty | Token for `POST /api/cases/{id}/approve`. Empty: approval is refused. |
| `CASE_ZERO_RISK_MW_URL` | empty | risk-mw base URL for `device_safety`. Empty: the tool answers `known=false`. |
| `CASE_ZERO_PROJECT_DIR` | repository root | Where `libs/`, `models/` and `data/` are found. |
| `CASE_ZERO_BACKEND` | automatic | `vertex` or `api_key` (with `GOOGLE_API_KEY`) to force a backend. |

Model IDs and prices come from the `workhorse`, `judge` and `reasoning` roles in
`services/risk-mw/config/models.yaml`, the single source for the whole repository.

### Spend cap

Before a Gemini call, Case Zero reserves the call's worst case: its prompt estimate plus its whole output cap, at the
role's price. The call is sent only if spent plus reserved plus this call fits under the cap, so concurrent calls
cannot pass it together. After the call, the reservation settles at the real cost. An error reply costs nothing. A
timeout or a cancellation after the request left is charged its full reservation, because Gemini can still bill it.
At the cap, cases come back score-only with the limitation "Gemini spend cap reached". The ledger is per process.

### Limits per instance

- One investigation runs for at most 90 s (55 s for the tool loop), then ends as `failed`.
- Per-IP limits and a concurrency gate protect the public URL.
- Cases and decisions are kept in memory. A restart clears them. The display history keeps the last 200 cases; the
  decisions store keeps every decided case that names someone, for the watch-list.

## Run locally

From the repository root:

```bash
python3.12 -m venv .venv && . .venv/bin/activate
pip install -r services/case-zero/requirements-dev.txt
cd services/case-zero
cp .env.example .env            # set CASE_ZERO_PROJECT_ID; leave it empty to run without Gemini
gcloud auth application-default login
set -a; . ./.env; set +a
uvicorn case_zero.app:app --port 8090
```

Open <http://localhost:8090>. Without a Gemini backend, the console still plays the recorded replay.

To point risk-mw at this instance, set `RISK_MW_INVESTIGATOR_URL=http://localhost:8090` there.

## Test

```bash
cd services/case-zero
python -m pytest -q
```

The tests use a fake model (`tests/fake_llm.py`) and never call Gemini or risk-mw. Some tests build a second
synthetic world (seed 7) in a temporary directory, so the first run takes a few minutes.

### Evaluation

`eval/run_eval.py` runs Case Zero on 17 labelled rings and 10 benign look-alikes of the seed-42 world, with baselines
and a Gemini judge. It calls Gemini and costs money. Results go to `eval/results/` (git-ignored). Thresholds are tuned
only on separate worlds made with `python -m eval.dev_world --seed 7` (written to `.dev_world/`).

To record a new replay, run the service with Gemini, then:

```bash
python scripts/record_replay.py http://127.0.0.1:8090 static/replay/demo.jsonl
```

`tests/test_served_replay.py` checks what the consoles need from the replay.

## Deploy

```bash
CASE_ZERO_PROJECT_ID=<gcp-project-id> CASE_ZERO_RISK_MW_URL=<risk-mw-url> ./deploy.sh
```

The script stages a build context with the repository layout (the synth packages, `models/mule`, two seed files and
`models.yaml`), builds the `Dockerfile` on Cloud Build and deploys one Cloud Run instance with Gemini on Vertex AI.
It uses `--no-cpu-throttling`, so a run continues after its viewer leaves; CPU is then billed for the whole life of
the instance. Behind an external load balancer, deploy with `CASE_ZERO_TRUSTED_HOPS=2` and close the run.app URL
(`--ingress internal-and-cloud-load-balancing`).

## Layout

```
case_zero/app.py           FastAPI app, routes, rate limits
case_zero/orchestrator.py  tool loop, case writer, retry
case_zero/tools.py         tool specs and implementations
case_zero/world.py         the synthetic world at an investigation time
case_zero/patterns.py      dormant cohort and common point of compromise
case_zero/validator.py     citation check and flag evidence
case_zero/gate.py          membership check
case_zero/policy.py        bands and actions
case_zero/schemas.py       draft, report and contract models
case_zero/llm.py, budget.py  Gemini client and spend ledger
case_zero/export.py        decisions and the payee watch-list
static/                    console and recorded replay
docs/payee_risk.example.json  example of the watch-list format
eval/                      evaluation harness, baselines, judge, dev worlds
scripts/record_replay.py   records a replay
tests/                     pytest suite and fixtures
```
