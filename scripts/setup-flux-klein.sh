#!/bin/bash
# Run this ON a RunPod pod (via SSH) to set up the FLUX.2-klein stream server.
# Spot pod = ephemeral, container-disk only. Fresh model download every boot (~13GB, 2-3 min).
# Base image: runpod/pytorch:1.0.3-cu1300-torch291-ubuntu2404 (CUDA 13 + torch 2.9.1, required for NVFP4).
set -euo pipefail

# All state lives on the container disk — no network volume.
MODELS_DIR="/root/kiki-models"
FK_SERVER_DIR="/root/flux-klein-server"
FK_VENV="/root/flux-klein-venv"
FK_LOG="/root/flux-klein.log"

PYTHON=$(command -v python3)
echo "System python: $PYTHON ($($PYTHON --version 2>&1))"

# ── Step 1: Create or reuse virtual environment ──

echo ""
echo "==> Setting up virtual environment..."

NEEDS_INSTALL=false
if [ -d "$FK_VENV" ] && [ -f "$FK_VENV/bin/python" ]; then
  # Quick sanity check: can we import torch and diffusers?
  if "$FK_VENV/bin/python" -c "import torch; import diffusers" 2>/dev/null; then
    echo "  Reusing existing venv at $FK_VENV"
  else
    echo "  Existing venv is broken, recreating..."
    rm -rf "$FK_VENV"
    NEEDS_INSTALL=true
  fi
else
  NEEDS_INSTALL=true
fi

if [ "$NEEDS_INSTALL" = "true" ]; then
  echo "  Creating venv at $FK_VENV (system-site-packages so we inherit the image's torch)..."
  $PYTHON -m venv --system-site-packages "$FK_VENV"
  echo "  ✓ venv created"
fi

VENV_PYTHON="$FK_VENV/bin/python"
VENV_PIP="$FK_VENV/bin/pip"

# ── Step 2: Install dependencies (skip if venv already has them) ──

echo ""
if [ "$NEEDS_INSTALL" = "true" ]; then
  echo "==> Installing dependencies in venv..."

  # Torch already present from the base image (2.9.1 + CUDA 13). Verify, don't reinstall.
  TORCH_VER=$($VENV_PYTHON -c 'import torch; print(torch.__version__)')
  CUDA_AVAIL=$($VENV_PYTHON -c 'import torch; print(torch.cuda.is_available())')
  echo "  Torch: $TORCH_VER, CUDA available: $CUDA_AVAIL"

  # Diffusers from git (required for Flux2KleinPipeline)
  echo "  Installing diffusers (from git)..."
  $VENV_PIP install --no-cache-dir \
      "git+https://github.com/huggingface/diffusers.git"
  echo "  ✓ diffusers installed"

  # Transformers, accelerate, sentencepiece for FLUX text encoder
  echo "  Installing transformers, accelerate..."
  $VENV_PIP install --no-cache-dir \
      "transformers>=4.40.0" \
      "accelerate>=0.28.0" \
      "sentencepiece>=0.2.0" \
      "safetensors>=0.4.0"
  echo "  ✓ ML dependencies installed"

  # torchvision: pinned to match the base image's torch 2.9.1 + cu128.
  # Used by pipeline.py's denoise-mode image preprocessing.
  echo "  Installing torchvision (cu128, matches torch 2.9.1)..."
  $VENV_PIP install --no-cache-dir \
      "torchvision==0.24.1" --index-url https://download.pytorch.org/whl/cu128
  echo "  ✓ torchvision installed"

  # Server deps
  echo "  Installing server dependencies..."
  $VENV_PIP install --no-cache-dir \
      "fastapi>=0.108.0" \
      "uvicorn[standard]>=0.25.0" \
      "websockets>=12.0" \
      "Pillow>=10.0.0"
  echo "  ✓ Server dependencies installed"
else
  echo "==> Dependencies already installed, skipping."
fi

# ── Step 3: Model weights are downloaded lazily by the pipeline on first load ──
# Cache lives on container disk — ephemeral, but matches spot pod lifecycle.

echo ""
export HF_HOME="${MODELS_DIR}/huggingface"
mkdir -p "$HF_HOME"
echo "==> HF_HOME=$HF_HOME (model downloads happen on pipeline load)"

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
export HF_HOME="${MODELS_DIR}/huggingface"
nohup "$VENV_PYTHON" server.py > "$FK_LOG" 2>&1 &
FK_PID=$!
echo "  FLUX.2-klein started (PID: $FK_PID, venv: $FK_VENV)"

# ── Step 7: Wait for health check ──
# Fresh boot: model download (~2-3 min) + load + warmup → total can be 5-8 min.

echo ""
echo "==> Waiting for FLUX.2-klein to be ready..."
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
