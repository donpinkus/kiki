"""LTX-2.5 image-to-video pipeline (ltx-pipelines Distilled / DFR, FP8-cast, H100 SXM).

Upgraded 2026-09-10 from the LTX-2.3 monolith checkpoint + hand-rolled
persistent-transformer path. Two things changed upstream that let this file
get SIMPLER than its predecessor:

1. **Split checkpoints + bundled Gemma 4.** LTX-2.5 ships one safetensors per
   component (`ModelPaths.from_split`), and the text encoder file embeds its
   own config + tokenizer, so nothing here touches the HF hub at runtime.
2. **Registry-backed residency.** ltx-pipelines blocks build a model per
   call and dispose it afterwards, but with
   ``ModelRegistry(cache_weights=True, cache_models=True)`` the loader keeps
   every (quantized) state dict ON THE GPU and re-attaches it to a cached
   model shell with ``load_state_dict(assign=True)`` — a zero-copy rebuild.
   So the official ``pipeline(...)`` call runs at steady-state speed after
   warmup, with ~48 GiB resident (FP8 transformer 22 GiB + Gemma 4 24 GiB +
   VAEs/upscaler), and we no longer replicate ``DistilledPipeline.__call__``
   to hold a transformer open. That also makes the DFR pipeline (generated
   keyframe slots + IC-LoRA spatial detailing pass) a config switch instead
   of a second port.

Pipelines (``LTX_PIPELINE``):
- ``distilled`` — 8 sigmas stage 1 (ancestral Euler on 2.5 checkpoints) +
  3 sigmas stage 2 after a 2x latent upsample. Fastest.
- ``dfr`` — Diffusion Fidelity Rendering: same distilled transformer, stage 1
  also generates keyframe slots, stage 2 re-denoises at full res with the
  detailing IC-LoRA (strength 0.5, fused per call) + the half-res video as
  IC reference. Production quality per Lightricks; slower, more VRAM.

Output: ``result.video`` is an iterator of float ``[0,1]`` ``(F,H,W,3)``
chunks (the VAE decoder runs lazily as it is consumed); we convert to PIL so
video/server.py can stream JPEGs + mux the MP4 unchanged. ``result.audio``
is an ``ltx_core.types.Audio`` (waveform + sampling_rate).

License note: LTX-2.x weights are released under the LTX-2.x Community
License (https://github.com/Lightricks/LTX-2/blob/main/LICENSE), NOT
Apache-2.0. Free commercial use under $10M annual revenue; verify before any
App Store rollout.
"""
from __future__ import annotations

import contextlib
import json
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
from torch.profiler import record_function

from shared import config
# Shared helper so both pods stamp the same /workspace/app/.version.json onto
# /health for drift detection by the orchestrator.
from shared.app_version import load_app_version

logger = logging.getLogger(__name__)

# Process-start marker for /health's boot decomposition (provision vs OS vs
# our stack, computed by the backend pool's ready event). Module import runs
# within seconds of exec, so this is "process start" to the precision the
# waterfall needs.
_STARTED_AT_EPOCH_S = int(time.time())

# Parallel reads issued against the network volume during weight prefetch.
# 8 saturates Lambda NFS (~1.3 GB/s measured on the image pod with the same
# worker count, 2026-08-22); the un-prefetched load path reads the same bytes
# at mmap speed (~250-460 MB/s observed) — this is a pure boot-time lever.
_PREFETCH_WORKERS = 8


def _booted_at_epoch_s() -> int | None:
    """Kernel boot time (epoch seconds) from /proc/uptime — the boundary
    between Lambda's VM provisioning and everything we control."""
    try:
        with open("/proc/uptime", "r") as f:
            return int(time.time() - float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return None


def _read_to_devnull(path: str) -> None:
    """Stream a file through the kernel read path so its pages land in the OS
    page cache (same pattern as image/pipeline.py's prefetch). 1 MB chunks;
    unbuffered open avoids double-copying through Python's io buffer."""
    chunk = 1 << 20
    try:
        with open(path, "rb", buffering=0) as f:
            while f.read(chunk):
                pass
    except OSError as e:
        # Never fail the boot on a prefetch error — the loaders fall back to
        # their own (slower) reads.
        logger.warning(f"Prefetch read failed for {path}: {e}", extra={"path": path})


def _resolve_hf_cache_path(repo_id: str, filename: str) -> str:
    """Resolve the local path of a single-file HF asset that was pre-cached
    via `hf_hub_download` at populate time. Pod runs offline (HF_HUB_OFFLINE=1)
    so we cannot use `hf_hub_download` again — we read directly from the
    cache with `local_files_only=True`. `filename` may carry a subdirectory
    (LTX-2.5's split layout: `vae/…`, `diffusion_models/…`)."""
    from huggingface_hub import hf_hub_download
    return hf_hub_download(repo_id=repo_id, filename=filename, local_files_only=True)


CancelState = Literal["ok", "before_start", "during_inference", "after_complete"]


@dataclass
class Keyframe:
    """A conditioning image pinned to a position in the output video.

    ``position`` is a 0.0–1.0 fraction of the video duration; it is resolved
    to a concrete frame index at generate() time (after num_frames is known)
    and snapped to the latent temporal grid (multiples of 8 — the same rule
    behind the (num_frames - 1) % 8 == 0 constraint, so position 1.0 lands
    exactly on the final frame).
    """

    image: Image.Image
    position: float = 0.0
    strength: float = 1.0


@dataclass
class GeneratedAudio:
    """PCM audio decoded from LTX's audio latent."""

    pcm_s16le: bytes
    sample_rate: int
    channels: int


@dataclass
class GenerateResult:
    """Outcome of a single ``generate()`` call.

    Carries enough to differentiate ``before_start`` (cheap), ``after_complete``
    (the wasted-GPU pattern, ~pipe_total_ms wasted per cancel), and
    ``during_inference`` (reserved; the official pipelines expose no
    mid-denoise callback).
    """

    frames: list[Image.Image] | None
    audio: GeneratedAudio | None
    cancel_state: CancelState
    lock_wait_ms: int
    pipe_total_ms: int
    cancelled_but_ran_ms: int


def _decoded_audio_to_pcm_s16le(decoded_audio: object, sample_rate: int) -> GeneratedAudio | None:
    """Normalize LTX decoded audio to interleaved signed 16-bit PCM."""
    if decoded_audio is None:
        return None
    if isinstance(decoded_audio, (list, tuple)):
        if not decoded_audio:
            return None
        decoded_audio = decoded_audio[0]
    # `pipe.audio_decoder(latent)` returns an `ltx_core.types.Audio` frozen
    # dataclass with `.waveform: torch.Tensor` and `.sampling_rate: int`.
    # Duck-type for `.waveform` so a raw tensor works too. The Audio's own
    # sampling_rate is the vocoder's authoritative output rate — prefer it
    # over the caller's default when present.
    waveform_attr = getattr(decoded_audio, "waveform", None)
    if isinstance(waveform_attr, torch.Tensor):
        rate_attr = getattr(decoded_audio, "sampling_rate", None)
        if isinstance(rate_attr, int) and rate_attr > 0:
            sample_rate = rate_attr
        decoded_audio = waveform_attr
    if not isinstance(decoded_audio, torch.Tensor):
        decoded_audio = torch.as_tensor(decoded_audio)

    audio = decoded_audio.detach().to("cpu")
    if audio.numel() == 0:
        return None
    audio = audio.float()

    while audio.dim() > 2 and audio.shape[0] == 1:
        audio = audio.squeeze(0)
    if audio.dim() == 0:
        return None
    if audio.dim() == 1:
        audio = audio.unsqueeze(0)
    elif audio.dim() == 2:
        # Normalize to (channels, samples). Decoder outputs are expected to be
        # channel-first, but accept common (samples, channels) tensors too.
        if audio.shape[0] > audio.shape[1] and audio.shape[1] <= 8:
            audio = audio.transpose(0, 1)
    else:
        audio = audio.reshape(-1, audio.shape[-1])

    if audio.shape[0] > 8:
        logger.warning(
            f"decoded audio has unexpected channel count {audio.shape[0]}; "
            f"using first channel",
            extra={"channel_count": int(audio.shape[0])},
        )
        audio = audio[:1]

    audio = torch.nan_to_num(audio, nan=0.0, posinf=1.0, neginf=-1.0).clamp(-1.0, 1.0)
    pcm = (audio.transpose(0, 1).contiguous().numpy() * 32767.0).astype("<i2").tobytes()
    return GeneratedAudio(
        pcm_s16le=pcm,
        sample_rate=sample_rate,
        channels=int(audio.shape[0]),
    )


class CancelledError(Exception):
    """Raised when the backend cancels mid-pipeline. NOTE: the official
    pipelines expose no mid-inference cancellation hook (no step callback).
    Cancellation is checked at start-of-generate only; if cancellation
    arrives during inference, the GPU keeps running to completion and the
    result is discarded by the caller. Acceptable cost (~10-40s wasted GPU
    time per cancelled generation) versus forking the denoising loops.
    """


class Ltx25VideoPipeline:
    """Wraps ``ltx_pipelines.DistilledPipeline`` / ``DFRPipeline`` for the
    Animate screen.

    Single-instance, single-GPU. Calls are serialized through `_lock` so the
    WebSocket layer can fire-and-forget without worrying about overlap.
    """

    def __init__(self) -> None:
        self.pipe = None
        self._registry = None
        self._ready = False
        self._lock = threading.Lock()
        self._load_ms: int = 0
        # Per-substage warmup timings + model-servers tree-hash version
        # exposed via /health. Mirrors the image pipeline so the orchestrator's
        # drift detection and substage observability work identically for
        # both pod kinds.
        self._phase_timings: dict[str, int] = {}
        # Per-inference phase timings (CUDA-synced ms). Reset at the start of
        # _run_inference; each phase wrapper appends.
        self._inference_timings: dict[str, list[int]] = defaultdict(list)
        # Resident VRAM after warmup = everything the registry keeps on the
        # GPU (the steady-state baseline every request builds on top of).
        self._resident_vram_gb: float = 0.0
        self._resident_alloc_gb_at_request_start: float = 0.0
        self._pipeline_name = config.LTX_PIPELINE
        self._resolved_paths: dict[str, str] = {}
        self._app_version = load_app_version()

    @property
    def ready(self) -> bool:
        return self._ready

    @contextmanager
    def _timed(self, name: str) -> Iterator[None]:
        """Context manager that records CUDA-synced wall-clock for a phase.

        ``torch.cuda.synchronize()`` before AND after is required because
        PyTorch dispatches kernels asynchronously — without sync, the timer
        captures kernel-launch time rather than completion time. Also emits a
        ``torch.profiler.record_function(name)`` annotation (no-op without an
        active profiler).
        """
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        t0 = time.perf_counter()
        try:
            with record_function(name):
                yield
        finally:
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            self._inference_timings[name].append(int((time.perf_counter() - t0) * 1000))

    def _spawn_weight_prefetch(self, files: list[str]) -> threading.Thread | None:
        """Warm the OS page cache for the given weight files with
        _PREFETCH_WORKERS parallel readers. Records prefetch_total_ms /
        prefetch_bytes_mb into phase timings. Returns the joinable
        coordinator thread, or None if nothing to read."""
        sized = []
        for p in files:
            try:
                real = os.path.realpath(p)
                if os.path.isfile(real):
                    sized.append((os.path.getsize(real), real))
            except OSError:
                continue
        if not sized:
            logger.warning("Weight prefetch found no readable files; skipping")
            return None
        # Largest first so the big transformer starts streaming immediately.
        sized.sort(reverse=True)
        total_bytes = sum(s for s, _ in sized)
        self._phase_timings["prefetch_workers"] = _PREFETCH_WORKERS
        self._phase_timings["prefetch_bytes_mb"] = total_bytes >> 20
        logger.info(
            f"Prefetching {len(sized)} files ({total_bytes / (1 << 30):.1f} GB) "
            f"into page cache ({_PREFETCH_WORKERS} workers)...",
            extra={"prefetch_files": len(sized), "prefetch_bytes_mb": total_bytes >> 20},
        )
        phase_timings = self._phase_timings

        def worker() -> None:
            from concurrent.futures import ThreadPoolExecutor

            t0 = time.time()
            with ThreadPoolExecutor(max_workers=_PREFETCH_WORKERS) as pool:
                list(pool.map(_read_to_devnull, [p for _, p in sized]))
            elapsed_ms = int((time.time() - t0) * 1000)
            phase_timings["prefetch_total_ms"] = elapsed_ms
            logger.info(
                f"Prefetch complete in {elapsed_ms / 1000:.1f}s",
                extra={"prefetch_total_ms": elapsed_ms},
            )

        thread = threading.Thread(target=worker, name="weight-prefetch", daemon=True)
        thread.start()
        return thread

    def load(self) -> None:
        logger.info(
            f"Loading {config.LTX_MODEL_FAMILY} ({self._pipeline_name}): "
            f"transformer={config.LTX_MODEL_REPO}/{config.LTX_MODEL_FILE} "
            f"text_encoder={config.LTX_TEXT_ENCODER_FILE} "
            f"video_vae={config.LTX_VIDEO_VAE_FILE} "
            f"quantization={config.LTX_QUANTIZATION}",
            extra={
                "model_family": config.LTX_MODEL_FAMILY,
                "pipeline": self._pipeline_name,
                "model_repo": config.LTX_MODEL_REPO,
                "model_file": config.LTX_MODEL_FILE,
                "text_encoder_file": config.LTX_TEXT_ENCODER_FILE,
                "video_vae_file": config.LTX_VIDEO_VAE_FILE,
                "quantization": config.LTX_QUANTIZATION,
            },
        )
        t0 = time.time()

        # Resolve pre-populated paths from the offline HF cache FIRST (needs
        # only huggingface_hub, not the slow ltx imports) so the weight
        # prefetch below can overlap everything that follows. Pod is
        # HF_HUB_OFFLINE=1; populate script ran these as online downloads.
        t_phase = time.time()
        paths = {
            "transformer": _resolve_hf_cache_path(config.LTX_MODEL_REPO, config.LTX_MODEL_FILE),
            "text_encoder": _resolve_hf_cache_path(config.LTX_MODEL_REPO, config.LTX_TEXT_ENCODER_FILE),
            "video_vae": _resolve_hf_cache_path(config.LTX_MODEL_REPO, config.LTX_VIDEO_VAE_FILE),
            "audio_vae": _resolve_hf_cache_path(config.LTX_MODEL_REPO, config.LTX_AUDIO_VAE_FILE),
            "spatial_upscaler": _resolve_hf_cache_path(
                config.LTX_SPATIAL_UPSCALER_REPO, config.LTX_SPATIAL_UPSCALER_FILE
            ),
        }
        if self._pipeline_name == "dfr":
            paths["detailing_lora"] = _resolve_hf_cache_path(
                config.LTX_DETAILING_LORA_REPO, config.LTX_DETAILING_LORA_FILE
            )
        self._resolved_paths = paths
        resolve_paths_ms = int((time.time() - t_phase) * 1000)
        self._phase_timings["resolve_paths_ms"] = resolve_paths_ms
        logger.info(
            f"Resolved offline paths in {resolve_paths_ms / 1000:.1f}s: "
            + " ".join(f"{k}={v}" for k, v in paths.items()),
            extra={"resolve_paths_ms": resolve_paths_ms, **{f"path_{k}": v for k, v in paths.items()}},
        )

        # Page-cache prefetch of ALL weights (~66 GB: 39 GB BF16 transformer +
        # 24 GB Gemma 4 + VAEs/upscaler/LoRA) with parallel readers,
        # overlapping the ltx imports below. Without it the builds read the
        # same bytes single-file at mmap speed.
        prefetch_thread = self._spawn_weight_prefetch(list(paths.values()))

        # Imports gated to load() so that startup failures (missing weights,
        # ImportError on ltx_core/ltx_pipelines) surface in the loader log
        # rather than at module import time. These read the ltx_*/torch
        # packages off the network-volume venv, so on a cold volume this block
        # can block on NFS for minutes.
        t_imports = time.time()
        from ltx_core.allocator_trim_strategy import AllocatorTrimStrategy
        from ltx_core.loader import LTXV_LORA_COMFY_RENAMING_MAP, LoraPathStrengthAndSDOps
        from ltx_core.loader.registry import ModelRegistry
        from ltx_core.model.transformer.compiling import CompilationConfig
        from ltx_core.model.video_vae.transformer import DiffVAEMode
        from ltx_core.quantization.fp8_cast import build_policy as build_fp8_cast_policy
        from ltx_pipelines.utils.model_paths import ModelPaths
        from ltx_pipelines.utils.types import OffloadMode
        if self._pipeline_name == "dfr":
            from ltx_pipelines.dfr_pipeline import DFRPipeline as PipelineCls
        else:
            from ltx_pipelines.distilled import DistilledPipeline as PipelineCls
        imports_ms = int((time.time() - t_imports) * 1000)
        self._phase_timings["imports_ms"] = imports_ms
        logger.info(
            f"{config.LTX_MODEL_FAMILY} gated imports loaded in {imports_ms / 1000:.1f}s",
            extra={"imports_ms": imports_ms},
        )

        # Join the prefetch before the builds so they hit page cache instead
        # of racing it for NFS bandwidth. Large wait here = prefetch is the
        # bandwidth-bound critical path; near-zero = imports covered it.
        if prefetch_thread is not None:
            t_wait = time.time()
            prefetch_thread.join()
            self._phase_timings["prefetch_wait_ms"] = int((time.time() - t_wait) * 1000)

        # FP8 modes:
        #   cast       — Lightricks' universal-no-deps default. Stores Linear
        #                weights in FP8; upcasts to BF16 per matmul. The only
        #                mode usable with the BF16 checkpoint 2.5 ships.
        #   scaled_mm  — native FP8 matmul, but it expects an FP8 checkpoint
        #                with per-tensor scales (none published for 2.5), so
        #                requesting it here falls back to cast with a warning.
        fp8_mode = os.getenv("LTX_FP8_MODE", "cast").lower()
        if fp8_mode == "scaled_mm":
            logger.warning(
                "LTX_FP8_MODE=scaled_mm requested but LTX-2.5 ships no FP8 checkpoint — using fp8_cast"
            )
        quantization = build_fp8_cast_policy(paths["transformer"])
        offload_mode = OffloadMode(os.getenv("LTX_OFFLOAD_MODE", "none").lower())
        if offload_mode != OffloadMode.NONE:
            # Block streaming would defeat the registry residency below; the
            # H100 fits everything resident, so this is a debugging knob only.
            logger.warning(
                f"LTX_OFFLOAD_MODE={offload_mode.value}: weights streamed per call (slow); "
                f"registry residency disabled"
            )
        try:
            diffvae_mode = DiffVAEMode(config.LTX_DIFFVAE_MODE)
        except ValueError:
            logger.warning(
                f"Unknown LTX_DIFFVAE_MODE={config.LTX_DIFFVAE_MODE!r}; using chunked_eager"
            )
            diffvae_mode = DiffVAEMode.CHUNKED_EAGER

        # The registry is what makes serving fast: it retains every loaded
        # (quantized) state dict on the GPU and the structural model shells,
        # so each block's per-call "build" becomes assign-only and "dispose"
        # only metas the shell's params (the cached tensors stay). DEFER skips
        # the sync + empty_cache trim between blocks — no reason to return
        # cached allocator blocks to the driver between requests on a
        # dedicated card.
        self._registry = ModelRegistry(
            cache_weights=offload_mode == OffloadMode.NONE, cache_models=True
        )
        model_paths = ModelPaths.from_split(
            transformer_path=paths["transformer"],
            text_encoder_path=paths["text_encoder"],
            video_vae_path=paths["video_vae"],
            audio_vae_path=paths["audio_vae"],
            # No duration head: every request carries an explicit frame count.
            duration_head_path=None,
        )
        logger.info(
            f"LTX quantization=fp8_cast offload_mode={offload_mode.value} "
            f"diffvae={diffvae_mode.value} pipeline={self._pipeline_name}",
            extra={
                "quantization": "fp8_cast",
                "offload_mode": offload_mode.value,
                "diffvae_mode": diffvae_mode.value,
                "pipeline": self._pipeline_name,
            },
        )

        # torch.compile on the transformer blocks (inductor, no CUDA graphs —
        # the cudagraph modes need block streaming on a single GPU). One
        # shape-polymorphic artifact serves every token count, so the compile
        # is paid once at warmup. Speed-up measured 2026-09-11 (see
        # decisions.md); LTX_TORCH_COMPILE=0 falls back to eager.
        compilation_config = CompilationConfig() if config.LTX_TORCH_COMPILE else None
        # Attention backend: ltx-core's AUTOMATIC picks FlashAttention 3 on
        # Hopper when the `flash_attn_3` wheel is importable, else torch SDPA.
        try:
            import flash_attn_interface  # noqa: F401
            self._attention_backend = "flash_attn_3"
        except Exception:  # noqa: BLE001
            self._attention_backend = "sdpa"
        logger.info(
            f"LTX attention={self._attention_backend} torch_compile={bool(compilation_config)}",
            extra={"attention": self._attention_backend, "torch_compile": bool(compilation_config)},
        )

        t_phase = time.time()
        common = dict(
            model_paths=model_paths,
            spatial_upsampler_path=paths["spatial_upscaler"],
            loras=[],
            quantization=quantization,
            registry=self._registry,
            compilation_config=compilation_config,
            offload_mode=offload_mode,
            alloc_trim_strategy=AllocatorTrimStrategy.DEFER,
            diffvae_optimization=diffvae_mode,
        )
        if self._pipeline_name == "dfr":
            # Strength is overridden to 0.5 inside DFRPipeline (hardcoded
            # upstream); the value here is ignored but must be present.
            detailing = [
                LoraPathStrengthAndSDOps(paths["detailing_lora"], 1.0, LTXV_LORA_COMFY_RENAMING_MAP)
            ]
            self.pipe = PipelineCls(detailing_lora=detailing, temporal_upsampler_path=None, **common)
        else:
            self.pipe = PipelineCls(**common)

        if self._pipeline_name == "dfr" and config.LTX_DFR_PLAIN_DECODE:
            # Experiment knob: DFR normally keyframe-anchors the final decode
            # (`decode_video(keyframes=)`), which runs the DiffVAE eager and
            # uncompiled whatever LTX_DIFFVAE_MODE says. Dropping the
            # keyframes turns it into the plain (compilable, natten-capable)
            # decode at the cost of the anchoring.
            self.pipe.video_decoder = _PlainDecodeProxy(self.pipe.video_decoder)
            logger.info("LTX_DFR_PLAIN_DECODE=1 — DFR final decode runs WITHOUT keyframe anchoring")

        if config.LTX_ENABLE_AUDIO:
            logger.info("LTX audio enabled — decoded audio will be muxed into completed MP4s")
        else:
            logger.info("LTX_ENABLE_AUDIO=0 — video MP4s will be silent")

        self._phase_timings["pipeline_init_ms"] = int((time.time() - t_phase) * 1000)
        logger.info(
            f"{config.LTX_MODEL_FAMILY} pipeline object built in {time.time() - t_phase:.1f}s "
            f"(weights load lazily on the warmup call)",
        )

        # Warmup — the first call reads every weight file into the registry
        # (the ~66 GB the prefetch just paged in), builds the model shells,
        # and pays the lazy CUDA kernel / Triton compiles. After it, every
        # request runs the steady-state path, so the user-visible first video
        # latency is clean.
        # Warm every duration preset the iPad sends (LTX_WARMUP_FRAMES), so
        # per-shape Triton autotune / inductor guards are paid at boot, not
        # on a user's first 2 s or 4 s clip. Largest first: it also loads
        # the weights into the registry.
        warm_frames = config.LTX_WARMUP_FRAMES
        logger.info(
            f"{config.LTX_MODEL_FAMILY} warmup ({config.LTX_WIDTH}x{config.LTX_HEIGHT} x frames={warm_frames})..."
        )
        t1 = time.time()
        warmup_image = Image.new("RGB", (config.LTX_WIDTH, config.LTX_HEIGHT), (128, 128, 128))
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            warmup_path = f.name
            warmup_image.save(warmup_path, format="PNG")
        try:
            with self._lock:
                for i, frames in enumerate(warm_frames):
                    t_shape = time.time()
                    _ = self._run_inference(
                        conditioning_paths=[(warmup_path, 0, 1.0)],
                        prompt="warmup",
                        seed=0,
                        width=config.LTX_WIDTH,
                        height=config.LTX_HEIGHT,
                        num_frames=frames,
                    )
                    self._phase_timings[f"warmup_{frames}f_ms"] = int((time.time() - t_shape) * 1000)
                    if i == 0 and torch.cuda.is_available():
                        self._resident_vram_gb = torch.cuda.memory_allocated() / (1024**3)
        finally:
            try:
                os.unlink(warmup_path)
            except OSError:
                pass
        self._phase_timings["warmup_inference_ms"] = int((time.time() - t1) * 1000)
        if torch.cuda.is_available():
            self._resident_vram_gb = torch.cuda.memory_allocated() / (1024**3)
        logger.info(
            f"{config.LTX_MODEL_FAMILY} warmup done ({time.time() - t1:.1f}s, "
            f"resident_vram={self._resident_vram_gb:.2f} GiB)",
            extra={
                "warmup_s": round(time.time() - t1, 1),
                "resident_vram_gb": round(self._resident_vram_gb, 2),
            },
        )

        self._load_ms = int((time.time() - t0) * 1000)
        self._ready = True

    def generate(
        self,
        image: Image.Image | None,
        prompt: str,
        seed: int | None,
        is_cancelled: Callable[[], bool],
        *,
        keyframes: list[Keyframe] | None = None,
        width: int | None = None,
        height: int | None = None,
        num_frames: int | None = None,
        profile: bool = False,
        prompt_suffix: str | None = None,
        enable_audio: bool = True,
    ) -> "GenerateResult":
        """Generate a video from `image`+`prompt`. Returns a ``GenerateResult``
        with `frames` (or None if cancelled), optional decoded `audio`,
        `cancel_state`, `lock_wait_ms`, `pipe_total_ms`, and
        `cancelled_but_ran_ms`.

        Per-call overrides for `width`, `height`, `num_frames`: when None (the
        default — what the WebSocket path does), falls back to
        ``config.LTX_WIDTH`` / ``LTX_HEIGHT`` / ``LTX_NUM_FRAMES``. Resolution
        is a call-time arg on the official pipelines, so these vary per
        request without a model rebuild.

        Cancellation states:
        - ``ok``: full inference, frames returned.
        - ``before_start``: cancel arrived before lock acquired or before
          inference body started; ~0ms wasted.
        - ``after_complete``: full inference ran, frames produced, cancel
          arrived during the post-inference re-check; ~pipe_total_ms wasted.

        Keyframes (Animate screen): pass `keyframes` to condition the video
        on multiple images pinned at fractional positions (0.0 = first frame,
        1.0 = last). `image` remains as the legacy single-image path
        (equivalent to one keyframe at position 0.0). Exactly one of
        `image` / `keyframes` must be provided.
        """
        if width is None:
            width = config.LTX_WIDTH
        if height is None:
            height = config.LTX_HEIGHT
        if num_frames is None:
            num_frames = config.LTX_NUM_FRAMES
        if width % 64 != 0:
            raise ValueError(f"width must be divisible by 64 (got {width})")
        if height % 64 != 0:
            raise ValueError(f"height must be divisible by 64 (got {height})")
        if (num_frames - 1) % 8 != 0:
            raise ValueError(
                f"num_frames must satisfy (n-1) %% 8 == 0 (got {num_frames})"
            )

        # Normalize the two input shapes into one keyframe list. Positions
        # resolve to frame indices snapped to the latent temporal grid
        # (multiples of 8); (num_frames - 1) % 8 == 0 guarantees position 1.0
        # lands exactly on the final frame. Duplicate indices keep the last.
        if keyframes is None:
            if image is None:
                raise ValueError("either image or keyframes must be provided")
            keyframes = [Keyframe(image=image, position=0.0, strength=1.0)]
        elif not keyframes:
            raise ValueError("keyframes must be non-empty when provided")

        by_idx: dict[int, tuple[Image.Image, float]] = {}
        for kf in keyframes:
            pos = min(max(float(kf.position), 0.0), 1.0)
            idx = round(pos * (num_frames - 1) / 8) * 8
            idx = min(idx, num_frames - 1)
            strength = min(max(float(kf.strength), 0.0), 1.0)
            by_idx[idx] = (kf.image, strength)
        resolved = sorted(by_idx.items())

        if is_cancelled():
            logger.info("LTX generate skipped — cancelled before start")
            return GenerateResult(
                frames=None, audio=None, cancel_state="before_start",
                lock_wait_ms=0, pipe_total_ms=0, cancelled_but_ran_ms=0,
            )

        # Resolve seed: if caller didn't specify, generate a fresh random one.
        # The pipelines require `seed: int`, not Optional.
        if seed is None:
            seed = int.from_bytes(os.urandom(4), byteorder="little") & 0x7FFFFFFF

        # Image conditioning is path-based in ltx-pipelines. Write each
        # keyframe image to a tempfile, pass (path, frame_idx, strength),
        # clean up after. PNG (lossless): upstream's preprocessing pass
        # re-encodes the image at the model's training CRF unless the caller
        # passes crf=0 (see _run_inference). For sparse line drawings from
        # the iPad, a lossy round-trip visibly damages thin strokes.
        conditioning_paths: list[tuple[str, int, float]] = []
        for idx, (kf_image, strength) in resolved:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
                kf_image.save(f.name, format="PNG")
                conditioning_paths.append((f.name, idx, strength))
        t_lock_request = time.perf_counter()
        try:
            with self._lock:
                lock_wait_ms = int((time.perf_counter() - t_lock_request) * 1000)
                # Re-check cancellation immediately after acquiring the lock:
                # the check at the top can be stale by ~lock_wait_ms.
                if is_cancelled():
                    logger.info(
                        f"LTX generate cancelled after acquiring lock (lock_wait_ms={lock_wait_ms})",
                        extra={"lock_wait_ms": lock_wait_ms},
                    )
                    return GenerateResult(
                        frames=None, audio=None, cancel_state="before_start",
                        lock_wait_ms=lock_wait_ms, pipe_total_ms=0, cancelled_but_ran_ms=0,
                    )
                base = (prompt or "").strip()
                suffix = (prompt_suffix or "").strip()
                if base and suffix:
                    if base[-1] not in ".!?":
                        base += "."
                    final_prompt = f"{base} {suffix}"
                else:
                    final_prompt = base or suffix
                logger.info(
                    f"LTX prompt: user='{base[:80]}' suffix='{suffix[:80]}' final='{final_prompt[:200]}'",
                    extra={
                        "user_prompt": base[:80],
                        "suffix": suffix[:80],
                        "final_prompt": final_prompt[:200],
                    },
                )
                frames, audio = self._run_inference(
                    conditioning_paths=conditioning_paths,
                    prompt=final_prompt,
                    seed=seed,
                    width=width,
                    height=height,
                    num_frames=num_frames,
                    profile=profile,
                    is_cancelled=is_cancelled,
                    enable_audio=enable_audio,
                )
                pipe_total_ms = self._inference_timings["pipe_total"][-1]
        finally:
            for path, _idx, _strength in conditioning_paths:
                try:
                    os.unlink(path)
                except OSError:
                    pass

        # Late cancel check: caller may have set the flag while inference was
        # running. This is the dominant wasted-GPU pattern; the classification
        # makes it visible in metrics.
        if is_cancelled():
            logger.info(
                f"LTX generate completed but cancellation arrived; discarding (wasted_ms={pipe_total_ms})",
                extra={"wasted_ms": pipe_total_ms},
            )
            return GenerateResult(
                frames=None, audio=None, cancel_state="after_complete",
                lock_wait_ms=lock_wait_ms, pipe_total_ms=pipe_total_ms,
                cancelled_but_ran_ms=pipe_total_ms,
            )

        return GenerateResult(
            frames=frames, audio=audio, cancel_state="ok",
            lock_wait_ms=lock_wait_ms, pipe_total_ms=pipe_total_ms, cancelled_but_ran_ms=0,
        )

    def _run_inference(
        self,
        conditioning_paths: list[tuple[str, int, float]],
        prompt: str,
        seed: int,
        *,
        width: int,
        height: int,
        num_frames: int,
        profile: bool = False,
        is_cancelled: Callable[[], bool] | None = None,
        enable_audio: bool = True,
    ) -> tuple[list[Image.Image], GeneratedAudio | None]:
        """Run one inference through the official pipeline, materialize
        frames/audio. Caller holds `self._lock`.

        Wraps everything in ``torch.inference_mode()`` — required to prevent
        autograd from retaining fp8_cast's per-matmul BF16 upcast tensors and
        OOMing on H100 80GB.
        """
        from ltx_core.model.video_vae import AUTO_TILING
        from ltx_pipelines.utils.args import ImageConditioningInput

        # crf=0 disables upstream's preprocessing re-encode of the conditioning
        # image (the model-matched default introduces compression artifacts on
        # sparse drawn linework, weakening conditioning). One entry per
        # keyframe; frame_idx is pre-snapped to the latent grid by generate().
        images = [
            ImageConditioningInput(path=path, frame_idx=frame_idx, strength=strength, crf=0)
            for path, frame_idx, strength in conditioning_paths
        ]
        pipe = self.pipe
        if pipe is None:
            raise RuntimeError("pipeline not loaded")

        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
            # Resident baseline at request start so request_peak_delta_gb
            # measures only this request's incremental allocation on top of
            # the registry-cached weights.
            self._resident_alloc_gb_at_request_start = torch.cuda.memory_allocated() / (1024**3)
        self._inference_timings.clear()

        frame_rate = float(config.LTX_FPS)
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        t_pipe = time.perf_counter()
        frames: list[Image.Image] = []
        audio_track: GeneratedAudio | None = None

        # Optional torch.profiler capture (per-request kwarg). nullcontext()
        # makes this a true zero-overhead no-op when off. Per-request
        # artifacts written to /tmp/ at the bottom of this method.
        if profile:
            from torch.profiler import ProfilerActivity, profile as _torch_profile
            profiler_ctx = _torch_profile(
                activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
                record_shapes=True,
                profile_memory=False,
                with_stack=False,
            )
        else:
            profiler_ctx = contextlib.nullcontext()

        # Per-request audio opt-out: the official __call__ always decodes the
        # audio latent and downstream code dereferences the returned Audio
        # (stubbing the decoder to None crashed with "'NoneType' object has
        # no attribute 'waveform'" — hit live 2026-09-10), so we let the
        # ~0.2 s decode run and simply don't convert/mux the track.
        want_audio = config.LTX_ENABLE_AUDIO and enable_audio

        extra_kwargs: dict[str, object] = {}
        if self._pipeline_name == "dfr":
            # Base fps only (no temporal x2 rounds — those reload the
            # transformer per tile and need the temporal upscaler); stage 1 at
            # h/2, detailing at h.
            extra_kwargs = {"temporal_upscalings": 0, "spatial_upscalings": 1}

        with profiler_ctx as profiler_obj, torch.inference_mode():
            with self._timed("pipeline_call"):
                result = pipe(
                    prompt=prompt,
                    seed=seed,
                    height=height,
                    width=width,
                    frame_rate=frame_rate,
                    images=images,
                    num_frames=num_frames,
                    tiling_config=AUTO_TILING,
                    **extra_kwargs,
                )

            # Tensor iterator → PIL list. The iterator drives the video
            # VAE decoder lazily, so it must be consumed inside the
            # inference_mode context. Chunks are float [0,1] (F, H, W, 3)
            # on the 2.5 decoders; uint8 is tolerated for older builds.
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            t_decode = time.perf_counter()
            t_pil = 0.0
            for chunk in result.video:
                if chunk.dtype != torch.uint8:
                    chunk = (chunk.float().clamp(0, 1) * 255).round().to(torch.uint8)
                arr = chunk.to("cpu").numpy()
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

            if want_audio and not (is_cancelled is not None and is_cancelled()):
                try:
                    with self._timed("audio_pcm_conversion"):
                        audio_track = _decoded_audio_to_pcm_s16le(result.audio, 16000)
                except Exception as e:  # noqa: BLE001
                    logger.warning(
                        f"LTX audio conversion failed; continuing with silent MP4: {e}",
                        exc_info=True,
                    )

        if torch.cuda.is_available():
            torch.cuda.synchronize()
        pipe_total_ms = int((time.perf_counter() - t_pipe) * 1000)
        self._inference_timings["pipe_total"].append(pipe_total_ms)

        # Unattributed = pipe_total minus the sum of every named phase.
        named_total = sum(
            sum(vs) for name, vs in self._inference_timings.items() if name != "pipe_total"
        )
        self._inference_timings["unattributed"].append(pipe_total_ms - named_total)

        if torch.cuda.is_available():
            free_b, _ = torch.cuda.mem_get_info()
            peak_alloc_gb = torch.cuda.max_memory_allocated() / (1024**3)
            request_peak_delta_gb = peak_alloc_gb - self._resident_alloc_gb_at_request_start
            peak_reserved_gb = torch.cuda.max_memory_reserved() / (1024**3)
            now_alloc_gb = torch.cuda.memory_allocated() / (1024**3)
            now_reserved_gb = torch.cuda.memory_reserved() / (1024**3)
            free_gb = free_b / (1024**3)
            logger.info(
                f"LTX VRAM GiB: peak_alloc={peak_alloc_gb:.2f} "
                f"peak_reserved={peak_reserved_gb:.2f} "
                f"now_alloc={now_alloc_gb:.2f} now_reserved={now_reserved_gb:.2f} "
                f"free={free_gb:.2f} "
                f"resident_alloc={self._resident_alloc_gb_at_request_start:.2f} "
                f"request_peak_delta={request_peak_delta_gb:.2f}",
                extra={
                    "peak_alloc_gb": round(peak_alloc_gb, 2),
                    "peak_reserved_gb": round(peak_reserved_gb, 2),
                    "now_alloc_gb": round(now_alloc_gb, 2),
                    "now_reserved_gb": round(now_reserved_gb, 2),
                    "free_gb": round(free_gb, 2),
                    "resident_alloc_gb": round(self._resident_alloc_gb_at_request_start, 2),
                    "request_peak_delta_gb": round(request_peak_delta_gb, 2),
                },
            )

        timings_summary = " ".join(
            f"{name}={vs[0] if len(vs) == 1 else vs}"
            for name, vs in sorted(self._inference_timings.items())
        )
        logger.info(
            f"LTX phase timings ms: {timings_summary} "
            f"(shape={width}x{height}x{num_frames} frames_out={len(frames)} pipeline={self._pipeline_name})",
            extra={
                "phase_timings_ms": timings_summary,
                "width": width,
                "height": height,
                "num_frames": num_frames,
                "frames_out": len(frames),
                "pipeline": self._pipeline_name,
            },
        )

        # Diagnostic: dump the first decoded frame to disk so that if the iPad
        # video looks wrong, we can SSH in and check whether the bug is in
        # inference (frame 0 itself is bad) or in MP4/streaming.
        if frames:
            try:
                frames[0].save("/tmp/ltx-first-frame.jpg", format="JPEG", quality=90)
            except OSError as e:
                logger.warning(f"Failed to save /tmp/ltx-first-frame.jpg: {e}")

        if profiler_obj is not None:
            self._save_profile_trace(
                profiler_obj,
                width=width, height=height, num_frames=num_frames,
                prompt=prompt, seed=seed, pipe_total_ms=pipe_total_ms,
            )
        return frames, audio_track

    def _save_profile_trace(
        self,
        prof,
        *,
        width: int,
        height: int,
        num_frames: int,
        prompt: str,
        seed: int,
        pipe_total_ms: int,
    ) -> None:
        """Write torch.profiler trace artifacts to /tmp/ for this request:
        .json (Chrome trace), .txt (key_averages), .meta.json (request
        metadata). Each write is independently guarded."""
        timestamp = time.strftime("%H%M%S")
        base = f"/tmp/ltx-profile-{timestamp}-{width}x{height}x{num_frames}"
        try:
            prof.export_chrome_trace(f"{base}.json")
            logger.info(f"LTX profile chrome trace written: {base}.json", extra={"trace_base": base})
        except Exception as e:  # noqa: BLE001
            logger.error(f"Failed to export Chrome trace {base}.json: {e}", extra={"trace_base": base})
        try:
            with open(f"{base}.meta.json", "w") as f:
                json.dump(
                    {
                        "prompt": (prompt or "")[:200],
                        "seed": seed,
                        "width": width,
                        "height": height,
                        "num_frames": num_frames,
                        "pipe_total_ms": pipe_total_ms,
                        "pipeline": self._pipeline_name,
                        "captured_at_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    },
                    f,
                    indent=2,
                )
        except Exception as e:  # noqa: BLE001
            logger.error(f"Failed to write {base}.meta.json: {e}", extra={"trace_base": base})
        try:
            with open(f"{base}.txt", "w") as f:
                f.write(prof.key_averages().table(sort_by="cuda_time_total", row_limit=30))
        except Exception as e:  # noqa: BLE001
            logger.error(f"Failed to write {base}.txt summary: {e}", extra={"trace_base": base})

    def get_info(self) -> dict:
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)
        return {
            "video_ready": self._ready,
            # Boot decomposition clocks: the backend pool's ready event uses
            # these to split provision (Lambda) / OS / our-stack time.
            "booted_at_epoch_s": _booted_at_epoch_s(),
            "started_at_epoch_s": _STARTED_AT_EPOCH_S,
            "model_family": config.LTX_MODEL_FAMILY,
            "model_repo": config.LTX_MODEL_REPO,
            "model_file": config.LTX_MODEL_FILE,
            "text_encoder": config.LTX_TEXT_ENCODER_FILE,
            "video_vae": config.LTX_VIDEO_VAE_FILE,
            "spatial_upscaler": config.LTX_SPATIAL_UPSCALER_FILE,
            "detailing_lora": config.LTX_DETAILING_LORA_FILE if self._pipeline_name == "dfr" else None,
            "quantization": config.LTX_QUANTIZATION,
            "pipeline": "DFRPipeline" if self._pipeline_name == "dfr" else "DistilledPipeline",
            "diffvae_mode": config.LTX_DIFFVAE_MODE,
            "torch_compile": config.LTX_TORCH_COMPILE,
            "attention": getattr(self, "_attention_backend", None),
            "dfr_plain_decode": config.LTX_DFR_PLAIN_DECODE,
            "resolution": f"{config.LTX_WIDTH}x{config.LTX_HEIGHT}",
            "num_frames": config.LTX_NUM_FRAMES,
            "fps": config.LTX_FPS,
            "audio_enabled": config.LTX_ENABLE_AUDIO,
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
            "resident_vram_gb": round(self._resident_vram_gb, 2),
            "load_ms": self._load_ms,
            "phase_timings_ms": dict(self._phase_timings),
            "app_version": dict(self._app_version),
        }

    def shutdown_persistent_models(self) -> None:
        """Release the registry-resident weights on graceful shutdown.
        Idempotent — safe to call zero, one, or multiple times. Ungraceful
        kills skip this entirely; the GPU is torn down with the process."""
        if self._registry is not None:
            try:
                logger.info(f"{config.LTX_MODEL_FAMILY} releasing registry-resident weights...")
                self._registry.clear()
            except Exception as e:  # noqa: BLE001
                logger.warning(f"Error during registry shutdown: {e}")
            finally:
                self._registry = None
        self.pipe = None
        self._ready = False
        if torch.cuda.is_available():
            try:
                torch.cuda.synchronize()
                torch.cuda.empty_cache()
            except Exception:  # noqa: BLE001
                pass


class _PlainDecodeProxy:
    """Wraps a ``VideoDecoder`` block so ``decode_video(keyframes=)`` calls
    become plain decodes (the keyframe kwarg is dropped). Every other
    attribute delegates, so pipeline code reading ``checkpoint_path`` /
    ``diffvae_optimization`` / ``decode_single_frames`` keeps working."""

    def __init__(self, inner):
        self._inner = inner

    def __call__(self, latent, tiling_config=None, generator=None, **kwargs):
        kwargs.pop("keyframes", None)
        return self._inner(latent, tiling_config, generator, **kwargs)

    def __getattr__(self, name):
        return getattr(self._inner, name)


# Back-compat alias for callers that still import the 2.3 name.
Ltx23VideoPipeline = Ltx25VideoPipeline
