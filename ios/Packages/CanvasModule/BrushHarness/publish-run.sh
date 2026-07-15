#!/bin/bash
# publish-run.sh — render the full brush battery and publish the PNGs to Kiki
# Insights as a test run (Tests tab: grid / side-by-side / progression views).
#
# Usage:  ./publish-run.sh ["note describing what changed"]
#
# Renders fresh (compiles the harness first — see README for the source list),
# tags the run with the current git SHA, and uploads every PNG in the output
# dir (battery scenes + any fixture replays present).
#
# Auth: INSIGHTS_INGEST_KEY env var, else auto-read from the kiki-insights
# Railway service vars (CLI must be linked; run once from backend/ if not).
set -euo pipefail
cd "$(dirname "$0")"

NOTE="${1:-}"
BASE="${INSIGHTS_URL:-https://kiki-insights-production.up.railway.app}"
SHA=$(git rev-parse --short=12 HEAD)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

S=../Sources/CanvasModule
swiftc -O -D BRUSH_HARNESS \
  $S/DrawingEngine.swift $S/BrushDynamics.swift $S/BrushShapeCatalog.swift \
  $S/WetKM.swift $S/BrushFixture.swift $S/StrokeStabilizer.swift $S/StrokeStampGenerator.swift $S/WetStrokeWalker.swift \
  $S/CanvasRenderer.swift main.swift -o "$OUT/brushharness"

FIXTURE_ARGS=()
[ -d fixtures ] && FIXTURE_ARGS=(--fixtures fixtures)
BRUSH_SHAPES_DIR="$PWD/$S/Resources/BrushShapes" "$OUT/brushharness" --out "$OUT/render" "${FIXTURE_ARGS[@]}" > /dev/null

if [ -z "${INSIGHTS_INGEST_KEY:-}" ]; then
  INSIGHTS_INGEST_KEY=$(cd ../../../../backend && railway variables --service kiki-insights --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("INSIGHTS_INGEST_KEY",""))') || true
fi
if [ -z "${INSIGHTS_INGEST_KEY:-}" ]; then
  echo "ERROR: set INSIGHTS_INGEST_KEY (or link the Railway CLI)" >&2
  exit 1
fi

# Fields must precede file parts (streaming multipart parser).
CURL_ARGS=(-s -X POST "$BASE/ingest/test-run" -H "x-insights-key: $INSIGHTS_INGEST_KEY"
           -F "git_sha=$SHA")
[ -n "$NOTE" ] && CURL_ARGS+=(-F "note=$NOTE")
# Scene descriptions (scene → one-liner), written by the harness next to the PNGs.
[ -f "$OUT/render/manifest.json" ] && CURL_ARGS+=(-F "descriptions=<$OUT/render/manifest.json")
COUNT=0
for png in "$OUT"/render/*.png; do
  CURL_ARGS+=(-F "image=@$png;type=image/png")
  COUNT=$((COUNT + 1))
done
if [ "$COUNT" -eq 0 ]; then echo "ERROR: no PNGs rendered" >&2; exit 1; fi

RESPONSE=$(curl "${CURL_ARGS[@]}")
echo "$RESPONSE"
echo "$RESPONSE" | grep -q '"ok":true' || { echo "ERROR: publish failed" >&2; exit 1; }
echo "Published $COUNT images @ $SHA → $BASE/tests"
