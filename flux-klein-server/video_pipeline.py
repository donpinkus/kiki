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
from collections import defaultdict
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Callable, Iterator, Literal

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


CancelState = Literal["ok", "before_start", "during_inference", "after_complete"]


@dataclass
class GenerateResult:
    """Outcome of a single ``generate()`` call.

    Carries enough to differentiate ``before_start`` (cheap), ``after_complete``
    (today's dominant wasted-GPU pattern, ~pipe_total_ms wasted per cancel),
    and ``during_inference`` (added in Step 5 with the forked denoising loop).
    """

    frames: list[Image.Image] | None
    cancel_state: CancelState
    lock_wait_ms: int
    pipe_total_ms: int
    cancelled_but_ran_ms: int


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
        # Per-inference phase timings (CUDA-synced ms). Reset at the start of
        # _run_inference; each phase wrapper appends. Logged at end of run so
        # we can attribute the 15s steady-state latency to specific stages
        # before optimizing blind. Lists because some phases (image_conditioner,
        # transformer stage) are called twice per inference.
        self._inference_timings: dict[str, list[int]] = defaultdict(list)
        # Persistent transformer (Step 2 of the perf plan). Built once at end
        # of load(), reused across all requests, freed only on graceful
        # shutdown via shutdown_persistent_models(). Eliminates the ~63s
        # per-request stage_build cost. None until built; if build fails,
        # _ready stays False and orchestrator's reaper rerolls the pod —
        # we explicitly do NOT fall back to per-request rebuild because that
        # would silently mask the failure and reintroduce 60s+ latency.
        self._transformer_ctx: object | None = None
        self._transformer: object | None = None
        self._persistent_transformer_ready: bool = False
        self._persistent_transformer_build_ms: int = 0
        self._vram_after_transformer_gb: float = 0.0
        # Persistent Gemma + embeddings_processor (Step 3 of the perf plan).
        # Built together at warmup as one unit. Same fail-fast +
        # idempotent-shutdown pattern as Step 2. Gated by
        # LTX_PERSIST_GEMMA env var (default "1") so we have a fast
        # rollback path if a host shows unexpected allocator behavior at
        # ~46 GiB resident. The two are persisted together because
        # upstream's PromptEncoder.__call__ runs them as one unit, and the
        # 1.5s embeddings_processor build cost is also per-request load.
        self._text_encoder_ctx: object | None = None
        self._text_encoder: object | None = None
        self._embeddings_processor_ctx: object | None = None
        self._embeddings_processor: object | None = None
        self._persistent_gemma_ready: bool = False
        self._persistent_gemma_build_ms: int = 0
        self._persistent_embeddings_processor_build_ms: int = 0
        self._vram_after_gemma_gb: float = 0.0
        self._vram_after_embeddings_processor_gb: float = 0.0
        # Per-request resident-vs-peak VRAM accounting. Without this, after
        # persistence lands, peak_alloc includes the resident transformer
        # baseline so per-request leaks become invisible. Captured at the
        # top of each _run_inference call.
        self._resident_alloc_gb_at_request_start: float = 0.0
        self._app_version = _load_app_version()

    @property
    def ready(self) -> bool:
        return self._ready

    @contextmanager
    def _timed(self, name: str) -> Iterator[None]:
        """Context manager that records CUDA-synced wall-clock for a phase.

        ``torch.cuda.synchronize()`` before AND after is required because
        PyTorch dispatches kernels asynchronously — without sync, the timer
        captures kernel-launch time rather than completion time, and prior
        phases' GPU work bleeds into the next phase's measured time. Appends
        to a list so callers can run the same phase twice (e.g. stage 1 vs
        stage 2 image conditioning) and see both samples.
        """
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        t0 = time.perf_counter()
        try:
            yield
        finally:
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            self._inference_timings[name].append(int((time.perf_counter() - t0) * 1000))

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

        # Kiki has no audio output. Replace audio_decoder with a stub. The new
        # _run_inference path replicates DistilledPipeline.__call__'s flow
        # without invoking audio_decoder, so this stub is mostly belt-and-
        # suspenders — but if anything ever falls back to upstream __call__,
        # the stub avoids spinning up the vocoder.
        self.pipe.audio_decoder = lambda *_args, **_kwargs: None  # type: ignore[assignment]

        self._tiling_config = TilingConfig.default()
        self._phase_timings["pipeline_init_ms"] = int((time.time() - t_phase) * 1000)
        logger.info("LTX-2.3 pipeline loaded in %.1fs", time.time() - t_phase)

        # Step 2 — Build persistent transformer BEFORE warmup so that warmup
        # validates the persistent path, not the legacy per-request build path.
        # Otherwise warmup metrics would still reflect the old behavior and
        # be misleading. Fail-fast: if the build raises, _ready stays False
        # and the orchestrator's /health-based reaper rerolls the pod. Do
        # NOT silently fall back to per-request rebuild — that would hide
        # the failure and reintroduce 60s+ latency per request.
        logger.info("LTX-2.3 building persistent transformer (Step 2)...")
        t_persist = time.time()
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        self._transformer_ctx = self.pipe.stage.model_context()
        self._transformer = self._transformer_ctx.__enter__()
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        self._persistent_transformer_build_ms = int((time.time() - t_persist) * 1000)
        if torch.cuda.is_available():
            self._vram_after_transformer_gb = torch.cuda.memory_allocated() / (1024**3)
        self._persistent_transformer_ready = True
        logger.info(
            "LTX-2.3 persistent transformer ready (%dms, vram_after=%.2f GiB)",
            self._persistent_transformer_build_ms,
            self._vram_after_transformer_gb,
        )

        # Step 3 — Build persistent Gemma + embeddings_processor as one unit,
        # also BEFORE warmup. Same fail-fast + idempotent-shutdown pattern
        # as Step 2. Gated by LTX_PERSIST_GEMMA so we have an env-flag
        # rollback path if a host shows unexpected allocator behavior at
        # ~46 GiB resident.
        #
        # Reuses upstream's _underscore-prefixed builders (`_text_encoder_ctx`
        # and `_embeddings_processor_builder`). Not strictly public API; if
        # Lightricks changes the signatures the failure surface is exactly
        # this block plus the prompt-encoding section in `_run_inference`.
        if os.getenv("LTX_PERSIST_GEMMA", "1") == "1":
            from ltx_pipelines.utils.gpu_model import gpu_model

            logger.info("LTX-2.3 building persistent Gemma + embeddings_processor (Step 3)...")
            prompt_enc = self.pipe.prompt_encoder

            # Persistent Gemma text encoder.
            t_gemma = time.time()
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            self._text_encoder_ctx = prompt_enc._text_encoder_ctx()
            self._text_encoder = self._text_encoder_ctx.__enter__()
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            self._persistent_gemma_build_ms = int((time.time() - t_gemma) * 1000)
            if torch.cuda.is_available():
                self._vram_after_gemma_gb = torch.cuda.memory_allocated() / (1024**3)
            logger.info(
                "LTX-2.3 persistent Gemma ready (%dms, vram_after=%.2f GiB)",
                self._persistent_gemma_build_ms,
                self._vram_after_gemma_gb,
            )

            # Persistent embeddings processor. Build same way upstream's
            # PromptEncoder.__call__ does it, then keep it on GPU via
            # gpu_model() — but never exit the context until shutdown.
            t_ep = time.time()
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            ep_model = (
                prompt_enc._embeddings_processor_builder.build(
                    device=prompt_enc._device, dtype=prompt_enc._dtype
                )
                .to(prompt_enc._device)
                .eval()
            )
            self._embeddings_processor_ctx = gpu_model(ep_model)
            self._embeddings_processor = self._embeddings_processor_ctx.__enter__()
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            self._persistent_embeddings_processor_build_ms = int((time.time() - t_ep) * 1000)
            if torch.cuda.is_available():
                self._vram_after_embeddings_processor_gb = (
                    torch.cuda.memory_allocated() / (1024**3)
                )
            self._persistent_gemma_ready = True
            logger.info(
                "LTX-2.3 persistent embeddings_processor ready (%dms, vram_after=%.2f GiB)",
                self._persistent_embeddings_processor_build_ms,
                self._vram_after_embeddings_processor_gb,
            )
        else:
            logger.info("LTX_PERSIST_GEMMA=0 — skipping Step 3 (Gemma rebuilds per request)")

        # Warmup — first call has lazy CUDA kernel compilation. Doing it
        # here keeps the user-visible first video latency clean. With the
        # persistent transformer + Gemma above, warmup now exercises the
        # full persistent serving path so metrics match steady-state.
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
    ) -> "GenerateResult":
        """Generate a video from `image`+`prompt`. Returns a ``GenerateResult``
        with `frames` (or None if cancelled), `cancel_state`, `lock_wait_ms`,
        `pipe_total_ms`, and `cancelled_but_ran_ms`.

        Cancellation states (Step 1 of the perf plan):
        - ``ok``: full inference, frames returned.
        - ``before_start``: cancel arrived before lock acquired or before
          inference body started; ~0ms wasted.
        - ``after_complete``: full inference ran, frames produced, cancel
          arrived during the post-inference re-check; ~pipe_total_ms wasted.
        - ``during_inference`` (future, after Step 5 lands): cancel landed
          while denoising; ≤1 sigma wasted.

        NOTE on cancellation: today's DistilledPipeline still doesn't expose
        mid-inference callbacks, so `during_inference` won't appear yet.
        Step 5 forks `euler_denoising_loop` to add it.
        """
        if is_cancelled():
            logger.info("LTX-2.3 generate skipped — cancelled before start")
            return GenerateResult(
                frames=None,
                cancel_state="before_start",
                lock_wait_ms=0,
                pipe_total_ms=0,
                cancelled_but_ran_ms=0,
            )

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
        # `lock_wait_ms` separates queue/lock-contention time from
        # `pipe_total`. Important once Step 5 lands and short-cancelled jobs
        # release the lock fast — without it, queue effects look like
        # spurious perf wins or losses on the next request.
        t_lock_request = time.perf_counter()
        try:
            with self._lock:
                lock_wait_ms = int((time.perf_counter() - t_lock_request) * 1000)
                # Re-check cancellation immediately after acquiring the lock.
                # The earlier check at the top of generate() can be stale by
                # ~lock_wait_ms; if the request was cancelled while queued,
                # we'd otherwise still run a full ~127s inference. This
                # closes that window before Step 5's mid-denoise hook lands.
                if is_cancelled():
                    logger.info(
                        "LTX-2.3 generate cancelled after acquiring lock "
                        "(lock_wait_ms=%d)",
                        lock_wait_ms,
                    )
                    return GenerateResult(
                        frames=None,
                        cancel_state="before_start",
                        lock_wait_ms=lock_wait_ms,
                        pipe_total_ms=0,
                        cancelled_but_ran_ms=0,
                    )
                frames = self._run_inference(
                    image_path=image_path,
                    prompt=prompt or "",
                    seed=seed,
                )
                pipe_total_ms = self._inference_timings["pipe_total"][-1]
        finally:
            try:
                os.unlink(image_path)
            except OSError:
                pass

        # Late cancel check: caller may have set the flag while inference was
        # running. Today this is the dominant wasted-GPU pattern (~21s per
        # cancel) and Step 1's classification makes it visible in metrics.
        if is_cancelled():
            logger.info(
                "LTX-2.3 generate completed but cancellation arrived; discarding "
                "(wasted_ms=%d)",
                pipe_total_ms,
            )
            return GenerateResult(
                frames=None,
                cancel_state="after_complete",
                lock_wait_ms=lock_wait_ms,
                pipe_total_ms=pipe_total_ms,
                cancelled_but_ran_ms=pipe_total_ms,
            )

        return GenerateResult(
            frames=frames,
            cancel_state="ok",
            lock_wait_ms=lock_wait_ms,
            pipe_total_ms=pipe_total_ms,
            cancelled_but_ran_ms=0,
        )

    def _run_inference(
        self,
        image_path: str,
        prompt: str,
        seed: int,
    ) -> list[Image.Image]:
        """Run one inference, materialize frames as PIL. Caller holds `self._lock`.

        Replicates ``DistilledPipeline.__call__``'s flow but builds the
        transformer ONCE per request via ``stage.model_context()`` and runs
        both stages with ``stage.run(transformer, ...)`` — upstream's
        ``stage(...)`` builds and tears down the transformer on each call,
        which empirically dominates latency (~7-8s of the 25s steady-state
        spent on per-stage build/teardown, vs ~1.5s on actual denoising math).
        Reusing the transformer across stage 1 + stage 2 cuts that overhead
        in half within a single request.

        Also wraps everything in ``torch.inference_mode()`` — required to
        prevent autograd from retaining fp8_cast's per-matmul BF16 upcast
        tensors and OOMing on H100 80GB.
        """
        from ltx_core.components.noisers import GaussianNoiser
        from ltx_pipelines.utils.args import ImageConditioningInput
        from ltx_pipelines.utils.constants import DISTILLED_SIGMAS, STAGE_2_DISTILLED_SIGMAS
        from ltx_pipelines.utils.denoisers import SimpleDenoiser
        from ltx_pipelines.utils.gpu_model import gpu_model
        from ltx_pipelines.utils.helpers import assert_resolution, combined_image_conditionings
        from ltx_pipelines.utils.types import ModalitySpec

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
        # Step 2 fail-fast: if the persistent transformer wasn't built (load
        # failed, or shutdown was called), don't silently fall back to a
        # per-request rebuild. Either we serve from a healthy persistent
        # transformer or we surface the failure to the orchestrator.
        if self._transformer is None or not self._persistent_transformer_ready:
            raise RuntimeError(
                "persistent transformer not initialized — pod should not have reached _ready=True"
            )

        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
            # Capture resident baseline at request start so request_peak_delta_gb
            # measures only this request's incremental allocation. After Step 2
            # the resident baseline is ~22 GiB (transformer); after Step 3 it
            # will be ~46 GiB (transformer + Gemma + processor). Without the
            # delta, peak_alloc would always look "huge" and we couldn't tell
            # whether a request leaked extra memory on top of the baseline.
            self._resident_alloc_gb_at_request_start = (
                torch.cuda.memory_allocated() / (1024**3)
            )
        self._inference_timings.clear()

        pipe = self.pipe
        width = config.LTX_WIDTH
        height = config.LTX_HEIGHT
        num_frames = config.LTX_NUM_FRAMES
        frame_rate = float(config.LTX_FPS)
        assert_resolution(height=height, width=width, is_two_stage=True)

        if torch.cuda.is_available():
            torch.cuda.synchronize()
        t_pipe = time.perf_counter()
        frames: list[Image.Image] = []

        with torch.inference_mode():
            # Step 3 — Use persistent Gemma + embeddings_processor when
            # available. Falls back to per-request build if
            # LTX_PERSIST_GEMMA=0 (env kill switch for fast rollback).
            #
            # Field naming (parallel to Step 2's stage_build_runtime):
            #   prompt_encoder_build_runtime      ≈ 0ms post-Step-3
            #   embeddings_processor_build_runtime ≈ 0ms post-Step-3
            # The one-time build costs are exposed via
            # persistent_gemma_build_ms / persistent_embeddings_processor_build_ms
            # on /health.
            prompt_enc = pipe.prompt_encoder
            if self._persistent_gemma_ready and self._text_encoder is not None:
                # Persistent path — no rebuild, no teardown.
                with self._timed("prompt_encoder_build_runtime"):
                    text_encoder = self._text_encoder
                with self._timed("prompt_encoder_encode"):
                    raw_outputs = [text_encoder.encode(prompt)]
                with self._timed("embeddings_processor_build_runtime"):
                    embeddings_processor = self._embeddings_processor
                with self._timed("embeddings_processor_run"):
                    proc_outputs = [
                        embeddings_processor.process_hidden_states(hs, mask)
                        for hs, mask in raw_outputs
                    ]
            else:
                # Legacy per-request path (kill-switch off, or build failed).
                # Same pattern as pre-Step-3 — kept so disabling persistence
                # via env doesn't break the pod.
                with self._timed("prompt_encoder_build"):
                    text_encoder_ctx = prompt_enc._text_encoder_ctx()
                    text_encoder = text_encoder_ctx.__enter__()
                try:
                    with self._timed("prompt_encoder_encode"):
                        raw_outputs = [text_encoder.encode(prompt)]
                finally:
                    text_encoder_ctx.__exit__(None, None, None)
                with self._timed("embeddings_processor"):
                    ep_builder = prompt_enc._embeddings_processor_builder
                    ep_model = ep_builder.build(
                        device=prompt_enc._device, dtype=prompt_enc._dtype
                    ).to(prompt_enc._device).eval()
                    with gpu_model(ep_model) as embeddings_processor:
                        proc_outputs = [
                            embeddings_processor.process_hidden_states(hs, mask)
                            for hs, mask in raw_outputs
                        ]
            (ctx_p,) = proc_outputs
            video_context, audio_context = ctx_p.video_encoding, ctx_p.audio_encoding

            generator = torch.Generator(device=pipe.device).manual_seed(seed)
            noiser = GaussianNoiser(generator=generator)
            stage_1_sigmas = DISTILLED_SIGMAS.to(dtype=torch.float32, device=pipe.device)
            stage_2_sigmas = STAGE_2_DISTILLED_SIGMAS.to(dtype=torch.float32, device=pipe.device)
            stage_1_w, stage_1_h = width // 2, height // 2

            with self._timed("image_conditioner"):
                stage_1_conditionings = pipe.image_conditioner(
                    lambda enc: combined_image_conditionings(
                        images=images,
                        height=stage_1_h,
                        width=stage_1_w,
                        video_encoder=enc,
                        dtype=torch.bfloat16,
                        device=pipe.device,
                    )
                )

            # Step 2 — Reuse the persistent transformer built once at load().
            # `stage_build_runtime` should be ~0ms after Step 2 lands; the
            # one-time build cost is exposed separately as
            # `persistent_transformer_build_ms` on /health.
            #
            # Pre-Step-2 (Round 1): `stage_build` here was the per-request
            # build cost (~63s on cold-cache hosts). Now it just measures
            # the cost of reusing — should be near-zero.
            #
            # Renamed from `stage_build` to `stage_build_runtime` so a value
            # of 0ms unambiguously means "no rebuild this request" rather
            # than "no transformer exists" (which is what Round-1's
            # untimed-model-context bug looked like).
            with self._timed("stage_build_runtime"):
                transformer = self._transformer
            try:
                with self._timed("stage_1_denoise"):
                    video_state, audio_state = pipe.stage.run(
                        transformer,
                        denoiser=SimpleDenoiser(video_context, audio_context),
                        sigmas=stage_1_sigmas,
                        noiser=noiser,
                        width=stage_1_w,
                        height=stage_1_h,
                        frames=num_frames,
                        fps=frame_rate,
                        video=ModalitySpec(
                            context=video_context,
                            conditionings=stage_1_conditionings,
                        ),
                        audio=ModalitySpec(context=audio_context),
                    )

                with self._timed("upsampler"):
                    upscaled_video_latent = pipe.upsampler(video_state.latent[:1])

                with self._timed("image_conditioner"):
                    stage_2_conditionings = pipe.image_conditioner(
                        lambda enc: combined_image_conditionings(
                            images=images,
                            height=height,
                            width=width,
                            video_encoder=enc,
                            dtype=torch.bfloat16,
                            device=pipe.device,
                        )
                    )

                with self._timed("stage_2_denoise"):
                    video_state, audio_state = pipe.stage.run(
                        transformer,
                        denoiser=SimpleDenoiser(video_context, audio_context),
                        sigmas=stage_2_sigmas,
                        noiser=noiser,
                        width=width,
                        height=height,
                        frames=num_frames,
                        fps=frame_rate,
                        video=ModalitySpec(
                            context=video_context,
                            conditionings=stage_2_conditionings,
                            noise_scale=stage_2_sigmas[0].item(),
                            initial_latent=upscaled_video_latent,
                        ),
                        audio=ModalitySpec(
                            context=audio_context,
                            noise_scale=stage_2_sigmas[0].item(),
                            initial_latent=audio_state.latent,
                        ),
                    )
            finally:
                # No teardown — transformer is persistent. `stage_teardown`
                # remains in the schema (timed at ~0) so log structure is
                # unchanged for downstream parsers.
                with self._timed("stage_teardown"):
                    pass

            with self._timed("video_decoder_call"):
                decoded_video = pipe.video_decoder(
                    video_state.latent, self._tiling_config, generator
                )

            # Tensor iterator → PIL list. The iterator drives the video VAE
            # decoder, which is also part of inference and must run inside
            # the inference_mode context. Each chunk is (F, H, W, 3) uint8
            # RGB (per ltx_pipelines.utils.media_io.encode_video which feeds
            # the same tensor straight into PyAV with format="rgb24").
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            t_decode = time.perf_counter()
            t_pil = 0.0
            for chunk in decoded_video:
                chunk_cpu = chunk.to("cpu")
                if chunk_cpu.dtype != torch.uint8:
                    # Defensive: float tensors get clamped + scaled.
                    # Shouldn't happen for the ltx-pipelines decoder, but
                    # guards against a silent regression if upstream changes
                    # the output dtype.
                    chunk_cpu = (chunk_cpu.clamp(0, 1) * 255).to(torch.uint8)
                arr = chunk_cpu.numpy()
                t_pil_start = time.perf_counter()
                for frame_arr in arr:
                    frames.append(Image.fromarray(frame_arr, mode="RGB"))
                t_pil += time.perf_counter() - t_pil_start
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            self._inference_timings["video_decoder_iter"].append(
                int((time.perf_counter() - t_decode) * 1000)
            )
            self._inference_timings["pil_conversion"].append(int(t_pil * 1000))

        if torch.cuda.is_available():
            torch.cuda.synchronize()
        pipe_total_ms = int((time.perf_counter() - t_pipe) * 1000)
        self._inference_timings["pipe_total"].append(pipe_total_ms)

        # Compute unattributed time: pipe_total minus the sum of every named
        # phase. Catches measurement gaps like Round 1's `model_context()`
        # call site that lived between two timer blocks. Acceptance target:
        # under ~300ms or explicitly explained.
        named_total = sum(
            sum(vs) for name, vs in self._inference_timings.items() if name != "pipe_total"
        )
        unattributed_ms = pipe_total_ms - named_total
        self._inference_timings["unattributed"].append(unattributed_ms)

        if torch.cuda.is_available():
            # Peak allocated alone hides allocator fragmentation. Reserved
            # (cached but not in use) and free (whatever the driver still
            # has unallocated) are independent signals — needed once we
            # hold the transformer (and later Gemma) resident across calls.
            #
            # `resident_alloc` = baseline at start of request (typically the
            # persistent transformer's ~22 GiB after Step 2, and ~46 GiB
            # after Step 3). `request_peak_delta` = peak - resident, the
            # actual incremental memory this request needed on top of the
            # persistent baseline. Without the delta, a per-request leak
            # would be invisible against the resident baseline.
            free_b, _ = torch.cuda.mem_get_info()
            peak_alloc_gb = torch.cuda.max_memory_allocated() / (1024**3)
            request_peak_delta_gb = peak_alloc_gb - self._resident_alloc_gb_at_request_start
            logger.info(
                "LTX VRAM GiB: peak_alloc=%.2f peak_reserved=%.2f "
                "now_alloc=%.2f now_reserved=%.2f free=%.2f "
                "resident_alloc=%.2f request_peak_delta=%.2f",
                peak_alloc_gb,
                torch.cuda.max_memory_reserved() / (1024**3),
                torch.cuda.memory_allocated() / (1024**3),
                torch.cuda.memory_reserved() / (1024**3),
                free_b / (1024**3),
                self._resident_alloc_gb_at_request_start,
                request_peak_delta_gb,
            )

        # Phase breakdown — single line, easy to scan in pod logs. Lists for
        # phases called twice per inference (image_conditioner stage 1+2,
        # transformer stage 1+2). `unattributed` should be small if the
        # named phases are accounted for; large value ⇒ measurement gap.
        timings_summary = " ".join(
            f"{name}={vs[0] if len(vs) == 1 else vs}"
            for name, vs in sorted(self._inference_timings.items())
        )
        logger.info("LTX phase timings ms: %s", timings_summary)

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
            # Step 2 — persistent transformer health.
            "persistent_transformer_ready": self._persistent_transformer_ready,
            "persistent_transformer_build_ms": self._persistent_transformer_build_ms,
            "vram_after_transformer_gb": round(self._vram_after_transformer_gb, 2),
            # Step 3 — persistent Gemma + embeddings_processor health.
            "persistent_gemma_ready": self._persistent_gemma_ready,
            "persistent_gemma_build_ms": self._persistent_gemma_build_ms,
            "persistent_embeddings_processor_build_ms": self._persistent_embeddings_processor_build_ms,
            "vram_after_gemma_gb": round(self._vram_after_gemma_gb, 2),
            "vram_after_embeddings_processor_gb": round(self._vram_after_embeddings_processor_gb, 2),
        }

    def shutdown_persistent_models(self) -> None:
        """Release persistent models on graceful shutdown. Idempotent — safe to
        call zero, one, or multiple times.

        Hooked into FastAPI's lifespan exit in ``video_server.py``. Covers
        ``railway up`` redeploys and orchestrator-initiated ``podTerminate``
        within the docker grace window. Ungraceful kills (SIGKILL after
        grace timeout) skip this entirely; that's fine because the GPU is
        torn down with the container.

        Releases in reverse build order: embeddings_processor → Gemma →
        transformer. Each block tolerates being already-None so partial
        builds (e.g., transformer succeeded but Gemma failed) shut down
        cleanly. After each successful exit the corresponding refs are
        cleared so a subsequent call is a no-op.
        """
        # Step 3 — release embeddings_processor first.
        if self._embeddings_processor_ctx is not None:
            try:
                logger.info("LTX-2.3 releasing persistent embeddings_processor...")
                self._embeddings_processor_ctx.__exit__(None, None, None)
            except Exception as e:  # noqa: BLE001
                logger.warning("Error during persistent embeddings_processor shutdown: %s", e)
            finally:
                self._embeddings_processor_ctx = None
                self._embeddings_processor = None

        # Step 3 — release Gemma text encoder.
        if self._text_encoder_ctx is not None:
            try:
                logger.info("LTX-2.3 releasing persistent Gemma text encoder...")
                self._text_encoder_ctx.__exit__(None, None, None)
            except Exception as e:  # noqa: BLE001
                logger.warning("Error during persistent Gemma shutdown: %s", e)
            finally:
                self._text_encoder_ctx = None
                self._text_encoder = None
                self._persistent_gemma_ready = False

        # Step 2 — release transformer.
        if self._transformer_ctx is not None:
            try:
                logger.info("LTX-2.3 releasing persistent transformer...")
                self._transformer_ctx.__exit__(None, None, None)
            except Exception as e:  # noqa: BLE001
                logger.warning("Error during persistent transformer shutdown: %s", e)
            finally:
                self._transformer_ctx = None
                self._transformer = None
                self._persistent_transformer_ready = False
