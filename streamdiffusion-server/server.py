"""StreamDiffusion WebSocket server.

Protocol:
  Client -> Server:
    - Text frame (JSON): { "type": "config", "prompt": "...", "tIndexList": [20, 30], "width": 512, "height": 512 }
    - Binary frame: Raw JPEG bytes of input sketch

  Server -> Client:
    - Text frame (JSON): { "type": "status", "status": "ready" | "warmup" | "error", "message": "..." }
    - Text frame (JSON): { "type": "frame", "data": "<base64 JPEG>" } (generated image)
"""

import asyncio
import io
import json
import logging
import time
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image
from streamdiffusion.image_utils import postprocess_image
from torchvision import transforms

import config
from pipeline import StreamPipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

pipeline = StreamPipeline()

# Image preprocessing: resize + normalize to [0,1] tensor
to_tensor = transforms.Compose([
    transforms.Resize((config.DEFAULT_HEIGHT, config.DEFAULT_WIDTH)),
    transforms.ToTensor(),
])


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the model on startup."""
    logger.info("Starting StreamDiffusion server...")
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
        # Wait for pipeline to be ready
        while not pipeline.ready:
            await asyncio.sleep(0.5)
        await ws.send_text(json.dumps({"type": "status", "status": "ready"}))

    frames_processed = 0
    frames_skipped = 0
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
                        # Handle t_index_list change (reinitializes pipeline)
                        t_index_list = data.get("tIndexList")
                        if t_index_list and isinstance(t_index_list, list):
                            pipeline.reinitialize(t_index_list)

                        pipeline.update_config(prompt=data.get("prompt"))
                        logger.info(
                            "Client %d config: prompt='%s', t_index_list=%s",
                            client_id,
                            str(data.get("prompt", ""))[:50],
                            t_index_list,
                        )
                except json.JSONDecodeError:
                    logger.warning("Client %d sent invalid JSON", client_id)
                continue

            # Binary frame: input image (JPEG)
            if "bytes" in message:
                jpeg_data = message["bytes"]
                try:
                    result_jpeg = await asyncio.to_thread(
                        _process_frame, jpeg_data
                    )

                    if result_jpeg is not None:
                        await ws.send_bytes(result_jpeg)
                        frames_processed += 1
                    else:
                        frames_skipped += 1

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
            "Client %d disconnected. Processed %d frames, skipped %d, %.1f FPS over %.1fs",
            client_id, frames_processed, frames_skipped, fps, elapsed,
        )


def _process_frame(jpeg_data: bytes) -> bytes | None:
    """Decode JPEG, run through pipeline, encode result as JPEG.

    Runs in a thread to avoid blocking the event loop.
    Returns JPEG bytes or None if the frame was skipped.
    """
    # Decode JPEG to PIL
    image = Image.open(io.BytesIO(jpeg_data)).convert("RGB")

    # Convert to tensor [C, H, W] on CUDA
    image_tensor = to_tensor(image).half().cuda()

    # Run through StreamDiffusion
    output_tensor = pipeline.process_frame(image_tensor)

    if output_tensor is None:
        return None

    # Convert output tensor to PIL image
    output_image = postprocess_image(output_tensor, output_type="pil")[0]

    # Encode as JPEG
    buffer = io.BytesIO()
    output_image.save(buffer, format="JPEG", quality=config.OUTPUT_JPEG_QUALITY)
    return buffer.getvalue()


if __name__ == "__main__":
    uvicorn.run(
        "server:app",
        host=config.HOST,
        port=config.PORT,
        log_level="info",
    )
