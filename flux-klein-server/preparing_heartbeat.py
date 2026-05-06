"""Background heartbeat for the `preparing` phase on both image and video pods.

Emits a structured `preparing heartbeat:` log line every 15s for the duration
of the `preparing` phase block in `lifespan()`. Carries `host_rss_gib`,
`cuda_alloc_gib`, `cuda_reserved_gib`, and elapsed seconds so a SIGKILL
during model load can be back-traced to "host RSS climbed past 65 GB
right before the silence" vs. "memory was fine, something else killed it."

Won't capture the SIGKILL itself — the kernel doesn't give Python a final
breath — but the trajectory is the most diagnostic-positive signal we get
when the pod goes silent mid-Step-2 transformer load.

Implemented with `threading.Thread` (daemon=True) rather than
`asyncio.create_task` because the load functions on both server.py
(FluxKleinPipeline.load) and video_server.py (video_pipeline.load) are
synchronous and block the asyncio event loop for 60-90s. An asyncio task
wouldn't get a chance to run until load completed — defeating the purpose.

Stops when its `Event` is set, typically via `stop_heartbeat()` in the
`finally` of the `with sentry_init.phase("preparing"):` block.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Optional

logger = logging.getLogger(__name__)

_HEARTBEAT_INTERVAL_SEC = 15.0


def start_heartbeat() -> threading.Event:
    """Spawn the heartbeat thread. Returns the Event used to stop it.

    Caller pattern:

        stop = preparing_heartbeat.start_heartbeat()
        try:
            pipeline.load()  # blocks 60-90s
        finally:
            stop.set()

    The phase ContextVar set by `sentry_init.phase("preparing")` is *not*
    inherited by threads (Python's `contextvars` only auto-propagates into
    asyncio Tasks). The heartbeat logs land without a `phase` attribute,
    so they're filterable as `!has:phase code.function.name:_loop` if
    needed — but most queries scope by `pod_id` or `user_id` which is
    enough.
    """
    stop = threading.Event()
    thread = threading.Thread(target=_loop, args=(stop,), daemon=True, name="preparing-heartbeat")
    thread.start()
    return stop


def _loop(stop: threading.Event) -> None:
    started = time.time()
    # Lazy imports — psutil/torch may take ~50ms to load on a cold pod, and
    # we don't want to add to the import path of the main server modules.
    try:
        import psutil
        proc: Optional[object] = psutil.Process()
    except Exception:
        proc = None
    try:
        import torch
        cuda_avail = torch.cuda.is_available()
    except Exception:
        torch = None  # type: ignore[assignment]
        cuda_avail = False

    while not stop.wait(timeout=_HEARTBEAT_INTERVAL_SEC):
        elapsed = time.time() - started
        rss_gib = float("nan")
        cuda_alloc_gib = float("nan")
        cuda_reserved_gib = float("nan")
        if proc is not None:
            try:
                rss_gib = proc.memory_info().rss / 1024 ** 3  # type: ignore[attr-defined]
            except Exception:
                pass
        if cuda_avail and torch is not None:
            try:
                cuda_alloc_gib = torch.cuda.memory_allocated() / 1024 ** 3
                cuda_reserved_gib = torch.cuda.memory_reserved() / 1024 ** 3
            except Exception:
                pass
        logger.info(
            f"preparing heartbeat: elapsed={elapsed:.0f}s "
            f"host_rss={rss_gib:.2f} GiB cuda_alloc={cuda_alloc_gib:.2f} GiB "
            f"cuda_reserved={cuda_reserved_gib:.2f} GiB",
            extra={
                "elapsed_sec": elapsed,
                "host_rss_gib": rss_gib,
                "cuda_alloc_gib": cuda_alloc_gib,
                "cuda_reserved_gib": cuda_reserved_gib,
            },
        )
