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

# ─── LTXV (video pod) ───────────────────────────────────────────────────────
# The video pod runs LTXImageToVideoPipeline with the 0.9.8 distilled
# transformer overwritten on top of the 0.9.5 base (VAE / text encoder /
# scheduler come from base). Must match the populate-volume.ts download
# constants so the pod can run fully offline.
LTXV_BASE_REPO = os.getenv("LTXV_BASE_REPO", "Lightricks/LTX-Video-0.9.5")
LTXV_TRANSFORMER_REPO = os.getenv("LTXV_TRANSFORMER_REPO", "Lightricks/LTX-Video")
LTXV_TRANSFORMER_FILE = os.getenv(
    "LTXV_TRANSFORMER_FILE", "ltxv-2b-0.9.8-distilled-fp8.safetensors"
)
# Generation parameters. Defaults sized for ~2 s video at 24 fps with
# headroom for sub-3 s end-to-end on a 5090: keeps the right pane
# responsive when the user resumes drawing.
LTXV_WIDTH = int(os.getenv("LTXV_WIDTH", "704"))
LTXV_HEIGHT = int(os.getenv("LTXV_HEIGHT", "480"))
LTXV_NUM_FRAMES = int(os.getenv("LTXV_NUM_FRAMES", "49"))
LTXV_STEPS = int(os.getenv("LTXV_STEPS", "8"))
LTXV_FPS = int(os.getenv("LTXV_FPS", "24"))
LTXV_OUTPUT_JPEG_QUALITY = int(os.getenv("LTXV_OUTPUT_QUALITY", "80"))
# Negative prompt — slight quality bump per LTX docs.
LTXV_NEGATIVE_PROMPT = os.getenv(
    "LTXV_NEGATIVE_PROMPT",
    "worst quality, inconsistent motion, blurry, jittery, distorted",
)
# Toggle for verbose per-step logging in the video pipeline. Off by default.
LTXV_DEBUG = os.getenv("LTXV_DEBUG", "0") == "1"
