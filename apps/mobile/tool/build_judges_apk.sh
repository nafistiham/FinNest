#!/usr/bin/env bash
# Build a demo APK for sideloaded installs (for example, competition judges).
#
#   FINNEST_APPCHECK_TOKEN=<uuid-v4> tool/build_judges_apk.sh [out.apk]
#
# The APK is a release build with the demo panel on, behaviour scoring off
# (a new user's typing is not learned yet, so live mode would hold every
# send) and the App Check debug provider with ONE fixed debug token. Play
# Integrity fails for sideloaded installs, so the fixed token is what lets
# the app call Firebase AI Logic (assistant chat, Live voice, Gemini TTS).
#
# Register the token once in the Firebase console (App Check > Apps > your
# Android app > Manage debug tokens > Add) and revoke it after the event.
# The token comes only from the environment and reaches Flutter through a
# temporary defines file (mode 600, deleted on exit). Never commit it.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$APP_DIR/build/FinNest-demo.apk}"

token="${FINNEST_APPCHECK_TOKEN:-}"
uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
if [[ ! "$token" =~ $uuid_re ]]; then
  echo "error: set FINNEST_APPCHECK_TOKEN to a UUID v4 registered as an App Check debug token." >&2
  exit 2
fi

cd "$APP_DIR"
if [[ ! -f config/dart_defines.json ]]; then
  echo "error: config/dart_defines.json is missing (copy config/dart_defines.example.json)." >&2
  exit 2
fi
# shellcheck source=/dev/null
source tool/env.sh

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/finnest-demo-XXXXXX")"
chmod 700 "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT
defines="$tmpdir/defines.json"
( umask 077; printf '{"APP_CHECK_DEBUG":"true","APP_CHECK_DEBUG_TOKEN":"%s","DEMO_PANEL":"true","BEHAVIOUR_MODE":"off"}\n' "$token" > "$defines" )
unset token

FLUTTER="${FLUTTER:-$(command -v fvm >/dev/null 2>&1 && echo "fvm flutter" || echo flutter)}"
$FLUTTER build apk --release \
  --dart-define-from-file=config/dart_defines.json \
  --dart-define-from-file="$defines"

mkdir -p "$(dirname "$OUT")"
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
echo "demo APK: $OUT"
shasum -a 256 "$OUT"
