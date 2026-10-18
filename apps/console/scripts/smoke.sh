#!/usr/bin/env bash
# Exercise every route of FinNest Admin against a base URL.
# Usage: scripts/smoke.sh <base-url>       e.g. http://127.0.0.1:8099, or CONSOLE_URL=... scripts/smoke.sh
# Signs in with ADMIN_USER / ADMIN_PASSWORD (the local-dev defaults when unset).
set -uo pipefail
BASE="${1:-${CONSOLE_URL:?usage: smoke.sh <base-url>, or set CONSOLE_URL}}"
USER_NAME="${ADMIN_USER:-admin}"
PASSWORD="${ADMIN_PASSWORD:-finnest-local-dev}"
fail=0

check() {
  local name="$1" expect="$2" method="$3" path="$4" auth="${5:-}"
  local args=(-sS -o /tmp/smoke_body -w '%{http_code} %{time_total}s' -X "$method")
  [[ -n "$auth" ]] && args+=(-H "Authorization: Bearer $auth")
  local out code
  out=$(curl "${args[@]}" "$BASE$path")
  code=${out%% *}
  if [[ "$code" == "$expect" ]]; then
    printf '  ok   %-34s %s\n' "$name" "$out"
  else
    printf '  FAIL %-34s %s (wanted %s)\n' "$name" "$out" "$expect"; head -c 300 /tmp/smoke_body; echo; fail=1
  fi
}

echo "smoke: $BASE"
check health            200 GET  /health
check console           200 GET  /
check favicon           200 GET  /favicon.ico
check manifest          200 GET  /manifest.webmanifest
check "admin needs auth" 401 GET /v1/admin/overview

TOKEN=$(curl -sS -X POST "$BASE/v1/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER_NAME\",\"password\":\"$PASSWORD\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
if [[ -z "$TOKEN" ]]; then echo "  FAIL login returned no token"; exit 1; fi
echo "  ok   login"

check overview          200 GET  /v1/admin/overview                 "$TOKEN"
check models            200 GET  /v1/admin/models                   "$TOKEN"
check account           200 GET  /v1/admin/account/acct_01070       "$TOKEN"
check "unknown account" 404 GET  /v1/admin/account/acct_nope        "$TOKEN"
check casezero-health   200 GET  /v1/admin/casezero/health          "$TOKEN"
check watchlist         200 GET  /v1/admin/casezero/watchlist       "$TOKEN"
check ring-graph        200 GET  /v1/admin/casezero/graph           "$TOKEN"
check audit             200 GET  /v1/admin/audit?limit=1            "$TOKEN"

# A 200 is not enough here. `/v1/admin/audit` answers 200 with {"available": false} when Firestore
# cannot be read, which is exactly the failure a status-code check cannot see - and exactly the
# failure that matters, because the page then shows an error where the log should be.
AVAILABLE=$(curl -sS "$BASE/v1/admin/audit?limit=1" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("available")); sys.stderr.write(str(d.get("error") or ""))' 2>/tmp/audit_err)
if [[ "$AVAILABLE" == "True" ]]; then
  echo "  ok   audit readable"
else
  echo "  FAIL audit route answered 200 but cannot read Firestore: $(cat /tmp/audit_err)"
  fail=1
fi

exit $fail
