#!/usr/bin/env bash
# Generate a style picker thumbnail via fal.ai FLUX.2 [dev] text-to-image.
#
# Renders the SAME reference scene as every other style thumbnail (a delivery
# courier + scooter on a city street) so styles compare apples-to-apples, with
# the given style suffix appended. Writes the 1024x1024 JPEG + Contents.json
# into ios/Kiki/Assets.xcassets/style_thumbnail_<id>.imageset/.
#
# Usage:
#   ./gen-style-thumbnail.sh <id> "<promptSuffix>"
#   ./gen-style-thumbnail.sh <id> "<promptSuffix>" <seed>   # optional fixed seed
#
# Requires FAL_KEY in backend/.env.local. Run from anywhere.
set -euo pipefail

ID="${1:?usage: gen-style-thumbnail.sh <id> \"<promptSuffix>\" [seed]}"
SUFFIX="${2:?usage: gen-style-thumbnail.sh <id> \"<promptSuffix>\" [seed]}"
SEED="${3:-}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$REPO/backend/.env.local"
ASSET_DIR="$REPO/ios/Kiki/Assets.xcassets/style_thumbnail_${ID}.imageset"

# shellcheck disable=SC2046
export $(grep -E '^FAL_KEY=' "$ENV_FILE" | xargs)
: "${FAL_KEY:?FAL_KEY not found in $ENV_FILE}"

# Style-neutral base scene shared by all thumbnails; the suffix supplies the look.
BASE="A young delivery courier standing beside a small three-wheeled delivery scooter on a city street, wearing a delivery backpack box and holding a parcel, shop fronts and a street lamp in the background, full scene"
PROMPT="${BASE}${SUFFIX}"

echo "→ id:        $ID"
echo "→ prompt:    $PROMPT"
[ -n "$SEED" ] && echo "→ seed:      $SEED"

BODY=$(SEED="$SEED" PROMPT="$PROMPT" python3 - <<'PY'
import json, os
body = {
    "prompt": os.environ["PROMPT"],
    "image_size": {"width": 1024, "height": 1024},
    "num_images": 1,
}
if os.environ.get("SEED"):
    body["seed"] = int(os.environ["SEED"])
print(json.dumps(body))
PY
)

sub=$(curl -s -X POST "https://queue.fal.run/fal-ai/flux-2" \
  -H "Authorization: Key $FAL_KEY" -H "Content-Type: application/json" -d "$BODY")
STATUS_URL=$(echo "$sub" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status_url"])')
RESP_URL=$(echo "$sub" | python3 -c 'import sys,json;print(json.load(sys.stdin)["response_url"])')

echo -n "→ generating"
for _ in $(seq 1 90); do
  s=$(curl -s "$STATUS_URL" -H "Authorization: Key $FAL_KEY" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')
  [ "$s" = "COMPLETED" ] && { echo " done"; break; }
  echo -n "."; sleep 2
done

curl -s "$RESP_URL" -H "Authorization: Key $FAL_KEY" -o /tmp/fal_result.json
URL=$(python3 -c 'import json;print(json.load(open("/tmp/fal_result.json"))["images"][0]["url"])')
SEED_USED=$(python3 -c 'import json;print(json.load(open("/tmp/fal_result.json")).get("seed",""))')

mkdir -p "$ASSET_DIR"
curl -s "$URL" -o /tmp/fal_dl.png
sips -s format jpeg -z 1024 1024 /tmp/fal_dl.png --out "$ASSET_DIR/thumbnail.jpg" >/dev/null
cat > "$ASSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "thumbnail.jpg",
      "idiom" : "universal",
      "scale" : "1x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "✓ wrote $ASSET_DIR/thumbnail.jpg (seed=$SEED_USED)"
