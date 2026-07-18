"""FLUX.2-klein WebSocket server for real-time img2img generation.

Protocol:
  Client -> Server:
    - Text frame (JSON): { "type": "config", "prompt": "...", "steps": 4, "seed": 42, "requestId": "..." }
    - Binary frame: Raw JPEG bytes of input sketch

  Server -> Client:
    - Text frame (JSON): { "type": "status", "status": "ready" | "warmup" | "error", "message": "..." }
    - Text frame (JSON): { "type": "frame_meta", "requestId": "..."|null, "queueEmpty": <bool> }
        Always sent immediately before each generated binary. `queueEmpty`
        is true when the input buffer was empty at frame-completion time —
        kept as the trigger signal for the idle-state video animation
        (archived, planned revival — see archive/video-ltx/).
    - Binary frame: Generated JPEG bytes

Frame dropping:
  The client may send frames faster than the server can generate (~1 FPS).
  Only the latest frame is kept; older frames are dropped. This prevents
  frame queue buildup and keeps the output responsive to the current sketch.

Correlation:
  `requestId` lets the client route responses to specific requests (used by
  the style-preview picker). The value is snapshotted into cfg at generation
  start so it survives config updates that arrive mid-generation. The same
  ID propagates through the backend, so a single grep matches the full
  lifecycle.
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import random
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image

from shared import config
from shared import preparing_heartbeat
from shared import sentry_init
from image.pipeline import FluxKleinPipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

sentry_init.init(pod_kind="image")

pipeline = FluxKleinPipeline()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the model on startup."""
    with sentry_init.phase("preparing"):
        logger.info("Starting FLUX.2-klein server...")
        # Threaded heartbeat — pipeline.load() blocks the asyncio event loop
        # for 60-90s, so an asyncio task wouldn't fire during the load.
        # See preparing_heartbeat.py header for context.
        stop_heartbeat = preparing_heartbeat.start_heartbeat()
        try:
            pipeline.load()
        finally:
            stop_heartbeat.set()
        # ASGI lifespan completed — pipeline ready, app about to accept
        # connections. One-time log so post-hoc analysis can correlate
        # WS failures against pod-config baselines: was lifespan reached,
        # how many uvicorn workers, what pid. Useful when triaging "is
        # this pod's setup unusual?" after a wire_relay failure.
        logger.info(
            "ASGI startup complete",
            extra={
                "event": "pod.app.startup",
                "pid": os.getpid(),
                # We launch with `uvicorn.run(... workers=None)` (single
                # worker per process); record the value if it's ever
                # changed in the future.
                "uvicorn_workers": 1,
            },
        )
    yield
    with sentry_init.phase("session_ending"):
        logger.info("Shutting down.")


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    info = pipeline.get_info()
    return {
        "status": "ok" if pipeline.ready else "loading",
        **info,
    }


@app.websocket("/ws")
async def websocket_stream(ws: WebSocket):
    # WS handshake lifecycle instrumentation. Each transition fires its own
    # log line so post-hoc analysis can see exactly *where* the pod-side
    # flow halted when traffic landed:
    #   - upgrade_attempt logged but no `accepted` → accept() hung/threw
    #   - accepted logged but no `first_send_ok` → connection torn down mid-handshake
    #   - none of the above logged → traffic never reached this handler
    #     (proxy dropped it, or routing didn't match /ws)
    # Cross-stack: backend's `wire_relay_failed` paired with the absence
    # of a matching `pod.ws.upgrade_attempt` is conclusive evidence that
    # the upgrade traffic was dropped before reaching the pod.
    client_ip = ws.client.host if ws.client else None
    logger.info(
        f"WS upgrade attempt from {client_ip or '?'}",
        extra={"event": "pod.ws.upgrade_attempt", "client_ip": client_ip},
    )
    # Optional shared-secret gate for deployments where this server sits on a
    # public IP with the port open to the internet (Lambda Cloud), unlike the
    # proxy with an unguessable hostname. No-op when KIKI_WS_TOKEN is unset
    # (local dev unchanged).
    expected_token = os.environ.get("KIKI_WS_TOKEN", "")
    if expected_token and ws.query_params.get("token") != expected_token:
        logger.warning(
            f"WS rejected: bad token from {client_ip or '?'}",
            extra={"event": "pod.ws.bad_token", "client_ip": client_ip},
        )
        await ws.close(code=4401)
        return
    try:
        await ws.accept()
    except Exception as e:
        logger.error(
            f"WS accept() failed: {e}",
            extra={"event": "pod.ws.accept_failed", "err": str(e), "client_ip": client_ip},
        )
        raise
    client_id = id(ws)
    logger.info(
        f"Client {client_id} connected",
        extra={"event": "pod.ws.accepted", "client_id": client_id, "client_ip": client_ip},
    )

    # Send initial status. Successful first send proves the bidirectional
    # pipe is up — distinguishes "accepted but immediately torn down" from
    # "accepted and serving normally."
    if pipeline.ready:
        await ws.send_text(json.dumps({"type": "status", "status": "ready"}))
    else:
        await ws.send_text(json.dumps({
            "type": "status",
            "status": "warmup",
            "message": "Pipeline warming up, please wait...",
        }))
        while not pipeline.ready:
            await asyncio.sleep(0.5)
        await ws.send_text(json.dumps({"type": "status", "status": "ready"}))
    logger.info(
        f"WS first send ok, client {client_id}",
        extra={"event": "pod.ws.first_send_ok", "client_id": client_id, "client_ip": client_ip},
    )

    # Per-connection state. Default seed is random-per-session (not per-frame)
    # so output is stable when the sketch doesn't change. Client can override.
    session_seed = random.randint(0, 2**32 - 1)
    current_config = {
        "prompt": "",
        "steps": config.STEPS,
        "seed": session_seed,
        "requestId": None,
    }

    # Single-slot frame buffer: only the latest frame is kept.
    # The receiver task writes here; the processor task reads.
    latest_frame: bytes | None = None
    frame_event = asyncio.Event()
    frames_received = 0
    frames_processed = 0
    frames_dropped = 0
    # Per-send dropped counter for the diagnostic log; reset after each emit.
    frames_dropped_since_last_send = 0
    # Count of false->true transitions on queueEmpty (i.e. distinct trigger
    # opportunities for the archived idle-state video animation). Useful in
    # disconnect summary + /health.
    queue_drained_count = 0
    # Last queueEmpty value seen, for edge detection.
    prev_queue_empty: bool | None = None
    session_start = time.time()
    done = False

    async def receive_loop():
        """Read messages from the client. Keep only the latest binary frame."""
        nonlocal latest_frame, frames_received, frames_dropped, done, current_config
        nonlocal frames_dropped_since_last_send

        try:
            while not done:
                message = await ws.receive()

                if message.get("type") == "websocket.disconnect":
                    done = True
                    frame_event.set()
                    break

                # Text frame: config update
                if "text" in message:
                    try:
                        data = json.loads(message["text"])
                        if data.get("type") == "config":
                            if "prompt" in data:
                                current_config["prompt"] = data["prompt"]
                            if "steps" in data:
                                current_config["steps"] = max(1, min(50, int(data["steps"])))
                            if "seed" in data and data["seed"] is not None:
                                current_config["seed"] = int(data["seed"])
                            # Snapshotted with cfg in process_loop so the
                            # outgoing frame_meta matches the frame the client
                            # will pair it with, even if a new config arrives
                            # mid-generation.
                            current_config["requestId"] = data.get("requestId")

                            prompt_preview = str(current_config["prompt"])[:50]
                            logger.info(
                                f"Client {client_id} config: "
                                f"prompt='{prompt_preview}', "
                                f"steps={current_config['steps']}",
                                extra={
                                    "client_id": client_id,
                                    "prompt": prompt_preview,
                                    "steps": current_config["steps"],
                                },
                            )
                    except json.JSONDecodeError:
                        logger.warning(
                            f"Client {client_id} sent invalid JSON",
                            extra={"client_id": client_id},
                        )
                    continue

                # Binary frame: input image — replace buffer (drop old frame)
                if "bytes" in message:
                    if latest_frame is not None:
                        frames_dropped += 1
                        frames_dropped_since_last_send += 1
                    latest_frame = message["bytes"]
                    frames_received += 1
                    frame_event.set()

        except WebSocketDisconnect:
            done = True
            frame_event.set()
        except Exception as e:
            logger.error(
                f"Client {client_id} receive error: {e}",
                extra={"client_id": client_id},
            )
            done = True
            frame_event.set()

    async def process_loop():
        """Process the latest frame whenever one is available."""
        nonlocal latest_frame, frames_processed, done
        nonlocal frames_dropped_since_last_send, queue_drained_count, prev_queue_empty

        while not done:
            await frame_event.wait()
            frame_event.clear()

            if done:
                break

            jpeg_data = latest_frame
            latest_frame = None

            if jpeg_data is None:
                continue

            with sentry_init.phase("drawing"):
                try:
                    cfg = dict(current_config)
                    gen_start = time.time()
                    result_jpeg = await asyncio.to_thread(_process_frame, jpeg_data, cfg)
                    gen_ms = int((time.time() - gen_start) * 1000)
                    if not done:
                        request_id = cfg.get("requestId")
                        # Evaluated at frame-completion time: if no new frame has
                        # arrived during generation, the iPad has stopped drawing
                        # and this image is eligible for video animation.
                        queue_empty = latest_frame is None
                        await ws.send_text(json.dumps({
                            "type": "frame_meta",
                            "requestId": request_id,
                            "queueEmpty": queue_empty,
                        }))
                        await ws.send_bytes(result_jpeg)
                        frames_processed += 1

                        # Edge log: false -> true transition — the moment the
                        # archived idle-state video trigger would fire. Single
                        # grep target during triage.
                        if queue_empty and prev_queue_empty is not True:
                            queue_drained_count += 1
                            logger.info(
                                f"queue drained: req={request_id} last_generated_set=true",
                                extra={"req": request_id},
                            )
                        prev_queue_empty = queue_empty

                        logger.info(
                            f"frame: req={request_id} queueEmpty={queue_empty} "
                            f"gen_ms={gen_ms} "
                            f"dropped_since_last={frames_dropped_since_last_send}",
                            extra={
                                "req": request_id,
                                "queue_empty": queue_empty,
                                "gen_ms": gen_ms,
                                "dropped_since_last": frames_dropped_since_last_send,
                            },
                        )
                        frames_dropped_since_last_send = 0
                except Exception as e:
                    logger.error(f"Frame processing error: {e}", exc_info=True)
                    if not done:
                        try:
                            await ws.send_text(json.dumps({
                                "type": "status",
                                "status": "error",
                                "message": str(e),
                            }))
                        except Exception:
                            pass

    # Run both loops concurrently
    try:
        await asyncio.gather(receive_loop(), process_loop())
    except Exception as e:
        logger.error(
            f"WebSocket error for client {client_id}: {e}",
            exc_info=True,
            extra={"client_id": client_id},
        )
    finally:
        elapsed = time.time() - session_start
        fps = frames_processed / elapsed if elapsed > 0 else 0
        logger.info(
            f"Client {client_id} disconnected. Received {frames_received}, "
            f"processed {frames_processed}, dropped {frames_dropped}, "
            f"queue_drained {queue_drained_count}, "
            f"{fps:.1f} FPS over {elapsed:.1f}s",
            extra={
                "client_id": client_id,
                "frames_received": frames_received,
                "frames_processed": frames_processed,
                "frames_dropped": frames_dropped,
                "queue_drained_count": queue_drained_count,
                "fps": round(fps, 1),
                "duration_s": round(elapsed, 1),
            },
        )


def _process_frame(jpeg_data: bytes, cfg: dict) -> bytes:
    """Decode JPEG, run through pipeline, encode result as JPEG.

    Runs in a thread to avoid blocking the event loop.
    """
    image = Image.open(io.BytesIO(jpeg_data)).convert("RGB")
    image = image.resize((config.DEFAULT_WIDTH, config.DEFAULT_HEIGHT), Image.LANCZOS)

    output = pipeline.generate_reference(
        image=image,
        prompt=cfg.get("prompt", ""),
        steps=cfg.get("steps", config.STEPS),
        seed=cfg.get("seed"),
    )

    buffer = io.BytesIO()
    output.save(buffer, format="JPEG", quality=config.OUTPUT_JPEG_QUALITY)
    return buffer.getvalue()


if __name__ == "__main__":
    # TLS: when FLUX_SSL_CERT/KEY are set (Lambda fleet — a self-signed cert
    # on the shared filesystem that the backend PINS), serve wss/https.
    # Unset = plain ws (local dev).
    _ssl_cert = os.environ.get("FLUX_SSL_CERT") or None
    _ssl_key = os.environ.get("FLUX_SSL_KEY") or None
    uvicorn.run(
        "image.server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
        ssl_certfile=_ssl_cert,
        ssl_keyfile=_ssl_key,
    )
