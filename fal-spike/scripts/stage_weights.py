"""Pre-stage FLUX.2-klein weights onto fal's /data volume — SPIKE.

fal auto-points HF_HOME at /data/.cache/huggingface and /data persists across
runners + deploys. Downloading the weights once into that cache means the image
app's setup() reads them off the NVMe volume instead of re-pulling from the Hub
on every cold start (the /data analog of our pre-populated RunPod network volumes).

This runs as a @fal.function (a throwaway runner that writes to the shared /data),
NOT as part of the serving app. Run it once before the first `fal deploy`, and
again whenever you change which quant checkpoint you're testing.

Usage:
    # base BF16 pipeline + NVFP4 overlay (default, for the RTX5090 path)
    fal run fal-spike/scripts/stage_weights.py::stage

    # stage the FP8 (H100) or INT8 (A100) variants instead/as well
    FLUX_STAGE_QUANT=fp8  fal run fal-spike/scripts/stage_weights.py::stage
    FLUX_STAGE_QUANT=int8 fal run fal-spike/scripts/stage_weights.py::stage

Requires FAL_KEY in env. If a checkpoint repo is gated/private, also set HF_TOKEN
(forwarded into the function env below).
"""

from __future__ import annotations

import os

import fal

# Same identifiers as generation.py. Duplicated deliberately (isolation rule) —
# if you change a repo in generation.py, change it here too.
MODEL_ID = os.getenv("FLUX_MODEL", "black-forest-labs/FLUX.2-klein-4B")
NVFP4_REPO = os.getenv("FLUX_NVFP4_REPO", "black-forest-labs/FLUX.2-klein-4b-nvfp4")
NVFP4_FILENAME = os.getenv("FLUX_NVFP4_FILENAME", "flux-2-klein-4b-nvfp4.safetensors")
FP8_REPO = os.getenv("FLUX_FP8_REPO", "Photoroom/FLUX.2-klein-4b-fp8-diffusers")
INT8_REPO = os.getenv("FLUX_INT8_REPO", "vistralis/FLUX.2-klein-base-4b-INT8-transformer")

# Which overlay checkpoint(s) to stage alongside the BF16 base.
STAGE_QUANT = os.getenv("FLUX_STAGE_QUANT", "nvfp4").strip().lower()


@fal.function(
    machine_type="GPU-RTX5090",   # any GPU runner mounts the same /data; SKU irrelevant for download
    requirements=["huggingface-hub>=0.25.0", "hf-transfer>=0.1.6"],
)
def stage() -> dict:
    """Download base + chosen quant into /data's HF cache. Idempotent (HF skips
    files already present), so re-running is cheap."""
    # hf-transfer parallelizes the multi-GB pulls off the Hub.
    os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

    from huggingface_hub import hf_hub_download, snapshot_download

    hf_home = os.environ.get("HF_HOME", "(unset!)")
    staged: list[str] = []

    # Base BF16 pipeline — full snapshot (transformer/vae/text_encoder/etc).
    print(f"HF_HOME={hf_home}; downloading base {MODEL_ID} ...")
    base_path = snapshot_download(repo_id=MODEL_ID, allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model"])
    staged.append(f"base:{MODEL_ID}")

    if STAGE_QUANT == "nvfp4":
        print(f"downloading NVFP4 overlay {NVFP4_REPO}/{NVFP4_FILENAME} ...")
        hf_hub_download(repo_id=NVFP4_REPO, filename=NVFP4_FILENAME)
        staged.append(f"nvfp4:{NVFP4_REPO}")
    elif STAGE_QUANT == "fp8":
        print(f"downloading FP8 transformer repo {FP8_REPO} ...")
        snapshot_download(repo_id=FP8_REPO, allow_patterns=["*.json", "*.safetensors"])
        staged.append(f"fp8:{FP8_REPO}")
    elif STAGE_QUANT == "int8":
        print(f"downloading INT8 transformer repo {INT8_REPO} ...")
        snapshot_download(repo_id=INT8_REPO, allow_patterns=["*.json", "*.safetensors"])
        staged.append(f"int8:{INT8_REPO}")
    elif STAGE_QUANT == "bf16":
        pass  # base already covers it
    else:
        print(f"WARNING: unknown FLUX_STAGE_QUANT={STAGE_QUANT!r}; staged base only")

    result = {"hf_home": hf_home, "base_path": base_path, "staged": staged}
    print(f"DONE staging: {result}")
    return result


if __name__ == "__main__":
    print("Run with: fal run fal-spike/scripts/stage_weights.py::stage")
