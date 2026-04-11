#!/bin/bash
# Run this ON a RunPod pod (via SSH) to set up the FLUX.2-klein stream server.
# Uses a virtual environment to isolate dependencies.
set -euo pipefail

VOLUME_MODELS="/workspace/kiki-models"
FK_MODELS_DIR="${VOLUME_MODELS}/flux-klein"
FK_SERVER_DIR="/workspace/flux-klein-server"
FK_VENV="/workspace/flux-klein-venv"
FK_LOG="/workspace/flux-klein.log"

PYTHON=$(command -v python3)
echo "System python: $PYTHON ($($PYTHON --version 2>&1))"

# ── Step 1: Create or reuse virtual environment ──

echo ""
echo "==> Setting up virtual environment..."

if [ -d "$FK_VENV" ] && [ -f "$FK_VENV/bin/python" ]; then
  echo "  Reusing existing venv at $FK_VENV"
else
  echo "  Creating venv at $FK_VENV..."
  $PYTHON -m venv "$FK_VENV" --system-site-packages
  echo "  ✓ venv created"
fi

VENV_PYTHON="$FK_VENV/bin/python"
VENV_PIP="$FK_VENV/bin/pip"

# ── Step 2: Install dependencies ──

echo ""
echo "==> Installing dependencies in venv..."

# Upgrade PyTorch — base image has 2.4.0 but latest diffusers needs >=2.5
# for torch._custom_op flash attention support
echo "  Upgrading PyTorch (base image 2.4 is too old for latest diffusers)..."
$VENV_PIP install -q --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cu124 2>&1 | tail -5
echo "  ✓ PyTorch upgraded ($($VENV_PYTHON -c 'import torch; print(torch.__version__)'))"

# Diffusers from git (required for Flux2KleinPipeline)
echo "  Installing diffusers (from git)..."
$VENV_PIP install -q --no-cache-dir \
    "git+https://github.com/huggingface/diffusers.git" 2>&1 | tail -5
echo "  ✓ diffusers installed"

# Transformers, accelerate, sentencepiece for FLUX text encoder
echo "  Installing transformers, accelerate..."
$VENV_PIP install -q --no-cache-dir \
    "transformers>=4.40.0" \
    "accelerate>=0.28.0" \
    "sentencepiece>=0.2.0" 2>&1 | tail -3
echo "  ✓ ML dependencies installed"

# Server deps
echo "  Installing server dependencies..."
$VENV_PIP install -q --no-cache-dir \
    "fastapi>=0.108.0" \
    "uvicorn[standard]>=0.25.0" \
    "websockets>=12.0" \
    "Pillow>=10.0.0" 2>&1 | tail -3
echo "  ✓ Server dependencies installed"

# ── Step 3: Pre-download model to network volume ──

echo ""
echo "==> Checking/downloading FLUX.2-klein model..."
mkdir -p "$FK_MODELS_DIR"

export HF_HOME="${FK_MODELS_DIR}/huggingface"
mkdir -p "$HF_HOME"

if [ -d "${HF_HOME}/hub/models--black-forest-labs--FLUX.2-klein-4B" ]; then
  echo "  Model already cached on network volume"
else
  echo "  Downloading FLUX.2-klein-4B (~8 GB, this will take a few minutes)..."
  $VENV_PYTHON -c "
import os
os.environ['HF_HOME'] = '${HF_HOME}'
from diffusers import Flux2KleinPipeline
print('  Downloading black-forest-labs/FLUX.2-klein-4B...')
Flux2KleinPipeline.from_pretrained('black-forest-labs/FLUX.2-klein-4B')
print('  ✓ FLUX.2-klein-4B downloaded and cached')
"
fi

# ── Step 4: Copy server files into place ──

echo ""
echo "==> Deploying FLUX.2-klein server..."
if [ -d /tmp/flux-klein-server ]; then
  mkdir -p "$FK_SERVER_DIR"
  cp -r /tmp/flux-klein-server/* "$FK_SERVER_DIR/"
  echo "  ✓ Server files deployed to $FK_SERVER_DIR"
else
  echo "ERROR: Server files not found at /tmp/flux-klein-server"
  exit 1
fi

# ── Step 5: Kill any existing process ──

echo ""
echo "==> Starting FLUX.2-klein server..."
pkill -f "flux-klein-venv.*server.py" 2>/dev/null || true
pkill -f "python.*server.py.*8766" 2>/dev/null || true
sleep 2

# ── Step 6: Launch server ──

cd "$FK_SERVER_DIR"
export FLUX_HOST="0.0.0.0"
export FLUX_PORT="8766"
export HF_HOME="${FK_MODELS_DIR}/huggingface"
nohup "$VENV_PYTHON" server.py > "$FK_LOG" 2>&1 &
FK_PID=$!
echo "  FLUX.2-klein started (PID: $FK_PID, venv: $FK_VENV)"

# ── Step 7: Wait for health check ──
# Model loading + warmup takes longer than StreamDiffusion (~3-5 min)

echo ""
echo "==> Waiting for FLUX.2-klein to be ready (model loading + warmup)..."
FK_READY=false
for i in $(seq 1 120); do
  HEALTH=$(curl -s http://localhost:8766/health 2>/dev/null || echo "")
  STATUS=$(echo "$HEALTH" | $PYTHON -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  if [ "$STATUS" = "ok" ]; then
    echo ""
    echo "  FLUX.2-klein is ready!"
    echo "$HEALTH" | $PYTHON -m json.tool 2>/dev/null || true
    FK_READY=true
    break
  fi

  # Check if process is still running
  if ! kill -0 "$FK_PID" 2>/dev/null; then
    echo ""
    echo "ERROR: FLUX.2-klein process died. Last log lines:"
    tail -50 "$FK_LOG" 2>/dev/null || true
    exit 1
  fi

  echo "  Waiting... (${i}/120, status: ${STATUS:-loading})"
  sleep 5
done

if [ "$FK_READY" != "true" ]; then
  echo ""
  echo "ERROR: FLUX.2-klein did not become ready within ~10 min. Last log lines:"
  tail -50 "$FK_LOG" 2>/dev/null || true
  exit 1
fi

echo ""
echo "==> FLUX.2-klein setup complete!"
echo "  Server: http://localhost:8766"
echo "  Health: http://localhost:8766/health"
echo "  WebSocket: ws://localhost:8766/ws"
echo "  Log: $FK_LOG"
exit 0
