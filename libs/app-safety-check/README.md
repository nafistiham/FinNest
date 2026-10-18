# App Safety Check (`bhorosha_app_safety_check`)

## Purpose

This library finds malware-shaped, fake-loan and remote-access apps on the customer's phone. It uses only data that
a bank app can read without a dangerous permission. It tells the customer in Bangla which app to uninstall before
money moves.

## How it fits in FinNest

- The mobile app collects the installed-app list (`android/collector/`) and posts it to
  `POST /v1/appsafety/check` in `services/risk-mw`.
- The risk-mw adapter `app/appsafety_engine.py` calls this library. The deploy script of risk-mw copies the
  library into the service image, together with `libs/synth` and `libs/ato`.
- The latest verdict per user feeds `/v1/risk/score`. A BLOCK holds the next transfer with `APP_SAFETY_BLOCK`.
- The serving model is in `models/app-safety-check/` (`model.txt`, `columns.json`, `meta.json`). risk-mw loads it
  from `RISK_MW_APPSAFETY_ARTEFACTS_DIR`. If the model is absent, the check runs on rules only. It never fails.

## Requirements

- Python 3.12.
- `pip install -r requirements.txt`. Serving needs `lightgbm`, `numpy` and `pydantic`. Training also needs
  `pandas`, `pyarrow` and `scikit-learn`.
- LightGBM needs OpenMP: `brew install libomp` on macOS, `libgomp1` on slim Linux images.
- Gemini triage (optional) runs through risk-mw on Vertex AI with Application Default Credentials. No API keys.

## Configuration

The library reads no environment variables. The evaluation script with `--gemini` uses the risk-mw settings:

| Variable | Used by | Meaning |
|---|---|---|
| `RISK_MW_GENAI_ENABLED` | `eval/appsafety_eval.py --gemini` | `true` turns on the Gemini call |
| `RISK_MW_GENAI_BACKEND` | same | `vertex` |
| `RISK_MW_PROJECT_ID` | same | your Google Cloud project id |

The serving settings (`RISK_MW_APPSAFETY_*`, for example `RISK_MW_APPSAFETY_REQUIRE_ATTESTATION`,
`RISK_MW_APPSAFETY_CERT_DIGESTS`, `RISK_MW_DEMO_INTEGRITY_SECRET`) are documented in `services/risk-mw/README.md`.

## Run locally

```bash
cd libs/app-safety-check
python eval/appsafety_eval.py            # rules + classifier on 32 synthetic cases -> ../../eval/results/appsafety.{json,md}
RISK_MW_GENAI_ENABLED=true RISK_MW_GENAI_BACKEND=vertex RISK_MW_PROJECT_ID=<gcp project> \
  python eval/appsafety_eval.py --gemini # also run Gemini triage through the risk-mw engine
```

Retrain the classifier (download LAMDA first, see "Model"):

```bash
python -m bhorosha_app_safety_check.train_lamda --lamda /path/to/lamda --years 2019-2022   # -> ../../models/app-safety-check
```

`train.py` trains the same artefacts from a CSV dataset (for example NATICUSdroid).

## Test

```bash
cd libs/app-safety-check
python -m pytest -q        # unit tests, no network, no model download
```

## Deploy

This is a library. It is deployed as part of `services/risk-mw` (Cloud Run). See that README.

## Layout

```
bhorosha_app_safety_check/
  schema.py       signals, severities, verdict thresholds and cited policy facts (Play Protect fraud permissions,
                  Personal Loans forbidden permissions, remote-access package ids, BFIU fake-loan names, install origins)
  rules.py        hand-written rules: pure functions, wire rows -> hits with Bangla and English copy
  scoring.py      strongest hit per app, noisy-OR across apps, capped below BLOCK unless a hard escalator exists
  features.py     permission vectoriser in the training column order (columns.json)
  model.py        LightGBM at serving time, TreeSHAP contributions via pred_contrib, under 1 ms per app
  train_lamda.py  LAMDA parquet files -> model.txt + columns.json + meta.json (metrics, gates, provenance)
  train.py        CSV dataset -> the same artefacts
  integrity.py    Play Integrity verdict mapping; demo-mode HMAC-signed synthetic verdict
  triage.py       evidence bundle, system instruction, TriageVerdict schema, post-hoc validation
  pipeline.py     one check end to end, no I/O; the fusion rules
eval/
  appsafety_cases.jsonl   32 synthetic bundles (clean, fake-loan, remote-access, privileged-benign, 2026 threats,
                          two 300-app phones that test the prompt size)
  appsafety_eval.py       classifier metrics, synthetic verdict accuracy, Gemini agreement
android/
  collector/      Kotlin reference sources for the Flutter app: the app-list collector and its MethodChannel
  takanow/        "TakaNow Loan", a harmless demo APK that declares the risky signals and uses none of them
tests/
```

Real brand names (mobile wallets, messaging apps) appear in `schema.py`, the tests and the evaluation cases. They are
kept only so the detector can recognise the genuine apps and the apps that impersonate them. They are never shown to
the customer.

## How a check decides

1. **Rules** (`rules.py`, every fact cited in `schema.py`). Examples: a sideloaded app with an accessibility service
   (`SIDELOADED_ACCESSIBILITY`, critical when enabled), known remote-access tools (`KNOWN_RAT`), loan-like or
   sideloaded apps that reach for two or more of contacts, photos, location, phone number, SMS and call log
   (`LOAN_APP_DATA_HARVEST`), sideloaded overlay and device-admin holders, root, developer options, Play Protect off,
   and the Play Integrity environment verdict (`UNKNOWN_CONTROLLING` is a hard BLOCK).
2. **Classifier** (`model.py`). LightGBM on the declared permissions of the app. `p >= 0.80` gives `CLASSIFIER_HIGH`:
   a hard high hit on a sideloaded app, a soft low hit on a Play-installed app.
3. **Score** (`scoring.py`). Strongest hit per app, noisy-OR across apps. Under 0.20 is SAFE, under 0.80 is CAUTION,
   else BLOCK. Without a critical hit or a hard high hit the score is capped at 0.79, so many Play apps that ask for
   broad permissions never cause a BLOCK.
4. **Gemini** (`triage.py`, structured output, minimal thinking). The model is called only when there is a hard hit or
   a soft classifier flag. It returns a verdict, a 0-100 score, up to six reasons, an action, the apps to uninstall,
   Bangla and English messages, `agrees_with_classifier` and `disagreement_reason`. Validation removes the words
   malware, virus and trojan, drops unknown packages, keeps on the uninstall list only apps with a hard finding, and
   uses a template when the message does not name the app.
   - **What the model sees** (`evidence_bundle`): the apps with findings in full, strongest first (at most 10 apps,
     at most 24 permissions each, policy-relevant permissions first), the other apps as counts by install origin,
     the device flags, the integrity verdict and the rule hits. The JSON is trimmed until it is under 8,000
     characters. A 300-app phone costs the same as a 3-app phone. Output is capped by
     `RISK_MW_APPSAFETY_MAX_OUTPUT_TOKENS` (default 1,536).
   - **When the model is not called**: if the caller or the shared Gemini quota is spent, the callable raises
     `GeminiDeclined` and the check answers from the rules (`gemini_used=false`). It never answers 429.
5. **Fusion** (`pipeline.fuse`): `final = max(rule floor, min(Gemini, CAUTION))`. Gemini can clear a soft flag and
   can raise a weak case to CAUTION. It can never lower a hard hit and never creates a BLOCK by itself. A model
   failure with hits present answers at least CAUTION with the generic Bangla message. A clean device never calls
   the model and is always SAFE.
6. **Persist** (in risk-mw): `appsafety_reports/{uid}_{ts}` in Firestore (prompt and response included, for the
   explainability panel), `audit/{id}`, and the latest verdict per user in process (BLOCK 24 h, else 15 min). The
   response says what lifts the verdict (`resolution`) and lists `uninstall_targets` with a Settings link per app.

**Install origin.** `installer` is the installing package, or the initiating package when the OS has only that (an
adb install arrives as `com.android.shell`), or `system`. The collector sends null only when `InstallSourceInfo` has
no provenance at all. That is the shape of OEM partner preloads and Phone Clone restores. Browser, shell, file-manager
and package-installer origins are sideloaded. Null is *unknown origin*: such an app counts as sideloaded only when it
can act on the screen now (enabled accessibility service, held overlay). Otherwise its reach is recorded as soft low
findings. A loan-named app with SMS reach stays a hard medium, and brand impersonation needs no provenance.

## Tamper resistance

"Mod APK" builds are common in Bangladesh. A patched FinNest app could post a clean, invented bundle and ask for a
SAFE. The server does not trust the bundle. It trusts a Play Integrity token that says three things:

1. the request came from the genuine Play-signed build (`appIntegrity.appRecognitionVerdict == PLAY_RECOGNIZED`,
   package and signing certificate as registered);
2. the device passes Google's checks (`deviceIntegrity` at least `MEETS_DEVICE_INTEGRITY`);
3. the token was made for this exact bundle: `requestDetails.requestHash` equals `integrity.bundle_hash()` over the
   received app list.

| Attestation | Meaning | Effect |
|---|---|---|
| `strong` / `device` | genuine build, bound token, healthy phone | evidence counts; SAFE possible |
| `basic` | bound, but only basic device integrity (custom ROM, unlocked bootloader) | `DEVICE_INTEGRITY_FAILED` medium |
| `virtual` | emulator | `DEVICE_INTEGRITY_FAILED` high |
| `unbound` / `none` | valid token without a request hash, or no token | production: `UNATTESTED_CLIENT` medium, never SAFE; demo: recorded, soft |
| `failed` | a token was sent but is bad or expired | `UNATTESTED_CLIENT` medium |
| `mismatch` | token made for another bundle (replay, or a lying client) | `BUNDLE_MISMATCH` critical: BLOCK, call the bank |
| `tampered` | `UNRECOGNIZED_VERSION`, wrong package or certificate | `CLIENT_TAMPERED` critical: BLOCK, reinstall from Play |

Two checks need no client honesty: an empty app list is `IMPLAUSIBLE_BUNDLE`, and a list under 30 % of the previous
size for the same user is `BUNDLE_SHRUNK`. Only a non-empty, attested re-check that lists no flagged package lifts a
BLOCK. For production, set `RISK_MW_APPSAFETY_REQUIRE_ATTESTATION=true`, set `RISK_MW_APPSAFETY_CERT_DIGESTS` to the
Play App Signing certificate digests, and turn on the Google decode path.

**Demo token.** The prototype is not on Play, so `appsDetected` cannot come from Google. In demo mode the app asks
`POST /v1/appsafety/demo-token` for `demo.<base64url json>.<hmac-sha256>`, signed with
`RISK_MW_DEMO_INTEGRITY_SECRET`. There is no default secret in the source: when it is unset, the service signs with a
random key per instance and logs a warning. The response is marked `simulated_verdict=true`. Build one with
`integrity.sign_demo_verdict(secret, ["UNKNOWN_CONTROLLING"], "POSSIBLE_RISK")`. Only a real token, decoded through
`playintegrity.googleapis.com`, gives `simulated_verdict=false`.

## Model

The shipped model (`appsafety-0.2-lamda-lgbm-305`) is trained on **LAMDA** Baseline (IQSeC Lab, UTEP;
<https://huggingface.co/datasets/IQSeC-Lab/LAMDA>; MIT licence; AndroZoo APKs, malware = VirusTotal detections >= 4),
years 2019-2022: 288,554 training rows. Features: 176 `android.permission.*` request columns plus two derived service
columns (`BIND_ACCESSIBILITY_SERVICE`, `BIND_NOTIFICATION_LISTENER_SERVICE`). SDK-marker permissions such as
`READ_PHONE_STATE` and `WRITE_EXTERNAL_STORAGE` are dropped, so that the model cannot learn "old app = malware".
LightGBM, 127 leaves x 305 rounds, 4.35 MB, about 0.07 ms per app. The raw score goes through the calibration knots in
`meta.json` before the 0.80 threshold.

| Slice | Rows (malware) | Accuracy | Macro-F1 | ROC-AUC | Recall @0.80 | Benign flagged @0.80 |
|---|---|---|---|---|---|---|
| In-distribution hold-out, 2019-2022 test files | 72,140 (33,043) | 0.903 | 0.902 | 0.965 | 0.834 | 3.7 % |
| 2023, unseen future | 54,354 (7,892) | 0.926 | 0.847 | 0.927 | 0.585 | 0.7 % |
| 2024, unseen future (few labels, noisy) | 48,427 (794) | 0.956 | 0.640 | 0.857 | 0.451 | 0.7 % |
| NATICUSdroid, 50 common columns | 29,332 (14,700) | 0.770 | 0.769 | 0.841 | 0.564 | 6.3 % |

Training on 2016-2022 (`--years 2016-2022`) lowered the pooled hold-out AUC to 0.920 with no gain on 2023, so the
oldest years are excluded. `meta.json` records this. On future years, recall at the operating threshold falls to about
one half, while the benign false-alarm rate stays near 1 %. Labelled malware for 2024-2026 is scarce in every open
corpus, because VirusTotal labels lag by about a year. For that reason the newest banking-trojan behaviours
(accessibility abuse, overlays, sideloading) are deterministic rules, not learned features. Retrain the model each
year as labels mature.

The offline evaluation gets 32 of 32 synthetic verdicts right with this model. All numbers are on public or
synthetic data, not on customer phones.

## Data kept

Every triage report in Firestore (`appsafety_reports/{id}`, written by risk-mw) stores the prompt sent to Gemini (the
app list and findings) and the raw reply. The log line leaves both out. All values are synthetic today. Before real
customer traffic, this needs a redaction policy (app lists truncated or hashed), a retention limit and access control
on the collection.
