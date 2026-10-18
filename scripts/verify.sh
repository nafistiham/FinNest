#!/usr/bin/env bash
# Run the repository acceptance checks in docs/evaluation.md.
#
# Usage: scripts/verify.sh [--install] [--mobile] [--skip-smoke]
#   --install     install every Python requirements file into the active virtualenv first
#   --mobile      also run the Flutter analyzer and tests (needs FVM and Flutter 3.47.7)
#   --skip-smoke  do not start risk-mw locally for the HTTP smoke test
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python}"
INSTALL=0 MOBILE=0 SMOKE=1
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --mobile) MOBILE=1 ;;
    --skip-smoke) SMOKE=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

FAILED=()
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED+=("$1"); }
section() { printf '\n== %s\n' "$1"; }

if [ "$INSTALL" = 1 ]; then
  section "Install Python requirements"
  find "$ROOT" -name 'requirements*.txt' -not -path '*/node_modules/*' -print0 |
    xargs -0 -n1 "$PY" -m pip install -q -r || fail "pip install"
fi

section "E1 Repository hygiene"
cd "$ROOT"
if command -v gitleaks >/dev/null; then
  if gitleaks dir . --no-banner --redact >/dev/null 2>&1; then pass "E1.1 gitleaks finds no secrets"; else fail "E1.1 gitleaks finds no secrets"; fi
else
  echo "  SKIP E1.1 gitleaks is not installed"
fi
ID_RE='AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]+|BEGIN (RSA |EC )?PRIVATE KEY|"private_key_id"'
if grep -rIlE "$ID_RE" --exclude-dir=node_modules --exclude-dir=.dart_tool --exclude-dir=build --exclude=verify.sh . >/dev/null; then
  fail "E1.2 no API keys, OAuth tokens or private keys"
else
  pass "E1.2 no API keys, OAuth tokens or private keys"
fi
if find . -type f -size +50M -not -path './.git/*' -not -path '*/node_modules/*' -not -path '*/build/*' | grep -q .; then
  fail "E1.3 no file is larger than 50 MB"
else
  pass "E1.3 no file is larger than 50 MB"
fi
TRACKED=0
for f in apps/mobile/android/app/google-services.json apps/mobile/config/dart_defines.json; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then fail "E1.4 $f is not tracked"; TRACKED=1; fi
done
[ "$TRACKED" = 0 ] && pass "E1.4 local Firebase and app config files are not tracked"

section "E2 Python test suites"
run_pytest() {
  local name="$1" dir="$2"
  if (cd "$ROOT/$dir" && "$PY" -m pytest -q -p no:cacheprovider >"/tmp/finnest-verify-${name}.log" 2>&1); then
    pass "E2 $name ($(tail -1 "/tmp/finnest-verify-${name}.log"))"
  else
    fail "E2 $name (see /tmp/finnest-verify-${name}.log)"
  fi
}
run_pytest risk-mw services/risk-mw
run_pytest case-zero services/case-zero
run_pytest synth libs/synth
run_pytest app-safety-check libs/app-safety-check
run_pytest ato libs/ato
run_pytest radar libs/radar
run_pytest eval eval

section "E3 Console web build"
if command -v npm >/dev/null; then
  if (cd "$ROOT/apps/console/web" && npm ci --silent && npm run build --silent) >/tmp/finnest-verify-web.log 2>&1; then
    pass "E3 console web app type-checks and builds"
  else
    fail "E3 console web app type-checks and builds (see /tmp/finnest-verify-web.log)"
  fi
else
  echo "  SKIP E3 npm is not installed"
fi

section "E2 Console tests (after the web build, which some tests serve)"
run_pytest console apps/console

if [ "$SMOKE" = 1 ]; then
  section "E4 risk-mw HTTP smoke test (demo mode)"
  PORT="${SMOKE_PORT:-18080}"
  (cd "$ROOT/services/risk-mw" && "$PY" -m uvicorn main:app --port "$PORT" >/tmp/finnest-verify-uvicorn.log 2>&1) &
  PID=$!
  for _ in $(seq 1 60); do curl -sf "localhost:$PORT/health" >/dev/null 2>&1 && break; sleep 1; done
  if curl -sf "localhost:$PORT/health" >/dev/null; then pass "E4.1 GET /health answers 200"; else fail "E4.1 GET /health answers 200"; fi
  BODY='{"user_id":"rina","session_id":"verify","txn":{"type":"pin_reset"},"demo_flags":{"call_active":true,"sim_swap":true}}'
  OUT="$(curl -s -X POST "localhost:$PORT/v1/risk/score" -H 'Content-Type: application/json' -d "$BODY")"
  if echo "$OUT" | grep -qiE '"decision" *: *"(hold|step_up|block)"'; then
    pass "E4.2 a PIN reset during a call after a SIM swap is not allowed"
  else
    fail "E4.2 a PIN reset during a call after a SIM swap is not allowed (got: ${OUT:0:200})"
  fi
  if curl -sf "localhost:$PORT/openapi.json" | grep -q '"/v1/scam/turn"'; then pass "E4.3 OpenAPI lists the scam-turn route"; else fail "E4.3 OpenAPI lists the scam-turn route"; fi
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
fi

if [ "$MOBILE" = 1 ]; then
  section "E5 Android app"
  if (cd "$ROOT/apps/mobile" && source tool/env.sh && fvm flutter pub get >/dev/null &&
      fvm flutter analyze --no-fatal-infos) >/tmp/finnest-verify-analyze.log 2>&1; then
    pass "E5.1 flutter analyze reports no errors or warnings"
  else
    fail "E5.1 flutter analyze (see /tmp/finnest-verify-analyze.log)"
  fi
  if (cd "$ROOT/apps/mobile" && source tool/env.sh && fvm flutter test) >/tmp/finnest-verify-flutter.log 2>&1; then
    pass "E5.2 flutter test"
  else
    fail "E5.2 flutter test (see /tmp/finnest-verify-flutter.log; one known failure is listed in docs/evaluation.md)"
  fi
fi

section "Result"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "  All checks passed."
else
  printf '  %d check(s) failed:\n' "${#FAILED[@]}"; printf '   - %s\n' "${FAILED[@]}"; exit 1
fi
