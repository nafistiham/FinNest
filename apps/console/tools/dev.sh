#!/usr/bin/env bash
# Run the console the way it runs in production: one service, API and built page together.
#
#   tools/dev.sh            build the web app, then serve everything from :8099
#   tools/dev.sh --watch    API on :8099, Vite on :5173 with hot reload and a proxy
set -euo pipefail
cd "$(dirname "$0")/.."
# Any Python with api/requirements.txt installed; set PYTHON to use a virtualenv.
PY=${PYTHON:-python3}

if [[ "${1:-}" == "--watch" ]]; then
  "$PY" -m uvicorn api.main:app --reload --port 8099 &
  trap 'kill 0' EXIT
  cd web && npm run dev
else
  (cd web && npm run build)
  exec "$PY" -m uvicorn api.main:app --port 8099
fi
