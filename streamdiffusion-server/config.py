"""StreamDiffusion server configuration."""

import os

# Server
HOST = os.getenv("SD_HOST", "0.0.0.0")
PORT = int(os.getenv("SD_PORT", "8765"))

# Model
BASE_MODEL = os.getenv("SD_BASE_MODEL", "Lykon/dreamshaper-8")
LCM_LORA = os.getenv("SD_LCM_LORA", "latent-consistency/lcm-lora-sdv1-5")

# Pipeline
# t_index_list controls which scheduler timesteps to use for denoising.
# Higher indices = more noise added to input = more transformation by the model.
# [0,1,2,3] = barely any noise (output ≈ input, prompt ignored)
# [32,45] = standard img2img setting from StreamDiffusion examples
T_INDEX_LIST_STR = os.getenv("SD_T_INDEX_LIST", "20,30")
T_INDEX_LIST = [int(x) for x in T_INDEX_LIST_STR.split(",")]
DEFAULT_WIDTH = int(os.getenv("SD_DEFAULT_WIDTH", "512"))
DEFAULT_HEIGHT = int(os.getenv("SD_DEFAULT_HEIGHT", "512"))
DEFAULT_PROMPT = os.getenv("SD_DEFAULT_PROMPT", "")
GUIDANCE_SCALE = float(os.getenv("SD_GUIDANCE_SCALE", "1.0"))  # LCM works best with low/no guidance

# Acceleration: "tensorrt" or "xformers"
ACCELERATION = os.getenv("SD_ACCELERATION", "xformers")

# Similarity filter: skip frames with minimal change
ENABLE_SIMILARITY_FILTER = os.getenv("SD_SIMILARITY_FILTER", "true").lower() == "true"
SIMILARITY_THRESHOLD = float(os.getenv("SD_SIMILARITY_THRESHOLD", "0.98"))

# Output JPEG quality (0-100)
OUTPUT_JPEG_QUALITY = int(os.getenv("SD_OUTPUT_JPEG_QUALITY", "85"))
