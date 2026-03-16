#!/bin/bash
# Run this ON the RunPod pod (via SSH) to set up ComfyUI with models from the network volume.
# Usage: Copy this script to the pod and run it, OR paste the commands manually.
#
# For EU volume (eu-nl-1): models are in /workspace/madapps/
# For US volume (us-ga-2): models are in /workspace/ComfyUI/models/

set -euo pipefail

# Auto-detect region based on which directory exists
if [ -d "/workspace/madapps" ]; then
  MODEL_BASE="/workspace/madapps/ComfyUI/models"
  echo "Detected EU volume (madapps)"
elif [ -d "/workspace/ComfyUI/models" ] && [ ! -L "/workspace/ComfyUI/models" ]; then
  MODEL_BASE="/workspace/ComfyUI/models"
  echo "Detected US volume"
else
  echo "Warning: Could not auto-detect model path. Defaulting to EU volume."
  MODEL_BASE="/workspace/madapps/ComfyUI/models"
fi

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"

echo ""
echo "==> Symlinking models from network volume..."

# Diffusion model
ln -sf "${MODEL_BASE}/diffusion_models/qwen_image_fp8_e4m3fn.safetensors" \
  "${COMFYUI_DIR}/models/diffusion_models/"
echo "  ✓ qwen_image_fp8_e4m3fn.safetensors"

# Text encoder
ln -sf "${MODEL_BASE}/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
  "${COMFYUI_DIR}/models/text_encoders/"
echo "  ✓ qwen_2.5_vl_7b_fp8_scaled.safetensors"

# VAE
ln -sf "${MODEL_BASE}/vae/qwen_image_vae.safetensors" \
  "${COMFYUI_DIR}/models/vae/"
echo "  ✓ qwen_image_vae.safetensors"

# ControlNet
ln -sf "${MODEL_BASE}/controlnet/Qwen-Image-InstantX-ControlNet-Union.safetensors" \
  "${COMFYUI_DIR}/models/controlnet/"
echo "  ✓ Qwen-Image-InstantX-ControlNet-Union.safetensors"

# Lightning LoRA (check if already present)
if [ -f "${COMFYUI_DIR}/models/loras/Qwen-Image-Lightning-8steps-V2.0.safetensors" ]; then
  echo "  ✓ Lightning LoRA already present"
else
  if [ -f "${MODEL_BASE}/loras/Qwen-Image-Lightning-8steps-V2.0.safetensors" ]; then
    ln -sf "${MODEL_BASE}/loras/Qwen-Image-Lightning-8steps-V2.0.safetensors" \
      "${COMFYUI_DIR}/models/loras/"
    echo "  ✓ Qwen-Image-Lightning-8steps-V2.0.safetensors (symlinked)"
  else
    echo "  ⚠ Lightning LoRA not found in network volume — check manually"
  fi
fi

echo ""
echo "==> Installing custom node dependencies..."
cd "${COMFYUI_DIR}/custom_nodes/comfyui_controlnet_aux"
"${COMFYUI_DIR}/.venv/bin/pip" install -r requirements.txt

echo ""
echo "==> Restarting ComfyUI..."
pkill -f "python.*main.py" || true
sleep 2
cd "${COMFYUI_DIR}"
source .venv/bin/activate
nohup python main.py --listen 0.0.0.0 --port 8188 > /workspace/runpod-slim/comfyui.log 2>&1 &

echo ""
echo "==> Waiting for ComfyUI to start..."
for i in $(seq 1 30); do
  if curl -s -o /dev/null -w "" http://localhost:8188/system_stats 2>/dev/null; then
    echo "ComfyUI is running on port 8188!"
    echo ""
    curl -s http://localhost:8188/system_stats | python -m json.tool 2>/dev/null || true
    echo ""
    echo "Setup complete!"
    exit 0
  fi
  sleep 2
done

echo "ComfyUI may still be loading models. Check logs:"
echo "  tail -f /workspace/runpod-slim/comfyui.log"
