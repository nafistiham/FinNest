#!/usr/bin/env bash
# Deploy Case Zero to Cloud Run.
# The script stages a clean build context with the repository layout that Case Zero reads:
# the synth packages (libs/synth), the mule scorer artefacts (models/mule), the two seed files
# (data/seed) and the shared model registry (services/risk-mw/config/models.yaml).
# Then it runs `gcloud run deploy --source`. Gemini runs on Vertex AI (location global) with the
# service's runtime identity. The image has no API keys, no .env and no tests.
#
# The per-IP rate limit trusts the last X-Forwarded-For hop. That is correct for the run.app URL
# (the Cloud Run front end appends the real client). Behind an external Application Load Balancer,
# which appends the client and then its own address, deploy with CASE_ZERO_TRUSTED_HOPS=2 (the
# number of proxies that append to the header). With a wrong count, every caller shares one limit,
# or callers can forge their address. With CASE_ZERO_TRUSTED_HOPS=2, also close the run.app URL
# (`gcloud run services update case-zero --ingress internal-and-cloud-load-balancing`). Otherwise a
# caller who skips the load balancer can choose their own address and so have no per-IP limit.
#
# Usage:
#   CASE_ZERO_PROJECT_ID=<gcp-project-id> CASE_ZERO_RISK_MW_URL=<risk-mw-url> ./deploy.sh
#   ./deploy.sh <gcp-project-id>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
PROJECT="${1:-${CASE_ZERO_PROJECT_ID:?set CASE_ZERO_PROJECT_ID or pass the project id}}"
REGION="${CASE_ZERO_REGION:-asia-southeast1}"
BUDGET="${CASE_ZERO_BUDGET_USD:-1.40}"
TRUSTED_HOPS="${CASE_ZERO_TRUSTED_HOPS:-1}"
# risk-mw, for the device_safety tool (the App Safety Check verdict per customer).
# Empty = the tool answers known=false.
RISK_MW_URL="${CASE_ZERO_RISK_MW_URL:-}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/libs/synth" "$STAGE/models" "$STAGE/data/seed" "$STAGE/services/risk-mw/config" "$STAGE/services/case-zero"
cp -R "$ROOT_DIR/libs/synth/bhorosha_graph" "$ROOT_DIR/libs/synth/bhorosha_synth" "$STAGE/libs/synth/"
cp -R "$ROOT_DIR/models/mule" "$STAGE/models/"
cp "$ROOT_DIR/data/seed/device_links.jsonl" "$ROOT_DIR/data/seed/sims.jsonl" "$STAGE/data/seed/"
cp "$ROOT_DIR/services/risk-mw/config/models.yaml" "$STAGE/services/risk-mw/config/"
cp -R "$HERE/case_zero" "$HERE/static" "$HERE/requirements.txt" "$STAGE/services/case-zero/"
cp "$HERE/Dockerfile" "$STAGE/Dockerfile"
cp "$HERE/Dockerfile.dockerignore" "$STAGE/.dockerignore"
find "$STAGE" -name __pycache__ -type d -prune -exec rm -rf {} +

# --no-cpu-throttling: a run continues after its viewer leaves. A throttled CPU would stall it into its 90 s limit.
# Billing: CPU is then charged for the whole lifetime of the instance, not per request. With --min-instances 1, that is all day.
gcloud run deploy case-zero --source "$STAGE" --project "$PROJECT" --region "$REGION" \
  --allow-unauthenticated --min-instances 1 --max-instances 1 --cpu 1 --memory 2Gi --cpu-boost --no-cpu-throttling --timeout 300 \
  --set-env-vars "CASE_ZERO_PROJECT_ID=$PROJECT,CASE_ZERO_LOCATION=global,CASE_ZERO_BUDGET_USD=$BUDGET,CASE_ZERO_TRUSTED_HOPS=$TRUSTED_HOPS,CASE_ZERO_RISK_MW_URL=$RISK_MW_URL" \
  --quiet
URL="$(gcloud run services describe case-zero --project "$PROJECT" --region "$REGION" --format='value(status.url)')"
echo "deployed: $URL"
curl -fsS "$URL/api/seeds" >/dev/null && echo "smoke: /api/seeds ok" || echo "smoke: /api/seeds is not reachable anonymously (a project Owner must grant public access)"
