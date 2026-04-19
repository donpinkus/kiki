"""FLUX.2-klein reference-mode img2img pipeline."""

from __future__ import annotations

import logging
import threading
import time

import torch
from PIL import Image

import config

logger = logging.getLogger(__name__)


class FluxKleinPipeline:
    """Wraps FLUX.2-klein for reference-mode img2img generation.

    The sketch is VAE-encoded and concatenated with generation latents via the
    pipeline's built-in ``image`` parameter — the transformer attends to both
    the sketch tokens and the generation tokens. This is the only img2img mode
    that produces usable output on klein (a 4-step distilled model), since the
    distillation trajectory doesn't tolerate partial-denoise starts.
    """

    def __init__(self, gpu_lock: threading.Lock | None = None):
        self.pipe = None
        self._ready = False
        self._dtype = getattr(torch, config.DTYPE)
        self._quantization = "bf16"  # overwritten to "nvfp4" if that path succeeds
        # Serialize pipeline calls — PyTorch is not thread-safe and
        # asyncio.to_thread could overlap frames. If a shared lock is passed in,
        # use it so the sibling LTXV video pipeline can't run on the same GPU
        # at the same time.
        self._lock = gpu_lock if gpu_lock is not None else threading.Lock()

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Load FLUX.2-klein model and warm up."""
        logger.info("Loading model: %s (dtype=%s)", config.MODEL_ID, config.DTYPE)
        t0 = time.time()

        from diffusers import Flux2KleinPipeline

        self.pipe = Flux2KleinPipeline.from_pretrained(
            config.MODEL_ID,
            torch_dtype=self._dtype,
        )

        # Optional: overwrite the transformer with BFL's NVFP4 weights for 2.7× speedup.
        # Must happen BEFORE .to("cuda") so the new weights land on device.
        if config.USE_NVFP4:
            self._try_load_nvfp4()

        self.pipe.to("cuda")

        logger.info("Model loaded in %.1fs (quantization=%s)", time.time() - t0, self._quantization)

        # Warmup with a dummy txt2img generation
        logger.info("Warming up...")
        t1 = time.time()
        with self._lock:
            _ = self.pipe(
                prompt="warmup",
                height=config.DEFAULT_HEIGHT,
                width=config.DEFAULT_WIDTH,
                num_inference_steps=config.STEPS,
                guidance_scale=1.0,
                generator=torch.Generator(device="cuda").manual_seed(0),
            )
        logger.info("Warmup done (%.1fs)", time.time() - t1)

        self._ready = True
        logger.info("Pipeline ready. Total init: %.1fs", time.time() - t0)

    def generate_reference(
        self,
        image: Image.Image,
        prompt: str,
        steps: int = config.STEPS,
        seed: int | None = None,
    ) -> Image.Image:
        """Run reference-mode img2img generation.

        The sketch is passed as a conditioning image via the pipeline's
        ``image`` parameter. Internally the model VAE-encodes it, patchifies
        the latents, and concatenates them with generation latents so the
        transformer attends to both.
        """
        generator = self._make_generator(seed)

        with self._lock:
            result = self.pipe(
                prompt=prompt,
                image=image,
                height=config.DEFAULT_HEIGHT,
                width=config.DEFAULT_WIDTH,
                num_inference_steps=steps,
                # klein is step-wise distilled and ignores guidance_scale;
                # diffusers prints a warning every frame if we don't pin it
                # to the neutral value.
                guidance_scale=1.0,
                generator=generator,
            )
        return result.images[0]

    def _make_generator(self, seed: int | None) -> torch.Generator | None:
        if seed is not None:
            return torch.Generator(device="cuda").manual_seed(seed)
        return None

    def _try_load_nvfp4(self) -> None:
        """Overwrite transformer weights with BFL's NVFP4 checkpoint.

        NVFP4 requires Blackwell (SM 10.0+) silicon. On older GPUs or if the
        weights file shape-mismatches the current diffusers version, we log a
        warning and leave the BF16 weights in place so the pipeline still runs.
        """
        if not torch.cuda.is_available():
            logger.warning("NVFP4 requested but CUDA not available; staying on BF16")
            return

        major, _ = torch.cuda.get_device_capability(0)
        if major < 10:
            logger.warning(
                "NVFP4 requires Blackwell (SM 10+); detected SM %d.x. Staying on BF16.",
                major,
            )
            return

        try:
            from huggingface_hub import hf_hub_download
            from safetensors.torch import load_file

            logger.info(
                "Loading NVFP4 transformer weights from %s (%s)...",
                config.NVFP4_REPO, config.NVFP4_FILENAME,
            )
            t0 = time.time()
            nvfp4_path = hf_hub_download(
                repo_id=config.NVFP4_REPO,
                filename=config.NVFP4_FILENAME,
            )
            state_dict = load_file(nvfp4_path)
            missing, unexpected = self.pipe.transformer.load_state_dict(
                state_dict, strict=False,
            )
            logger.info(
                "NVFP4 weights loaded in %.1fs (missing=%d, unexpected=%d)",
                time.time() - t0, len(missing), len(unexpected),
            )
            self._quantization = "nvfp4"
        except Exception as e:  # noqa: BLE001 — want all-exception fallback
            logger.warning(
                "NVFP4 load failed (%s: %s); falling back to BF16",
                type(e).__name__, e,
            )

    def get_info(self) -> dict:
        """Return pipeline info for health endpoint."""
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)

        return {
            "model": config.MODEL_ID,
            "dtype": config.DTYPE,
            "quantization": self._quantization,
            "default_steps": config.STEPS,
            "resolution": f"{config.DEFAULT_WIDTH}x{config.DEFAULT_HEIGHT}",
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
        }
