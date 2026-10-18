# FinNest Admin console

FinNest Admin (ফিননেস্ট অ্যাডমিন) is the operator console for FinNest. It is a FastAPI service
(`api/`) and a React, Vite and TypeScript page (`web/`). One container serves both.

## Purpose

The console shows the people who run FinNest what the fraud defences did, and with what evidence.
It reads and replays. It does not decide and it does not write.

- Every figure comes from code: the seed world, replayed through risk-mw's own rule engine and
  mule scorer, plus the eval result files. No figure is typed in by hand.
- Every section carries a badge: MODEL, RULE, STUB, SYNTHETIC or NO DATA.
- Each rate is shown next to its denominator. The catch rate and the false-positive rate are always
  shown together.
- The page is bilingual. Bangla is the default and English is the alternative.

## How it fits in FinNest

| Component | Relation to the console |
|---|---|
| `services/risk-mw` | The console imports its `app` package (rules, mule scorer, settings, Gemini client) through `api/risk_mw.py`. The browser calls a running risk-mw for the Live panel. |
| `services/case-zero` | The API reads Case Zero server-side (watch-list, ring graph, case files, a recorded replay). |
| Firestore `audit` collection | risk-mw writes one document per call. The Logs view reads it (`api/audit.py`). |
| `data/seed`, `data/seed-campaign` | The synthetic worlds that the fixtures are built from. |
| `models/mule`, `models/ato` | The model files that the replay and the scenarios load. |
| `libs/synth`, `libs/ato`, `libs/radar` | Packages that the scorer, the scenarios and the fixture builders import. |
| `design-system` | `web/src/main.tsx` imports `design-system/web/finnest.css`. The console has no colours, sizes or durations of its own. |

The console is a separate Cloud Run service. risk-mw runs on one instance because it keeps state
in memory, and a SHAP pass in the console must not share that instance.

## Requirements

- Python 3.12 with `api/requirements.txt` installed.
- Node.js 20 or later and npm, for `web/`.
- To see live data: a running risk-mw and Case Zero, and Google Cloud application-default
  credentials for Firestore and Vertex AI. Without them the related panels say that the source is
  not available. The rest of the console still works from the committed fixtures.

## Configuration

Copy `.env.example` to `.env`, fill it in and export it (`set -a; . ./.env; set +a`).

| Variable | Read by | Default | Purpose |
|---|---|---|---|
| `ADMIN_USER` | `api/auth.py` | `admin` | The one operator account. |
| `ADMIN_PASSWORD` | `api/auth.py` | local-dev default | The account password. Required on Cloud Run. |
| `SESSION_SECRET` | `api/auth.py` | local-dev default | Signs tokens and salts the password hash. Required on Cloud Run. |
| `TOKEN_HOURS` | `api/auth.py` | `12` | Token lifetime. |
| `RISK_MW_URL` | `api/main.py` | empty | risk-mw base URL, reported on `/health`. |
| `CASE_ZERO_URL` | `api/casezero.py` | empty | Case Zero base URL. Empty means the Cases view reports "not configured". |
| `PROJECT_ID` | `api/audit.py`, `scripts/deploy.sh` | ADC project | Google Cloud project for the Firestore audit log, and the deploy target. |
| `RISK_MW_GENAI_ENABLED`, `RISK_MW_PROJECT_ID`, `RISK_MW_GENAI_BUDGET_USD` | risk-mw settings | off | Gemini's reading of a stored score in the audit drawer, with a per-instance spend cap. |
| `FINNEST_ADMIN_GEMINI_WARM_UP_CALL` | `api/insight.py` | off | Make one full warm-up reading at start-up. |
| `CONSOLE_ATO_SESSIONS` | `api/scenarios.py` | none | JSONL behaviour enrolment sessions. Without them the behaviour step reports "off". |
| `VITE_RISK_MW_URL` | `web/src/lib/api.ts`, at build time | `http://localhost:8080` | risk-mw base URL that the browser calls. |
| `PYTHON` | `tools/dev.sh`, `scripts/deploy.sh` | `python3` | The Python interpreter to use. |
| `REGION`, `SERVICE` | `scripts/deploy.sh` | `asia-southeast1`, `finnest-admin` | Cloud Run region and service name. |
| `CONSOLE_URL` | `scripts/smoke.sh` | none | Base URL to smoke-test. |

When `K_SERVICE` is set (on Cloud Run), the API does not start if `ADMIN_PASSWORD` or
`SESSION_SECRET` is unset. Thus a deployed console never accepts the local-dev password.

## Run locally

```bash
cd apps/console
python3 -m pip install -r api/requirements.txt
(cd web && npm ci)

tools/dev.sh            # builds web/ and serves API and page on http://127.0.0.1:8099
tools/dev.sh --watch    # API on :8099, Vite with hot reload on http://127.0.0.1:5173
```

Sign in as `admin`, with the password in `ADMIN_PASSWORD`. If `ADMIN_PASSWORD` is unset, the
password is the local-dev default in `api/auth.py`.

The fixtures in `fixtures/` are committed. Rebuild them after you change the seed, the rules or
the radar:

```bash
python3 tools/build_overview.py     # fixtures/overview.json and payee_rollup.json (about a minute)
python3 tools/build_campaigns.py    # fixtures/campaigns.json; needs eval/results/campaign.json
python3 tools/build_cashout.py      # fixtures/cashout.json; needs eval/results/cashout.json
```

Each builder takes `--check`, which fails if the committed file is stale. The eval result files are
not committed. Make them with `eval/run.py`, `libs/radar/eval/radar_eval.py` and
`libs/radar/eval/cashout_eval.py`.

## Test

```bash
python3 -m pytest -q          # API, aggregate, fixtures, brand and deploy checks
cd web && npm ci && npm run build && npm run typecheck
node tests/app_safety_harness.cjs        # also run by pytest when web/node_modules exists
node tests/campaigns_view_harness.cjs
node tests/gemini_insight_harness.cjs
```

The tests do not call Google Cloud. Tests that need a reachable Case Zero are skipped. When the
eval result files are absent, the fixture checks compare only the parts built from the seed world.

## Deploy

```bash
PROJECT_ID=my-project ADMIN_PASSWORD='...' RISK_MW_URL=https://... CASE_ZERO_URL=https://... \
  scripts/deploy.sh                 # test, build, assemble .deploy/, deploy to Cloud Run, smoke test
scripts/deploy.sh --context-only    # only assemble .deploy/ for a local `docker build .deploy`
scripts/smoke.sh https://<console-url>
```

`scripts/deploy.sh` assembles a build context that mirrors the repo layout. The context holds
`apps/console` with a vendored `vendor/` (risk-mw's `app`, `bhorosha_graph`, `bhorosha_synth`,
`bhorosha_ato`), `data/seed`, `models/mule`, `models/ato` and any eval results that are present.
Then `gcloud run deploy --source` builds the `Dockerfile` in that context. The service runs as
exactly one instance. The script reuses the signing secret of the running service, so a redeploy
does not sign anyone out. Passwords that contain a comma break `--set-env-vars`. For production,
keep `ADMIN_PASSWORD` and `SESSION_SECRET` in Secret Manager.

This sign-in is for demos only: one account, no roles, no reset and no lockout. The production
design is Firebase Auth with custom claims, checked on every route.

## Layout

```
api/            FastAPI service: routes (router.py), the aggregate, auth, audit, Case Zero, Gemini insight
fixtures/       committed build outputs that the API serves: overview, payee rollup, campaigns, cash-out
tools/          fixture builders, map-data builders, icon generator, dev.sh
web/            React console; src/components (views, panels), src/lib (API client, i18n, types)
tests/          pytest suite and the Node harnesses that render components with the real strings
scripts/        deploy.sh and smoke.sh
API.md          what the console consumes from risk-mw and the /v1/admin/* routes it adds
Dockerfile      the Cloud Run image, built from the context that deploy.sh assembles
.env.example    every configuration variable, with placeholders
```
