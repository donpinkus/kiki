"""FLUX.2-klein server configuration."""

import os

# Server
HOST = os.getenv("FLUX_HOST", "0.0.0.0")
PORT = int(os.getenv("FLUX_PORT", "8766"))

# Model
MODEL_ID = os.getenv("FLUX_MODEL", "black-forest-labs/FLUX.2-klein-4B")

# Pipeline defaults
MODE = os.getenv("FLUX_MODE", "reference")  # "reference" or "denoise"
STEPS = int(os.getenv("FLUX_STEPS", "4"))
# Denoise mode gets its own step count because the 4-step klein distillation
# falls apart when you try to run fewer than 4 steps on a partially-noised
# latent (distilled models assume a specific full trajectory). 8 steps gives
# the model finer-grained movement per step to recover from the off-trajectory
# start, at the cost of more transformer forwards.
DENOISE_STEPS = int(os.getenv("FLUX_DENOISE_STEPS", "8"))
GUIDANCE_SCALE = float(os.getenv("FLUX_GUIDANCE_SCALE", "4.0"))
DENOISE_STRENGTH = float(os.getenv("FLUX_DENOISE", "0.6"))

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
