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
for i in $(seq 1 30); do
  if curl -s -o /dev/null -w "" http://localhost:8188/system_stats 2>/dev/null; then
    echo "ComfyUI is running on port 8188!"
    echo ""
    curl -s http://localhost:8188/system_stats | python3 -m json.tool 2>/dev/null || true
    echo ""
    echo "Setup complete!"
    exit 0
  fi
  sleep 2
done

echo "ERROR: ComfyUI did not start within 60s. Last log lines:"
tail -20 /workspace/runpod-slim/comfyui.log 2>/dev/null || true
exit 1
