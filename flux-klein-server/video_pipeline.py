"""LTX-2.3 image-to-video pipeline (DistilledPipeline, FP8, H100 SXM).

Replaces the prior LTXV 0.9.8 (2B distilled FP8) Diffusers pipeline. Uses
Lightricks' official `ltx-pipelines.DistilledPipeline`:

- Stage 1: half-resolution video generation (8 sigmas)
- Stage 2: 2x spatial upsample + refinement (4 sigmas)

Output (Iterator[Tensor], Audio). Audio is discarded — Kiki's video pane is
silent. Frames-as-tensors get converted to PIL Images so video_server.py
can stream them as JPEGs over the existing WebSocket protocol unchanged.

License note: LTX-2 weights are released under the LTX-2 Community License
(https://github.com/Lightricks/LTX-2/blob/main/LICENSE), NOT Apache-2.0.
The license restricts commercial use for entities with >=$10M annual
revenue. Verify license terms before any commercial deployment.
"""
from __future__ import annotations

import logging
import os
import tempfile
import threading
import time
from typing import Callable

import torch
from PIL import Image

import config
# Reuse the image pipeline's helper so both pods stamp the same
# /workspace/app/.version.json onto /health for drift detection by the
# orchestrator.
from pipeline import _load_app_version

logger = logging.getLogger(__name__)


def _resolve_hf_cache_path(repo_id: str, filename: str) -> str:
    """Resolve the local path of a single-file HF asset that was pre-cached
    via `hf_hub_download` at populate time. Pod runs offline (HF_HUB_OFFLINE=1)
    so we cannot use `hf_hub_download` again — we read directly from the
    cache layout written by the populate script.
    """
    from huggingface_hub import hf_hub_download
    return hf_hub_download(repo_id=repo_id, filename=filename, local_files_only=True)


def _resolve_hf_snapshot_path(repo_id: str) -> str:
    """Resolve the local path of a multi-file HF snapshot (e.g., Gemma) that
    was pre-cached via `snapshot_download` at populate time. Returns the
    snapshot directory path that DistilledPipeline expects as `gemma_root`.
    """
    from huggingface_hub import snapshot_download
    return snapshot_download(repo_id=repo_id, local_files_only=True)


class CancelledError(Exception):
    """Raised when the backend cancels mid-pipeline. NOTE: DistilledPipeline
    does NOT expose mid-inference cancellation hooks (no step callback like
    Diffusers had). Cancellation is checked at start-of-generate only; if
    cancellation arrives during inference, the GPU keeps running to
    completion and the result is discarded by the caller. Acceptable cost
    (~10-30s wasted GPU time per cancelled generation) versus rewriting
    DistilledPipeline internals.
    """


class Ltx23VideoPipeline:
    """Wraps `ltx_pipelines.DistilledPipeline` for the idle-state animation flow.

    Single-instance, single-GPU. Calls are serialized through `_lock` so the
    WebSocket layer can fire-and-forget without worrying about overlap.
    """

    def __init__(self) -> None:
        self.pipe = None
        self._tiling_config = None
        self._ready = False
        self._lock = threading.Lock()
        self._load_ms: int = 0
        # Per-substage warmup timings + flux-klein-server tree-hash version
        # exposed via /health. Mirrors the image pipeline so the orchestrator's
        # drift detection and substage observability work identically for
        # both pod kinds.
        self._phase_timings: dict[str, int] = {}
        self._app_version = _load_app_version()

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        logger.info(
            "Loading %s: model=%s/%s gemma=%s upscaler=%s/%s quantization=%s",
            config.LTX_MODEL_FAMILY,
            config.LTX_MODEL_REPO,
            config.LTX_MODEL_FILE,
            config.LTX_TEXT_ENCODER_REPO,
            config.LTX_SPATIAL_UPSCALER_REPO,
            config.LTX_SPATIAL_UPSCALER_FILE,
            config.LTX_QUANTIZATION,
        )
        t0 = time.time()

        # Imports gated to load() so that startup failures (missing weights,
        # ImportError on ltx_core/ltx_pipelines) surface in the loader log
        # rather than at module import time.
        from ltx_core.model.video_vae import TilingConfig
        from ltx_core.quantization import QuantizationPolicy
        from ltx_pipelines.distilled import DistilledPipeline
        from ltx_pipelines.utils.types import OffloadMode

        # Resolve pre-populated paths from the offline HF cache. Pod is
        # HF_HUB_OFFLINE=1; populate script ran these as online downloads.
        t_phase = time.time()
        checkpoint_path = _resolve_hf_cache_path(config.LTX_MODEL_REPO, config.LTX_MODEL_FILE)
        upscaler_path = _resolve_hf_cache_path(
            config.LTX_SPATIAL_UPSCALER_REPO, config.LTX_SPATIAL_UPSCALER_FILE
        )
        gemma_root = _resolve_hf_snapshot_path(config.LTX_TEXT_ENCODER_REPO)
        self._phase_timings["resolve_paths_ms"] = int((time.time() - t_phase) * 1000)
        logger.info(
            "Resolved offline paths: checkpoint=%s upscaler=%s gemma=%s",
            checkpoint_path,
            upscaler_path,
            gemma_root,
        )

        # Quantization + offload mode are env-controlled so we can flip without
        # redeploying. ltx-pipelines rejects quantization combined with layer
        # streaming, so when LTX_OFFLOAD_MODE != "none" we drop quantization.
        #
        # FP8 modes:
        #   cast       — Lightricks' universal-no-deps default. Stores Linear
        #                weights in FP8; upcasts to BF16 per matmul. Works on
        #                any CUDA GPU. Default.
        #   scaled_mm  — native FP8 matmul via TensorRT-LLM. Hopper-only,
        #                ~10-30% faster on H100. Currently blocked on upstream
        #                issue #181 (shape mismatch); flip when fixed.
        offload_mode_name = os.getenv("LTX_OFFLOAD_MODE", "none").lower()
        offload_mode = OffloadMode(offload_mode_name)
        if offload_mode == OffloadMode.NONE:
            fp8_mode = os.getenv("LTX_FP8_MODE", "cast").lower()
            quantization = (
                QuantizationPolicy.fp8_scaled_mm()
                if fp8_mode == "scaled_mm"
                else QuantizationPolicy.fp8_cast()
            )
            logger.info("LTX quantization=fp8_%s offload_mode=none", fp8_mode)
        else:
            quantization = None
            logger.info("LTX quantization=disabled offload_mode=%s", offload_mode_name)

        t_phase = time.time()
        self.pipe = DistilledPipeline(
            distilled_checkpoint_path=checkpoint_path,
            gemma_root=gemma_root,
            spatial_upsampler_path=upscaler_path,
            loras=[],
            quantization=quantization,
            offload_mode=offload_mode,
        )

        # Kiki has no audio output. Replace audio_decoder with a stub so the
        # vocoder is never built/run — saves the audio decode build/free cycle
        # and a few seconds of latency. DistilledPipeline's __call__ unpacks
        # `(decoded_video, decoded_audio)`; a None second element is fine —
        # our wrapper discards `_audio`.
        self.pipe.audio_decoder = lambda *_args, **_kwargs: None  # type: ignore[assignment]
        self._tiling_config = TilingConfig.default()
        self._phase_timings["pipeline_init_ms"] = int((time.time() - t_phase) * 1000)
        logger.info("LTX-2.3 pipeline loaded in %.1fs", time.time() - t_phase)

        # Warmup — first call has lazy CUDA kernel compilation. Doing it
        # here keeps the user-visible first video latency clean.
        logger.info("LTX-2.3 warmup...")
        t1 = time.time()
        warmup_image = Image.new("RGB", (config.LTX_WIDTH, config.LTX_HEIGHT), (128, 128, 128))
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            warmup_path = f.name
            warmup_image.save(warmup_path, format="PNG")
        try:
            with self._lock:
                # _run_inference already wraps in torch.inference_mode().
                _ = self._run_inference(
                    image_path=warmup_path,
                    prompt="warmup",
                    seed=0,
                )
        finally:
            try:
                os.unlink(warmup_path)
            except OSError:
                pass
        self._phase_timings["warmup_inference_ms"] = int((time.time() - t1) * 1000)
        logger.info("LTX-2.3 warmup done (%.1fs)", time.time() - t1)

        self._load_ms = int((time.time() - t0) * 1000)
        self._ready = True

    def generate(
        self,
        image: Image.Image,
        prompt: str,
        seed: int | None,
        is_cancelled: Callable[[], bool],
    ) -> list[Image.Image] | None:
        """Generate a video from `image`+`prompt`. Returns the decoded frame
        list, or `None` if cancellation was requested before inference started.

        NOTE on cancellation: DistilledPipeline doesn't expose mid-inference
        callbacks, so once we enter `pipe(...)` we run to completion. The
        cancel check at the top is the only opportunity to bail cheaply.
        Mid-inference cancels result in a wasted full inference; the caller
        discards the frames if cancel.is_set() upon return. See class
        docstring for details.
        """
        if is_cancelled():
            logger.info("LTX-2.3 generate skipped — cancelled before start")
            return None

        # Resolve seed: if caller didn't specify, generate a fresh random one.
        # DistilledPipeline.__call__ requires `seed: int`, not Optional.
        if seed is None:
            seed = int.from_bytes(os.urandom(4), byteorder="little") & 0x7FFFFFFF

        # Image conditioning is path-based in ltx-pipelines. Write the
        # incoming PIL image to a tempfile, pass the path, clean up after.
        # PNG (lossless) instead of JPEG: upstream's preprocessing pass
        # re-encodes the image at crf=33 unless the caller explicitly passes
        # crf=0 (see _run_inference). For sparse line drawings from the iPad,
        # JPEG-then-crf=33 cumulative loss visibly damages thin strokes.
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            image_path = f.name
            image.save(image_path, format="PNG")
        try:
            with self._lock:
                frames = self._run_inference(
                    image_path=image_path,
                    prompt=prompt or "",
                    seed=seed,
                )
        finally:
            try:
                os.unlink(image_path)
            except OSError:
                pass

        # Late cancel check: caller may have set the flag while inference was
        # running. Returning None lets video_server emit `video_cancelled`
        # cleanly and the caller's counters tick the cancelled tally.
        if is_cancelled():
            logger.info("LTX-2.3 generate completed but cancellation arrived; discarding")
            return None

        return frames

    def _run_inference(
        self,
        image_path: str,
        prompt: str,
        seed: int,
    ) -> list[Image.Image]:
        """Run one DistilledPipeline call, materialize the frame iterator
        into PIL Images. Caller holds `self._lock`.

        Wraps the pipeline call in ``torch.inference_mode()`` — without it
        PyTorch retains autograd buffers for every fp8_cast Linear's BF16
        upcast tensor, blowing past 80 GiB on the 22B transformer. Lightricks'
        own ``ltx_pipelines.distilled.main()`` is decorated with
        ``@torch.inference_mode()``; replicating that here is the load-bearing
        fix for the H100 OOM. ``model.eval()`` alone is NOT enough — it only
        toggles dropout/batchnorm, not autograd.
        """
        from ltx_pipelines.utils.args import ImageConditioningInput

        # crf=0 disables upstream's preprocessing re-encode of the conditioning
        # image (default crf=33 introduces visible compression artifacts on
        # sparse drawn linework, weakening conditioning).
        images = [
            ImageConditioningInput(
                path=image_path,
                frame_idx=0,
                strength=1.0,
                crf=0,
            )
        ]
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()

        frames: list[Image.Image] = []
        with torch.inference_mode():
            decoded_video, _audio = self.pipe(
                prompt=prompt,
                seed=seed,
                height=config.LTX_HEIGHT,
                width=config.LTX_WIDTH,
                num_frames=config.LTX_NUM_FRAMES,
                frame_rate=float(config.LTX_FPS),
                images=images,
                tiling_config=self._tiling_config,
                enhance_prompt=False,
            )

            # Tensor iterator → PIL list. The iterator drives the video VAE
            # decoder, which is also part of inference and must run inside
            # the inference_mode context. Each chunk is (F, H, W, 3) uint8
            # RGB (per ltx_pipelines.utils.media_io.encode_video which feeds
            # the same tensor straight into PyAV with format="rgb24").
            for chunk in decoded_video:
                chunk_cpu = chunk.to("cpu")
                if chunk_cpu.dtype != torch.uint8:
                    # Defensive: float tensors get clamped + scaled.
                    # Shouldn't happen for the ltx-pipelines decoder, but
                    # guards against a silent regression if upstream changes
                    # the output dtype.
                    chunk_cpu = (chunk_cpu.clamp(0, 1) * 255).to(torch.uint8)
                arr = chunk_cpu.numpy()
                for frame_arr in arr:
                    frames.append(Image.fromarray(frame_arr, mode="RGB"))

        if torch.cuda.is_available():
            logger.info(
                "LTX inference CUDA peak allocated %.2f GiB, peak reserved %.2f GiB",
                torch.cuda.max_memory_allocated() / (1024**3),
                torch.cuda.max_memory_reserved() / (1024**3),
            )

        # Diagnostic: dump the first decoded frame to disk so that if the iPad
        # video looks wrong, we can SSH in and check whether the bug is in
        # inference (frame 0 itself is bad) or in MP4/streaming (frame 0 is
        # clean but the encoded MP4 is corrupted). Overwrite each call.
        if frames:
            try:
                frames[0].save("/tmp/ltx-first-frame.jpg", format="JPEG", quality=90)
            except OSError as e:
                logger.warning("Failed to save /tmp/ltx-first-frame.jpg: %s", e)
        return frames

    def get_info(self) -> dict:
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)
        return {
            "video_ready": self._ready,
            "model_family": config.LTX_MODEL_FAMILY,
            "model_repo": config.LTX_MODEL_REPO,
            "model_file": config.LTX_MODEL_FILE,
            "text_encoder": config.LTX_TEXT_ENCODER_REPO,
            "spatial_upscaler": config.LTX_SPATIAL_UPSCALER_FILE,
            "quantization": config.LTX_QUANTIZATION,
            "pipeline": "DistilledPipeline",
            "resolution": f"{config.LTX_WIDTH}x{config.LTX_HEIGHT}",
            "num_frames": config.LTX_NUM_FRAMES,
            "fps": config.LTX_FPS,
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
            "load_ms": self._load_ms,
            "phase_timings_ms": dict(self._phase_timings),
            "app_version": dict(self._app_version),
        }
