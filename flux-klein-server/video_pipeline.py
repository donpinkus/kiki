"""LTX-Video 2B (0.9.8 distilled) image-to-video pipeline.

Loads the 0.9.5 base for VAE/text-encoder/scheduler and overwrites the
transformer with the 0.9.8 distilled single-file checkpoint — same pattern
FluxKleinPipeline uses for NVFP4. The base 0.9.5 transformer weights are
deliberately NOT on the volume (see backend/scripts/populate-volume.ts);
we sidestep that by loading the distilled transformer first via
``from_single_file`` and injecting it into ``from_pretrained`` so the
pipeline's own transformer load is skipped.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Callable

import torch
from PIL import Image

import config
# Reuse the image pipeline's helper so both pods stamp the same
# /workspace/app/.version.json onto /health for drift detection by the
# orchestrator. Cross-module private import is fine here — both files
# live in the same package.
from pipeline import _load_app_version

logger = logging.getLogger(__name__)


class CancelledError(Exception):
    """Raised inside the diffusion loop when the backend signals cancel.

    Bubbles up out of ``self.pipe(...)``; ``generate()`` catches it and
    returns ``None`` so the caller can emit a ``video_cancelled`` frame
    cleanly.
    """


class LtxvVideoPipeline:
    """Wraps ``LTXImageToVideoPipeline`` for the idle-state animation flow.

    Single-instance, single-GPU. Calls are serialized through ``_lock`` so
    the WebSocket layer can fire-and-forget without worrying about overlap.
    """

    def __init__(self) -> None:
        self.pipe = None
        self._ready = False
        self._lock = threading.Lock()
        self._load_ms: int = 0
        # Per-substage warmup timings + flux-klein-server tree-hash version
        # exposed via /health. Mirrors the image pipeline so the orchestrator's
        # drift detection and substage observability work identically for
        # both pod kinds (per-DC volume sync coverage, slow-warmup root-cause).
        self._phase_timings: dict[str, int] = {}
        self._app_version = _load_app_version()

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        logger.info(
            "Loading LTXV: base=%s transformer=%s/%s",
            config.LTXV_BASE_REPO,
            config.LTXV_TRANSFORMER_REPO,
            config.LTXV_TRANSFORMER_FILE,
        )
        t0 = time.time()

        from diffusers import LTXImageToVideoPipeline, LTXVideoTransformer3DModel
        from huggingface_hub import hf_hub_download

        # Distilled transformer — single-file checkpoint. Loading via
        # ``from_single_file`` lets diffusers infer the architecture from
        # the safetensors metadata without needing the 0.9.5 transformer
        # weights as a fallback (which the volume doesn't have).
        t_phase = time.time()
        transformer_path = hf_hub_download(
            repo_id=config.LTXV_TRANSFORMER_REPO,
            filename=config.LTXV_TRANSFORMER_FILE,
        )
        logger.info("Loading transformer single-file: %s", transformer_path)
        transformer = LTXVideoTransformer3DModel.from_single_file(
            transformer_path,
            torch_dtype=torch.bfloat16,
        )
        self._phase_timings["transformer_load_ms"] = int((time.time() - t_phase) * 1000)

        # Base pipeline — passing transformer= bypasses transformer load
        # from the base repo (which is intentional: those weights aren't
        # on the volume).
        t_phase = time.time()
        self.pipe = LTXImageToVideoPipeline.from_pretrained(
            config.LTXV_BASE_REPO,
            transformer=transformer,
            torch_dtype=torch.bfloat16,
        )
        self._phase_timings["from_pretrained_ms"] = int((time.time() - t_phase) * 1000)

        t_phase = time.time()
        self.pipe.to("cuda")
        self._phase_timings["to_cuda_ms"] = int((time.time() - t_phase) * 1000)

        logger.info("LTXV loaded in %.1fs", time.time() - t0)

        # Warmup — first call has lazy CUDA kernel compilation. Doing it
        # here keeps the user-visible first video latency clean.
        logger.info("LTXV warmup...")
        t1 = time.time()
        warmup_image = Image.new("RGB", (config.LTXV_WIDTH, config.LTXV_HEIGHT), (128, 128, 128))
        with self._lock:
            _ = self.pipe(
                image=warmup_image,
                prompt="warmup",
                negative_prompt=config.LTXV_NEGATIVE_PROMPT,
                width=config.LTXV_WIDTH,
                height=config.LTXV_HEIGHT,
                num_frames=config.LTXV_NUM_FRAMES,
                num_inference_steps=config.LTXV_STEPS,
                guidance_scale=1.0,
                generator=torch.Generator(device="cuda").manual_seed(0),
            )
        self._phase_timings["warmup_inference_ms"] = int((time.time() - t1) * 1000)
        logger.info("LTXV warmup done (%.1fs)", time.time() - t1)

        self._load_ms = int((time.time() - t0) * 1000)
        self._ready = True

    def generate(
        self,
        image: Image.Image,
        prompt: str,
        seed: int | None,
        is_cancelled: Callable[[], bool],
    ) -> list[Image.Image] | None:
        """Generate a video from ``image``+``prompt``. Returns the decoded
        frame list, or ``None`` if cancelled mid-generation.

        ``is_cancelled`` is polled in a step callback; raising inside the
        callback is what actually aborts the diffusion loop.
        """
        generator = self._make_generator(seed)

        def _step_cb(pipe, step, timestep, callback_kwargs):  # noqa: ANN001
            if is_cancelled():
                # Raising propagates out of pipe.__call__ — we catch it
                # below. Diffusers swallows callback return values but
                # propagates exceptions, so this is the supported way to
                # exit early.
                raise CancelledError(f"cancel at step {step}")
            if config.LTXV_DEBUG:
                logger.debug("ltxv step %d ts=%s", step, timestep)
            return callback_kwargs

        with self._lock:
            try:
                result = self.pipe(
                    image=image,
                    prompt=prompt or "",
                    negative_prompt=config.LTXV_NEGATIVE_PROMPT,
                    width=config.LTXV_WIDTH,
                    height=config.LTXV_HEIGHT,
                    num_frames=config.LTXV_NUM_FRAMES,
                    num_inference_steps=config.LTXV_STEPS,
                    guidance_scale=1.0,
                    generator=generator,
                    callback_on_step_end=_step_cb,
                )
            except CancelledError as e:
                logger.info("LTXV cancelled (%s)", e)
                return None

        # result.frames is List[List[PIL.Image.Image]] — one per batch
        # element; we ran a single prompt so the outer list has length 1.
        frames = result.frames[0]
        return frames

    def _make_generator(self, seed: int | None) -> torch.Generator | None:
        if seed is not None:
            return torch.Generator(device="cuda").manual_seed(seed)
        return None

    def get_info(self) -> dict:
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)
        return {
            "video_ready": self._ready,
            "model": f"{config.LTXV_TRANSFORMER_REPO}/{config.LTXV_TRANSFORMER_FILE}",
            "base": config.LTXV_BASE_REPO,
            "resolution": f"{config.LTXV_WIDTH}x{config.LTXV_HEIGHT}",
            "num_frames": config.LTXV_NUM_FRAMES,
            "steps": config.LTXV_STEPS,
            "fps": config.LTXV_FPS,
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
            "load_ms": self._load_ms,
            "phase_timings_ms": dict(self._phase_timings),
            "app_version": dict(self._app_version),
        }
