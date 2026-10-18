# risk-mw

## Purpose

risk-mw is the risk backend of FinNest. It decides, before a payment or a PIN reset completes, whether to allow it,
ask for a step-up, or hold it. When it holds a payment during a suspected scam call, it prepares a short spoken
warning for the customer. It also runs the App Safety Check on the customer's phone and fronts Case Zero, the
investigator agent.

The service is a FastAPI application on Cloud Run. It uses Gemini on Vertex AI, Firestore for state and audit, and
three model libraries from `libs/`. All data is synthetic.

## How it fits in FinNest

```
apps/mobile ──► risk-mw ──► Gemini (Vertex AI)
apps/console ─┘    │ ├────► Firestore (state, audit, reports)
                   │ └────► services/case-zero (investigations)
                   └── libs/synth (mule scorer), libs/ato (behaviour), libs/app-safety-check
```

- The mobile app posts device signals, asks for a score before each transfer, sends call transcript turns to the
  scam detector, and plays the warning when a payment is held.
- The operator console reads scores, App Safety results and investigations.
- Case Zero reads the App Safety verdict for a customer from `GET /v1/appsafety/latest/{uid}`.

The request and response models are in `app/contracts.py`. They are frozen: change them only in an additive way.

## Endpoints

| Method and path | What it does |
|---|---|
| `GET /health` | Liveness, service name and model version. |
| `POST /v1/risk/signals` | Stores the phone's live signals (call state, screen capture, SIM change, behaviour features) for the session. |
| `POST /v1/risk/score` | Scores a transaction with rules, models and stored signals; returns allow, step_up or hold with reasons. |
| `POST /v1/scam/turn` | Scores the call transcript so far with the scam detector and updates the call's evidence ledger. |
| `POST /v1/scam/transcribe` | File-mode speech to text for one caller turn. Off by default. |
| `WS /v1/scam/live` | Live caller transcription through Gemini Live. Off by default. |
| `POST /v1/intervene` | Opens an intervention for a held action and returns the warning card and its audio token. |
| `POST /v1/apa/turn` | Placeholder for a conversation with the assistant; it answers with empty text. |
| `POST /v1/apa/why` | Writes one validated warning on demand, signed with a token. |
| `POST /v1/apa/why-audio` | Speaks a signed warning line with Gemini TTS (streamed WAV). |
| `GET /v1/apa/warning/{session_id}` | The warning prepared for this call before the hold. |
| `GET /v1/apa/clips/{clip_id}` | One pre-rendered warning clip. |
| `POST /v1/apa/warning/stream` | Streams a freshly written warning, line by line. |
| `POST /v1/appsafety/check` | Runs the App Safety Check on the phone's app list and integrity verdict. |
| `GET /v1/appsafety/latest/{uid}` | The standing App Safety verdict for a customer. |
| `POST /v1/appsafety/demo-token` | Mints a demo Play Integrity token (demo mode only). |
| `GET /v1/mule/score/{acct_id}` | The mule score of an account at the scenario clock, with reasons. |
| `GET /v1/mule/demo-ring` | The accounts of the demo mule ring. |
| `POST /v1/actions/trusted-contact` | Asks the customer's trusted contact to approve a held action. |
| `GET /v1/actions/trusted-contact/{id}` | The state of a trusted-contact request. |
| `POST /v1/actions/trusted-contact/{id}/approve` | The trusted contact approves. |
| `POST /v1/actions/trusted-contact/{id}/decline` | The trusted contact declines. |
| `POST /v1/actions/trusted-contact/sweep` | Expires overdue requests (for a scheduler, `X-Operator-Token`). |
| `POST /v1/actions/money-lock` | Locks the balance, or part of it, for a time. |
| `DELETE /v1/actions/money-lock/{user_id}` | Removes the money lock. |
| `POST /v1/investigate` | Starts a Case Zero investigation for an account (or the scripted stub). |
| `GET /v1/investigations/{case_id}` | The case report. |
| `GET /v1/investigations/{case_id}/events` | The investigation as server-sent events. |
| `GET/PUT/DELETE /v1/demo/state/{uid}` | Demo-panel flags for a customer (demo mode only). |

Every response carries `X-Processing-Time-Ms`. Full schemas: `GET /openapi.json`.

## Scoring pipeline

`POST /v1/risk/score` runs these steps:

1. **Identity.** The caller is the uid from the Firebase ID token (`app/identity.py`). In demo mode the caller is the
   `X-Demo-User` header, and the response marks the identity as `demo`.
2. **Inputs.** The service reads, in parallel, the customer document, the demo flags, the call's scam session and the
   session signals that `/v1/risk/signals` stored (`app/sessions.py`).
3. **Rules.** Deterministic rules decide first (`app/rules.py`): a call in progress during a PIN reset, a recent SIM
   change, a new payee above the customer's usual amount, a money lock, an App Safety BLOCK.
4. **Payee screen.** For `send_money`, the mule scorer (`libs/synth`, `app/mule.py`) scores the payee at the scenario
   clock twice: on the evidence so far, and with this transfer added as one more inbound edge.
   `DEST_MULE_RISK` fires on the second score. A request cannot move the scenario clock (`app/clock.py`).
5. **Scam call.** The scam detector's score for the live call (`app/scam.py`) feeds the decision.
6. **Behaviour.** The behaviour models (`libs/ato`, `app/ato.py`) turn the session's PIN and swipe timing into
   identity and coaching hits. Without behaviour artefacts this step returns no hits.
7. **App Safety.** The latest App Safety verdict for the uid, or the result the phone sent with the request.
8. **Session model.** A small gradient-boosted model over about 20 session features (`models/session_risk.joblib`).
   The final score is the maximum of the rules and the model.
9. **Decision and warning.** The response gives the decision, the band and the reasons. On a hold during a scam call,
   it also carries the warning that the assistant prepared for this call.

Every request and response is written to the audit trail (`app/audit.py`).

### Scam detector

The detector reads the call transcript turn by turn. Gemini fills an evidence checklist (tactics with exact quotes,
the claimed identity, the request). Code keeps the evidence ledger and applies the rules in `app/scam_rules.py`; the
model never decides alone. The tactic cards and examples in `app/data/` are versioned data, loaded at runtime, so a
new card needs no deploy. When Gemini is off, over budget or fails, a keyword fallback answers (`app/scam_stub.py`).

### Warnings

The warning has four short lines: attention, tactic, rule and action. Code plans what the warning says
(`app/warnings/planner.py`), Gemini phrases it (`app/warnings/composer.py`), and a validator checks every line before
anyone hears it (`app/warnings/validator.py`). The validator rejects private brand names, names of people, numbers the
plan did not give, and words that tip off a scammer. The warning is prepared before the hold where possible
(`app/prerender.py`) and spoken with Gemini TTS (`app/tts.py`).

## Use of Google Cloud

| Service | Use |
|---|---|
| Gemini on Vertex AI | Scam detector (`volume` role), warning composer, App Safety triage, optional transcription and Live, TTS. |
| Firestore | Customer documents, demo state, interventions, transactions, scam sessions, `audit/{id}`, `appsafety_reports/{id}`. |
| Firebase Authentication | ID token check when `RISK_MW_AUTH_REQUIRED=true`. |
| Firebase Cloud Messaging | Trusted-contact push when `RISK_MW_FCM_ENABLED=true`. |
| Cloud Run | Hosting, one instance. |

The service does not use BigQuery.

Gemini model IDs and prices are only in `config/models.yaml`. Gemini runs on Vertex AI with the service account of
the Cloud Run service; the deployed service has no API key. Every Gemini call reserves its worst-case cost before it
is sent. Past `RISK_MW_GENAI_BUDGET_USD`, the Gemini routes answer from their stubs.

## Demo mode

`RISK_MW_DEMO_MODE=true` (the default) is for the demo and for local runs:

- With `RISK_MW_AUTH_REQUIRED=false`, there is no token check. Send `X-Demo-User: <uid>` to act as a customer
  (for example `rina`). Without the header the caller is `demo`.
- The demo panel can set flags (`/v1/demo/state/{uid}`, `demo_flags` in the score request). The response names each
  input that was simulated.
- The scenario clock is the demo transfer's moment in the synthetic world (`2026-11-10T14:13:00`).

With `RISK_MW_AUTH_REQUIRED=true`, every route needs a Firebase ID token, and a caller can act only on its own uid.

## Requirements

- Python 3.12.
- The packages in `requirements.txt` (tests: `requirements-dev.txt`).
- On macOS, `brew install libomp` for LightGBM.
- For Gemini and Firestore: a Google Cloud project with Vertex AI and Firestore, and Application Default Credentials.

## Configuration

All settings are environment variables with the prefix `RISK_MW_` (`app/settings.py`). `.env.example` lists the
common ones. The main settings:

| Variable | Default | Effect |
|---|---|---|
| `RISK_MW_PROJECT_ID` | empty | Google Cloud project for Vertex AI and Firestore. |
| `RISK_MW_REGION` | `asia-southeast1` | Cloud Run region. |
| `RISK_MW_DEMO_MODE` | `true` | Demo mode (see above). |
| `RISK_MW_AUTH_REQUIRED` | `false` | Verify Firebase ID tokens on every route. |
| `RISK_MW_FIRESTORE_ENABLED` | `false` | Use Firestore. Off: in-memory store, audit to the log. |
| `RISK_MW_GENAI_ENABLED` | `false` | Call Gemini. Off: stubs answer. |
| `RISK_MW_GENAI_BACKEND` | `auto` | `auto`, `vertex` or `api_key`. |
| `RISK_MW_GENAI_LOCATION` | `global` | Vertex AI location for Gemini. |
| `RISK_MW_GENAI_BUDGET_USD` | `5.0` | Gemini spend ceiling per instance. |
| `RISK_MW_MULE_ARTEFACTS_DIR` | unset | Mule scorer artefacts (`models/mule`). Unset: payee screen off. |
| `RISK_MW_ATO_ARTEFACTS_DIR` | unset | Behaviour artefacts (`models/ato`, not published). Unset: no behaviour hits. |
| `RISK_MW_APPSAFETY_ARTEFACTS_DIR` | unset | App permission classifier (`models/app-safety-check`). Unset: rules only. |
| `RISK_MW_SCENARIO_NOW` | empty | The moment payees are scored at (`YYYY-MM-DDTHH:MM:SS`). |
| `RISK_MW_INVESTIGATOR_URL` | empty | Case Zero base URL. Empty: the scripted stub answers. |
| `RISK_MW_HELP_LINES` | two wallet short codes | Caller numbers that count as a genuine help line. |
| `RISK_MW_TTS_ENABLED` | `false` | Speak warnings with Gemini TTS. |
| `RISK_MW_TRANSCRIPTION_ENABLED` | `false` | `/v1/scam/transcribe`. |
| `RISK_MW_LIVE_TRANSCRIPTION_ENABLED` | `false` | `/v1/scam/live`. |
| `RISK_MW_FCM_ENABLED` | `false` | Trusted-contact push. |
| `RISK_MW_RATE_LIMIT_ENABLED` | `true` | Per-caller quotas (429 with `Retry-After`). |
| `RISK_MW_DEMO_INTEGRITY_SECRET` | empty | Key for demo Play Integrity tokens. Empty: a random key per instance. |
| `RISK_MW_APA_TOKEN_SECRET` | empty | Key that signs warning lines for `/v1/apa/why-audio`. Empty: a random key per process. |
| `RISK_MW_OPERATOR_TOKEN` | empty | Shared secret for the trusted-contact sweep. |
| `RISK_MW_SESSION_TTL_S` | `1800` | How long stored session signals stay readable. |
| `GOOGLE_API_KEY` | empty | Gemini Developer API key, used only with `RISK_MW_GENAI_BACKEND=api_key` or `auto`. |

## Run locally

From the repository root:

```bash
python3.12 -m venv .venv && . .venv/bin/activate
pip install -r services/risk-mw/requirements-dev.txt
cd services/risk-mw
export PYTHONPATH=../../libs/synth:../../libs/ato:../../libs/app-safety-check
export RISK_MW_MULE_ARTEFACTS_DIR=../../models/mule
export RISK_MW_APPSAFETY_ARTEFACTS_DIR=../../models/app-safety-check
uvicorn main:app --reload --port 8080
curl -s -H 'X-Demo-User: rina' -H 'Content-Type: application/json' \
  -d '{"user_id":"rina","session_id":"s1","txn":{"type":"send_money","amount_bdt":500,"to_account":"acct_pirganj"}}' \
  http://localhost:8080/v1/risk/score
```

The defaults need no cloud access: no token check, an in-memory store, and stubs instead of Gemini. To use Gemini on
Vertex AI, run `gcloud auth application-default login`, then set `RISK_MW_PROJECT_ID` and `RISK_MW_GENAI_ENABLED=true`.

## Test

```bash
cd services/risk-mw
python -m pytest -q
```

`tests/conftest.py` puts the libraries on the path and points the service at `models/mule` and
`models/app-safety-check`. No test calls Gemini or any other network service. Tests that need data which is not in
the repository (the behaviour models, the HMOG feature table, the speech smoke set, saved eval results) skip and say
why.

The scripts in `eval/` and `scripts/` measure the detector, the warnings and TTS. Most of them call Gemini and cost
money; each says so in its first line. They write to `eval/results/`, which git ignores.

## Deploy

```bash
RISK_MW_PROJECT_ID=<gcp-project-id> RISK_MW_INVESTIGATOR_URL=<case-zero-url> scripts/deploy.sh
```

The script copies the three libraries into `vendor/` and the model artefacts into `artifacts/`, builds the image on
Cloud Build from the `Dockerfile`, deploys one Cloud Run instance with Firestore and Gemini on, and runs
`scripts/smoke.sh` against the new URL. `.gcloudignore` keeps tests and eval data out of the upload.

The service runs as one instance on purpose. The rate limits, the Gemini spend ledger, the session signals, the
App Safety verdicts, the interventions and the stub cases are in process memory. A second instance would count and
remember them separately. A production deployment must move them to Firestore or Redis first.

## Data the service keeps

The audit trail stores each request and response body in full, including behaviour feature vectors, amounts, payees,
the phone's app list and call transcripts. App Safety reports store the prompt sent to Gemini and its reply. All
values are synthetic. Before any real customer traffic, the service needs a redaction policy, a retention limit and
access control on these collections.

## Layout

```
main.py                 FastAPI app, routers, start-up
app/contracts.py        frozen request and response models
app/settings.py         configuration
app/routers/            HTTP routes
app/rules.py            deterministic rules and the decision
app/scam*.py            scam detector, rules, variants, fallback
app/warnings/           warning planner, composer, validator
app/data/               tactic cards and examples (versioned)
app/mule.py, ato.py, appsafety_engine.py   adapters for the model libraries
config/models.yaml      Gemini model IDs and prices
config/personas.json    demo personas
models/                 session risk model
seed/scam_scripts.jsonl scripted demo calls
eval/                   evaluation scripts and labelled dialogue sets
scripts/                deploy, smoke test, replays, training
tests/                  pytest suite
```
