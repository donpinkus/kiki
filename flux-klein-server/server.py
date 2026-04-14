"""FLUX.2-klein WebSocket server for real-time img2img generation.

Protocol:
  Client -> Server:
    - Text frame (JSON): { "type": "config", "prompt": "...", "mode": "reference"|"denoise",
                           "denoise": 0.6, "guidanceScale": 4.0, "steps": 4, "seed": 42 }
    - Binary frame: Raw JPEG bytes of input sketch

  Server -> Client:
    - Text frame (JSON): { "type": "status", "status": "ready" | "warmup" | "error", "message": "..." }
    - Binary frame: Generated JPEG bytes

Frame dropping:
  The client may send frames faster than the server can generate (~1 FPS).
  Only the latest frame is kept; older frames are dropped. This prevents
  frame queue buildup and keeps the output responsive to the current sketch.
"""

import asyncio
import io
import json
import logging
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

    # Per-connection state
    # Default seed is random-per-session (not per-frame) so output is
    # stable when the sketch doesn't change. Client can override.
    import random
    session_seed = random.randint(0, 2**32 - 1)
    current_config = {
        "prompt": "",
        "mode": config.MODE,
        "denoise": config.DENOISE_STRENGTH,
        "guidanceScale": config.GUIDANCE_SCALE,
        "steps": config.STEPS,
        "seed": session_seed,
    }

    # Single-slot frame buffer: only the latest frame is kept.
    # The receiver task writes here; the processor task reads.
    latest_frame: bytes | None = None
    frame_event = asyncio.Event()
    frames_received = 0
    frames_processed = 0
    frames_dropped = 0
    session_start = time.time()
    done = False

    async def receive_loop():
        """Read messages from the client. Keep only the latest binary frame."""
        nonlocal latest_frame, frames_received, frames_dropped, done, current_config

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
                            if "mode" in data and data["mode"] in ("reference", "denoise"):
                                current_config["mode"] = data["mode"]
                            if "denoise" in data:
                                current_config["denoise"] = max(0.0, min(1.0, float(data["denoise"])))
                            if "guidanceScale" in data:
                                current_config["guidanceScale"] = max(0.0, min(20.0, float(data["guidanceScale"])))
                            if "steps" in data:
                                current_config["steps"] = max(1, min(50, int(data["steps"])))
                            if "seed" in data and data["seed"] is not None:
                                current_config["seed"] = int(data["seed"])

                            logger.info(
                                "Client %d config: prompt='%s', mode=%s, steps=%d",
                                client_id,
                                str(current_config["prompt"])[:50],
                                current_config["mode"],
                                current_config["steps"],
                            )
                    except json.JSONDecodeError:
                        logger.warning("Client %d sent invalid JSON", client_id)
                    continue

                # Binary frame: input image — replace buffer (drop old frame)
                if "bytes" in message:
                    if latest_frame is not None:
                        frames_dropped += 1
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

        while not done:
            # Wait for a frame to arrive
            await frame_event.wait()
            frame_event.clear()

            if done:
                break

            # Grab the latest frame and clear the buffer
            jpeg_data = latest_frame
            latest_frame = None

            if jpeg_data is None:
                continue

            try:
                # Snapshot config so it doesn't change mid-generation
                cfg = dict(current_config)
                t_frame_start = time.perf_counter()
                result_jpeg = await asyncio.to_thread(
                    _process_frame, jpeg_data, cfg
                )
                t_process_done = time.perf_counter()
                if not done:
                    await ws.send_bytes(result_jpeg)
                    t_sent = time.perf_counter()
                    frames_processed += 1
                    logger.info(
                        "frame client=%d process_ms=%.0f send_ms=%.0f total_ms=%.0f",
                        client_id,
                        (t_process_done - t_frame_start) * 1000,
                        (t_sent - t_process_done) * 1000,
                        (t_sent - t_frame_start) * 1000,
                    )
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
            "Client %d disconnected. Received %d, processed %d, dropped %d, %.1f FPS over %.1fs",
            client_id, frames_received, frames_processed, frames_dropped, fps, elapsed,
        )


def _process_frame(jpeg_data: bytes, cfg: dict) -> bytes:
    """Decode JPEG, run through pipeline, encode result as JPEG.

    Runs in a thread to avoid blocking the event loop.
    """
    # Decode input
    t0 = time.perf_counter()
    image = Image.open(io.BytesIO(jpeg_data)).convert("RGB")
    t_decode = time.perf_counter()
    image = image.resize((config.DEFAULT_WIDTH, config.DEFAULT_HEIGHT), Image.LANCZOS)
    t_resize = time.perf_counter()

    # Generate based on mode
    mode = cfg.get("mode", config.MODE)
    prompt = cfg.get("prompt", "")
    steps = cfg.get("steps", config.STEPS)
    seed = cfg.get("seed")

    if mode == "denoise":
        output = pipeline.generate_denoise(
            image=image,
            prompt=prompt,
            denoise_strength=cfg.get("denoise", config.DENOISE_STRENGTH),
            steps=steps,
            seed=seed,
        )
    else:
        output = pipeline.generate_reference(
            image=image,
            prompt=prompt,
            steps=steps,
            guidance_scale=cfg.get("guidanceScale", config.GUIDANCE_SCALE),
            seed=seed,
        )
    t_pipe = time.perf_counter()

    # Encode as JPEG
    buffer = io.BytesIO()
    output.save(buffer, format="JPEG", quality=config.OUTPUT_JPEG_QUALITY)
    jpeg = buffer.getvalue()
    t_encode = time.perf_counter()

    logger.info(
        "frame_breakdown decode_ms=%.0f resize_ms=%.0f pipe_ms=%.0f encode_ms=%.0f in_bytes=%d out_bytes=%d",
        (t_decode - t0) * 1000,
        (t_resize - t_decode) * 1000,
        (t_pipe - t_resize) * 1000,
        (t_encode - t_pipe) * 1000,
        len(jpeg_data),
        len(jpeg),
    )
    return jpeg


if __name__ == "__main__":
    uvicorn.run(
        "server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
    )
