#!/bin/bash
# Run this ON the kiki-comfyui RunPod pod (via SSH or via the
# .github/workflows/deploy-semantic-draw.yml action) to set up the upstream
# semantic-draw Gradio demo (https://github.com/ironjr/semantic-draw)
# alongside ComfyUI and StreamDiffusion.
#
# Access pattern (port 8000 is NOT exposed in deploy-pod.yml — laptop only):
#   ssh -L 8000:localhost:8000 -i ~/.ssh/runpod_key -p <SSH_PORT> root@<SSH_IP>
#   open http://localhost:8000
#
# Mirrors the structure of scripts/setup-streamdiffusion.sh:
#   - venv with --system-site-packages (inherits torch/CUDA/xformers)
#   - HF cache on the network volume under /workspace/kiki-models
#   - nohup launch + curl-poll readiness check
# Idempotent: safe to re-run after a failure.
set -euo pipefail

# ── Logging helpers ──────────────────────────────────────────────────────────
# Always emit ANSI colors. GitHub Actions and most terminals render them; raw
# escapes in `cat | grep` are an acceptable trade-off for clear status output.
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[1;36m'

ts() { date +%H:%M:%S; }
log()  { printf "%s[%s]%s %s\n" "$C_DIM" "$(ts)" "$C_RESET" "$*"; }
step() { printf "\n%s[%s] ━━━ %s ━━━%s\n" "$C_CYAN$C_BOLD" "$(ts)" "$*" "$C_RESET"; }
ok()   { printf "%s[%s] ✓%s %s\n" "$C_GREEN" "$(ts)" "$C_RESET" "$*"; }
warn() { printf "%s[%s] ⚠ %s%s\n" "$C_YELLOW" "$(ts)" "$*" "$C_RESET" >&2; }
err()  { printf "%s[%s] ✗ ERROR: %s%s\n" "$C_RED" "$(ts)" "$*" "$C_RESET" >&2; }
die()  { err "$*"; exit 1; }

# Trap unhandled errors (anything `set -e` would kill us on outside an `if`).
# Without this, `set -e` exits silently with no indication of which line failed.
on_err() {
  local exit_code=$? lineno=$1
  err "Unhandled failure at line $lineno (exit code $exit_code)"
  err "The most recent log lines above show what was running."
  err "Re-run after fixing, or check $SDR_LOG if the launch step had started."
  exit "$exit_code"
}
trap 'on_err $LINENO' ERR

# ── Configuration ────────────────────────────────────────────────────────────
START_TS=$(date +%s)
VOLUME_MODELS="/workspace/kiki-models"
SDR_MODELS_DIR="${VOLUME_MODELS}/semantic-draw"
SDR_REPO_DIR="/workspace/semantic-draw"
SDR_VENV="/workspace/semantic-draw-venv"
SDR_LOG="/workspace/semantic-draw.log"
SDR_PORT="8000"
SDR_REPO_URL="https://github.com/ironjr/semantic-draw.git"

PYTHON=$(command -v python3) || die "python3 not found in PATH"
log "System python: $PYTHON ($($PYTHON --version 2>&1))"
log "Working dir:   $(pwd)"
log "Pod paths:"
log "  repo:        $SDR_REPO_DIR"
log "  venv:        $SDR_VENV"
log "  HF cache:    $SDR_MODELS_DIR/huggingface"
log "  log:         $SDR_LOG"
log "  Gradio port: $SDR_PORT (loopback only — SSH tunnel required for laptop access)"

# ── Step 1/7: Clone or update the upstream repo ──────────────────────────────

step "[1/7] Clone or update semantic-draw repo"
if [ -d "$SDR_REPO_DIR/.git" ]; then
  log "Repo exists at $SDR_REPO_DIR — fetching latest"
  if ! git -C "$SDR_REPO_DIR" pull --ff-only; then
    die "git pull --ff-only failed. The on-pod clone may have diverged from origin/main. Inspect with 'git -C $SDR_REPO_DIR status' and either resolve manually or 'rm -rf $SDR_REPO_DIR' to force a fresh clone on the next run."
  fi
else
  log "Cloning fresh from $SDR_REPO_URL"
  if ! git clone "$SDR_REPO_URL" "$SDR_REPO_DIR"; then
    die "git clone failed. Check pod outbound network to github.com and that $SDR_REPO_DIR is writable."
  fi
fi
ok "Repo ready at $SDR_REPO_DIR ($(git -C "$SDR_REPO_DIR" rev-parse --short HEAD))"

# ── Step 2/7: Create or reuse virtual environment ────────────────────────────

step "[2/7] Create or reuse Python venv (--system-site-packages)"
if [ -d "$SDR_VENV" ] && [ -f "$SDR_VENV/bin/python" ]; then
  log "Reusing existing venv at $SDR_VENV"
else
  log "Creating venv at $SDR_VENV (inherits torch/CUDA/xformers from base image)"
  if ! $PYTHON -m venv "$SDR_VENV" --system-site-packages; then
    die "venv creation failed. Check that python3-venv is installed on the base image and that $SDR_VENV is writable."
  fi
fi

VENV_PYTHON="$SDR_VENV/bin/python"
VENV_PIP="$SDR_VENV/bin/pip"
[ -x "$VENV_PYTHON" ] || die "Venv python not executable at $VENV_PYTHON. Venv creation may have failed silently — try 'rm -rf $SDR_VENV' and re-run."
ok "Venv ready: $VENV_PYTHON"

# ── Step 3/7: Install upstream deps from requirement.txt ─────────────────────

# The upstream README says `pip install -r requirements.txt` (plural) but the
# actual file in the repo is named `requirement.txt` (singular). It is also
# fully unpinned and includes a custom diffusers fork at
# `git+https://github.com/initml/diffusers.git@clement/feature/flash_sd3`
# which is only required for the SD3 demo. The SD 1.5 stream demo we run here
# does NOT need it. If `pip install -r requirement.txt` fails because of the
# fork, the recovery hints in the err block below will guide you.
step "[3/7] Install dependencies from requirement.txt"
log "This is the most failure-prone step — requirement.txt is fully unpinned."
log "Watch for: xformers/torch ABI mismatch, diffusers fork build failures, transformers conflicts."
log "Running: pip install -q --no-cache-dir -r $SDR_REPO_DIR/requirement.txt"
# -q reduces per-package noise; we deliberately do NOT pipe through tail here
# because tail buffers stdin and would hide live progress on the slowest step.
if ! $VENV_PIP install -q --no-cache-dir -r "$SDR_REPO_DIR/requirement.txt"; then
  err "pip install failed. Most likely causes (in order):"
  err "  1) xformers wheel does not match the inherited torch ABI (--system-site-packages)"
  err "  2) the custom diffusers fork (git+...flash_sd3) failed to build"
  err "  3) some unpinned dep resolved to a version that conflicts with the inherited site-packages"
  err "Recovery options:"
  err "  a) Comment out the diffusers fork line in $SDR_REPO_DIR/requirement.txt and re-run"
  err "  b) Add explicit version pins to this script before the -r line and re-run"
  err "  c) 'rm -rf $SDR_VENV' and edit step 2 to drop --system-site-packages (clean install, ~5 GB)"
  die "Dependency installation failed (see causes/recovery above)"
fi
ok "All declared dependencies installed"

log "Verifying venv imports (catches system-site leaks)"
if ! $VENV_PYTHON - <<'PY'
import sys
try:
    import diffusers, torch
    try:
        import xformers
        xformers_v = xformers.__version__
    except Exception as e:
        xformers_v = f"NOT IMPORTABLE: {e}"
    print(f"  diffusers: {diffusers.__version__} ({diffusers.__file__})")
    print(f"  torch:     {torch.__version__}")
    print(f"  xformers:  {xformers_v}")
    print(f"  cuda:      available={torch.cuda.is_available()} devices={torch.cuda.device_count()}")
except Exception as e:
    print(f"IMPORT FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PY
then
  die "Venv import check failed. Install completed but the packages aren't importable from the venv. This usually means the venv inherited a broken transformers/huggingface_hub from the base image — try the 'rm -rf venv + drop --system-site-packages' recovery."
fi
ok "Venv imports verified"

# ── Step 4/7: Pre-download model weights to network volume ───────────────────

step "[4/7] Pre-download semantic-draw model weights"
mkdir -p "$SDR_MODELS_DIR" || die "Cannot create $SDR_MODELS_DIR (network volume issue?)"
export HF_HOME="${SDR_MODELS_DIR}/huggingface"
mkdir -p "$HF_HOME" || die "Cannot create HF_HOME=$HF_HOME"
log "HF_HOME=$HF_HOME"

if [ -d "${HF_HOME}/hub/models--ironjr--BlazingDriveV11m" ] && \
   [ -d "${HF_HOME}/hub/models--latent-consistency--lcm-lora-sdv1-5" ]; then
  log "Both models already cached on the network volume — skipping download"
  ok "Models cached"
else
  log "Downloading models (~2-3 GB total — first run only)"
  if ! $VENV_PYTHON - <<PY
import os
os.environ['HF_HOME'] = '${HF_HOME}'
from huggingface_hub import snapshot_download
print('  Downloading ironjr/BlazingDriveV11m...')
snapshot_download('ironjr/BlazingDriveV11m')
print('  ✓ BlazingDriveV11m')
print('  Downloading latent-consistency/lcm-lora-sdv1-5...')
snapshot_download('latent-consistency/lcm-lora-sdv1-5')
print('  ✓ lcm-lora-sdv1-5')
print('  All declared models downloaded. The SemanticDraw constructor may pull')
print('  additional assets (e.g. taesd) at first launch — that is expected.')
PY
  then
    err "Model download failed. Most likely causes:"
    err "  1) Pod outbound network to huggingface.co is broken or rate-limited"
    err "  2) One of the models was removed from HF (BlazingDriveV11m or lcm-lora-sdv1-5)"
    err "  3) HF_HOME ($HF_HOME) is not writable or the network volume is full"
    die "Model download failed (see causes above)"
  fi
  ok "Models downloaded to $HF_HOME"
fi

# ── Step 5/7: Stop any prior semantic-draw process ───────────────────────────

step "[5/7] Stop any prior semantic-draw process"
PRIOR_PIDS=$(pgrep -f "semantic-draw-venv.*demo/stream/app.py" 2>/dev/null || true)
if [ -n "$PRIOR_PIDS" ]; then
  log "Found prior PID(s): $PRIOR_PIDS — terminating"
  pkill -f "semantic-draw-venv.*demo/stream/app.py" 2>/dev/null || true
  pkill -f "python.*demo/stream/app.py" 2>/dev/null || true
  sleep 2
  ok "Prior processes terminated"
else
  log "No prior semantic-draw process running"
  ok "Clean slate"
fi

# ── Step 6/7: Launch demo/stream/app.py via nohup ────────────────────────────

step "[6/7] Launch Gradio demo on port $SDR_PORT"
APP_PY="$SDR_REPO_DIR/demo/stream/app.py"
[ -f "$APP_PY" ] || die "$APP_PY not found. The clone is incomplete or the upstream layout changed."
log "Found app.py at $APP_PY"

# CRITICAL: app.py contains `sys.path.append('../../src')` so it MUST be run
# from the demo/stream/ directory or imports will fail.
# We omit --model so the in-code default `ironjr/BlazingDriveV11m` is used.
log "cd to demo/stream/ (required by app.py's sys.path.append('../../src'))"
cd "$SDR_REPO_DIR/demo/stream"

log "Launching: nohup $VENV_PYTHON app.py --port $SDR_PORT (model: in-code default)"
nohup "$VENV_PYTHON" app.py --port "$SDR_PORT" > "$SDR_LOG" 2>&1 &
SDR_PID=$!
log "PID: $SDR_PID, log: $SDR_LOG"

# Sanity check: did the process die immediately (e.g. import error)?
sleep 2
if ! kill -0 "$SDR_PID" 2>/dev/null; then
  err "semantic-draw process died immediately after launch."
  err "This usually means an import error or a missing model. Last 50 log lines:"
  tail -50 "$SDR_LOG" 2>/dev/null || true
  die "Launch failed (see log above)"
fi
ok "Process started (PID $SDR_PID), surviving initial 2s"

# ── Step 7/7: Poll readiness via curl until Gradio answers 200 ───────────────

step "[7/7] Wait for Gradio to answer HTTP 200"
log "Polling http://localhost:$SDR_PORT/ every 5s, up to 10 min total"
log "(Models pre-cached in step 4, so this should be model-load + Gradio init only.)"

SDR_READY=false
for i in $(seq 1 120); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${SDR_PORT}/" 2>/dev/null || echo "000")

  if [ "$CODE" = "200" ]; then
    ok "Gradio is responding (HTTP 200)"
    SDR_READY=true
    break
  fi

  # Bail early if the process died during warmup
  if ! kill -0 "$SDR_PID" 2>/dev/null; then
    err "semantic-draw process died during warmup (poll iteration $i/120)."
    err "Last 50 log lines:"
    tail -50 "$SDR_LOG" 2>/dev/null || true
    die "Process died during warmup (see log above)"
  fi

  log "Waiting... ($i/120, http: $CODE)"
  sleep 5
done

if [ "$SDR_READY" != "true" ]; then
  err "semantic-draw did not become ready within 10 minutes (120 × 5s)."
  err "The process is still running but not answering HTTP 200 on /."
  err "Last 50 log lines:"
  tail -50 "$SDR_LOG" 2>/dev/null || true
  die "Readiness timeout"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

# Disable the ERR trap before clean exit so the trailing summary commands
# can't accidentally trigger it.
trap - ERR

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

step "Done — semantic-draw setup complete"
ok "Total time: ${DURATION_MIN}m ${DURATION_SEC}s"
log "Gradio (on pod):  http://localhost:${SDR_PORT}"
log "Process PID:      $SDR_PID (running under nohup)"
log "Server log:       $SDR_LOG"
echo ""
log "To access from your laptop, open an SSH tunnel and leave it open:"
log "  ssh -L ${SDR_PORT}:localhost:${SDR_PORT} -i ~/.ssh/runpod_key -p <SSH_PORT> root@<SSH_IP>"
log "Then open http://localhost:${SDR_PORT} in your browser."
exit 0
