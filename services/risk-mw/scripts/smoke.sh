#!/usr/bin/env bash
# Exercise every risk-mw route against a base URL (spec FR-8). Usage: scripts/smoke.sh https://risk-mw-xxxx.run.app
set -euo pipefail
BASE="${1:?usage: smoke.sh <base-url>}"
AUTH_HEADER="${AUTH_HEADER:-X-Demo-User: smoke}"
fail=0

check() {
  local name="$1" method="$2" path="$3" body="${4:-}"
  local out code
  if [[ -n "$body" ]]; then
    out=$(curl -sS -o /tmp/smoke_body -w '%{http_code} %{time_total}' -X "$method" -H 'Content-Type: application/json' -H "$AUTH_HEADER" --data "$body" "$BASE$path")
  else
    out=$(curl -sS -o /tmp/smoke_body -w '%{http_code} %{time_total}' -X "$method" -H "$AUTH_HEADER" "$BASE$path")
  fi
  code=${out%% *}
  if [[ "$code" == "200" ]]; then printf '  ok   %-40s %s\n' "$name" "$out"; else printf '  FAIL %-40s %s\n' "$name" "$out"; cat /tmp/smoke_body; echo; fail=1; fi
}

echo "smoke: $BASE"
check health GET /health
check signals POST /v1/risk/signals '{"session_id":"s1","signals":{"call_state":"OFFHOOK"}}'
check score_allow POST /v1/risk/score '{"user_id":"rina","session_id":"s1","txn":{"type":"send_money","amount_bdt":500,"to_account":"a1"}}'
check score_hold POST /v1/risk/score '{"user_id":"rina","session_id":"s1","txn":{"type":"pin_reset"},"demo_flags":{"call_active":true,"sim_swap":true}}'
# A trusted-contact request needs a real hold and rina's contact on file (libs/synth/load_seed.py seeds users/rina).
IID=$(grep -o '"intervention_id":"[^"]*"' /tmp/smoke_body | head -1 | cut -d'"' -f4 || true)
check appsafety_latest GET /v1/appsafety/latest/smoke
check appsafety POST /v1/appsafety/check '{"installed_apps":[{"package":"com.example.loan","has_accessibility_service":true,"accessibility_enabled":true,"installer":"unknown"}]}'
check intervene POST /v1/intervene '{"user_id":"rina","trigger":"call_active","txn":{"type":"pin_reset"}}'
check scam_turn POST /v1/scam/turn '{"session_id":"s1","turns":[{"speaker":"caller","text":"আপনার একাউন্ট বন্ধ হয়ে যাবে, কোডটা বলুন","ts":1}]}'
check apa_turn POST /v1/apa/turn '{"user_id":"rina","text_bn":"আমি কি টাকা পাঠাবো?"}'
check trusted_contact POST /v1/actions/trusted-contact "{\"intervention_id\":\"${IID:-none}\"}"
check investigate POST /v1/investigate '{"acct_id":"acct_mule_1"}'

exit $fail
