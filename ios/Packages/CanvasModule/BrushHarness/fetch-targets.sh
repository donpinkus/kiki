#!/bin/bash
# fetch-targets.sh — pull the brush clone TARGETS (reference/settings screenshots +
# notes) from Kiki Insights' Brushes tab into ./targets/<id>-<slug>/, ready for
# Claude to study and recreate. Companion of fetch-fixtures.sh.
#
# Usage:  ./fetch-targets.sh
#
# Auth: ADMIN_PASSWORD env var, else read from the kiki-insights Railway service.
set -euo pipefail
cd "$(dirname "$0")"

BASE="${INSIGHTS_URL:-https://kiki-insights-production.up.railway.app}"
OUT="targets"
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
  -H 'Content-Type: application/json' -d "{\"password\": \"$ADMIN_PASSWORD\"}")
if [ "$login_status" != "200" ]; then
  echo "ERROR: admin login failed (HTTP $login_status)" >&2
  exit 1
fi

JSON_TMP=$(mktemp)
curl -s -b "$JAR" "$BASE/admin/api/brush-targets" > "$JSON_TMP"
python3 - "$BASE" "$OUT" "$JAR" "$JSON_TMP" << 'PY'
import json, os, re, subprocess, sys
base, out, jar, json_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(json_path))
targets = data.get('targets', [])
if not targets:
    print('No brush targets yet.')
    sys.exit(0)
for t in targets:
    slug = re.sub(r'[^a-zA-Z0-9]+', '-', t['name']).strip('-').lower() or 'target'
    d = os.path.join(out, f"{t['id']}-{slug}")
    os.makedirs(d, exist_ok=True)
    lines = [f"# {t['name']}", '', f"status: {t['status']}", f"updated: {t['updated_at']}", '']
    if t.get('note'):
        lines += ['## Brief / settings notes', '', t['note'], '']
    for kind in ('reference', 'settings', 'attempt'):
        imgs = [i for i in t['images'] if i['kind'] == kind]
        if not imgs: continue
        lines += [f'## {kind} images', '']
        for i in imgs:
            fname = f"{kind}-{i['id']}-{re.sub(r'[^a-zA-Z0-9]+', '-', (i.get('label') or 'img'))[:40]}.png"
            path = os.path.join(d, fname)
            subprocess.run(['curl', '-s', '-b', jar, '-o', path, f"{base}/blobs/{i['blob_key']}"], check=True)
            note = f" — {i['note']}" if i.get('note') else ''
            lines += [f"- {fname} (label: {i.get('label') or '-'}){note}"]
        lines += ['']
    with open(os.path.join(d, 'BRIEF.md'), 'w') as f:
        f.write('\n'.join(lines))
    n = len(t['images'])
    print(f"{t['id']} {t['name']} [{t['status']}] — {n} image(s) → {d}/")
print()
print('Study each target dir (BRIEF.md + images), build a preset, render, then post the')
print('attempt back with publish-attempt.sh <target_id> <png> "<note>".')
PY
rm -f "$JSON_TMP"
