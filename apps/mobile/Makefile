# FinNest Android app. Every target sources tool/env.sh first.
# FLUTTER defaults to `fvm flutter` when FVM is installed, else `flutter`.
# Pass build settings with DEFINES, e.g.
#   make build-debug DEFINES=--dart-define-from-file=config/dart_defines.json
SHELL := /bin/bash
ENV := source tool/env.sh &&
FLUTTER ?= $(shell command -v fvm >/dev/null 2>&1 && echo "fvm flutter" || echo flutter)
DEFINES ?= $(shell test -f config/dart_defines.json && echo --dart-define-from-file=config/dart_defines.json)

.PHONY: require-defines deps gen analyze test build-debug build-release build-release-demo build-recording run clean doctor

deps:
	$(ENV) $(FLUTTER) pub get

gen:
	$(ENV) $(FLUTTER) gen-l10n

analyze: gen
	$(ENV) $(FLUTTER) analyze --no-fatal-infos

test: gen
	$(ENV) $(FLUTTER) test

build-debug: gen
	$(ENV) $(FLUTTER) build apk --debug $(DEFINES)

# Release builds talk to the deployed backend, so they need its URLs.
require-defines:
	@test -f config/dart_defines.json || { echo "config/dart_defines.json is missing: copy config/dart_defines.example.json and fill in the deployed URLs and Firebase values" >&2; exit 1; }

build-release: require-defines gen
	$(ENV) $(FLUTTER) build apk --release $(DEFINES)

# Release APK for a demo phone: the hidden demo panel and the App Check debug
# provider (register its token for the phone) are off in release unless asked.
# Behaviour scoring is live by default; add --dart-define=BEHAVIOUR_MODE=off for
# a phone the per-user models do not fit yet (every ordinary send is held with
# ATO_BEHAVIOUR_MISMATCH). The demo panel can switch it per session.
build-release-demo: require-defines gen
	$(ENV) $(FLUTTER) build apk --release $(DEFINES) --dart-define=DEMO_PANEL=true --dart-define=APP_CHECK_DEBUG=true

# Debug APK for screen recordings: skips FLAG_SECURE (debug builds only) and
# keeps a registered App Check debug token working.
build-recording: gen
	$(ENV) $(FLUTTER) build apk --debug $(DEFINES) --dart-define=RECORDING=true --dart-define=APP_CHECK_DEBUG=true

# Emulator demo build: skips FLAG_SECURE so the window can be recorded.
run:
	$(ENV) $(FLUTTER) run $(DEFINES) --dart-define=RECORDING=true

doctor:
	$(ENV) $(FLUTTER) doctor

clean:
	$(ENV) $(FLUTTER) clean
