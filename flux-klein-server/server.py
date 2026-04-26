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
        the backend uses this as the trigger to dispatch the just-sent
        image to the video pod for animation.
    - Binary frame: Generated JPEG bytes

Frame dropping:
  The client may send frames faster than the server can generate (~1 FPS).
  Only the latest frame is kept; older frames are dropped. This prevents
  frame queue buildup and keeps the output responsive to the current sketch.

Correlation:
  `requestId` lets the client route responses to specific requests (used by
  the style-preview picker). The value is snapshotted into cfg at generation
  start so it survives config updates that arrive mid-generation. The same
  ID propagates to the video pod via the backend, so a single grep matches
  the full lifecycle.
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
import random
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image

import config
from pipeline import FluxKleinPipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

pipeline = FluxKleinPipeline()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the model on startup."""
    logger.info("Starting FLUX.2-klein server...")
    pipeline.load()
    yield
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
    await ws.accept()
    client_id = id(ws)
    logger.info("Client %d connected", client_id)

    # Send initial status
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
    # opportunities for the video pod). Useful in disconnect summary + /health.
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

                            logger.info(
                                "Client %d config: prompt='%s', steps=%d",
                                client_id,
                                str(current_config["prompt"])[:50],
                                current_config["steps"],
                            )
                    except json.JSONDecodeError:
                        logger.warning("Client %d sent invalid JSON", client_id)
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
            logger.error("Client %d receive error: %s", client_id, e)
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

                    # Edge log: false -> true transition. This is the moment
                    # the backend will dispatch the just-sent image to the
                    # video pod. Single grep target during triage.
                    if queue_empty and prev_queue_empty is not True:
                        queue_drained_count += 1
                        logger.info(
                            "queue drained: req=%s last_generated_set=true",
                            request_id,
                        )
                    prev_queue_empty = queue_empty

                    logger.info(
                        "frame: req=%s queueEmpty=%s gen_ms=%d dropped_since_last=%d",
                        request_id, queue_empty, gen_ms, frames_dropped_since_last_send,
                    )
                    frames_dropped_since_last_send = 0
            except Exception as e:
                logger.error("Frame processing error: %s", e, exc_info=True)
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
        logger.error("WebSocket error for client %d: %s", client_id, e, exc_info=True)
    finally:
        elapsed = time.time() - session_start
        fps = frames_processed / elapsed if elapsed > 0 else 0
        logger.info(
            "Client %d disconnected. Received %d, processed %d, dropped %d, queue_drained %d, %.1f FPS over %.1fs",
            client_id, frames_received, frames_processed, frames_dropped, queue_drained_count, fps, elapsed,
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
    uvicorn.run(
        "server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
    )
