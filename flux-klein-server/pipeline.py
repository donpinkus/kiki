"""FLUX.2-klein reference-mode img2img pipeline."""

from __future__ import annotations

import concurrent.futures
import json
import logging
import os
import threading
import time

import torch
from PIL import Image

import config

logger = logging.getLogger(__name__)


def _load_app_version() -> dict[str, str | bool]:
    """Read /workspace/app/.version.json — written by sync-flux-app.ts at deploy
    time. Returns a flat dict that gets spread into /health so PostHog sees
    per-DC version skew on every cold start. Empty dict on missing/unreadable
    file (dev environments, manual pod boots)."""
    path = "/workspace/app/.version.json"
    try:
        with open(path, "r") as f:
            data = json.load(f)
        return {f"app_{k}": v for k, v in data.items() if isinstance(v, (str, int, float, bool))}
    except (OSError, json.JSONDecodeError) as e:
        logger.info("No app version file at %s (%s); reporting empty", path, type(e).__name__)
        return {}

# How many parallel reads to issue against the network volume during prefetch.
# 4 left ~7-14s of residual prefetch_wait_ms in early data; bumping to 8 to
# better saturate the NFS read pipeline. If the join still waits, prefetch is
# bandwidth-bound; if it's near zero, we're done squeezing this lever.
_PREFETCH_WORKERS = 8


def _read_meminfo_avail_mb() -> int | None:
    """Return /proc/meminfo's MemAvailable in MB, or None if not Linux/readable.
    Used to surface memory headroom on /health so we can spot prefetch causing
    page-cache thrash on memory-constrained pods."""
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024  # kB → MB
    except OSError:
        pass
    return None


def _read_to_devnull(path: str) -> None:
    """Stream a file's bytes through the kernel read path so its pages land
    in the OS page cache. 1 MB chunks; unbuffered open avoids double-copying
    through Python's io buffer."""
    chunk = 1 << 20
    try:
        with open(path, "rb", buffering=0) as f:
            while f.read(chunk):
                pass
    except OSError as e:
        # Don't fail the boot if a prefetch read errors — pipe.to("cuda") will
        # fall back to its own mmap reads, just slower.
        logger.warning("Prefetch read failed for %s: %s", path, e)


class FluxKleinPipeline:
    """Wraps FLUX.2-klein for reference-mode img2img generation.

    The sketch is VAE-encoded and concatenated with generation latents via the
    pipeline's built-in ``image`` parameter — the transformer attends to both
    the sketch tokens and the generation tokens. This is the only img2img mode
    that produces usable output on klein (a 4-step distilled model), since the
    distillation trajectory doesn't tolerate partial-denoise starts.
    """

    def __init__(self):
        self.pipe = None
        self._ready = False
        self._dtype = getattr(torch, config.DTYPE)
        self._quantization = "bf16"  # overwritten to "nvfp4" if that path succeeds
        # Serialize pipeline calls — PyTorch is not thread-safe and
        # asyncio.to_thread could overlap frames.
        self._lock = threading.Lock()
        # Per-substage load timings (ms). Surfaced on /health so the orchestrator
        # can record them as phase keys on pod.provision.completed in PostHog.
        self._phase_timings: dict[str, int] = {}
        # Read at __init__ (before load) so it's available even if load() crashes —
        # /health can still report the version that's deployed on this volume.
        self._app_version = _load_app_version()

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Load FLUX.2-klein model and warm up."""
        logger.info("Loading model: %s (dtype=%s)", config.MODEL_ID, config.DTYPE)
        t0 = time.time()

        from diffusers import Flux2KleinPipeline

        # Page-cache prefetch (parallel reads of all safetensors). Note we
        # now prefetch the transformer dir too — under device_map='cuda'
        # from_pretrained reads it directly to GPU regardless, so warming the
        # cache helps. The previous "skip transformer" optimization assumed
        # the BF16 transformer would be discarded post-mmap; that's no longer
        # the path we take.
        self._phase_timings["prefetch_workers"] = _PREFETCH_WORKERS
        prefetch_thread = self._spawn_weight_prefetch(include_transformer=True)

        # Try the fast path: device_map='cuda' makes accelerate place each
        # tensor directly on GPU as it loads — no CPU intermediate buffer, no
        # separate to('cuda') walk. low_cpu_mem_usage uses meta-tensor init to
        # avoid temporary allocations. Falls back to the legacy path if the
        # diffusers version doesn't support these kwargs.
        device_map_used = False
        t_phase = time.time()
        try:
            self.pipe = Flux2KleinPipeline.from_pretrained(
                config.MODEL_ID,
                torch_dtype=self._dtype,
                low_cpu_mem_usage=True,
                device_map="cuda",
            )
            device_map_used = True
        except (TypeError, ValueError, NotImplementedError) as e:
            logger.warning(
                "device_map='cuda' rejected (%s: %s); falling back to standard load + to('cuda')",
                type(e).__name__, e,
            )
            self.pipe = Flux2KleinPipeline.from_pretrained(
                config.MODEL_ID,
                torch_dtype=self._dtype,
                low_cpu_mem_usage=True,
            )
        self._phase_timings["from_pretrained_ms"] = int((time.time() - t_phase) * 1000)
        self._phase_timings["device_map_used"] = 1 if device_map_used else 0

        # NVFP4 overwrite. Try loading directly to CUDA (saves a CPU→GPU
        # bounce for the ~3 GB state_dict); fall back to CPU load if the
        # safetensors version doesn't support device=. load_state_dict
        # handles either case correctly when the transformer is on GPU.
        t_phase = time.time()
        if config.USE_NVFP4:
            self._try_load_nvfp4()
        self._phase_timings["nvfp4_load_ms"] = int((time.time() - t_phase) * 1000)

        # Wait for prefetch to finish — under the new path, from_pretrained
        # has already done the disk reads, so this join is a sanity bound on
        # how much the prefetch contended for NFS bandwidth. Large values
        # here on the device_map path = prefetch was racing with from_pretrained
        # for the same NFS reads (which is what we want to detect).
        t_phase = time.time()
        if prefetch_thread is not None:
            prefetch_thread.join()
        self._phase_timings["prefetch_wait_ms"] = int((time.time() - t_phase) * 1000)

        # Move to GPU only if device_map didn't already place us there.
        # Stays in the metric for parity with prior runs (will be ~0 on the
        # fast path, real on the fallback path).
        t_phase = time.time()
        if not device_map_used:
            self.pipe.to("cuda")
        self._phase_timings["to_cuda_ms"] = int((time.time() - t_phase) * 1000)

        logger.info(
            "Model loaded in %.1fs (quantization=%s, device_map=%s)",
            time.time() - t0, self._quantization, device_map_used,
        )

        # Warmup with a dummy txt2img generation
        logger.info("Warming up...")
        t_phase = time.time()
        with self._lock:
            _ = self.pipe(
                prompt="warmup",
                height=config.DEFAULT_HEIGHT,
                width=config.DEFAULT_WIDTH,
                num_inference_steps=config.STEPS,
                guidance_scale=1.0,
                generator=torch.Generator(device="cuda").manual_seed(0),
            )
        self._phase_timings["warmup_inference_ms"] = int((time.time() - t_phase) * 1000)
        logger.info("Warmup done (%.1fs)", self._phase_timings["warmup_inference_ms"] / 1000)

        # Capture memory headroom after load completes — high prefetch worker
        # counts can pin gigabytes of page cache. If MemAvailable trends low
        # across cold starts, the prefetch is causing pressure and we should
        # back off the worker count or skip prefetching the transformer dir.
        mem_avail = _read_meminfo_avail_mb()
        if mem_avail is not None:
            self._phase_timings["cpu_mem_avail_mb_at_ready"] = mem_avail

        self._ready = True
        logger.info(
            "Pipeline ready. Total init: %.1fs (phases: %s)",
            time.time() - t0, self._phase_timings,
        )

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

    def _spawn_weight_prefetch(self, include_transformer: bool) -> threading.Thread | None:
        """Read the FLUX safetensors into the OS page cache in parallel.

        Targets all safetensors under HF_HOME for the configured MODEL_ID.
        When include_transformer=False, skips the transformer dir (legacy
        path — NVFP4 overwrites those weights eagerly, so prefetching them
        was wasted I/O). On the device_map='cuda' path we want them too
        because from_pretrained reads them straight to GPU regardless.

        Records prefetch_total_ms (actual thread wall time) and
        prefetch_bytes_mb into self._phase_timings so we can tell whether
        the prefetch itself was bandwidth-bound vs whether prefetch_wait_ms
        is just the join overhead.

        Returns the started thread, or None if HF_HOME / cache dir is missing
        (graceful no-op in dev / on misconfigured pods).
        """
        hf_home = os.environ.get("HF_HOME")
        if not hf_home or not os.path.isdir(hf_home):
            logger.info("HF_HOME unset or missing; skipping weight prefetch")
            return None

        # FLUX.2-klein cache layout: {HF_HOME}/hub/models--{org}--{name}/snapshots/<sha>/
        cache_name = "models--" + config.MODEL_ID.replace("/", "--")
        base = os.path.join(hf_home, "hub", cache_name)
        if not os.path.isdir(base):
            logger.info("FLUX cache dir %s missing; skipping prefetch", base)
            return None

        targets: list[str] = []
        for root, _dirs, files in os.walk(base):
            if not include_transformer and os.path.sep + "transformer" in root:
                continue
            for f in files:
                if f.endswith(".safetensors"):
                    targets.append(os.path.join(root, f))

        if not targets:
            logger.info("No safetensors found under %s; skipping prefetch", base)
            return None

        total_bytes = sum(os.path.getsize(p) for p in targets)
        self._phase_timings["prefetch_bytes_mb"] = total_bytes >> 20
        logger.info(
            "Prefetching %d safetensors (%.1f GB) into page cache (%d workers)...",
            len(targets), total_bytes / (1 << 30), _PREFETCH_WORKERS,
        )

        phase_timings = self._phase_timings  # capture for closure

        def worker() -> None:
            t0 = time.time()
            with concurrent.futures.ThreadPoolExecutor(max_workers=_PREFETCH_WORKERS) as ex:
                list(ex.map(_read_to_devnull, targets))
            elapsed_ms = int((time.time() - t0) * 1000)
            phase_timings["prefetch_total_ms"] = elapsed_ms
            logger.info("Prefetch complete in %.1fs", elapsed_ms / 1000)

        thread = threading.Thread(target=worker, name="weight-prefetch", daemon=True)
        thread.start()
        return thread

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
            # Try direct GPU-side load (newer safetensors); falls back to CPU
            # load with auto-copy in load_state_dict on older versions.
            try:
                state_dict = load_file(nvfp4_path, device="cuda")
            except (TypeError, ValueError) as e:
                logger.info("safetensors load_file device='cuda' rejected (%s); using CPU load", type(e).__name__)
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
            "phase_timings_ms": dict(self._phase_timings),
            "app_version": dict(self._app_version),
        }
