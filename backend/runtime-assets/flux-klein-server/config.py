"""FLUX.2-klein server configuration."""

import os

# Server
HOST = os.getenv("FLUX_HOST", "0.0.0.0")
PORT = int(os.getenv("FLUX_PORT", "8766"))

# Model
MODEL_ID = os.getenv("FLUX_MODEL", "black-forest-labs/FLUX.2-klein-4B")

# Pipeline defaults — reference mode only. klein is step-wise distilled and
# ignores guidance_scale; denoise mode proved architecturally incompatible
# with the distilled trajectory.
STEPS = int(os.getenv("FLUX_STEPS", "4"))

# Resolution
DEFAULT_WIDTH = int(os.getenv("FLUX_WIDTH", "768"))
DEFAULT_HEIGHT = int(os.getenv("FLUX_HEIGHT", "768"))

# Output
OUTPUT_JPEG_QUALITY = int(os.getenv("FLUX_OUTPUT_QUALITY", "85"))

# Torch
DTYPE = os.getenv("FLUX_DTYPE", "bfloat16")  # "bfloat16" or "float16"

# Quantization — load BFL's NVFP4 transformer weights on top of the BF16 pipeline.
# Requires Blackwell GPU (RTX 5090 / RTX PRO 6000 / B200) + PyTorch 2.9 + CUDA 13.
# If the GPU isn't Blackwell or the load fails, pipeline falls back to BF16 with a logged warning.
USE_NVFP4 = os.getenv("FLUX_USE_NVFP4", "1") == "1"
NVFP4_REPO = os.getenv("FLUX_NVFP4_REPO", "black-forest-labs/FLUX.2-klein-4b-nvfp4")
NVFP4_FILENAME = os.getenv("FLUX_NVFP4_FILENAME", "flux-2-klein-4b-nvfp4.safetensors")

# ── LTXV 2B distilled (image-to-video) ────────────────────────────────────
# Runs whenever the img2img input buffer is empty and we have a last-generated
# still to animate. Resolution and frame count are set for speed, not quality:
# the SLA is <5s from "user stopped drawing" to first playback.
ENABLE_VIDEO = os.getenv("KIKI_ENABLE_VIDEO", "1") == "1"
LTXV_MODEL_ID = os.getenv("LTXV_MODEL", "Lightricks/LTX-Video-2B-v0.9.1-distilled")
LTXV_WIDTH = int(os.getenv("LTXV_WIDTH", "512"))
LTXV_HEIGHT = int(os.getenv("LTXV_HEIGHT", "512"))
LTXV_NUM_FRAMES = int(os.getenv("LTXV_NUM_FRAMES", "25"))   # ~1s at 24fps
LTXV_STEPS = int(os.getenv("LTXV_STEPS", "8"))              # distilled = fewer steps
LTXV_GUIDANCE = float(os.getenv("LTXV_GUIDANCE", "1.0"))
LTXV_FPS = int(os.getenv("LTXV_FPS", "24"))
LTXV_DTYPE = os.getenv("LTXV_DTYPE", "bfloat16")
LTXV_OUTPUT_CRF = int(os.getenv("LTXV_CRF", "28"))           # MP4 quality knob
