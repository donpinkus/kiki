#!/bin/bash
# fetch-fixtures.sh — pull the latest brush fixtures (stroke JSON + canvas snapshot
# PNG) from Kiki Insights into ./fixtures/, ready for `brushharness --fixtures`.
#
# Usage:  ./fetch-fixtures.sh [N]        # newest N fixtures (default 5)
#
# Auth: ADMIN_PASSWORD env var, else read from the kiki-insights Railway service
# (requires the Railway CLI linked to the kiki-backend project — run from backend/
# once with `railway link` if needed).
set -euo pipefail
cd "$(dirname "$0")"

BASE="${INSIGHTS_URL:-https://kiki-insights-production.up.railway.app}"
N="${1:-5}"
OUT="fixtures"
mkdir -p "$OUT"

if [ -z "${ADMIN_PASSWORD:-}" ]; then
  ADMIN_PASSWORD=$(cd ../../../../backend && railway variables --service kiki-insights --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ADMIN_PASSWORD",""))') || true
fi
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set ADMIN_PASSWORD (or link the Railway CLI so it can be read from kiki-insights vars)" >&2
  exit 1
fi

JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

login_status=$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -X POST "$BASE/admin/login" \
  -H 'content-type: application/json' -d "{\"password\":\"$ADMIN_PASSWORD\"}")
if [ "$login_status" != "200" ]; then
  echo "ERROR: admin login failed ($login_status)" >&2
  exit 1
fi

curl -s -b "$JAR" "$BASE/admin/api/fixtures?limit=$N" | python3 -c '
import json, sys
for f in json.load(sys.stdin)["fixtures"]:
    note = (f.get("note") or "").replace("\n", " ")
    print(f["id"], f["created_at"], f.get("stroke_count") or "?", "strokes |", note)
    print("KEYS", f["id"], f["fixture_key"], f.get("snapshot_key") or "-")
' | while read -r line; do
  case "$line" in
    KEYS\ *)
      set -- $line
      id="$2"; fkey="$3"; skey="$4"
      curl -s -b "$JAR" "$BASE/blobs/$fkey" -o "$OUT/fixture-$id.json"
      if [ "$skey" != "-" ]; then
        curl -s -b "$JAR" "$BASE/blobs/$skey" -o "$OUT/fixture-$id.png"
      fi
      echo "  → $OUT/fixture-$id.json$([ "$skey" != "-" ] && echo " + .png")"
      ;;
    *) echo "$line" ;;
  esac
done

echo
echo "Replay: /tmp/brushharness --fixtures ./$OUT --out /tmp/brush-out   (see README.md for the build line)"
