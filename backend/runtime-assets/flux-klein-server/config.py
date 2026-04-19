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

# ── LTXV 2B 0.9.8 distilled (image-to-video) ──────────────────────────────
# Runs whenever the img2img input buffer is empty and we have a last-generated
# still to animate. Resolution and frame count are set for speed, not quality:
# the SLA is <5s from "user stopped drawing" to first playback.
#
# The 2B transformer is loaded from a single-file checkpoint in the main
# Lightricks/LTX-Video repo; VAE, text encoder, and scheduler come from the
# Lightricks/LTX-Video-0.9.5 repo (same 2B architecture). Weights are stored
# in FP8 (float8_e4m3fn) via enable_layerwise_casting for lower VRAM + faster
# inference on Blackwell tensor cores; compute stays in BF16.
ENABLE_VIDEO = os.getenv("KIKI_ENABLE_VIDEO", "1") == "1"
# Repo that holds VAE, text encoder, scheduler (2B architecture).
LTXV_BASE_REPO = os.getenv("LTXV_BASE_REPO", "Lightricks/LTX-Video-0.9.5")
# Single-file transformer checkpoint from the main Lightricks/LTX-Video repo.
LTXV_TRANSFORMER_REPO = os.getenv("LTXV_TRANSFORMER_REPO", "Lightricks/LTX-Video")
LTXV_TRANSFORMER_FILE = os.getenv("LTXV_TRANSFORMER_FILE", "ltxv-2b-0.9.8-distilled-fp8.safetensors")
LTXV_WIDTH = int(os.getenv("LTXV_WIDTH", "512"))
LTXV_HEIGHT = int(os.getenv("LTXV_HEIGHT", "512"))
LTXV_NUM_FRAMES = int(os.getenv("LTXV_NUM_FRAMES", "25"))   # ~1s at 24fps
# Distilled 8-step schedule (normalized timesteps × 1000).
LTXV_TIMESTEPS = [1000, 993, 987, 981, 975, 909, 725]
LTXV_GUIDANCE = float(os.getenv("LTXV_GUIDANCE", "1.0"))
LTXV_FPS = int(os.getenv("LTXV_FPS", "24"))
LTXV_DTYPE = os.getenv("LTXV_DTYPE", "bfloat16")
LTXV_OUTPUT_CRF = int(os.getenv("LTXV_CRF", "28"))           # MP4 quality knob
