"""FLUX.2-klein reference-mode img2img pipeline — fal-spike copy.

ISOLATION NOTE
==============
This file is a deliberate, self-contained COPY of the generation logic from
``model-servers/image/pipeline.py`` (+ the relevant constants from
``model-servers/shared/config.py``). It does NOT import from ``model-servers``.

Per the fal.ai spike plan, fal and RunPod code never share modules so that
deleting the fal experiment later is a clean ``rm -rf fal-spike/``. If you change
generation behavior in the RunPod server, port it here by hand (or vice-versa) —
do not introduce a shared import.

WHAT'S DIFFERENT FROM THE RUNPOD COPY
=====================================
The RunPod server only ever runs on Blackwell (RTX 5090) and loads BFL's NVFP4
transformer on top of the BF16 pipeline. On fal we don't control the GPU SKU as
tightly, so this copy picks the transformer-quantization variant from the GPU
architecture at load time:

    Blackwell (SM 10+, RTX 5090 / B200)   -> NVFP4   (same as RunPod today)
    Hopper / Ada (SM 8.9 / 9.0, H100/L40) -> FP8     (native fp8_e4m3)
    Ampere (SM 8.0, A100) or older        -> INT8 or plain BF16

The RunPod-side NFS page-cache prefetch dance is dropped here — fal's /data is an
NVMe-backed distributed volume with HF_HOME auto-pointed at it, so cold reads come
straight off /data without the prefetch lever. Measuring that cold-start is itself
one of the spike's goals.
"""

from __future__ import annotations

import logging
import os
import time

import torch
from PIL import Image

logger = logging.getLogger(__name__)

# ─── Config (inlined copy of the FLUX bits of shared/config.py) ──────────────
# BF16 base pipeline.
MODEL_ID = os.getenv("FLUX_MODEL", "black-forest-labs/FLUX.2-klein-4B")
STEPS = int(os.getenv("FLUX_STEPS", "4"))
WIDTH = int(os.getenv("FLUX_WIDTH", "768"))
HEIGHT = int(os.getenv("FLUX_HEIGHT", "768"))
OUTPUT_JPEG_QUALITY = int(os.getenv("FLUX_OUTPUT_QUALITY", "85"))
DTYPE = os.getenv("FLUX_DTYPE", "bfloat16")

# Transformer-overlay checkpoints by quantization. NVFP4 is BFL-official; the
# FP8/INT8 4B variants are community/partner conversions (BFL's official FP8 is
# the 9B). Verifying the FP8/INT8 4B source loads cleanly into Flux2KleinPipeline
# is the FIRST spike step — see fal-spike/README.md. Override via env to test
# alternatives without editing code.
NVFP4_REPO = os.getenv("FLUX_NVFP4_REPO", "black-forest-labs/FLUX.2-klein-4b-nvfp4")
NVFP4_FILENAME = os.getenv("FLUX_NVFP4_FILENAME", "flux-2-klein-4b-nvfp4.safetensors")

FP8_REPO = os.getenv("FLUX_FP8_REPO", "Photoroom/FLUX.2-klein-4b-fp8-diffusers")
FP8_FILENAME = os.getenv("FLUX_FP8_FILENAME", "")  # empty -> load the repo's default transformer

INT8_REPO = os.getenv("FLUX_INT8_REPO", "vistralis/FLUX.2-klein-base-4b-INT8-transformer")
INT8_FILENAME = os.getenv("FLUX_INT8_FILENAME", "")

# Force a specific quant for A/B testing: "nvfp4" | "fp8" | "int8" | "bf16".
# Empty -> auto-pick from GPU arch.
FORCE_QUANT = os.getenv("FLUX_FORCE_QUANT", "").strip().lower()


def _pick_quant_for_gpu() -> str:
    """Choose transformer quantization from the detected GPU architecture."""
    if FORCE_QUANT:
        return FORCE_QUANT
    if not torch.cuda.is_available():
        return "bf16"
    major, minor = torch.cuda.get_device_capability(0)
    if major >= 10:          # Blackwell: RTX 5090, B200
        return "nvfp4"
    if (major, minor) >= (8, 9):  # Ada (8.9) + Hopper (9.0): L40, H100 — native FP8
        return "fp8"
    if major == 8:           # Ampere: A100 — no native FP8
        return "int8"
    return "bf16"


class FluxKleinPipeline:
    """Wraps FLUX.2-klein for reference-mode img2img generation.

    The sketch is VAE-encoded and concatenated with generation latents via the
    pipeline's built-in ``image`` parameter — the transformer attends to both
    the sketch tokens and the generation tokens. This is the only img2img mode
    that produces usable output on klein (a 4-step distilled model); the
    distillation trajectory doesn't tolerate partial-denoise starts.
    """

    def __init__(self):
        self.pipe = None
        self._ready = False
        self._dtype = getattr(torch, DTYPE)
        self._quantization = "bf16"  # overwritten once the overlay succeeds
        self._timings: dict[str, int] = {}

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Load FLUX.2-klein, overlay the arch-appropriate quant, and warm up.

        Called from fal's App.setup() — runs once per runner. NOT thread-safe;
        call once before serving. PyTorch itself is not thread-safe, so the WS
        handler serializes generate calls.
        """
        t0 = time.time()
        target_quant = _pick_quant_for_gpu()
        gpu = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu"
        logger.info(
            f"Loading {MODEL_ID} on {gpu}; target quant={target_quant}",
            extra={"model_id": MODEL_ID, "gpu": gpu, "target_quant": target_quant},
        )

        from diffusers import Flux2KleinPipeline

        # device_map='cuda' places each tensor directly on GPU as it loads (no CPU
        # bounce). Falls back to the standard load + to('cuda') if the installed
        # diffusers rejects the kwarg.
        device_map_used = False
        t = time.time()
        try:
            self.pipe = Flux2KleinPipeline.from_pretrained(
                MODEL_ID,
                torch_dtype=self._dtype,
                low_cpu_mem_usage=True,
                device_map="cuda",
            )
            device_map_used = True
        except (TypeError, ValueError, NotImplementedError) as e:
            logger.warning(
                f"device_map='cuda' rejected ({type(e).__name__}: {e}); standard load",
                extra={"error_type": type(e).__name__},
            )
            self.pipe = Flux2KleinPipeline.from_pretrained(
                MODEL_ID, torch_dtype=self._dtype, low_cpu_mem_usage=True,
            )
        self._timings["from_pretrained_ms"] = int((time.time() - t) * 1000)

        # Overlay the quantized transformer (skip for bf16 / cpu).
        t = time.time()
        if target_quant == "nvfp4":
            self._overlay_transformer(NVFP4_REPO, NVFP4_FILENAME, "nvfp4", require_sm=10)
        elif target_quant == "fp8":
            self._overlay_transformer(FP8_REPO, FP8_FILENAME, "fp8", require_sm=None)
        elif target_quant == "int8":
            self._overlay_transformer(INT8_REPO, INT8_FILENAME, "int8", require_sm=None)
        else:
            logger.info("Staying on BF16 transformer (no overlay).")
        self._timings["overlay_ms"] = int((time.time() - t) * 1000)

        t = time.time()
        if not device_map_used and torch.cuda.is_available():
            self.pipe.to("cuda")
        self._timings["to_cuda_ms"] = int((time.time() - t) * 1000)

        # Warm up with a dummy txt2img so the first real frame isn't paying
        # kernel-autotune / cudnn-benchmark cost.
        t = time.time()
        gen = torch.Generator(device="cuda").manual_seed(0) if torch.cuda.is_available() else None
        _ = self.pipe(
            prompt="warmup",
            height=HEIGHT,
            width=WIDTH,
            num_inference_steps=STEPS,
            guidance_scale=1.0,
            generator=gen,
        )
        self._timings["warmup_ms"] = int((time.time() - t) * 1000)

        self._ready = True
        total_s = time.time() - t0
        logger.info(
            f"Pipeline ready in {total_s:.1f}s (quant={self._quantization}, "
            f"device_map={device_map_used}, timings={self._timings})",
            extra={
                "total_init_s": round(total_s, 1),
                "quantization": self._quantization,
                "device_map_used": device_map_used,
                "timings": self._timings,
            },
        )

    def generate_reference(
        self,
        image: Image.Image,
        prompt: str,
        steps: int = STEPS,
        seed: int | None = None,
    ) -> Image.Image:
        """Run reference-mode img2img generation.

        The sketch is passed as a conditioning image via the pipeline's ``image``
        parameter. Internally the model VAE-encodes it, patchifies the latents,
        and concatenates them with generation latents so the transformer attends
        to both. klein ignores guidance_scale (step-wise distilled); we pin it to
        1.0 to silence the per-frame diffusers warning.
        """
        generator = None
        if seed is not None and torch.cuda.is_available():
            generator = torch.Generator(device="cuda").manual_seed(seed)
        result = self.pipe(
            prompt=prompt,
            image=image,
            height=HEIGHT,
            width=WIDTH,
            num_inference_steps=steps,
            guidance_scale=1.0,
            generator=generator,
        )
        return result.images[0]

    def _overlay_transformer(
        self, repo: str, filename: str, label: str, require_sm: int | None
    ) -> None:
        """Overwrite transformer weights with a quantized checkpoint.

        Mirrors the RunPod NVFP4 overlay but generalized over quant variants. On
        SM mismatch (NVFP4 needs Blackwell SM 10+) or any load error, logs a
        warning and leaves the BF16 weights in place so the pipeline still runs —
        we'd rather serve BF16 than crash the runner during the spike.
        """
        if not torch.cuda.is_available():
            logger.warning(f"{label} requested but CUDA unavailable; staying on BF16")
            return
        if require_sm is not None:
            major, _ = torch.cuda.get_device_capability(0)
            if major < require_sm:
                logger.warning(
                    f"{label} requires SM {require_sm}+; detected SM {major}.x. Staying on BF16.",
                    extra={"sm_major": major, "quant": label},
                )
                return
        try:
            from huggingface_hub import hf_hub_download
            from safetensors.torch import load_file

            if filename:
                logger.info(
                    f"Loading {label} transformer from {repo} ({filename})",
                    extra={"repo": repo, "filename": filename, "quant": label},
                )
                path = hf_hub_download(repo_id=repo, filename=filename)
                try:
                    state_dict = load_file(path, device="cuda")
                except (TypeError, ValueError):
                    state_dict = load_file(path)
                missing, unexpected = self.pipe.transformer.load_state_dict(
                    state_dict, strict=False
                )
                logger.info(
                    f"{label} loaded (missing={len(missing)}, unexpected={len(unexpected)})",
                    extra={"missing": len(missing), "unexpected": len(unexpected), "quant": label},
                )
            else:
                # No single-file weights given: load the transformer as a
                # diffusers subfolder module and swap it in wholesale. Used for
                # repos published as diffusers-format transformers (e.g. the FP8
                # Photoroom conversion).
                from diffusers import Flux2Transformer2DModel  # type: ignore

                logger.info(
                    f"Loading {label} transformer module from {repo}",
                    extra={"repo": repo, "quant": label},
                )
                transformer = Flux2Transformer2DModel.from_pretrained(
                    repo, torch_dtype=self._dtype
                )
                if torch.cuda.is_available():
                    transformer = transformer.to("cuda")
                self.pipe.transformer = transformer
            self._quantization = label
        except Exception as e:  # noqa: BLE001 — want all-exception BF16 fallback
            logger.warning(
                f"{label} overlay failed ({type(e).__name__}: {e}); falling back to BF16",
                extra={"error_type": type(e).__name__, "quant": label},
            )

    def get_info(self) -> dict:
        gpu = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)
        return {
            "model": MODEL_ID,
            "dtype": DTYPE,
            "quantization": self._quantization,
            "default_steps": STEPS,
            "resolution": f"{WIDTH}x{HEIGHT}",
            "gpu": gpu,
            "vram_free_gb": round(vram_free, 2),
            "timings_ms": dict(self._timings),
        }
