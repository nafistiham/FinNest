# Evaluation criteria

This guide defines how to check that the code in this repository works as expected. Each check has
an id, a method and a pass condition. `scripts/verify.sh` runs the automatic checks (E1 to E5).
The manual checks (E6 to E8) need a phone or a deployed environment.

## How to run

```bash
python3.12 -m venv .venv && source .venv/bin/activate
scripts/verify.sh --install            # E1-E4, about 10 minutes on a laptop
scripts/verify.sh --mobile             # adds E5 (needs FVM and Flutter 3.47.7)
```

The script exits with code 0 only when every check passes. It prints the failed check ids
otherwise, with the path of the log file to read.

## E1 Repository hygiene

| Id | Check | Pass condition |
|---|---|---|
| E1.1 | `gitleaks dir .` | No findings |
| E1.2 | Search for API keys, OAuth tokens and private keys | No match |
| E1.3 | File sizes | No file is larger than 50 MB (GitHub's warning limit) |
| E1.4 | Local config | `google-services.json` and `apps/mobile/config/dart_defines.json` are not tracked |
| E1.5 | Brand names (manual) | No private company name in user-facing text: app strings, the knowledge base, warning copy, console strings, seed data. Names may appear only in detector word lists and detector test inputs, each marked with a comment |
| E1.6 | Process noise (manual) | No ticket ids, team member names or links to private tools in code, comments or docs |

## E2 Unit and integration tests

Run inside each component directory with `python -m pytest -q`. No test calls a cloud service.

| Id | Component | Expected result |
|---|---|---|
| E2.1 | `services/risk-mw` | 1,343 or more passed, 0 failed. About 30 skips are allowed. Each skip names the missing behaviour model or optional data file |
| E2.2 | `services/case-zero` | 325 or more passed, 0 failed |
| E2.3 | `libs/synth` | 74 or more passed, 0 failed |
| E2.4 | `libs/app-safety-check` | 80 or more passed, 0 failed |
| E2.5 | `libs/ato` | 373 or more passed, 0 failed |
| E2.6 | `libs/radar` | 151 or more passed, 0 failed |
| E2.7 | `eval` | 42 or more passed, 0 failed |
| E2.8 | `apps/console` | 228 or more passed, 0 failed, after the web build (E3). 1 skip needs a running case-zero. 6 more skip until `libs/radar/eval/radar_eval.py` and `cashout_eval.py` write `eval/results/`; then 234 pass |

## E3 Console web build

| Id | Check | Pass condition |
|---|---|---|
| E3.1 | `cd apps/console/web && npm ci && npm run build` | TypeScript reports no errors and Vite writes `dist/` |

## E4 Local HTTP smoke test (risk-mw in demo mode)

`scripts/verify.sh` starts `uvicorn main:app` in `services/risk-mw` with no cloud configuration.

| Id | Request | Pass condition |
|---|---|---|
| E4.1 | `GET /health` | HTTP 200 |
| E4.2 | `POST /v1/risk/score`: a PIN reset during an active call after a SIM swap | `decision` is not `allow` |
| E4.3 | `GET /openapi.json` | Lists `/v1/scam/turn` |

## E5 Android app

| Id | Check | Pass condition |
|---|---|---|
| E5.1 | `fvm flutter analyze --no-fatal-infos` | No errors or warnings |
| E5.2 | `fvm flutter test` | 2,549 or more passed. One known failure is allowed: `shared_widgets_test` "TxnRow never repeats its title" |
| E5.3 | `make build-debug` | The debug APK builds with no Firebase configuration |

## E6 Deployed services (manual)

Deploy with each component's `deploy.sh` (see its README), or use the team's deployment.

| Id | Check | Pass condition |
|---|---|---|
| E6.1 | `GET <risk-mw>/health` and `GET <case-zero>/health` | HTTP 200 |
| E6.2 | `services/risk-mw/scripts/smoke.sh <risk-mw-url>` | Every step passes |
| E6.3 | `POST <risk-mw>/v1/scam/turn` with a caller who asks for an OTP | Gemini answers (not the stub): `model_version` names a Gemini model and the verdict is a scam |
| E6.4 | `POST <risk-mw>/v1/investigate` for a flagged account | case-zero returns a case with cited tool calls |
| E6.5 | Console sign-in with the configured operator account | The overview, cases and campaign pages load |

## E7 Phone walkthrough (manual, on a real Android 9+ phone)

Install a release APK that is built with the deployed URLs and registered for App Check.

| Id | Step | Pass condition |
|---|---|---|
| E7.1 | Sign in with the demo password | Home opens. The language switch changes every screen between Bangla and English |
| E7.2 | Send money to a new payee while a demo scam call is active | The transfer is held. The hold screen shows and speaks the server's reason |
| E7.3 | Cash in, cash out, pay a bill, recharge, history | Each flow completes with a receipt and appears in history |
| E7.4 | Run the App Safety Check with the demo risky app installed | The verdict names the app and the reason |
| E7.5 | Open the assistant and type a safety question in Bangla, then in English | The answer is on topic, cites the knowledge base and contains no code, PIN or link |
| E7.6 | Ask the assistant "Is my phone safe?" | The answer matches the App Safety Check verdict |
| E7.7 | Tap Talk and ask a question by voice | The assistant answers by voice. The text of the answer shows in the same view |
| E7.8 | Talk over the assistant while it speaks | It stops speaking |
| E7.9 | Ask for a summary of the suspicious call after a scam check | The call summary card shows what the caller asked for, with codes hidden |
| E7.10 | Turn on aeroplane mode and ask a question | An offline answer comes from the on-device knowledge base |

## E8 Equivalence with the development repository

The code here was exported from the team's private development repository. The export moved
folders, replaced hard-coded cloud identifiers with configuration, made user-facing brand names
generic, and removed personal data and process notes. It changed no scoring or model logic.

| Id | Check | Pass condition |
|---|---|---|
| E8.1 | Compare test counts with the development repository | Equal, except for tests that were removed or now skip because personal data or third-party models were removed |
| E8.2 | Compare model outputs | The mule scorer on seed 42 gives the numbers in `models/README.md` (AUC-PR 0.841) |
| E8.3 | Review the diff of non-documentation code against the development repository | Each change is a path, configuration, naming or comment change, or is listed in this guide |
