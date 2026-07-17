#!/bin/bash
# publish-attempt.sh <target_id> <png> ["note"] — post a brush recreation render
# to a Brushes-tab target as kind:'attempt' (shown beside the references).
set -euo pipefail
cd "$(dirname "$0")"
TARGET_ID="${1:?usage: publish-attempt.sh <target_id> <png> [note]}"
PNG="${2:?usage: publish-attempt.sh <target_id> <png> [note]}"
NOTE="${3:-}"
BASE="${INSIGHTS_URL:-https://kiki-insights-production.up.railway.app}"
if [ -z "${INSIGHTS_INGEST_KEY:-}" ]; then
  INSIGHTS_INGEST_KEY=$(cd ../../../../backend && railway variables --service kiki-insights --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("INSIGHTS_INGEST_KEY",""))') || true
fi
[ -n "$INSIGHTS_INGEST_KEY" ] || { echo "ERROR: INSIGHTS_INGEST_KEY unavailable" >&2; exit 1; }
curl -s -X POST "$BASE/ingest/brush-target-attempt" \
  -H "x-insights-key: $INSIGHTS_INGEST_KEY" \
  -F "target_id=$TARGET_ID" \
  -F "note=$NOTE" \
  -F "label=$(basename "$PNG" .png)" \
  -F "image=@$PNG;type=image/png"
echo
