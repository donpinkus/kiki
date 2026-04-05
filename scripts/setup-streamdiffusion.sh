#!/bin/bash
# Run this ON the RunPod pod (via SSH) to set up StreamDiffusion alongside ComfyUI.
# Uses a virtual environment to avoid dependency conflicts with the base image
# (ComfyUI needs transformers 5.x / huggingface_hub>=1.3, StreamDiffusion pins diffusers==0.24.0
#  which needs huggingface_hub<0.25 — these are fundamentally incompatible in one env).
set -euo pipefail

VOLUME_MODELS="/workspace/kiki-models"
SD_MODELS_DIR="${VOLUME_MODELS}/streamdiffusion"
SD_SERVER_DIR="/workspace/streamdiffusion-server"
SD_VENV="/workspace/streamdiffusion-venv"
SD_LOG="/workspace/streamdiffusion.log"

PYTHON=$(command -v python3)
echo "System python: $PYTHON"

# ── Step 1: Create or reuse virtual environment ──

echo ""
echo "==> Setting up virtual environment..."

if [ -d "$SD_VENV" ] && [ -f "$SD_VENV/bin/python" ]; then
  echo "  Reusing existing venv at $SD_VENV"
else
  echo "  Creating venv at $SD_VENV..."
  $PYTHON -m venv "$SD_VENV" --system-site-packages
  echo "  ✓ venv created"
fi

# Use venv python/pip from here on
VENV_PYTHON="$SD_VENV/bin/python"
VENV_PIP="$SD_VENV/bin/pip"

# ── Step 2: Install StreamDiffusion + deps in venv ──

echo ""
echo "==> Installing StreamDiffusion in venv..."

# Install StreamDiffusion first — it pins diffusers==0.24.0
echo "  Installing StreamDiffusion from source..."
$VENV_PIP install -q --no-cache-dir \
    "git+https://github.com/cumulo-autumn/StreamDiffusion.git@main#egg=streamdiffusion" 2>&1 | tail -5
echo "  ✓ StreamDiffusion installed"

# Pin huggingface_hub to a version compatible with diffusers 0.24.0
# (hf_cache_home was removed in huggingface_hub>=0.25)
echo "  Pinning huggingface_hub<0.25..."
$VENV_PIP install -q --no-cache-dir "huggingface_hub>=0.20.2,<0.25.0" 2>&1 | tail -3

# Pin transformers to a version compatible with huggingface_hub<0.25
echo "  Pinning transformers<4.40..."
$VENV_PIP install -q --no-cache-dir "transformers>=4.36.0,<4.40.0" 2>&1 | tail -3

# Install server deps
echo "  Installing server dependencies..."
$VENV_PIP install -q --no-cache-dir \
    "fastapi>=0.108.0" \
    "uvicorn[standard]>=0.25.0" \
    "websockets>=12.0" \
    "Pillow>=10.0.0" 2>&1 | tail -3
echo "  ✓ All dependencies installed"

# ── Step 3: Pre-download models to network volume ──

echo ""
echo "==> Checking/downloading StreamDiffusion models..."
mkdir -p "$SD_MODELS_DIR"

export HF_HOME="${SD_MODELS_DIR}/huggingface"
mkdir -p "$HF_HOME"

if [ -d "${HF_HOME}/hub/models--Lykon--dreamshaper-8" ] && \
   [ -d "${HF_HOME}/hub/models--latent-consistency--lcm-lora-sdv1-5" ]; then
  echo "  Models already cached on network volume"
else
  echo "  Downloading models (~2-3 GB)..."
  $VENV_PYTHON -c "
import os
os.environ['HF_HOME'] = '${HF_HOME}'
from diffusers import StableDiffusionImg2ImgPipeline
from huggingface_hub import hf_hub_download
print('  Downloading Lykon/dreamshaper-8...')
StableDiffusionImg2ImgPipeline.from_pretrained('Lykon/dreamshaper-8')
print('  ✓ dreamshaper-8')
print('  Downloading LCM-LoRA...')
hf_hub_download('latent-consistency/lcm-lora-sdv1-5', 'pytorch_lora_weights.safetensors')
print('  ✓ lcm-lora-sdv1-5')
print('  All models downloaded!')
"
fi

# ── Step 4: Copy server files into place ──

echo ""
echo "==> Deploying StreamDiffusion server..."
if [ -d /tmp/streamdiffusion-server ]; then
  mkdir -p "$SD_SERVER_DIR"
  cp -r /tmp/streamdiffusion-server/* "$SD_SERVER_DIR/"
  echo "  ✓ Server files deployed to $SD_SERVER_DIR"
else
  echo "ERROR: Server files not found at /tmp/streamdiffusion-server"
  exit 1
fi

# ── Step 5: Kill any existing StreamDiffusion process ──

echo ""
echo "==> Starting StreamDiffusion server..."
pkill -f "streamdiffusion-venv.*server.py" 2>/dev/null || true
pkill -f "python.*server.py.*8765" 2>/dev/null || true
sleep 2

# ── Step 6: Launch StreamDiffusion server using venv python ──

cd "$SD_SERVER_DIR"
export SD_HOST="0.0.0.0"
export SD_PORT="8765"
nohup "$VENV_PYTHON" server.py > "$SD_LOG" 2>&1 &
SD_PID=$!
echo "  StreamDiffusion started (PID: $SD_PID, venv: $SD_VENV)"

# ── Step 7: Wait for health check ──

echo ""
echo "==> Waiting for StreamDiffusion to be ready (model loading + warmup)..."
SD_READY=false
for i in $(seq 1 90); do
  HEALTH=$(curl -s http://localhost:8765/health 2>/dev/null || echo "")
  STATUS=$(echo "$HEALTH" | $PYTHON -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  if [ "$STATUS" = "ok" ]; then
    echo ""
    echo "  StreamDiffusion is ready!"
    echo "$HEALTH" | $PYTHON -m json.tool 2>/dev/null || true
    SD_READY=true
    break
  fi

  # Check if process is still running
  if ! kill -0 "$SD_PID" 2>/dev/null; then
    echo ""
    echo "ERROR: StreamDiffusion process died. Last log lines:"
    tail -30 "$SD_LOG" 2>/dev/null || true
    exit 1
  fi

  echo "  Waiting... (${i}/90, status: ${STATUS:-loading})"
  sleep 5
done

if [ "$SD_READY" != "true" ]; then
  echo ""
  echo "ERROR: StreamDiffusion did not become ready within ~7.5 min. Last log lines:"
  tail -30 "$SD_LOG" 2>/dev/null || true
  exit 1
fi

echo ""
echo "==> StreamDiffusion setup complete!"
echo "  Server: http://localhost:8765"
echo "  Health: http://localhost:8765/health"
echo "  WebSocket: ws://localhost:8765/ws"
echo "  Log: $SD_LOG"
exit 0
