#!/usr/bin/env bash
# One-command deploy of risk-mw to Cloud Run.
# The script vendors the synth, behaviour and App Safety packages and their model artefacts into the
# service directory, builds the image on Cloud Build and deploys one instance. Then it runs scripts/smoke.sh.
#
# Usage:
#   RISK_MW_PROJECT_ID=<gcp-project-id> scripts/deploy.sh
#   scripts/deploy.sh <gcp-project-id>
# Optional: RISK_MW_INVESTIGATOR_URL (the Case Zero URL), RISK_MW_REGION, RISK_MW_GENAI_BUDGET_USD,
# RISK_MW_DEMO_INTEGRITY_SECRET, RISK_MW_APPSAFETY_WARM_UP_CALL, RISK_MW_TTS_ENABLED.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
PROJECT="${1:-${RISK_MW_PROJECT_ID:?set RISK_MW_PROJECT_ID or pass the project id}}"
# Case Zero, which /v1/investigate fronts. Empty = the scripted stub answers.
INVESTIGATOR_URL="${RISK_MW_INVESTIGATOR_URL:-}"
# One instance on purpose (--max-instances 1): the rate limits, the Gemini spend ledger, the stub case store
# and the per-session behaviour features are in memory, so a second instance would count and remember separately.
# --concurrency 80, not 20: each open investigation stream (/v1/investigations/{id}/events) holds a request slot
# for about a minute while it idles on Case Zero, and a score call must not queue behind 20 open consoles.
# Gemini spend ceiling per instance; past it the Gemini routes answer from their stubs.
GENAI_BUDGET_USD="${RISK_MW_GENAI_BUDGET_USD:-5}"
REGION="${RISK_MW_REGION:-asia-southeast1}"
# The demo Play Integrity signing secret. Set RISK_MW_DEMO_INTEGRITY_SECRET to keep tokens valid across deploys;
# otherwise a fresh random one per deploy (a token lives ten minutes, so a redeploy only retires the panel's current one).
# Never a value from source: the service refuses to run on a known default and logs loudly when the variable is unset.
DEMO_INTEGRITY_SECRET="${RISK_MW_DEMO_INTEGRITY_SECRET:-$(openssl rand -hex 16)}"
# One background Gemini call per instance start (about $0.0005 on Flash-Lite) so the demo's first triage is not the cold one.
WARM_UP_CALL="${RISK_MW_APPSAFETY_WARM_UP_CALL:-true}"
# Apa's voice (Gemini TTS, voice Sulafat): the whole warning once, when it is given, paced under each engine's quota (app.tts).
TTS_ENABLED="${RISK_MW_TTS_ENABLED:-true}"
# Speech to text is off (FinNest does not listen to phone calls): file mode (/v1/scam/transcribe) and the
# live bridge (/v1/scam/live, Gemini Live in us-central1). Set either variable to true to bring one back.
TRANSCRIPTION_ENABLED="${RISK_MW_TRANSCRIPTION_ENABLED:-false}"
LIVE_TRANSCRIPTION_ENABLED="${RISK_MW_LIVE_TRANSCRIPTION_ENABLED:-false}"
SYNTH="$ROOT_DIR/libs/synth"
ATO="$ROOT_DIR/libs/ato"
APP_SAFETY="$ROOT_DIR/libs/app-safety-check"
ARTEFACTS="$ROOT_DIR/models/mule"
ATO_ARTEFACTS="$ROOT_DIR/models/ato"
APP_SAFETY_ARTEFACTS="$ROOT_DIR/models/app-safety-check"

[[ -d "$ARTEFACTS" ]] || { echo "missing $ARTEFACTS - run libs/synth/eval/mule_eval.py first" >&2; exit 1; }
# vendor/ and artifacts/ are build-time copies (git-ignored, kept in the upload by .gcloudignore).
rm -rf "$HERE/vendor" "$HERE/artifacts"
mkdir -p "$HERE/vendor" "$HERE/artifacts/mule" "$HERE/artifacts/ato" "$HERE/artifacts/app-safety-check"
cp -R "$SYNTH/bhorosha_graph" "$SYNTH/bhorosha_synth" "$ATO/bhorosha_ato" "$APP_SAFETY/bhorosha_app_safety_check" "$HERE/vendor/"
find "$HERE/vendor" -name __pycache__ -type d -prune -exec rm -rf {} +
cp "$ARTEFACTS"/* "$HERE/artifacts/mule/"
# Behaviour artefacts are optional. The per-user and cold-start models are fitted on a dataset that is not in
# the repository, and app/ato.py degrades to no hits when they are absent. So a missing model never blocks a deploy.
if compgen -G "$ATO_ARTEFACTS/*" > /dev/null; then
  cp "$ATO_ARTEFACTS"/*.pkl "$ATO_ARTEFACTS"/*.json "$HERE/artifacts/ato/"
  echo "vendored behaviour artefacts: $(ls -1 "$HERE/artifacts/ato" | wc -l | tr -d ' ') files"
else
  echo "no behaviour artefacts at $ATO_ARTEFACTS - deploying without them (adapter returns no hits)" >&2
fi
# App Safety Check artefacts are committed like mule's; without them the route still answers from rules.
if compgen -G "$APP_SAFETY_ARTEFACTS/*" > /dev/null; then
  cp "$APP_SAFETY_ARTEFACTS"/* "$HERE/artifacts/app-safety-check/"
else
  echo "no app-safety artefacts at $APP_SAFETY_ARTEFACTS - deploying rules-only (run libs/app-safety-check/bhorosha_app_safety_check/train_lamda.py)" >&2
fi

gcloud run deploy risk-mw --source "$HERE" --project "$PROJECT" --region "$REGION" \
  --clear-base-image --allow-unauthenticated --min-instances 1 --max-instances 1 --cpu-boost --concurrency 80 --memory 1Gi \
  --set-env-vars "RISK_MW_PROJECT_ID=$PROJECT,RISK_MW_REGION=$REGION,RISK_MW_GENAI_LOCATION=global,RISK_MW_FIRESTORE_ENABLED=true,RISK_MW_GENAI_ENABLED=true,RISK_MW_DEMO_MODE=true,RISK_MW_INVESTIGATOR_URL=$INVESTIGATOR_URL,RISK_MW_GENAI_BUDGET_USD=$GENAI_BUDGET_USD,RISK_MW_DEMO_INTEGRITY_SECRET=$DEMO_INTEGRITY_SECRET,RISK_MW_APPSAFETY_WARM_UP_CALL=$WARM_UP_CALL,RISK_MW_TTS_ENABLED=$TTS_ENABLED,RISK_MW_TRANSCRIPTION_ENABLED=$TRANSCRIPTION_ENABLED,RISK_MW_LIVE_TRANSCRIPTION_ENABLED=$LIVE_TRANSCRIPTION_ENABLED" \
  --quiet
URL="$(gcloud run services describe risk-mw --project "$PROJECT" --region "$REGION" --format='value(status.url)')"
echo "deployed: $URL"
"$HERE/scripts/smoke.sh" "$URL"
