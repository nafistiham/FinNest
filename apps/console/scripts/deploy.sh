#!/usr/bin/env bash
# Deploy FinNest Admin (the operator console) to Cloud Run.
#
#   PROJECT_ID=my-project ADMIN_PASSWORD=... scripts/deploy.sh    build the context, build the image, deploy
#   scripts/deploy.sh --context-only                             just assemble .deploy/ (for a local docker build)
#
# Required for a deploy: PROJECT_ID and ADMIN_PASSWORD. Optional: REGION (default asia-southeast1),
# SERVICE (default finnest-admin), ADMIN_USER (default admin), SESSION_SECRET (reused from the running
# service, else generated), RISK_MW_URL and CASE_ZERO_URL (the services the console reads), PYTHON.
#
# The context is assembled rather than taken from the repo root, because the image needs a few
# things from outside apps/console/ and none of the rest: risk-mw's rule engine, the seed world, the
# model files and any eval results the model-health table renders. Copying only those keeps the
# upload at a few megabytes and keeps other services out of this image.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
STAGE=.deploy
SERVICE=${SERVICE:-finnest-admin}
REGION=${REGION:-asia-southeast1}
CONTEXT_ONLY=false
[[ "${1:-}" == "--context-only" ]] && CONTEXT_ONLY=true
if [[ "$CONTEXT_ONLY" == false ]]; then
  PROJECT=${PROJECT_ID:?set PROJECT_ID to the Google Cloud project to deploy into}
  : "${ADMIN_PASSWORD:?set ADMIN_PASSWORD; the console refuses to start on Cloud Run without it}"
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Nothing is built or deployed until the suite passes, and the suite's exit code is the shell's.
# Piping pytest through anything hands the pipeline the last command's status, so a failing test
# cannot stop a deploy - which it did not, once.
say "0/5  tests"
PY=${PYTHON:-python3}
"$PY" -m pytest tests -q
say "1/5  building the console"
# VITE_RISK_MW_URL is baked into the bundle: the browser half of the console calls risk-mw directly.
(cd web && VITE_RISK_MW_URL="${RISK_MW_URL:?set RISK_MW_URL to the deployed risk-mw URL}" npm run build)

say "2/5  assembling the build context"
rm -rf "$STAGE"
CONSOLE="$STAGE/apps/console"
mkdir -p "$CONSOLE"

# Our own service: everything but the parts that are rebuilt or installed.
rsync -a --exclude node_modules --exclude .deploy --exclude __pycache__ \
      --exclude .pytest_cache --exclude 'web/src' --exclude 'web/*.json' \
      --exclude 'web/*.ts' --exclude 'web/index.html' \
      api fixtures web tools "$CONSOLE/"
cp Dockerfile "$STAGE/Dockerfile"
cp .dockerignore "$STAGE/.dockerignore"
cp .gcloudignore "$STAGE/.gcloudignore"

# A unique marker in the context. Without it a deploy once shipped a stale bundle: the image came
# back with the previous revision's JS and the current revision's CSS, because the build was
# served from cache. The digest of COPY . /srv now changes on every deploy, by construction.
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STAGE/BUILD_ID"
git -C "$ROOT" rev-parse --short HEAD >> "$STAGE/BUILD_ID" 2>/dev/null || true

# risk-mw's rule engine and the graph bundle its scorer imports. Vendored, not depended on: this
# service must keep answering if risk-mw is redeployed mid-demo.
mkdir -p "$CONSOLE/vendor"
rsync -a --exclude __pycache__ "$ROOT/services/risk-mw/app" "$CONSOLE/vendor/"
# Gemini's reading of a score (api/insight.py) goes through risk-mw's own client, and app/settings.py reads model ids
# and prices from ../config/models.yaml beside the package. One table, so the console never names a model itself.
mkdir -p "$CONSOLE/vendor/config"
cp "$ROOT/services/risk-mw/config/models.yaml" "$CONSOLE/vendor/config/"
rsync -a --exclude __pycache__ "$ROOT/libs/synth/bhorosha_graph" "$ROOT/libs/synth/bhorosha_synth" \
      "$CONSOLE/vendor/"
# The behaviour model: api/scenarios.py imports bhorosha_ato and runs risk-mw's app.ato on an
# enrolment session; tests/test_deploy_context.py keeps this list in step with the imports.
rsync -a --exclude __pycache__ "$ROOT/libs/ato/bhorosha_ato" "$CONSOLE/vendor/"

# The seed world and the model files, for the account drill-down and a live rebuild. The image
# mirrors the repo layout, so api/risk_mw.py finds them at the same relative paths.
mkdir -p "$STAGE/data" "$STAGE/models"
rsync -a "$ROOT/data/seed" "$STAGE/data/"
rsync -a "$ROOT/models/mule" "$STAGE/models/"
# The behaviour model files; api/risk_mw.py points RISK_MW_ATO_ARTEFACTS_DIR here when they exist.
if [[ -d "$ROOT/models/ato" ]]; then rsync -a "$ROOT/models/ato" "$STAGE/models/"; fi

# Only the eval results, not the harnesses: model health renders these files as they are. They are
# not committed; run the evals first if the deployed console should show them.
mkdir -p "$STAGE/eval/results" "$STAGE/libs/ato/eval/results" "$STAGE/services/case-zero/eval/results"
cp "$ROOT/eval/results/"*.json "$STAGE/eval/results/" 2>/dev/null || true
cp "$ROOT/libs/ato/eval/results/"*.json "$STAGE/libs/ato/eval/results/" 2>/dev/null || true
cp "$ROOT/services/case-zero/eval/results/"*.json "$STAGE/services/case-zero/eval/results/" 2>/dev/null || true

printf '  context: %s\n' "$(du -sh "$STAGE" | cut -f1)"

if [[ "$CONTEXT_ONLY" == true ]]; then
  say "done — build it with:  docker build -t $SERVICE $STAGE"
  exit 0
fi

# Reuse the signing secret if this service already has one, so a redeploy does not sign everyone
# out. A fresh service gets a random one; the local-dev default in api/auth.py is refused on Cloud Run.
#
# `|| true` on both halves on purpose: under `set -e` a describe of a service that does not exist
# yet would abort the first deploy, which is exactly when it does not exist.
EXISTING=""
if gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  EXISTING=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" \
    --format=json 2>/dev/null | python3 -c '
import json, sys
try:
    spec = json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e.get("value", "") for e in spec.get("env", [])}
    print(env.get("SESSION_SECRET") or "")
except Exception:
    print("")
' || true)
fi
SECRET=${SESSION_SECRET:-$EXISTING}
if [[ -z "$SECRET" ]]; then
  SECRET=$(openssl rand -hex 24)
  echo "  signing secret: new"
else
  echo "  signing secret: reused from the running service"
fi

say "3/5  deploying to Cloud Run ($SERVICE, $REGION, $PROJECT)"
# Gemini on for the drawer's reading (Vertex, through the service account; no API key is ever set here), under the
# console's own per-instance spend cap. CONSOLE_GEMINI_BUDGET_USD overrides it; each reading costs about a tenth of a cent.
# One tiny warm-up call at start (insight.warm_up) so the first reading after a deploy is not the cold one; well under a
# cent per deploy. CONSOLE_GEMINI_WARM_UP_CALL=false skips it (the client and its token are still warmed).
# One instance, like risk-mw: the overview cache and the Case Zero cache live in process memory,
# and a second instance would recompute both. The console serves one team, not a public.
# --allow-unauthenticated exposes only the sign-in page; every /v1/admin route needs a token.
gcloud run deploy "$SERVICE" \
  --source "$STAGE" \
  --project "$PROJECT" \
  --region "$REGION" \
  --allow-unauthenticated \
  --min-instances 1 --max-instances 1 \
  --cpu 1 --memory 1Gi --cpu-boost \
  --timeout 120 \
  --set-env-vars "ADMIN_USER=${ADMIN_USER:-admin},ADMIN_PASSWORD=$ADMIN_PASSWORD,SESSION_SECRET=$SECRET,PROJECT_ID=$PROJECT,RISK_MW_URL=${RISK_MW_URL:-},CASE_ZERO_URL=${CASE_ZERO_URL:-},RISK_MW_GENAI_ENABLED=true,RISK_MW_PROJECT_ID=$PROJECT,RISK_MW_GENAI_BUDGET_USD=${CONSOLE_GEMINI_BUDGET_USD:-1.00},FINNEST_ADMIN_GEMINI_WARM_UP_CALL=${CONSOLE_GEMINI_WARM_UP_CALL:-true}"

# The bundle the image serves must be the bundle we just built. This is the check that would have
# caught the stale deploy immediately instead of a day later.
EXPECTED=$(basename "$(ls web/dist/assets/index-*.js | head -1)")

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" --format='value(status.url)')
say "4/5  deployed: $URL"

say "5/5  smoke"
SERVED=$(curl -sS "$URL/" | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' | head -1 | xargs basename)
if [[ "$SERVED" == "$EXPECTED" ]]; then
  echo "  ok   bundle                             $SERVED"
else
  echo "  FAIL bundle: serving $SERVED, built $EXPECTED — the image is stale"
  exit 1
fi
scripts/smoke.sh "$URL"
