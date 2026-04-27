"""LTXV video pod WebSocket server.

Protocol (backend -> pod):
    - Text frame (JSON):
        { "type": "video_request",
          "requestId": "...",
          "image_b64": "<JPEG, base64>",
          "prompt": "...",
          "seed": <int|null> }
    - Text frame (JSON):
        { "type": "video_cancel", "requestId": "..." }

Protocol (pod -> backend):
    - Text frame (JSON): { "type": "status", "status": "ready"|"warmup"|"error", "message": "..." }
    - Per decoded frame: text frame { "type": "video_frame", "requestId": "..." } then binary JPEG.
    - On completion: text frame { "type": "video_complete", "requestId": "...",
                                  "fps": <int>, "frames": <int> } then binary MP4.
    - On cancel: text frame { "type": "video_cancelled", "requestId": "...", "atStep": <int|null> }.

One in-flight generation per connection. A new ``video_request`` cancels
any running generation before starting (defensive — the backend already
serializes via the queueEmpty trigger, but new sketches can interleave).

The pipeline is loaded once at process start (``lifespan``) and shared
across connections via an ``asyncio.Lock`` inside the pipeline class.
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import subprocess
import time
from contextlib import asynccontextmanager
from threading import Event

import imageio_ffmpeg
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image

import config
from video_pipeline import LtxvVideoPipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

video_pipeline = LtxvVideoPipeline()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting LTXV video server...")
    video_pipeline.load()
    yield
    logger.info("Shutting down.")


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    info = video_pipeline.get_info()
    return {"status": "ok" if video_pipeline.ready else "loading", **info}


@app.websocket("/ws")
async def websocket_video(ws: WebSocket):
    await ws.accept()
    client_id = id(ws)
    logger.info("client connected: id=%d", client_id)

    if video_pipeline.ready:
        await ws.send_text(json.dumps({"type": "status", "status": "ready"}))
    else:
        await ws.send_text(json.dumps({"type": "status", "status": "warmup"}))
        while not video_pipeline.ready:
            await asyncio.sleep(0.5)
        await ws.send_text(json.dumps({"type": "status", "status": "ready"}))

    # Per-connection state
    current_task: asyncio.Task | None = None
    current_request_id: str | None = None
    current_cancel: Event | None = None
    current_step_count = {"step": 0}  # mutable so the cb can update it
    videos_total = 0
    videos_cancelled = 0
    videos_failed = 0
    session_start = time.time()

    async def cancel_running(reason: str) -> None:
        nonlocal current_task, current_cancel
        if current_task and not current_task.done():
            logger.info("cancelling in-flight gen: req=%s reason=%s", current_request_id, reason)
            if current_cancel is not None:
                current_cancel.set()
            try:
                await asyncio.wait_for(current_task, timeout=10.0)
            except asyncio.TimeoutError:
                logger.warning("cancel wait timed out (req=%s)", current_request_id)
            except Exception as e:  # noqa: BLE001
                logger.error("cancel task error (req=%s): %s", current_request_id, e)
        current_task = None
        current_cancel = None

    async def run_video(request_id: str, image: Image.Image, prompt: str, seed: int | None,
                        cancel: Event) -> None:
        """Generate video, stream frames, encode MP4. Updates outer counters."""
        nonlocal videos_total, videos_cancelled, videos_failed
        t0 = time.time()
        current_step_count["step"] = 0

        # Step counter via a separate callback hook that runs alongside the
        # cancel check. We can't hand the pipeline two callbacks, so the
        # cancel check inside the pipeline tracks step internally. Wrap
        # is_cancelled to also bump our counter.
        def _is_cancelled() -> bool:
            current_step_count["step"] += 1
            return cancel.is_set()

        try:
            frames = await asyncio.to_thread(
                video_pipeline.generate, image, prompt, seed, _is_cancelled,
            )
        except Exception as e:  # noqa: BLE001
            videos_failed += 1
            logger.error("ltxv generate error: req=%s err=%s", request_id, e, exc_info=True)
            await ws.send_text(json.dumps({
                "type": "video_cancelled",
                "requestId": request_id,
                "atStep": current_step_count["step"],
                "error": str(e),
            }))
            return

        gen_ms = int((time.time() - t0) * 1000)

        if frames is None:
            videos_cancelled += 1
            logger.info(
                "cancelled: req=%s at_step=%d elapsed_ms=%d",
                request_id, current_step_count["step"], gen_ms,
            )
            await ws.send_text(json.dumps({
                "type": "video_cancelled",
                "requestId": request_id,
                "atStep": current_step_count["step"],
            }))
            return

        # Stream each decoded frame as JPEG (text preamble + binary).
        # Tight loop — no awaits between frames except the WS send itself.
        for i, frame in enumerate(frames):
            if cancel.is_set():
                videos_cancelled += 1
                logger.info("cancelled mid-stream: req=%s frame=%d/%d", request_id, i, len(frames))
                await ws.send_text(json.dumps({
                    "type": "video_cancelled",
                    "requestId": request_id,
                    "atStep": current_step_count["step"],
                }))
                return
            buf = io.BytesIO()
            frame.save(buf, format="JPEG", quality=config.LTXV_OUTPUT_JPEG_QUALITY)
            await ws.send_text(json.dumps({
                "type": "video_frame",
                "requestId": request_id,
                "index": i,
                "total": len(frames),
            }))
            await ws.send_bytes(buf.getvalue())

            if config.LTXV_DEBUG and i % 4 == 0:
                logger.info(
                    "frame %d/%d streamed elapsed_ms=%d",
                    i + 1, len(frames), int((time.time() - t0) * 1000),
                )

        # Encode MP4 via the bundled ffmpeg binary. Using a subprocess
        # rather than imageio.mimwrite() because we want explicit control
        # over codec / pixel format / faststart for smooth iOS playback.
        # Wrap encode + send in try/except so a failure here emits
        # video_cancelled (visible to backend + iPad) instead of silently
        # dying — the create_task future has nobody awaiting it.
        try:
            encode_t0 = time.time()
            mp4_bytes = await asyncio.to_thread(_encode_mp4, frames, config.LTXV_FPS)
            encode_ms = int((time.time() - encode_t0) * 1000)

            videos_total += 1
            logger.info(
                "complete: req=%s frames=%d gen_ms=%d encode_ms=%d mp4_bytes=%d",
                request_id, len(frames), gen_ms, encode_ms, len(mp4_bytes),
            )
            await ws.send_text(json.dumps({
                "type": "video_complete",
                "requestId": request_id,
                "fps": config.LTXV_FPS,
                "frames": len(frames),
                "genMs": gen_ms,
                "encodeMs": encode_ms,
            }))
            await ws.send_bytes(mp4_bytes)
        except Exception as e:  # noqa: BLE001
            videos_failed += 1
            logger.error(
                "encode/send failed: req=%s err=%s", request_id, e, exc_info=True,
            )
            try:
                await ws.send_text(json.dumps({
                    "type": "video_cancelled",
                    "requestId": request_id,
                    "atStep": current_step_count["step"],
                    "error": f"encode_or_send_failed: {e}",
                }))
            except Exception:  # noqa: BLE001
                # WS already broken; nothing else to do.
                pass

    try:
        while True:
            msg = await ws.receive()

            if msg.get("type") == "websocket.disconnect":
                break

            if "text" not in msg:
                continue

            try:
                data = json.loads(msg["text"])
            except json.JSONDecodeError:
                logger.warning("invalid JSON")
                continue

            mtype = data.get("type")

            if mtype == "video_request":
                # Cancel any in-flight gen first.
                await cancel_running(reason="superseded")

                request_id = str(data.get("requestId") or "")
                prompt = str(data.get("prompt") or "")
                seed = data.get("seed")
                if seed is not None:
                    try:
                        seed = int(seed)
                    except (TypeError, ValueError):
                        seed = None

                image_b64 = data.get("image_b64") or ""
                try:
                    image_bytes = base64.b64decode(image_b64)
                    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
                except Exception as e:  # noqa: BLE001
                    logger.error("invalid image_b64: req=%s err=%s", request_id, e)
                    await ws.send_text(json.dumps({
                        "type": "video_cancelled",
                        "requestId": request_id,
                        "error": "invalid_image",
                    }))
                    continue

                logger.info(
                    "video_request: req=%s prompt='%s' image=%dx%d seed=%s",
                    request_id, prompt[:60], image.width, image.height, seed,
                )
                cancel = Event()
                current_request_id = request_id
                current_cancel = cancel
                current_task = asyncio.create_task(
                    run_video(request_id, image, prompt, seed, cancel)
                )

            elif mtype == "video_cancel":
                logger.info("video_cancel: req=%s", data.get("requestId"))
                if current_cancel is not None:
                    current_cancel.set()

            else:
                logger.warning("unknown message type: %s", mtype)

    except WebSocketDisconnect:
        logger.info("client disconnected: id=%d", client_id)
    except Exception as e:  # noqa: BLE001
        logger.error("ws handler error: %s", e, exc_info=True)
    finally:
        await cancel_running(reason="ws_close")
        elapsed = time.time() - session_start
        logger.info(
            "session: id=%d videos_total=%d cancelled=%d failed=%d duration_s=%.1f",
            client_id, videos_total, videos_cancelled, videos_failed, elapsed,
        )


def _encode_mp4(frames: list[Image.Image], fps: int) -> bytes:
    """Encode a frame list to H.264 MP4 for iPad playback.

    Pipes raw RGB through the bundled ffmpeg binary — avoids tempfiles and
    works inside the offline pod with no external ffmpeg dependency. NOTE:
    no `-movflags +faststart` — that flag requires seekable output to
    rewrite the moov atom at the front, and ffmpeg 7.x (in imageio-ffmpeg
    0.6.0) refuses with "muxer does not support non seekable output" when
    piping to stdout. Faststart only matters for HTTP streaming anyway;
    we ship the whole MP4 to the iPad in one WS message and play from disk.
    """
    if not frames:
        return b""
    width, height = frames[0].size
    ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [
        ffmpeg_path,
        "-y",
        "-loglevel", "error",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-s", f"{width}x{height}",
        "-r", str(fps),
        "-i", "-",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
        "-f", "mp4",
        "pipe:1",
    ]
    # NOTE: must use communicate(input=...) — sequential stdin-then-stdout
    # deadlocks when ffmpeg's stdout fills the 64 KB pipe buffer (a 100-300 KB
    # MP4 will). communicate() does the IO concurrently via threads.
    raw_input = b"".join(f.tobytes() for f in frames)
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(input=raw_input, timeout=30)
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: rc={proc.returncode} stderr={err.decode('utf-8', 'replace')[:500]}")
        return out
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    uvicorn.run(
        "video_server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
    )
