"""CUDA preflight: prove the GPU is usable BEFORE loading a model.

Why this exists (2026-09-12/13): Lambda occasionally hands out an H100 SXM
VM whose GPU the host never fabric-initialized. `nvidia-smi` lists the card,
but every CUDA call fails with error 802 ("system not yet initialized") and
nothing inside the pass-through guest can fix it (fabricmanager has no
NVSwitch to manage there). torch then silently falls back to CPU: the model
warmup crawled for ~11 minutes and finally died in an unrelated-looking
dtype error, and the pool held the VM the whole time. Checking CUDA up front
turns that into an immediate, explicit `/health` error the pool fails fast
on (instancePool watchBoot → boot_load_error → terminate + replace).

Retries briefly because a GPU can legitimately be a few seconds behind the
first process start on a fresh VM; the broken case is persistent (a relaunch
25 minutes later still failed).
"""

from __future__ import annotations

import logging
import subprocess
import time

logger = logging.getLogger(__name__)


class CudaUnavailableError(RuntimeError):
    pass


def _nvidia_smi() -> str:
    try:
        out = subprocess.run(
            ["nvidia-smi", "-L"], capture_output=True, text=True, timeout=15, check=False
        )
        return (out.stdout or out.stderr).strip()[:400]
    except Exception as e:  # noqa: BLE001
        return f"nvidia-smi unavailable: {e}"


def check_cuda(*, retries: int = 3, delay_s: float = 10.0) -> str:
    """Return a one-line description of the usable GPU, or raise
    CudaUnavailableError with the CUDA error text + nvidia-smi's view."""
    import torch

    last = ""
    for attempt in range(1, retries + 1):
        try:
            if not torch.cuda.is_available():
                raise RuntimeError("torch.cuda.is_available() is False")
            torch.cuda.init()
            # A real allocation + kernel: is_available() can be True while
            # the first context creation still fails.
            x = torch.ones(1, device="cuda")
            _ = (x + 1).item()
            name = torch.cuda.get_device_name(0)
            total_gib = torch.cuda.get_device_properties(0).total_memory / 2**30
            desc = f"{name} ({total_gib:.0f} GiB)"
            logger.info(
                f"cuda preflight ok: {desc}",
                extra={"event": "cuda_preflight_ok", "gpu_name": name, "preflight_attempt": attempt},
            )
            return desc
        except Exception as e:  # noqa: BLE001
            last = f"{type(e).__name__}: {e}".splitlines()[0][:300]
            logger.warning(
                f"cuda preflight attempt {attempt}/{retries} failed: {last}",
                extra={"event": "cuda_preflight_retry", "preflight_attempt": attempt},
            )
            if attempt < retries:
                time.sleep(delay_s)
    smi = _nvidia_smi()
    msg = f"cuda_preflight_failed after {retries} attempts: {last} | nvidia-smi: {smi}"
    logger.error(msg, extra={"event": "cuda_preflight_failed"})
    raise CudaUnavailableError(msg)
