#!/bin/bash
# Run this ON the RunPod pod (via SSH) to set up ComfyUI with models from the network volume.
# Handles both existing volumes (with models) and fresh volumes (downloads models).
set -euo pipefail

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
# Standard model location on network volume (used for all new volumes)
VOLUME_MODELS="/workspace/kiki-models"

# ── Find Python/pip ──
# runpod/comfyui:latest has no venv — pip/python3 are system-wide.
COMFYUI_PIP=$(command -v pip3 || command -v pip)
COMFYUI_PYTHON=$(command -v python3)
echo "Using pip: $COMFYUI_PIP  python: $COMFYUI_PYTHON"

# ── Step 1: Find or download models ──

# Check known model locations (varies by volume history)
if [ -d "/workspace/madapps/ComfyUI/models" ]; then
  MODEL_BASE="/workspace/madapps/ComfyUI/models"
  echo "Found models at: $MODEL_BASE (EU volume)"
elif [ -f "/workspace/ComfyUI/models/diffusion_models/qwen_image_fp8_e4m3fn.safetensors" ]; then
  MODEL_BASE="/workspace/ComfyUI/models"
  echo "Found models at: $MODEL_BASE (US volume)"
elif [ -f "${VOLUME_MODELS}/diffusion_models/qwen_image_fp8_e4m3fn.safetensors" ]; then
  MODEL_BASE="$VOLUME_MODELS"
  echo "Found models at: $MODEL_BASE"
else
  echo ""
  echo "⚠️  No models found on this volume — downloading (~30GB, may take 5-10 min)..."
  echo ""
  MODEL_BASE="$VOLUME_MODELS"

  mkdir -p "${MODEL_BASE}/diffusion_models"
  mkdir -p "${MODEL_BASE}/text_encoders"
  mkdir -p "${MODEL_BASE}/vae"
  mkdir -p "${MODEL_BASE}/controlnet"
  mkdir -p "${MODEL_BASE}/loras"

  "$COMFYUI_PIP" install -q huggingface_hub 2>&1 | tail -1

  python3 -c "
from huggingface_hub import hf_hub_download
import concurrent.futures, os

models = [
    ('Comfy-Org/Qwen-Image_ComfyUI', 'split_files/diffusion_models/qwen_image_fp8_e4m3fn.safetensors', '${MODEL_BASE}/diffusion_models'),
    ('Comfy-Org/Qwen-Image_ComfyUI', 'split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors', '${MODEL_BASE}/text_encoders'),
    ('Comfy-Org/Qwen-Image_ComfyUI', 'split_files/vae/qwen_image_vae.safetensors', '${MODEL_BASE}/vae'),
    ('Comfy-Org/Qwen-Image-InstantX-ControlNets', 'split_files/controlnet/Qwen-Image-InstantX-ControlNet-Union.safetensors', '${MODEL_BASE}/controlnet'),
    ('lightx2v/Qwen-Image-Lightning', 'Qwen-Image-Lightning-8steps-V2.0.safetensors', '${MODEL_BASE}/loras'),
]

def download(args):
    repo, filename, local_dir = args
    print(f'  Downloading {filename.split(\"/\")[-1]}...')
    hf_hub_download(repo, filename, local_dir=local_dir)
    # Move from split_files subdirectory if needed
    basename = filename.split('/')[-1]
    split_path = os.path.join(local_dir, filename)
    dest_path = os.path.join(local_dir, basename)
    if os.path.exists(split_path) and split_path != dest_path:
        os.rename(split_path, dest_path)
    print(f'  ✓ {basename}')

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
    executor.map(download, models)

print('All models downloaded!')
"

  # Clean up split_files subdirectories
  find "$MODEL_BASE" -name "split_files" -type d -exec rm -rf {} + 2>/dev/null || true
fi

# ── Step 2: Symlink models into ComfyUI ──

echo ""
echo "==> Symlinking models into ComfyUI..."

ln -sf "${MODEL_BASE}/diffusion_models/qwen_image_fp8_e4m3fn.safetensors" \
  "${COMFYUI_DIR}/models/diffusion_models/"
echo "  ✓ qwen_image_fp8_e4m3fn.safetensors"

ln -sf "${MODEL_BASE}/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
  "${COMFYUI_DIR}/models/text_encoders/"
echo "  ✓ qwen_2.5_vl_7b_fp8_scaled.safetensors"

ln -sf "${MODEL_BASE}/vae/qwen_image_vae.safetensors" \
  "${COMFYUI_DIR}/models/vae/"
echo "  ✓ qwen_image_vae.safetensors"

ln -sf "${MODEL_BASE}/controlnet/Qwen-Image-InstantX-ControlNet-Union.safetensors" \
  "${COMFYUI_DIR}/models/controlnet/"
echo "  ✓ Qwen-Image-InstantX-ControlNet-Union.safetensors"

if [ -f "${MODEL_BASE}/loras/Qwen-Image-Lightning-8steps-V2.0.safetensors" ]; then
  ln -sf "${MODEL_BASE}/loras/Qwen-Image-Lightning-8steps-V2.0.safetensors" \
    "${COMFYUI_DIR}/models/loras/"
  echo "  ✓ Qwen-Image-Lightning-8steps-V2.0.safetensors"
else
  echo "  ⚠ Lightning LoRA not found"
fi

# ── Step 3: Save backend workflow to ComfyUI UI ──

WORKFLOWS_DIR="${COMFYUI_DIR}/user/default/workflows"
if [ -f /tmp/comfyui-workflow-api.json ]; then
  mkdir -p "$WORKFLOWS_DIR"
  TIMESTAMP=$(date +%Y-%m-%d-%H%M)
  cp /tmp/comfyui-workflow-api.json "${WORKFLOWS_DIR}/kiki-backend-${TIMESTAMP}.json"
  echo "  ✓ Saved workflow as kiki-backend-${TIMESTAMP}.json"
fi

# ── Step 4: Install custom nodes ──

echo ""
echo "==> Installing custom node dependencies..."
if [ ! -d "${COMFYUI_DIR}/custom_nodes/comfyui_controlnet_aux" ]; then
  echo "  Cloning comfyui_controlnet_aux..."
  git clone https://github.com/Fannovel16/comfyui_controlnet_aux.git \
    "${COMFYUI_DIR}/custom_nodes/comfyui_controlnet_aux"
fi
cd "${COMFYUI_DIR}/custom_nodes/comfyui_controlnet_aux"
"$COMFYUI_PIP" install -r requirements.txt 2>&1 | tail -3

# ── Step 5: Restart ComfyUI ──

echo ""
echo "==> Restarting ComfyUI..."
pkill -f "python.*main.py" || true
sleep 2
cd "${COMFYUI_DIR}"
nohup "$COMFYUI_PYTHON" main.py --listen 0.0.0.0 --port 8188 > /workspace/runpod-slim/comfyui.log 2>&1 &

echo ""
echo "==> Waiting for ComfyUI to start..."
COMFYUI_READY=false
for i in $(seq 1 30); do
  if curl -s -o /dev/null -w "" http://localhost:8188/system_stats 2>/dev/null; then
    echo "ComfyUI is running on port 8188!"
    echo ""
    curl -s http://localhost:8188/system_stats | python3 -m json.tool 2>/dev/null || true
    COMFYUI_READY=true
    break
  fi
  sleep 2
done

if [ "$COMFYUI_READY" != "true" ]; then
  echo "ERROR: ComfyUI did not start within 60s. Last log lines:"
  tail -20 /workspace/runpod-slim/comfyui.log 2>/dev/null || true
  exit 1
fi

# ── Step 6: Warm up models (load into VRAM) ──

warmup_models() {
  local WARMUP_START
  WARMUP_START=$(date +%s)

  if [ ! -f /tmp/comfyui-workflow-api.json ]; then
    echo "  Skipping warmup: workflow template not found at /tmp/comfyui-workflow-api.json"
    return 1
  fi

  # Create a small dummy image
  python3 -c "
from PIL import Image
img = Image.new('RGB', (256, 256), (128, 128, 128))
img.save('/tmp/warmup_input.png')
"

  # Upload dummy image to ComfyUI
  local UPLOAD_RESP
  UPLOAD_RESP=$(curl -s -X POST http://localhost:8188/upload/image \
    -F "image=@/tmp/warmup_input.png" \
    -F "overwrite=true")
  local WARMUP_FILENAME
  WARMUP_FILENAME=$(echo "$UPLOAD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")

  if [ -z "$WARMUP_FILENAME" ]; then
    echo "  Failed to upload warmup image"
    return 1
  fi
  echo "  Uploaded warmup image: $WARMUP_FILENAME"

  # Build warmup workflow: use template but with dummy image, minimal prompt, 1 step
  python3 -c "
import json
with open('/tmp/comfyui-workflow-api.json') as f:
    wf = json.load(f)
wf['71']['inputs']['image'] = '${WARMUP_FILENAME}'
wf['111:6']['inputs']['text'] = 'warmup test'
wf['111:3']['inputs']['steps'] = 1
wf['111:3']['inputs']['seed'] = 1
print(json.dumps({'prompt': wf, 'client_id': 'warmup'}))
" > /tmp/warmup-payload.json

  # Submit warmup workflow
  local PROMPT_RESP
  PROMPT_RESP=$(curl -s -X POST http://localhost:8188/prompt \
    -H "Content-Type: application/json" \
    -d @/tmp/warmup-payload.json)
  local PROMPT_ID
  PROMPT_ID=$(echo "$PROMPT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt_id',''))")

  if [ -z "$PROMPT_ID" ]; then
    echo "  Failed to submit warmup workflow"
    echo "  Response: $PROMPT_RESP"
    return 1
  fi
  echo "  Submitted warmup workflow: $PROMPT_ID"

  # Poll for completion
  local WARMUP_TIMEOUT=120
  local WARMUP_POLL=3
  local WARMUP_ELAPSED=0

  while [ "$WARMUP_ELAPSED" -lt "$WARMUP_TIMEOUT" ]; do
    local HISTORY
    HISTORY=$(curl -s "http://localhost:8188/history/${PROMPT_ID}" 2>/dev/null || echo "{}")
    local STATUS
    STATUS=$(echo "$HISTORY" | python3 -c "
import sys, json
h = json.load(sys.stdin)
entry = h.get('${PROMPT_ID}', {})
status = entry.get('status', {})
if status.get('status_str') == 'error':
    print('error')
elif entry.get('outputs', {}).get('60', {}).get('images'):
    print('done')
else:
    print('pending')
" 2>/dev/null || echo "pending")

    if [ "$STATUS" = "done" ]; then
      local WARMUP_END
      WARMUP_END=$(date +%s)
      echo "  Models loaded and warm! (${WARMUP_ELAPSED}s, total warmup: $((WARMUP_END - WARMUP_START))s)"
      return 0
    elif [ "$STATUS" = "error" ]; then
      echo "  Warmup workflow failed on ComfyUI server"
      return 1
    fi

    sleep "$WARMUP_POLL"
    WARMUP_ELAPSED=$((WARMUP_ELAPSED + WARMUP_POLL))
  done

  echo "  Warmup timed out after ${WARMUP_TIMEOUT}s"
  return 1
}

echo ""
echo "==> Warming up models (loading into VRAM)..."
warmup_models || echo "WARNING: Model warmup failed (non-fatal). First request will load models on demand."

echo ""
echo "Setup complete!"
exit 0
