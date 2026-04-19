"""FLUX.2-klein WebSocket server for real-time img2img generation.

Protocol:
  Client -> Server:
    - Text frame (JSON): { "type": "config", "prompt": "...", "steps": 4, "seed": 42 }
    - Binary frame: Raw JPEG bytes of input sketch

  Server -> Client:
    - Text frame (JSON): { "type": "status", "status": "ready" | "warmup" | "error", "message": "..." }
    - Binary frame: Generated JPEG bytes (img2img result)
    - Text frame (JSON): { "type": "video_frame", "data": "<base64 JPEG>" } — one
      per decoded LTXV animation frame, sent while the user is idle
    - Text frame (JSON): { "type": "video_complete", "data": "<base64 MP4>" }
    - Text frame (JSON): { "type": "video_cancelled" }

Frame dropping:
  The client may send frames faster than the server can generate (~1 FPS).
  Only the latest frame is kept; older frames are dropped. This prevents
  frame queue buildup and keeps the output responsive to the current sketch.

Video generation:
  When the input buffer is empty and we have a last-generated still,
  `video_loop` kicks off LTXV animation on the GPU. Arrival of a new
  input frame cancels the in-flight video generation.
"""

import asyncio
import base64
import io
import json
import logging
import random
import threading
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image

import config
from pipeline import FluxKleinPipeline
from video_pipeline import (
    LtxvVideoPipeline,
    VideoCancelled,
    encode_mp4,
    frames_to_jpeg,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

# Shared serialization point across FLUX and LTXV — PyTorch isn't thread-safe
# and both pipelines would otherwise interleave CUDA kernels on the same stream.
gpu_lock = threading.Lock()

pipeline = FluxKleinPipeline(gpu_lock)
video_pipeline = LtxvVideoPipeline(gpu_lock)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the model(s) on startup."""
    logger.info("Starting FLUX.2-klein server...")
    pipeline.load()
    # LTXV is optional — if it fails to load, the server still serves img2img.
    video_pipeline.load()
    yield
    logger.info("Shutting down.")


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    info = pipeline.get_info()
    info.update(video_pipeline.get_info())
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

    # ── Video-generation state (LTXV) ────────────────────────────────────
    # The most recent generated still, used as the first-frame keyframe for
    # video generation. Reset whenever a new img2img result is produced.
    last_generated: Image.Image | None = None
    # Guards against re-generating a video for the same still more than once.
    video_done_for_last = False
    # Set to abort an in-flight LTXV generation when a new sketch arrives.
    video_cancel_event = threading.Event()
    video_task: asyncio.Task | None = None
    videos_generated = 0

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
                            if "steps" in data:
                                current_config["steps"] = max(1, min(50, int(data["steps"])))
                            if "seed" in data and data["seed"] is not None:
                                current_config["seed"] = int(data["seed"])

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
                    latest_frame = message["bytes"]
                    frames_received += 1
                    # User is drawing again — abort any running video generation.
                    video_cancel_event.set()
                    frame_event.set()

        except WebSocketDisconnect:
            done = True
            video_cancel_event.set()
            frame_event.set()
        except Exception as e:
            logger.error("Client %d receive error: %s", client_id, e)
            done = True
            video_cancel_event.set()
            frame_event.set()

    async def process_loop():
        """Process the latest frame whenever one is available."""
        nonlocal latest_frame, frames_processed, done
        nonlocal last_generated, video_done_for_last

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
                result_jpeg, result_image = await asyncio.to_thread(
                    _process_frame, jpeg_data, cfg
                )
                if not done:
                    await ws.send_bytes(result_jpeg)
                    frames_processed += 1
                    # Stash the PIL result as the keyframe for any future video
                    # generation. Reset the once-per-still guard + cancel flag
                    # so the video loop can pick it up on the next idle window.
                    last_generated = result_image
                    video_done_for_last = False
                    video_cancel_event.clear()
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

    async def run_video_generation():
        """Generate an LTXV animation for the current `last_generated` still
        and stream frames + MP4 back to the client. Any new sketch arriving
        during generation aborts via `video_cancel_event`."""
        nonlocal videos_generated, video_done_for_last

        if last_generated is None:
            return
        keyframe = last_generated
        prompt = str(current_config.get("prompt") or "")
        seed = current_config.get("seed")

        logger.info(
            "Client %d: starting LTXV animation (prompt='%s', %d frames, %dx%d)",
            client_id, prompt[:50], config.LTXV_NUM_FRAMES,
            config.LTXV_WIDTH, config.LTXV_HEIGHT,
        )
        t0 = time.time()

        try:
            frames = await asyncio.to_thread(
                video_pipeline.generate,
                keyframe, prompt, video_cancel_event, seed,
            )
        except VideoCancelled:
            logger.info("Client %d: LTXV cancelled by user", client_id)
            if not done:
                try:
                    await ws.send_text(json.dumps({"type": "video_cancelled"}))
                except Exception:
                    pass
            return
        except Exception as e:  # noqa: BLE001
            logger.error("Client %d: LTXV error: %s", client_id, e, exc_info=True)
            return

        if done or video_cancel_event.is_set():
            return

        # Stream decoded frames one at a time so the client can start playback
        # before the MP4 arrives. If cancelled between frames, bail out.
        for i, frame in enumerate(frames):
            if done or video_cancel_event.is_set():
                if not done:
                    try:
                        await ws.send_text(json.dumps({"type": "video_cancelled"}))
                    except Exception:
                        pass
                return
            try:
                jpeg = frames_to_jpeg(frame, quality=config.OUTPUT_JPEG_QUALITY)
                await ws.send_text(json.dumps({
                    "type": "video_frame",
                    "data": base64.b64encode(jpeg).decode("ascii"),
                }))
            except Exception as e:  # noqa: BLE001
                logger.warning("Client %d: video_frame send failed: %s", client_id, e)
                return

        # Encode the full MP4 for smooth looping on the client.
        try:
            mp4 = await asyncio.to_thread(
                encode_mp4, frames, config.LTXV_FPS, config.LTXV_OUTPUT_CRF,
            )
            if done:
                return
            await ws.send_text(json.dumps({
                "type": "video_complete",
                "data": base64.b64encode(mp4).decode("ascii"),
            }))
            video_done_for_last = True
            videos_generated += 1
            logger.info(
                "Client %d: LTXV done in %.1fs (%d frames, %d bytes MP4)",
                client_id, time.time() - t0, len(frames), len(mp4),
            )
        except Exception as e:  # noqa: BLE001
            logger.error("Client %d: MP4 encode failed: %s", client_id, e, exc_info=True)

    async def video_loop():
        """Poll for idle windows (no input frame, no in-flight generation) and
        kick off LTXV animation. Runs concurrently with receive/process loops."""
        nonlocal video_task

        if not video_pipeline.ready:
            return
        # Small wait so the initial warmup img2img frame has a chance to land.
        await asyncio.sleep(0.5)
        while not done:
            await asyncio.sleep(0.1)
            if done:
                break
            if latest_frame is not None:
                continue
            if last_generated is None:
                continue
            if video_done_for_last:
                continue
            if video_task is not None and not video_task.done():
                continue
            # Clear the abort flag just before we launch so stale signals from
            # the previous generation don't carry over.
            video_cancel_event.clear()
            video_task = asyncio.create_task(run_video_generation())

    # Run all loops concurrently
    try:
        await asyncio.gather(receive_loop(), process_loop(), video_loop())
    except Exception as e:
        logger.error("WebSocket error for client %d: %s", client_id, e, exc_info=True)
    finally:
        # Make sure any in-flight video generation stops cleanly.
        video_cancel_event.set()
        if video_task is not None and not video_task.done():
            video_task.cancel()
        elapsed = time.time() - session_start
        fps = frames_processed / elapsed if elapsed > 0 else 0
        logger.info(
            "Client %d disconnected. Received %d, processed %d, dropped %d, "
            "videos %d, %.1f FPS over %.1fs",
            client_id, frames_received, frames_processed, frames_dropped,
            videos_generated, fps, elapsed,
        )


def _process_frame(jpeg_data: bytes, cfg: dict) -> tuple[bytes, Image.Image]:
    """Decode JPEG, run through pipeline, encode result as JPEG.

    Returns the encoded JPEG bytes plus the PIL result so the caller can
    reuse it as a keyframe for subsequent LTXV animation. Runs in a thread
    to avoid blocking the event loop.
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
    return buffer.getvalue(), output


if __name__ == "__main__":
    uvicorn.run(
        "server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
    )
