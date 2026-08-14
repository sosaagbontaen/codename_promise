# Development shortcuts. Run `make` on its own to see what's here.
#
# Nothing in here is required — every target is a one-liner you could type by hand — but
# these are the exact commands, with the flags that matter already set.

SIMULATOR ?= iPhone 17
PORT      ?= 8077
BUNDLE_ID := com.codenamepromise.journal
APP_PATH  := ./DerivedData/Build/Products/Debug-iphonesimulator/CodenamePromise.app
BACKEND_URL ?= http://localhost:$(PORT)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "make test        Run both test suites (Swift + Python)"
	@echo "make test-core   Swift only — fast, no simulator"
	@echo "make test-api    Python only"
	@echo "make server      Run the backend on port $(PORT), reloading on change"
	@echo "make app         Build, install and launch in the $(SIMULATOR) simulator"
	@echo "make boot        Boot the simulator (only needed if it's shut down)"
	@echo "make device      Build and install on a connected iPhone (uses your Mac's LAN IP)"
	@echo "make stop-server Kill whatever is listening on port $(PORT)"
	@echo "make clean       Remove build output"
	@echo ""
	@echo "Override defaults:  make app SIMULATOR='iPhone 17 Pro'"
	@echo "                    make server PORT=8000"

# --- Tests -------------------------------------------------------------------

.PHONY: test test-core test-api
test: test-core test-api

test-core:
	@cd Core && swift test

test-api:
	@cd backend && .venv/bin/python -m pytest -q

# --- Backend -----------------------------------------------------------------

# Sources .env if present, so GROQ_API_KEY and the Notion integration credentials are picked
# up without being typed on the command line (where they'd land in shell history).
.PHONY: server
server:
	@cd backend && set -a && [ -f .env ] && . ./.env; set +a; \
		.venv/bin/python -m uvicorn app.main:app --reload --port $(PORT) --host 0.0.0.0

.PHONY: stop-server
stop-server:
	@lsof -ti:$(PORT) | xargs kill 2>/dev/null && echo "stopped" || echo "nothing on port $(PORT)"

# --- iOS app -----------------------------------------------------------------

.PHONY: boot
boot:
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	@open -a Simulator

# BACKEND_BASE_URL is substituted into Config/Info.plist at build time. Leave it blank
# (make app BACKEND_URL=) to build an app that behaves exactly as it does offline.
.PHONY: app
app:
	@xcodebuild -scheme CodenamePromise \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath ./DerivedData \
		BACKEND_BASE_URL=$(BACKEND_URL) \
		build | grep -E "error:|BUILD" || true
	@xcrun simctl install booted $(APP_PATH)
	@xcrun simctl launch booted $(BUNDLE_ID)

# Builds for a physically connected iPhone and installs it.
#
# Two things differ from `make app` and both matter. The build must be code-signed, and the
# backend URL must be this Mac's address on the network — `localhost` on a phone is the
# phone, which is why a simulator build reports "no backend configured" once it's on device.
.PHONY: device
device:
	@DEVICE_ID=$$(xcrun devicectl list devices --json-output /tmp/cp-devices.json >/dev/null 2>&1; \
		python3 -c "import json;d=json.load(open('/tmp/cp-devices.json'))['result']['devices'];print(next((x['identifier'] for x in d if x.get('connectionProperties',{}).get('tunnelState')!='unavailable'),''))" 2>/dev/null); \
	LAN_IP=$$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1); \
	if [ -z "$$DEVICE_ID" ]; then echo "No connected device found. Plug it in and unlock it."; exit 1; fi; \
	echo "device $$DEVICE_ID  ->  backend http://$$LAN_IP:$(PORT)"; \
	xcodebuild -scheme CodenamePromise -destination "platform=iOS,id=$$DEVICE_ID" \
		-derivedDataPath ./DerivedDataDevice \
		BACKEND_BASE_URL=http://$$LAN_IP:$(PORT) build | grep -E "error:|BUILD" || true; \
	xcrun devicectl device install app --device $$DEVICE_ID \
		./DerivedDataDevice/Build/Products/Debug-iphoneos/CodenamePromise.app | tail -3

.PHONY: clean
clean:
	@rm -rf DerivedData DerivedDataDevice Core/.build
	@echo "cleaned"
