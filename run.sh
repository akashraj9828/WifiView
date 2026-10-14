#!/usr/bin/env bash
# One command: build the scanner if needed, start the server, open the browser.
#   ./run.sh          real WiFi data
#   ./run.sh --sim    fake data (no WiFi / Location permission needed)
# Env: PORT (3000), RSSI_MS (250), SCAN_GAP_MS (1000), NO_OPEN=1 (don't open browser)
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-3000}"
SIM=0; [[ "${1:-}" == "--sim" ]] && SIM=1

command -v node >/dev/null || { echo "node not found. Install Node 18+ (https://nodejs.org)"; exit 1; }

if [[ $SIM -eq 0 ]]; then
  if ! command -v swiftc >/dev/null; then
    echo "swiftc not found. Run: xcode-select --install"; exit 1
  fi
  APP=WifiviewScan.app
  BIN="$APP/Contents/MacOS/scan"
  if [[ ! -x "$BIN" || scan.swift -nt "$BIN" || Info.plist -nt "$BIN" ]]; then
    echo "Building scanner app..."
    mkdir -p "$APP/Contents/MacOS"
    swiftc -O -o "$BIN" scan.swift
    cp Info.plist "$APP/Contents/Info.plist"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  fi
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is busy. Stop the other process or run: PORT=3001 ./run.sh"; exit 1
fi

URL="http://127.0.0.1:$PORT"
if [[ "${NO_OPEN:-0}" != "1" ]]; then
  ( sleep 1; open "$URL" >/dev/null 2>&1 || true ) &
fi

export PORT
if [[ $SIM -eq 1 ]]; then exec node server.js --sim; else exec node server.js; fi
