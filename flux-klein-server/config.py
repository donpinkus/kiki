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

# ─── LTX-2.3 (video pod) ────────────────────────────────────────────────────
# The video pod runs LTX-2.3 22B distilled FP8 via Lightricks' official
# `ltx-pipelines.DistilledPipeline`. Two-stage: stage 1 generates at half
# resolution, stage 2 upscales (via spatial upscaler) and refines at full.
# All assets are pre-populated on per-DC video volumes at /workspace/huggingface
# so the pod can run fully offline (HF_HUB_OFFLINE=1).
#
# License note: LTX-2 weights are released under the LTX-2 Community License
# Agreement (https://github.com/Lightricks/LTX-2/blob/main/LICENSE), NOT
# Apache-2.0. The license restricts commercial use for entities with
# >=$10M annual revenue. Verify license terms before any commercial
# deployment (App Store / TestFlight rollout).
LTX_MODEL_FAMILY = "LTX-2.3"
LTX_MODEL_REPO = os.getenv("LTX_MODEL_REPO", "Lightricks/LTX-2.3-fp8")
LTX_MODEL_FILE = os.getenv("LTX_MODEL_FILE", "ltx-2.3-22b-distilled-fp8.safetensors")

# Spatial upscaler is REQUIRED by DistilledPipeline (stage 2 upscales by 2x
# from the half-res stage 1 latent). Lives in the base LTX-2.3 repo.
LTX_SPATIAL_UPSCALER_REPO = os.getenv("LTX_SPATIAL_UPSCALER_REPO", "Lightricks/LTX-2.3")
LTX_SPATIAL_UPSCALER_FILE = os.getenv(
    "LTX_SPATIAL_UPSCALER_FILE", "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
)

# Gemma-3-12B is LTX-2.3's text encoder (replaces T5 from LTXV 0.9.x). Gated
# by Google's Gemma terms — populate must run with HF_TOKEN that has
# accepted the license. Pod runtime stays offline.
LTX_TEXT_ENCODER_REPO = os.getenv(
    "LTX_TEXT_ENCODER_REPO", "google/gemma-3-12b-it-qat-q4_0-unquantized"
)

# Inference parameters. DistilledPipeline runs 8 sigmas in stage 1 + 4 in
# stage 2 = 12 effective denoising steps; LTX_INFERENCE_STEPS is informational
# (the pipeline owns the actual step count via its predefined sigmas).
LTX_INFERENCE_STEPS = 8
LTX_CFG_SCALE = 1.0
LTX_QUANTIZATION = "fp8"

# Resolution + frame-count constraints (enforced by ltx-pipelines.utils.helpers
# .assert_resolution at __call__ time). We validate at config load too so
# misconfig surfaces at pod boot, not first inference.
#
# DistilledPipeline is two-stage: stage 1 generates at half resolution, stage 2
# upsamples by 2x. ltx-pipelines requires full resolution divisible by 64
# (so half-res is divisible by 32). LTXV 0.9.x only required %32; the
# tighter %64 rule was a 2.3 regression that bit us in 2026-04-28's first
# end-to-end test.
#
# 320x320 squares the aspect (matches FLUX 1:1 output, no pillarboxing in
# the iPad's square pane) and keeps activation memory low: 22B FP8 + Gemma
# + fp8_cast's transient bf16 upcast buffers OOMed H100 80GB at 512x512
# (78 GiB allocated). ltx-pipelines forbids combining OffloadMode.CPU
# with quantization, so the only knob to reduce VRAM pressure is making
# activations smaller. 320 = 5x64 satisfies the two-stage divisor.
# Upscale to 768 happens iPad-side via AVPlayerLayer's resizeAspect.
LTX_WIDTH = int(os.getenv("LTX_WIDTH", "320"))
LTX_HEIGHT = int(os.getenv("LTX_HEIGHT", "320"))
LTX_NUM_FRAMES = int(os.getenv("LTX_NUM_FRAMES", "49"))
LTX_FPS = int(os.getenv("LTX_FPS", "24"))
LTX_OUTPUT_JPEG_QUALITY = int(os.getenv("LTX_OUTPUT_QUALITY", "80"))

if LTX_WIDTH % 64 != 0:
    raise ValueError(
        f"LTX_WIDTH must be divisible by 64 (got {LTX_WIDTH}) — DistilledPipeline two-stage rule"
    )
if LTX_HEIGHT % 64 != 0:
    raise ValueError(
        f"LTX_HEIGHT must be divisible by 64 (got {LTX_HEIGHT}) — DistilledPipeline two-stage rule"
    )
if (LTX_NUM_FRAMES - 1) % 8 != 0:
    raise ValueError(
        f"LTX_NUM_FRAMES must satisfy (n - 1) % 8 == 0 — valid: 9, 17, 25, 33, 41, 49, … "
        f"(got {LTX_NUM_FRAMES})"
    )

# Toggle for verbose per-step logging in the video pipeline. Off by default.
LTX_DEBUG = os.getenv("LTX_DEBUG", "0") == "1"
