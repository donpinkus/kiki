"""fal Serverless app: FLUX.2-klein realtime img2img — SPIKE.

Validation spike per fal-spike/README.md. Stands up Kiki's image path as a fal
private serverless app so we can measure FPS / latency / cold-start / WS lifetime
on fal before committing to a migration. NOT production; NOT wired to iOS.

Two endpoints, so we can compare both fal realtime mechanisms with the same
resident model:

  /ws        raw WebSocket (@fal.endpoint is_websocket=True). Ports the EXACT
             single-slot frame-drop loop from model-servers/image/server.py, so
             the benchmark exercises our real protocol & buffering. Primary.

  /realtime  fal's msgpack realtime protocol (@fal.realtime). Needed to later
             test the official fal Swift client against a *private* app. Secondary.

Deploy:   fal deploy fal-spike/image/app.py::KikiImageSpike
Local:    fal run   fal-spike/image/app.py::KikiImageSpike
(Requires FAL_KEY in env and weights staged on /data — see scripts/stage_weights.py.)
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import time

import fal
from fastapi import WebSocket, WebSocketDisconnect
from PIL import Image
from pydantic import BaseModel

from generation import (
    OUTPUT_JPEG_QUALITY,
    STEPS,
    FluxKleinPipeline,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("kiki-fal-spike")

# GPU SKU to try. Override with FAL_MACHINE_TYPE for the fallback ladder:
# GPU-RTX5090 (Blackwell/NVFP4, best case) -> GPU-H100 (FP8) -> GPU-A100 (INT8).
# Quant is auto-selected from the actual arch inside generation.py.
MACHINE_TYPE = os.getenv("FAL_MACHINE_TYPE", "GPU-RTX5090")

# Keep a runner warm across brief draw pauses. Spike default high so a benchmark
# reconnect doesn't pay another cold start; tune for cost later.
KEEP_ALIVE = int(os.getenv("FAL_KEEP_ALIVE", "600"))

# Pinned deps mirror model-servers/requirements.txt's image bits. torch is
# provided by fal's base image — do NOT pin it here (same rule as RunPod).
REQUIREMENTS = [
    "diffusers @ git+https://github.com/huggingface/diffusers.git",
    "transformers>=4.52,<5",
    "accelerate>=0.28.0,<2",
    "sentencepiece>=0.2.0",
    "safetensors>=0.4.0",
    "huggingface-hub>=0.25.0",
    "Pillow>=10.0.0",
]


class RealtimeInput(BaseModel):
    """msgpack realtime payload. image_b64 is a base64 JPEG of the sketch."""

    image_b64: str
    prompt: str = ""
    steps: int = STEPS
    seed: int | None = None
    request_id: str | None = None


class RealtimeOutput(BaseModel):
    image_b64: str          # base64 JPEG of the generated frame
    queue_empty: bool       # mirrors the RunPod frame_meta.queueEmpty trigger
    request_id: str | None
    gen_ms: int


def _decode_sketch(jpeg_bytes: bytes) -> Image.Image:
    img = Image.open(io.BytesIO(jpeg_bytes)).convert("RGB")
    # generate_reference re-sizes via the pipeline's WIDTH/HEIGHT; resize here
    # too to match the RunPod server's pre-resize and keep timings comparable.
    return img


def _encode_jpeg(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=OUTPUT_JPEG_QUALITY)
    return buf.getvalue()


class KikiImageSpike(fal.App):
    machine_type = MACHINE_TYPE
    keep_alive = KEEP_ALIVE
    requirements = REQUIREMENTS
    # min_concurrency intentionally unset (0): we WANT to measure cold start.
    # Set FAL_MIN_CONCURRENCY>0 later to test warm-pool masking.

    def setup(self) -> None:
        """Runs once per runner. Loads klein (+ arch-appropriate quant) from /data."""
        # fal auto-points HF_HOME at /data/.cache/huggingface, so from_pretrained
        # reads staged weights off the persistent volume. Log it for the spike record.
        logger.info(
            "setup() start",
            extra={"hf_home": os.environ.get("HF_HOME"), "machine_type": self.machine_type},
        )
        self.pipeline = FluxKleinPipeline()
        self.pipeline.load()
        logger.info("setup() complete", extra=self.pipeline.get_info())

    # ── Raw WebSocket: exact port of the RunPod single-slot frame-drop loop ──
    @fal.endpoint("/ws", is_websocket=True)
    async def stream(self, ws: WebSocket) -> None:
        """Bidirectional img2img stream.

        Protocol (identical to model-servers/image/server.py):
          client -> text JSON  {type:"config", prompt, steps, seed, requestId}
          client -> binary     raw JPEG sketch bytes
          server -> text JSON  {type:"frame_meta", requestId, queueEmpty}
          server -> binary     generated JPEG
        Only the latest input frame is kept; older frames are dropped.
        """
        await ws.accept()
        client_id = id(ws)
        logger.info(f"client {client_id} connected")

        if self.pipeline.ready:
            await ws.send_text(json.dumps({"type": "status", "status": "ready"}))
        else:
            await ws.send_text(json.dumps({"type": "status", "status": "warmup"}))
            while not self.pipeline.ready:
                await asyncio.sleep(0.5)
            await ws.send_text(json.dumps({"type": "status", "status": "ready"}))

        cfg = {"prompt": "", "steps": STEPS, "seed": None, "requestId": None}
        latest_frame: bytes | None = None
        frame_event = asyncio.Event()
        done = False
        frames_received = frames_processed = frames_dropped = 0
        session_start = time.time()

        async def receive_loop():
            nonlocal latest_frame, frames_received, frames_dropped, done, cfg
            try:
                while not done:
                    message = await ws.receive()
                    if message.get("type") == "websocket.disconnect":
                        done = True
                        frame_event.set()
                        break
                    if "text" in message:
                        try:
                            data = json.loads(message["text"])
                            if data.get("type") == "config":
                                if "prompt" in data:
                                    cfg["prompt"] = data["prompt"]
                                if "steps" in data:
                                    cfg["steps"] = max(1, min(50, int(data["steps"])))
                                if data.get("seed") is not None:
                                    cfg["seed"] = int(data["seed"])
                                cfg["requestId"] = data.get("requestId")
                        except json.JSONDecodeError:
                            logger.warning(f"client {client_id} invalid JSON")
                        continue
                    if "bytes" in message:
                        if latest_frame is not None:
                            frames_dropped += 1  # drop older, keep latest
                        latest_frame = message["bytes"]
                        frames_received += 1
                        frame_event.set()
            except WebSocketDisconnect:
                done = True
                frame_event.set()
            except Exception as e:  # noqa: BLE001
                logger.error(f"client {client_id} receive error: {e}")
                done = True
                frame_event.set()

        async def process_loop():
            nonlocal latest_frame, frames_processed, done
            while not done:
                await frame_event.wait()
                frame_event.clear()
                if done:
                    break
                jpeg = latest_frame
                latest_frame = None
                if jpeg is None:
                    continue
                try:
                    snap = dict(cfg)
                    gen_start = time.time()
                    out_jpeg = await asyncio.to_thread(self._process_frame, jpeg, snap)
                    gen_ms = int((time.time() - gen_start) * 1000)
                    if not done:
                        queue_empty = latest_frame is None
                        await ws.send_text(json.dumps({
                            "type": "frame_meta",
                            "requestId": snap.get("requestId"),
                            "queueEmpty": queue_empty,
                        }))
                        await ws.send_bytes(out_jpeg)
                        frames_processed += 1
                        logger.info(
                            f"frame req={snap.get('requestId')} "
                            f"queueEmpty={queue_empty} gen_ms={gen_ms}",
                            extra={"gen_ms": gen_ms, "queue_empty": queue_empty},
                        )
                except Exception as e:  # noqa: BLE001
                    logger.error(f"frame error: {e}", exc_info=True)
                    if not done:
                        try:
                            await ws.send_text(json.dumps(
                                {"type": "status", "status": "error", "message": str(e)}
                            ))
                        except Exception:
                            pass

        try:
            await asyncio.gather(receive_loop(), process_loop())
        finally:
            elapsed = time.time() - session_start
            fps = frames_processed / elapsed if elapsed > 0 else 0
            logger.info(
                f"client {client_id} disconnected: recv={frames_received} "
                f"proc={frames_processed} dropped={frames_dropped} "
                f"{fps:.2f} FPS over {elapsed:.1f}s",
                extra={
                    "frames_received": frames_received,
                    "frames_processed": frames_processed,
                    "frames_dropped": frames_dropped,
                    "fps": round(fps, 2),
                    "duration_s": round(elapsed, 1),
                },
            )

    def _process_frame(self, jpeg: bytes, cfg: dict) -> bytes:
        img = _decode_sketch(jpeg)
        out = self.pipeline.generate_reference(
            image=img,
            prompt=cfg.get("prompt", ""),
            steps=cfg.get("steps", STEPS),
            seed=cfg.get("seed"),
        )
        return _encode_jpeg(out)

    # ── fal msgpack realtime: same model, fal's protocol/clients ─────────────
    @fal.realtime("/realtime")
    def realtime(self, input: RealtimeInput) -> RealtimeOutput:
        """One generation per inbound msgpack frame.

        fal owns the connection/serialization; frame coalescing is governed by
        the client's throttleInterval (whose latest-wins semantics are an open
        question — see README). No server-side single-slot buffer here, which is
        exactly why /ws exists for the apples-to-apples comparison.
        """
        gen_start = time.time()
        jpeg = base64.b64decode(input.image_b64)
        out = self._process_frame(
            jpeg,
            {"prompt": input.prompt, "steps": input.steps, "seed": input.seed},
        )
        return RealtimeOutput(
            image_b64=base64.b64encode(out).decode("ascii"),
            queue_empty=True,
            request_id=input.request_id,
            gen_ms=int((time.time() - gen_start) * 1000),
        )


if __name__ == "__main__":
    # `python app.py` won't serve — use `fal run app.py::KikiImageSpike`.
    print("Deploy with: fal deploy fal-spike/image/app.py::KikiImageSpike")
    print("Local test:  fal run   fal-spike/image/app.py::KikiImageSpike")
