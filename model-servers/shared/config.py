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

# Pipeline variant: `base` (Flux2KleinPipeline) or `kv` (Flux2KleinKVPipeline —
# reference-token K/V cached across denoising steps, ~30% faster/frame). `kv`
# REQUIRES a KV-trained checkpoint (set FLUX_MODEL=black-forest-labs/
# FLUX.2-klein-9b-kv); on standard klein weights it destroys sketch adherence.
# Every generated frame still conditions on the CURRENT sketch (per-call
# extract) — no cross-frame staleness by construction.
PIPELINE_VARIANT = os.getenv("FLUX_PIPELINE", "base")

# torch.compile the transformer at load (measured 1.2-1.25x per-frame on H100 BF16,
# pixel-identical output; ~80-90s one-time compile absorbed into warmup). Off by
# default; set FLUX_COMPILE=1 on Lambda serving instances (boot.sh).
USE_COMPILE = os.getenv("FLUX_COMPILE", "0") == "1"

# ─── LTX-2.5 (video server — dedicated Lambda H100) ─────────────────────────
# Upgraded 2026-09-10 from LTX-2.3 (see documents/decisions.md). The video
# server runs LTX-2.5 22B distilled via Lightricks' official `ltx-pipelines`
# (DistilledPipeline, or DFRPipeline for the production-quality "Diffusion
# Fidelity Rendering" path — same distilled transformer + a detailing IC-LoRA
# + generated keyframe slots + a full-res spatial detailing pass).
#
# 2.5 ships as ONE FILE PER COMPONENT (Comfy-aligned split layout) on the
# Lightricks/LTX-2.5 HF repo, and the Gemma 4 12B text encoder is BUNDLED
# (config + tokenizer embedded in the safetensors) — no separate gated Google
# download any more. The repo itself is HF "auto-gated": the downloading
# account must have clicked through the LTX-2.x Community License once.
# All assets are pre-populated on the per-region `kiki-video-<region>` NFS
# filesystem (HF_HOME points there; server runs HF_HUB_OFFLINE=1).
#
# License note: LTX-2.x weights are released under the LTX-2.x Community
# License (https://github.com/Lightricks/LTX-2/blob/main/LICENSE), NOT
# Apache-2.0. Free commercial use under $10M annual revenue. Verify before
# any App Store rollout.
LTX_MODEL_FAMILY = "LTX-2.5"
LTX_MODEL_REPO = os.getenv("LTX_MODEL_REPO", "Lightricks/LTX-2.5")
# Distilled transformer, BF16. FP8 is applied at load by QuantizationPolicy
# .fp8_cast() (downcast BF16 → FP8 storage, upcast per matmul) — Lightricks
# ships no FP8 checkpoint for 2.5. fp8_scaled_mm expects an FP8 checkpoint
# with per-tensor scales and is therefore NOT usable with this file (the 2.3
# era hit exactly that mismatch: random-noise output).
LTX_MODEL_FILE = os.getenv(
    "LTX_MODEL_FILE", "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
)
# Gemma 4 12B fine-tuned for LTX, with the text projection bundled in.
LTX_TEXT_ENCODER_FILE = os.getenv(
    "LTX_TEXT_ENCODER_FILE", "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
)
# Video VAE: `diff` = the diffusion decoder (NADiffusionDecoder), `conv` =
# the convolutional decoder. Speed work 2026-09-12 (decisions.md): under DFR
# the diffusion decoder runs keyframe-anchored, eager, and uncompiled by
# upstream design, and it was two thirds of every clip's wall time (6.4 s of
# 12.8 s for 4 s, 13.7 s of 21.5 s for 6 s at 768²). The conv decoder takes
# 1.0 s / 1.5 s for the same latents; same-seed frames compare as slightly
# crisper with a touch more edge aliasing. Default is therefore `conv`;
# `diff` remains a one-env rollback (with `LTX_DFR_PLAIN_DECODE=1` +
# natten it lands in between: 4.5 s / 8.9 s decode).
LTX_VIDEO_VAE = os.getenv("LTX_VIDEO_VAE", "conv").lower()
LTX_VIDEO_VAE_FILE = os.getenv(
    "LTX_VIDEO_VAE_FILE",
    "vae/ltx-2.5-video-vae-bf16.safetensors"
    if LTX_VIDEO_VAE == "diff"
    else "vae/ltx-2.5-video-vae-conv-bf16.safetensors",
)
LTX_AUDIO_VAE_FILE = os.getenv("LTX_AUDIO_VAE_FILE", "vae/ltx-2.5-audio-vae-bf16.safetensors")
# Spatial upscaler is REQUIRED by both pipelines (stage 2 upscales by 2x
# from the half-res stage 1 latent).
LTX_SPATIAL_UPSCALER_REPO = os.getenv("LTX_SPATIAL_UPSCALER_REPO", LTX_MODEL_REPO)
LTX_SPATIAL_UPSCALER_FILE = os.getenv(
    "LTX_SPATIAL_UPSCALER_FILE",
    "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors",
)
# DFR's detailing IC-LoRA lives in its own (also auto-gated) repo.
LTX_DETAILING_LORA_REPO = os.getenv(
    "LTX_DETAILING_LORA_REPO", "Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler"
)
LTX_DETAILING_LORA_FILE = os.getenv(
    "LTX_DETAILING_LORA_FILE", "ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors"
)
# Pipeline: `distilled` (fastest: 8 sigmas stage 1 + 3 stage 2) or `dfr`
# (production quality: same transformer + generated keyframe slots + IC-LoRA
# spatial detailing; slower, more VRAM). H100 SXM bench 2026-09-10, 97 frames
# (4 s), FP8-cast, DiffVAE decoder, steady state:
#   distilled 512² 6.1 s / 768² 9.4 s / 1024² 16 s  (peak 56 / 60 / 61 GiB)
#   dfr       512² 7.1 s / 768² 12.9 s / 1024² 30 s (peak 66 / 67 / 69 GiB)
#   dfr 768² × 145 frames (6 s preset): 29.6 s, peak 68.9 GiB
#   dfr 1024² × 145 frames: FAILS — DiffVAE keyframe-decode can't fit a tile
#   under the memory budget on 80 GB. 1024² is fine for ≤97 frames only.
# Default = dfr at 768²: Lightricks' production path, 1.5× the old 512²
# output, every duration preset fits with ~11 GiB headroom.
# 2026-09-12 speed pass (torch.compile + conv VAE, see below): dfr 768² =
# 5.8 s (97 f) / 8.4 s (145 f); dfr 1024² conv = 9.4 s / 15.2 s (peak
# 70.5 GiB — now fits the 6 s preset) if sharper output is worth the wait.
LTX_PIPELINE = os.getenv("LTX_PIPELINE", "dfr").lower()
if LTX_PIPELINE not in ("distilled", "dfr"):
    raise ValueError(f"LTX_PIPELINE must be 'distilled' or 'dfr' (got {LTX_PIPELINE!r})")
# DiffVAE decode preset (ignored for the conv VAE): chunked_eager (no
# compile, ~½ peak VRAM of combined), chunked_compile, combined_compile.
# NOTE: DFR's final decode is keyframe-anchored, which upstream runs eager
# regardless of this mode — it only matters for distilled / plain decodes.
LTX_DIFFVAE_MODE = os.getenv("LTX_DIFFVAE_MODE", "chunked_eager").lower()
# torch.compile the transformer blocks (inductor, shape-polymorphic; no CUDA
# graphs). Measured 2026-09-12 on H100: denoise 6.4 → 4.8 s (97 f) and
# 9.2 → 6.9 s (145 f) at DFR 768²; paid once at warmup (~+100 s boot, every
# preset shape warmed via LTX_WARMUP_FRAMES). Default on.
LTX_TORCH_COMPILE = os.getenv("LTX_TORCH_COMPILE", "1") == "1"
# DFR experiment: decode the final latent WITHOUT keyframe anchoring (plain,
# compilable decode). Trades DFR's decode anchoring for speed.
LTX_DFR_PLAIN_DECODE = os.getenv("LTX_DFR_PLAIN_DECODE", "0") == "1"
# Frame counts warmed at boot (csv). Defaults to every Animate preset (2/4/6 s
# at 24 fps) so no user request is the first at its shape.
LTX_WARMUP_FRAMES = [
    int(x) for x in os.getenv("LTX_WARMUP_FRAMES", "145,97,49").split(",") if x.strip()
]

# Inference parameters. DistilledPipeline runs 8 sigmas in stage 1 + 3 in
# stage 2; LTX_INFERENCE_STEPS is informational (the pipeline owns the actual
# step count via its predefined sigmas).
LTX_INFERENCE_STEPS = 8
LTX_CFG_SCALE = 1.0
LTX_QUANTIZATION = "fp8"

# Resolution + frame-count constraints (enforced by ltx-pipelines.utils.helpers
# .assert_resolution at __call__ time). We validate at config load too so
# misconfig surfaces at server boot, not first inference.
#
# Both pipelines are two-stage: stage 1 generates at half resolution, stage 2
# upsamples by 2x. ltx-pipelines requires full resolution divisible by 64
# (so half-res is divisible by 32).
#
# Square output matches FLUX 1:1 output (no pillarboxing in the iPad's square
# pane). Upscale to display size happens iPad-side via AVPlayerLayer's
# resizeAspect. The default here is the H100-benchmarked pick (2026-09-10).
LTX_WIDTH = int(os.getenv("LTX_WIDTH", "768"))
LTX_HEIGHT = int(os.getenv("LTX_HEIGHT", "768"))
LTX_NUM_FRAMES = int(os.getenv("LTX_NUM_FRAMES", "145"))
LTX_FPS = int(os.getenv("LTX_FPS", "24"))
LTX_OUTPUT_JPEG_QUALITY = int(os.getenv("LTX_OUTPUT_QUALITY", "80"))
# LTX generates audio latents during the same denoising pass as video. This
# flag controls only the decoder + AAC mux path, so it is a fast rollback if
# audio decode or encode adds unacceptable tail latency.
LTX_ENABLE_AUDIO = os.getenv("LTX_ENABLE_AUDIO", "1") == "1"

if LTX_WIDTH % 64 != 0:
    raise ValueError(
        f"LTX_WIDTH must be divisible by 64 (got {LTX_WIDTH}) — two-stage pipeline rule"
    )
if LTX_HEIGHT % 64 != 0:
    raise ValueError(
        f"LTX_HEIGHT must be divisible by 64 (got {LTX_HEIGHT}) — two-stage pipeline rule"
    )
if (LTX_NUM_FRAMES - 1) % 8 != 0:
    raise ValueError(
        f"LTX_NUM_FRAMES must satisfy (n - 1) % 8 == 0 — valid: 9, 17, 25, 33, 41, 49, … "
        f"(got {LTX_NUM_FRAMES})"
    )

# Toggle for verbose per-step logging in the video pipeline. Off by default.
LTX_DEBUG = os.getenv("LTX_DEBUG", "0") == "1"
