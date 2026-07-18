#!/bin/bash
# ipad.sh — CLI dev loop against Donald's physical iPad (no Xcode GUI needed).
# Requires: iPad connected (USB or paired wifi) + unlocked; pymobiledevice3 (uv tool install pymobiledevice3).
#
#   ipad.sh build       # build Kiki for the device
#   ipad.sh install     # install the last build
#   ipad.sh launch      # (re)launch Kiki, terminating any running instance
#   ipad.sh deploy      # build + install + launch
#   ipad.sh screenshot [out.png]   # capture the iPad screen
#   ipad.sh logs [seconds]         # stream Kiki process logs (default 15s)
set -euo pipefail

DEVICE_ID="AFBD3614-0BAE-5A0A-9BA1-E9F999BEB0B9"
BUNDLE_ID="com.don.Kiki"
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${IPAD_DERIVED_DATA:-$HOME/Library/Caches/kiki-ipad-dd}"
APP="$DERIVED/Build/Products/Debug-iphoneos/Kiki.app"
PMD3="$HOME/.local/bin/pymobiledevice3"

cmd="${1:-deploy}"
case "$cmd" in
  build)
    xcodebuild -project "$IOS_DIR/Kiki.xcodeproj" -scheme Kiki \
      -destination "platform=iOS,id=$DEVICE_ID" \
      -derivedDataPath "$DERIVED" build | tail -5
    ;;
  install)
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP" --quiet
    ;;
  launch)
    xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" --quiet
    ;;
  deploy)
    "$0" build && "$0" install && "$0" launch
    ;;
  screenshot)
    out="${2:-/tmp/ipad_$(date +%H%M%S).png}"
    "$PMD3" developer dvt screenshot "$out" --userspace 2>/dev/null
    echo "$out"
    ;;
  logs)
    secs="${2:-15}"
    "$PMD3" syslog live -m Kiki 2>/dev/null &
    pid=$!
    sleep "$secs"
    kill "$pid" 2>/dev/null || true
    ;;
  *)
    echo "unknown command: $cmd (build|install|launch|deploy|screenshot|logs)" >&2
    exit 1
    ;;
esac
