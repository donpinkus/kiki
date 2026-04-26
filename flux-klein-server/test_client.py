"""Test client for the FLUX.2-klein WebSocket server.

Usage:
    # Single frame
    python test_client.py --image sketch.png --prompt "a cat"

    # Burst mode: send N frames and measure throughput
    python test_client.py --image sketch.png --prompt "a cat" --burst 10

    # With fixed seed for reproducibility
    python test_client.py --image sketch.png --prompt "a cat" --seed 42

    # Connect to remote server
    python test_client.py --url ws://pod-ip:8766/ws --image sketch.png --prompt "a cat"
"""

import argparse
import asyncio
import io
import json
import time

import websockets
from PIL import Image


async def run_test(args):
    print(f"Connecting to {args.url}...")

    async with websockets.connect(args.url, max_size=10 * 1024 * 1024) as ws:
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
            print("Server ready.")

        config = {
            "type": "config",
            "prompt": args.prompt,
            "steps": args.steps,
            "seed": args.seed,
        }

        await ws.send(json.dumps(config))
        print(f"Config sent: prompt='{args.prompt}', steps={args.steps}")

        image = Image.open(args.image).convert("RGB").resize((768, 768))
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=70)
        jpeg_data = buffer.getvalue()
        print(f"Input image: {args.image} ({len(jpeg_data)} bytes)")

        num_frames = args.burst if args.burst else 1
        results_received = 0
        t_start = time.time()

        for i in range(num_frames):
            await ws.send(jpeg_data)

            try:
                # Server sends frame_meta (text) then binary, in that order,
                # for every generated frame.
                meta_msg = await asyncio.wait_for(ws.recv(), timeout=30.0)
                assert isinstance(meta_msg, str), (
                    f"expected frame_meta text before binary, got {type(meta_msg)}"
                )
                meta = json.loads(meta_msg)
                if meta.get("type") == "status" and meta.get("status") == "error":
                    print(f"\nServer error: {meta.get('message')}")
                    continue
                assert meta.get("type") == "frame_meta", f"unexpected: {meta}"
                assert "queueEmpty" in meta, "frame_meta missing queueEmpty"

                response = await asyncio.wait_for(ws.recv(), timeout=30.0)
                assert isinstance(response, bytes), (
                    f"expected binary after frame_meta, got {type(response)}"
                )

                results_received += 1
                size_kb = len(response) / 1024
                elapsed = time.time() - t_start
                fps = results_received / elapsed if elapsed > 0 else 0

                if num_frames == 1:
                    output_path = "output.jpg"
                    with open(output_path, "wb") as f:
                        f.write(response)
                    print(
                        f"Result saved to {output_path} ({size_kb:.1f} KB) "
                        f"queueEmpty={meta['queueEmpty']} reqId={meta.get('requestId')}"
                    )
                    result_img = Image.open(io.BytesIO(response))
                    print(f"Output resolution: {result_img.size}")
                else:
                    print(
                        f"Frame {i+1}/{num_frames}: "
                        f"{size_kb:.1f} KB, {fps:.1f} FPS avg, "
                        f"queueEmpty={meta['queueEmpty']}",
                        end="\r",
                    )

            except asyncio.TimeoutError:
                print(f"\nTimeout waiting for frame {i+1}")

        elapsed = time.time() - t_start
        fps = results_received / elapsed if elapsed > 0 else 0

        print(f"\n\nResults:")
        print(f"  Frames sent:     {num_frames}")
        print(f"  Frames received: {results_received}")
        print(f"  Total time:      {elapsed:.2f}s")
        print(f"  Average FPS:     {fps:.1f}")

        if num_frames > 1 and results_received > 0:
            output_path = "output.jpg"
            with open(output_path, "wb") as f:
                f.write(response)
            print(f"  Last frame saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="FLUX.2-klein test client")
    parser.add_argument("--url", default="ws://localhost:8766/ws", help="WebSocket URL")
    parser.add_argument("--image", required=True, help="Input image path")
    parser.add_argument("--prompt", default="", help="Generation prompt")
    parser.add_argument("--steps", type=int, default=4, help="Number of inference steps")
    parser.add_argument("--seed", type=int, default=None, help="Random seed for reproducibility")
    parser.add_argument("--burst", type=int, default=0, help="Number of frames to send (0=single)")
    args = parser.parse_args()

    asyncio.run(run_test(args))


if __name__ == "__main__":
    main()
