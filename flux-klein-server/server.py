"""FLUX.2-klein WebSocket server for real-time img2img generation.

Protocol:
  Client -> Server:
    - Text frame (JSON): { "type": "config", "prompt": "...", "mode": "reference"|"denoise",
                           "denoise": 0.6, "guidanceScale": 4.0, "steps": 4, "seed": 42 }
    - Binary frame: Raw JPEG bytes of input sketch

  Server -> Client:
    - Text frame (JSON): { "type": "status", "status": "ready" | "warmup" | "error", "message": "..." }
    - Binary frame: Generated JPEG bytes
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
    current_config = {
        "prompt": "",
        "mode": config.MODE,
        "denoise": config.DENOISE_STRENGTH,
        "guidanceScale": config.GUIDANCE_SCALE,
        "steps": config.STEPS,
        "seed": None,
    }

    frames_processed = 0
    session_start = time.time()

    try:
        while True:
            message = await ws.receive()

            if message.get("type") == "websocket.disconnect":
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
                        if "seed" in data:
                            current_config["seed"] = int(data["seed"]) if data["seed"] is not None else None

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

            # Binary frame: input image (JPEG)
            if "bytes" in message:
                jpeg_data = message["bytes"]
                try:
                    result_jpeg = await asyncio.to_thread(
                        _process_frame, jpeg_data, current_config
                    )
                    await ws.send_bytes(result_jpeg)
                    frames_processed += 1

                except Exception as e:
                    logger.error("Frame processing error: %s", e, exc_info=True)
                    await ws.send_text(json.dumps({
                        "type": "status",
                        "status": "error",
                        "message": str(e),
                    }))

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error("WebSocket error for client %d: %s", client_id, e, exc_info=True)
    finally:
        elapsed = time.time() - session_start
        fps = frames_processed / elapsed if elapsed > 0 else 0
        logger.info(
            "Client %d disconnected. Processed %d frames, %.1f FPS over %.1fs",
            client_id, frames_processed, fps, elapsed,
        )


def _process_frame(jpeg_data: bytes, cfg: dict) -> bytes:
    """Decode JPEG, run through pipeline, encode result as JPEG.

    Runs in a thread to avoid blocking the event loop.
    """
    # Decode input
    image = Image.open(io.BytesIO(jpeg_data)).convert("RGB")
    image = image.resize((config.DEFAULT_WIDTH, config.DEFAULT_HEIGHT), Image.LANCZOS)

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

    # Encode as JPEG
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
