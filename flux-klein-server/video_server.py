"""LTX-2.3 video pod WebSocket server.

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
import os
import subprocess
import tempfile
import time
from contextlib import asynccontextmanager
from threading import Event

import imageio_ffmpeg
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image

import config
import sentry_init
from video_pipeline import GeneratedAudio, Ltx23VideoPipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

sentry_init.init(pod_kind="video")

video_pipeline = Ltx23VideoPipeline()
# Captures any load() failure so /health can surface it to whoever's polling
# (orchestrator, manual curl). Without this, a load() exception kills the
# FastAPI app before /health responds, the pod crashloops, and the only
# observable signal is "container restarted" — actual Python error never
# escapes the pod's stdout. We trade off "fail loud at boot" for "fail
# observably via /health" because RunPod doesn't expose pod stdout to us.
_load_error_traceback: str | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _load_error_traceback
    logger.info(
        "Starting %s video server: model=%s/%s pipeline=DistilledPipeline "
        "quantization=%s resolution=%dx%d num_frames=%d fps=%d",
        config.LTX_MODEL_FAMILY,
        config.LTX_MODEL_REPO,
        config.LTX_MODEL_FILE,
        config.LTX_QUANTIZATION,
        config.LTX_WIDTH,
        config.LTX_HEIGHT,
        config.LTX_NUM_FRAMES,
        config.LTX_FPS,
    )
    try:
        video_pipeline.load()
    except Exception:
        import traceback
        _load_error_traceback = traceback.format_exc()
        logger.exception("LTX-2.3 pipeline load failed — exposing traceback via /health")
        # Don't re-raise — keep the FastAPI app alive so /health can return
        # the traceback. The pipeline is unusable but observable.
    yield
    # Step 2 — release persistent transformer (and later Gemma/processor) on
    # graceful shutdown. Idempotent inside the pipeline; runs in a thread to
    # avoid blocking the event loop on CUDA cleanup.
    logger.info("Shutting down — releasing persistent models...")
    try:
        await asyncio.to_thread(video_pipeline.shutdown_persistent_models)
    except Exception as e:  # noqa: BLE001
        logger.warning("Error during shutdown_persistent_models: %s", e)
    logger.info("Shutting down.")


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    if _load_error_traceback is not None:
        # Status "error" surfaces the failure to anyone polling /health.
        # The orchestrator's waitForHealth watches for status=="ok" and
        # otherwise keeps polling — but we can curl this URL directly to
        # read the traceback without depending on the orchestrator's loop.
        return {
            "status": "error",
            "load_error": _load_error_traceback,
        }
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
                        cancel: Event,
                        *,
                        req_width: int | None = None,
                        req_height: int | None = None,
                        req_frames: int | None = None,
                        req_profile: bool = False,
                        prompt_suffix: str | None = None) -> None:
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
            result = await asyncio.to_thread(
                video_pipeline.generate, image, prompt, seed, _is_cancelled,
                width=req_width, height=req_height, num_frames=req_frames,
                profile=req_profile, prompt_suffix=prompt_suffix,
            )
        except Exception as e:  # noqa: BLE001
            videos_failed += 1
            logger.error("LTX-2.3 generate error: req=%s err=%s", request_id, e, exc_info=True)
            await ws.send_text(json.dumps({
                "type": "video_cancelled",
                "requestId": request_id,
                "atStep": current_step_count["step"],
                "error": str(e),
            }))
            return

        gen_ms = int((time.time() - t0) * 1000)
        frames = result.frames

        if frames is None:
            # Cancellation — three classes per the perf plan's Step 1:
            #   before_start: ~0ms wasted
            #   during_inference: ≤1 sigma wasted (after Step 5 lands)
            #   after_complete: pipe_total wasted (today's dominant pattern)
            # cancelled_but_ran_ms is the explicit "wasted GPU" metric.
            videos_cancelled += 1
            logger.info(
                "cancelled: req=%s state=%s at_step=%d elapsed_ms=%d "
                "lock_wait_ms=%d pipe_total_ms=%d cancelled_but_ran_ms=%d",
                request_id,
                result.cancel_state,
                current_step_count["step"],
                gen_ms,
                result.lock_wait_ms,
                result.pipe_total_ms,
                result.cancelled_but_ran_ms,
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
            frame.save(buf, format="JPEG", quality=config.LTX_OUTPUT_JPEG_QUALITY)
            await ws.send_text(json.dumps({
                "type": "video_frame",
                "requestId": request_id,
                "index": i,
                "total": len(frames),
            }))
            await ws.send_bytes(buf.getvalue())

            if config.LTX_DEBUG and i % 4 == 0:
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
            mp4_bytes = await asyncio.to_thread(_encode_mp4, frames, config.LTX_FPS, result.audio)
            encode_ms = int((time.time() - encode_t0) * 1000)

            videos_total += 1
            logger.info(
                "complete: req=%s frames=%d gen_ms=%d encode_ms=%d mp4_bytes=%d "
                "audio=%s audio_bytes=%d lock_wait_ms=%d pipe_total_ms=%d",
                request_id, len(frames), gen_ms, encode_ms, len(mp4_bytes),
                result.audio is not None,
                len(result.audio.pcm_s16le) if result.audio is not None else 0,
                result.lock_wait_ms, result.pipe_total_ms,
            )
            await ws.send_text(json.dumps({
                "type": "video_complete",
                "requestId": request_id,
                "fps": config.LTX_FPS,
                "frames": len(frames),
                "genMs": gen_ms,
                "encodeMs": encode_ms,
                "hasAudio": result.audio is not None,
                "audioSampleRate": result.audio.sample_rate if result.audio is not None else None,
                "audioChannels": result.audio.channels if result.audio is not None else None,
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

                # Step 3.5 — Optional per-request shape overrides. None
                # means "use config defaults" (today: 320x320, 49 frames).
                # video_pipeline.generate() applies the defaults; we only
                # type-coerce here.
                req_width = data.get("videoWidth")
                if req_width is not None:
                    try:
                        req_width = int(req_width)
                    except (TypeError, ValueError):
                        req_width = None
                req_height = data.get("videoHeight")
                if req_height is not None:
                    try:
                        req_height = int(req_height)
                    except (TypeError, ValueError):
                        req_height = None
                req_frames = data.get("videoFrames")
                if req_frames is not None:
                    try:
                        req_frames = int(req_frames)
                    except (TypeError, ValueError):
                        req_frames = None

                # Optional per-request torch.profiler capture (iPad
                # SettingsPanel > Diagnostics toggle). Coerce to plain bool
                # so a missing/non-bool field defaults to False.
                req_profile = bool(data.get("enableProfiling") or False)

                req_prompt_suffix = data.get("videoPromptSuffix")
                if req_prompt_suffix is not None and not isinstance(req_prompt_suffix, str):
                    req_prompt_suffix = None

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
                    "video_request: req=%s prompt='%s' suffix='%s' image=%dx%d seed=%s "
                    "videoWidth=%s videoHeight=%s videoFrames=%s profile=%s",
                    request_id, prompt[:60], (req_prompt_suffix or "")[:60],
                    image.width, image.height, seed,
                    req_width, req_height, req_frames, req_profile,
                )
                cancel = Event()
                current_request_id = request_id
                current_cancel = cancel
                current_task = asyncio.create_task(
                    run_video(
                        request_id, image, prompt, seed, cancel,
                        req_width=req_width, req_height=req_height, req_frames=req_frames,
                        req_profile=req_profile, prompt_suffix=req_prompt_suffix,
                    )
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


def _encode_mp4(frames: list[Image.Image], fps: int, audio: GeneratedAudio | None = None) -> bytes:
    """Encode a frame list to H.264/AAC MP4 for iPad playback.

    Writes ffmpeg output to a tempfile rather than piping to stdout. The
    mp4 muxer in ffmpeg 7.x (bundled in imageio-ffmpeg 0.6.0) needs
    seekable output by default to lay out the moov atom — non-seekable
    output (a pipe) fails with "muxer does not support non seekable
    output" even without `-movflags +faststart`. A tempfile is seekable
    and gives AVPlayer the expected non-fragmented MP4 shape.
    """
    if audio is not None and audio.pcm_s16le and audio.channels > 0:
        try:
            return _encode_mp4_with_audio(frames, fps, audio)
        except Exception as e:  # noqa: BLE001
            logger.warning("AAC mux failed; falling back to silent MP4: %s", e, exc_info=True)
    return _encode_silent_mp4(frames, fps)


def _encode_silent_mp4(frames: list[Image.Image], fps: int) -> bytes:
    """Encode a frame list to H.264 MP4 with no audio track."""
    if not frames:
        return b""
    width, height = frames[0].size
    ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()
    with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as tmp:
        out_path = tmp.name
    try:
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
            "-movflags", "+faststart",
            out_path,
        ]
        raw_input = b"".join(f.tobytes() for f in frames)
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            _, err = proc.communicate(input=raw_input, timeout=30)
            if proc.returncode != 0:
                raise RuntimeError(f"ffmpeg failed: rc={proc.returncode} stderr={err.decode('utf-8', 'replace')[:500]}")
        finally:
            if proc.poll() is None:
                proc.kill()
        with open(out_path, "rb") as f:
            return f.read()
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def _encode_mp4_with_audio(frames: list[Image.Image], fps: int, audio: GeneratedAudio) -> bytes:
    """Encode a frame list and interleaved PCM audio to H.264/AAC MP4."""
    if not frames:
        return b""
    width, height = frames[0].size
    ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()
    temp_paths: list[str] = []
    try:
        with tempfile.NamedTemporaryFile(suffix=".rgb", delete=False) as video_tmp:
            video_path = video_tmp.name
            temp_paths.append(video_path)
            video_tmp.write(b"".join(f.tobytes() for f in frames))
        with tempfile.NamedTemporaryFile(suffix=".pcm", delete=False) as audio_tmp:
            audio_path = audio_tmp.name
            temp_paths.append(audio_path)
            audio_tmp.write(_pcm_for_video_duration(audio, len(frames), fps))
        with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as tmp:
            out_path = tmp.name
            temp_paths.append(out_path)

        cmd = [
            ffmpeg_path,
            "-y",
            "-loglevel", "error",
            "-f", "rawvideo",
            "-pix_fmt", "rgb24",
            "-s", f"{width}x{height}",
            "-r", str(fps),
            "-i", video_path,
            "-f", "s16le",
            "-ar", str(audio.sample_rate),
            "-ac", str(audio.channels),
            "-i", audio_path,
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "23",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            out_path,
        ]
        proc = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=45,
            check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"ffmpeg failed: rc={proc.returncode} "
                f"stderr={proc.stderr.decode('utf-8', 'replace')[:500]}"
            )
        with open(out_path, "rb") as f:
            return f.read()
    finally:
        for path in temp_paths:
            try:
                os.unlink(path)
            except OSError:
                pass


def _pcm_for_video_duration(audio: GeneratedAudio, frame_count: int, fps: int) -> bytes:
    """Trim or pad PCM to exactly the MP4 video duration."""
    frame_bytes = max(1, audio.channels) * 2
    expected_samples = max(1, round((frame_count / fps) * audio.sample_rate))
    expected_bytes = expected_samples * frame_bytes
    pcm = audio.pcm_s16le
    aligned_len = len(pcm) - (len(pcm) % frame_bytes)
    if aligned_len != len(pcm):
        pcm = pcm[:aligned_len]
    if len(pcm) < expected_bytes:
        pcm += b"\x00" * (expected_bytes - len(pcm))
    elif len(pcm) > expected_bytes:
        pcm = pcm[:expected_bytes]
    return pcm


if __name__ == "__main__":
    uvicorn.run(
        "video_server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
    )
