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
GUIDANCE_SCALE = float(os.getenv("FLUX_GUIDANCE_SCALE", "4.0"))
DENOISE_STRENGTH = float(os.getenv("FLUX_DENOISE", "0.6"))

# Resolution
DEFAULT_WIDTH = int(os.getenv("FLUX_WIDTH", "768"))
DEFAULT_HEIGHT = int(os.getenv("FLUX_HEIGHT", "768"))

# Output
OUTPUT_JPEG_QUALITY = int(os.getenv("FLUX_OUTPUT_QUALITY", "85"))

# Torch
DTYPE = os.getenv("FLUX_DTYPE", "bfloat16")  # "bfloat16" or "float16"
