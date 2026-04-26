"""Test client for the LTXV video pod WebSocket server.

Usage:
    python test_video_client.py --url ws://localhost:8766/ws --image still.jpg --prompt "a cat dancing"

Asserts the wire protocol matches video_server.py: receives frame_meta-style
status, then a sequence of (video_frame text + JPEG binary) pairs, then
(video_complete text + MP4 binary). Saves the MP4 + last frame for
visual inspection.
"""
import argparse
import asyncio
import base64
import io
import json
import time

import websockets
from PIL import Image


async def run_test(args):
    print(f"Connecting to {args.url}...")

    async with websockets.connect(args.url, max_size=50 * 1024 * 1024) as ws:
        # Initial status
        msg = await ws.recv()
        status = json.loads(msg)
        print(f"Server status: {status}")
        if status.get("status") != "ready":
            print("Waiting for server to be ready...")
            while True:
                msg = await ws.recv()
                status = json.loads(msg)
                if status.get("status") == "ready":
                    break

        # Build a video_request
        image = Image.open(args.image).convert("RGB")
        buf = io.BytesIO()
        image.save(buf, format="JPEG", quality=85)
        image_b64 = base64.b64encode(buf.getvalue()).decode("ascii")

        request_id = f"test-{int(time.time())}"
        await ws.send(json.dumps({
            "type": "video_request",
            "requestId": request_id,
            "image_b64": image_b64,
            "prompt": args.prompt,
            "seed": args.seed,
        }))
        print(f"Sent video_request: req={request_id}, prompt='{args.prompt}', image={image.size}")

        frames_received = 0
        last_frame_jpeg = None
        mp4_bytes = None
        t_start = time.time()

        while True:
            msg = await asyncio.wait_for(ws.recv(), timeout=120.0)
            if isinstance(msg, str):
                meta = json.loads(msg)
                t = meta.get("type")
                if t == "video_frame":
                    # Next message is the JPEG binary
                    binary = await ws.recv()
                    assert isinstance(binary, (bytes, bytearray)), f"expected bytes, got {type(binary)}"
                    frames_received += 1
                    last_frame_jpeg = bytes(binary)
                    print(f"  frame {meta.get('index')}/{meta.get('total')}: {len(binary)} bytes "
                          f"(elapsed {time.time() - t_start:.1f}s)")
                elif t == "video_complete":
                    binary = await ws.recv()
                    assert isinstance(binary, (bytes, bytearray)), f"expected MP4 bytes, got {type(binary)}"
                    mp4_bytes = bytes(binary)
                    print(f"  video_complete: frames={meta.get('frames')} fps={meta.get('fps')} "
                          f"genMs={meta.get('genMs')} encodeMs={meta.get('encodeMs')} "
                          f"mp4_bytes={len(mp4_bytes)}")
                    break
                elif t == "video_cancelled":
                    print(f"  video_cancelled: atStep={meta.get('atStep')} error={meta.get('error')}")
                    break
                else:
                    print(f"  unexpected: {meta}")
            else:
                print(f"  unexpected binary (no preceding text): {len(msg)} bytes")

    elapsed = time.time() - t_start
    print(f"\nResults:")
    print(f"  Frames received: {frames_received}")
    print(f"  Total time:      {elapsed:.2f}s")

    if last_frame_jpeg:
        with open("video_last_frame.jpg", "wb") as f:
            f.write(last_frame_jpeg)
        print(f"  Last frame -> video_last_frame.jpg ({len(last_frame_jpeg)} bytes)")
    if mp4_bytes:
        with open("output.mp4", "wb") as f:
            f.write(mp4_bytes)
        print(f"  MP4         -> output.mp4 ({len(mp4_bytes)} bytes)")


def main():
    parser = argparse.ArgumentParser(description="LTXV video pod test client")
    parser.add_argument("--url", default="ws://localhost:8766/ws")
    parser.add_argument("--image", required=True, help="Input still image (JPEG/PNG)")
    parser.add_argument("--prompt", default="a still scene", help="Animation prompt")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    asyncio.run(run_test(args))


if __name__ == "__main__":
    main()
