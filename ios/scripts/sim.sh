#!/bin/bash
# sim.sh — fully-automated iPad Simulator dev loop (no human interaction needed).
# Companion to ipad.sh (physical device). The simulator additionally supports:
#   - auth bypass: launch with pre-minted backend JWTs (Sign in with Apple
#     can't complete in the simulator) — see DevAutomation.swift
#   - stroke replay: paint recorded BrushHarness fixtures onto the live canvas
#
#   sim.sh mint                 # mint dev JWTs via Railway (writes ~/.kiki/sim-dev-tokens.json)
#   sim.sh boot                 # boot the iPad simulator + open Simulator.app
#   sim.sh deploy               # build + install + (re)launch with auth bypass
#   sim.sh launch               # (re)launch only
#   sim.sh replay <fixture.json>  # replay a recorded stroke fixture onto the canvas
#   sim.sh screenshot [out.png] # capture the simulator screen
#   sim.sh logs [seconds]       # stream Kiki process logs (default 15s)
set -euo pipefail

SIM_NAME="iPad Pro 13-inch (M4)"
BUNDLE_ID="com.don.Kiki"
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/.." && pwd)"
DERIVED="${SIM_DERIVED_DATA:-$HOME/Library/Caches/kiki-sim-dd}"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Kiki.app"
TOKENS="$HOME/.kiki/sim-dev-tokens.json"

sim_udid() {
  xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

token() { python3 -c "import json,sys; print(json.load(open('$TOKENS'))['$1'])"; }

cmd="${1:-deploy}"
case "$cmd" in
  mint)
    mkdir -p "$HOME/.kiki"
    # Default to Donald's test account — the internal DATABASE_URL isn't
    # reachable locally, so the script can't auto-pick one under `railway run`.
    args=("${@:2}")
    [[ ${#args[@]} -eq 0 ]] && args=(--user 92ad1c16-c5b7-4e54-bac8-8985574f9036)
    (cd "$REPO_DIR/backend" && railway run npx tsx scripts/mint-dev-token.ts "${args[@]}") > "$TOKENS"
    echo "minted for user $(token userId) → $TOKENS"
    ;;
  boot)
    udid="$(sim_udid)"
    xcrun simctl boot "$udid" 2>/dev/null || true
    open -a Simulator
    echo "$udid"
    ;;
  build)
    # Destination by id — the name-based specifier is ambiguous when several
    # runtimes ship a device with the same name.
    xcodebuild -project "$IOS_DIR/Kiki.xcodeproj" -scheme Kiki \
      -destination "platform=iOS Simulator,id=$(sim_udid)" \
      -derivedDataPath "$DERIVED" build | tail -5
    ;;
  install)
    xcrun simctl install "$(sim_udid)" "$APP"
    ;;
  launch)
    udid="$(sim_udid)"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    if [[ -f "$TOKENS" ]]; then
      xcrun simctl launch "$udid" "$BUNDLE_ID" \
        -KikiDevAccessToken "$(token accessToken)" \
        -KikiDevRefreshToken "$(token refreshToken)"
    else
      echo "no $TOKENS — launching without auth bypass (run: sim.sh mint)" >&2
      xcrun simctl launch "$udid" "$BUNDLE_ID"
    fi
    ;;
  deploy)
    "$0" boot >/dev/null && "$0" build && "$0" install && "$0" launch
    ;;
  replay)
    fixture="${2:?usage: sim.sh replay <fixture.json>}"
    cp "$fixture" /tmp/kiki-replay.json
    xcrun simctl spawn "$(sim_udid)" notifyutil -p com.don.kiki.dev.replay
    echo "replay triggered: $fixture"
    ;;
  screenshot)
    out="${2:-/tmp/sim_$(date +%H%M%S).png}"
    xcrun simctl io "$(sim_udid)" screenshot "$out" >/dev/null
    echo "$out"
    ;;
  logs)
    secs="${2:-15}"
    xcrun simctl spawn "$(sim_udid)" log stream --level info \
      --predicate 'process == "Kiki"' &
    pid=$!
    sleep "$secs"
    kill "$pid" 2>/dev/null || true
    ;;
  *)
    echo "unknown command: $cmd (mint|boot|build|install|launch|deploy|replay|screenshot|logs)" >&2
    exit 1
    ;;
esac
